"""PBZCoop network relay: carries game state between two PCs over UDP (designed for Tailscale IPs).

The game mod and this relay talk through small text files in the mod folder:
  net_out.txt         written by the mod: the local snapshot, several lines (player "P ...", enemies "E ...")
  net_in.txt          written by the relay: the remote side's latest snapshot
  net_events_out.txt  written by the mod: "S <session>" then one numbered event per line ("<id> <type> <args>")
  net_events_in.txt   written by the relay: the remote side's events, in order, same format
  net_status.txt      written by the relay: connection state, peer address, round-trip time

Snapshots are newest-wins: a lost packet is simply replaced by the next one 50 ms later.
Events (attacks, kills, pickups) are reliable: resent every tick until the peer acknowledges them.
The relay doesn't interpret either; only echo mode shifts the "P" line so the fake friend stands aside.

Usage:
  host:   python -I pbzcoop_net.py host   --dir <mod folder>
  client: python -I pbzcoop_net.py client --dir <mod folder> --peer 100.112.4.45
  echo:   python -I pbzcoop_net.py echo   --dir <mod folder>
          (no network: plays your own snapshot and events back, 3 m to the side and 0.3 s late, as a fake
          friend for solo testing)
  record: python -I pbzcoop_net.py record --dir <mod folder> --file host.jsonl       (mod as host)
  replay: python -I pbzcoop_net.py replay --dir <mod folder> --file host.jsonl --client-log client.txt
          (mod as client, ideally in a fresh game session: a recorded real host plays against the client)
"""

import collections

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
import re
import struct
import select
import socket
import time

PORT = 47800
TICK = 0.05          # 20 sends per second
WATCH = 0.005        # how often the mod's files are checked for something new to send at once
PING_EVERY = 1.0
PEER_TIMEOUT = 3.0
PROTOCOL = 2
MAX_EVENTS_PER_PACKET = 40
MAX_SNAPSHOT_BYTES = 48000


def read_text(path):
    # errors="replace": a stray non-UTF-8 byte (e.g. a half-written multibyte name) must not kill the relay.
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def read_complete_lines(path):
    """read_text, minus a last line the mod is still writing (no newline yet): it is sent once it's complete."""
    text = read_text(path)
    return text[:text.rfind("\n") + 1]


def write_atomic(path, text):
    """Returns False if the file couldn't be written this time; the next tick writes fresh data anyway."""
    tmp = path + ".tmp"
    # The mod may have the file open for a moment, and Windows can briefly refuse a rename for other reasons
    # (WinError 1450 "insufficient system resources" killed a relay mid-session): retry, then skip, never crash.
    for attempt in range(5):
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, path)
            return True
        except OSError:
            time.sleep(0.002 * (attempt + 1))
    return False


def append_lines(path, lines):
    """Returns False if the lines couldn't be appended (the caller keeps them and retries next time)."""
    for attempt in range(5):
        try:
            with open(path, "a", encoding="utf-8") as f:
                f.write("".join(line + "\n" for line in lines))
            return True
        except OSError:
            time.sleep(0.002 * (attempt + 1))
    return False


def parse_events(text):
    """Return (session, [(id, line), ...]) from an events file."""
    session, events = None, []
    for line in text.splitlines():
        parts = line.split(" ", 1)
        if not parts or not parts[0]:
            continue
        if parts[0] == "S" and len(parts) == 2:
            session = parts[1].strip()
        elif parts[0].isascii() and parts[0].isdigit() and len(parts[0]) <= 12:
            # (isdigit() alone also takes "²" and 5000-digit strings, which int() refuses: one bad line from the
            # peer would kill the relay.)
            events.append((int(parts[0]), line))
    return session, events


class EventInbox:
    """Writes the peer's events to net_events_in.txt exactly once each, in order."""

    def __init__(self, path):
        self.path = path
        self.session = None
        self.last_id = 0

    def accept(self, session, events):
        if session != self.session:
            # The peer restarted its mod: start a fresh file so old events aren't replayed.
            if not write_atomic(self.path, f"S {session}\n"):
                return self.last_id if self.session == session else 0
            self.session = session
            self.last_id = 0
        fresh, last = [], self.last_id
        for eid, line in sorted(events):
            if eid == last + 1:
                fresh.append(line)
                last = eid
        # Only acknowledged once written: if the write fails the peer keeps resending them.
        if fresh and append_lines(self.path, fresh):
            self.last_id = last
        return self.last_id


# Where a partner can be: Tailscale (100.64.0.0/10), home networks, this PC, and the Hamachi (25/8) and Radmin
# (26/8) VPN ranges. The host takes packets only from these by default ("--allow any" lifts it): before, anyone
# the firewall let through could take the partner's place or inject events. (Raised by appdoze, PR #2.)
PARTNER_NETWORKS = [ipaddress.ip_network(n) for n in (
    "100.64.0.0/10", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
    "25.0.0.0/8", "26.0.0.0/8")]
MAX_PACKETS_PER_RECEIVE = 256   # a flood can't keep the relay reading forever (ticks and status would stall)


def address_allowed(ip, allow):
    if allow == "any":
        return True
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in PARTNER_NETWORKS)


class Auth:
    """Optional shared secret (Secret = ... in PhantomPact.ini, the same on both PCs): every packet is signed.

    packet = MAGIC | role (1) | session (8) | counter (8) | time ms (8) | payload | HMAC-SHA256 (32)

    A relay refuses packets that are unsigned, wrongly signed, from its own role or own session (a packet bounced
    back at its sender), older or newer than REPLAY_WINDOW_S, or not newer than the last one from that session
    (replays). The key is stretched with scrypt, so one captured packet doesn't make guessing a typed secret cheap.
    (Signing, the session counter and refusing downgrades are from appdoze's PR #2; the role/own-session check, the
    time window and scrypt are fixes from reviewing it.)
    """

    MAGIC = b"PPA1"
    HEADER = struct.Struct(">c8sQQ")
    TAG = 32
    REPLAY_WINDOW_S = 120.0
    SESSIONS_KEPT = 8

    def __init__(self, secret, role):
        master = hashlib.scrypt(secret.encode("utf-8"), salt=b"PhantomPact/relay/1", n=2 ** 14, r=8, p=1, dklen=32)
        self.key = hmac.new(master, b"packet-mac", hashlib.sha256).digest()
        self.role = b"H" if role == "host" else b"C"
        self.session = os.urandom(8)
        self.counter = 0
        self.last_seen = collections.OrderedDict()   # session -> highest counter accepted

    def seal(self, payload):
        self.counter += 1
        head = self.MAGIC + self.HEADER.pack(self.role, self.session, self.counter, int(time.time() * 1000))
        body = head + payload
        return body + hmac.new(self.key, body, hashlib.sha256).digest()

    def open(self, data):
        """The payload of a valid packet from the other side, or None."""
        n = len(self.MAGIC) + self.HEADER.size
        if len(data) < n + self.TAG or not data.startswith(self.MAGIC):
            return None
        body, tag = data[:-self.TAG], data[-self.TAG:]
        if not hmac.compare_digest(tag, hmac.new(self.key, body, hashlib.sha256).digest()):
            return None
        role, session, counter, sent_ms = self.HEADER.unpack(body[len(self.MAGIC):n])
        if role == self.role or session == self.session:
            return None
        if abs(time.time() * 1000 - sent_ms) > self.REPLAY_WINDOW_S * 1000:
            return None
        if counter <= self.last_seen.get(session, 0):
            return None
        self.last_seen[session] = counter
        self.last_seen.move_to_end(session)
        while len(self.last_seen) > self.SESSIONS_KEPT:
            self.last_seen.popitem(last=False)
        return body[n:]


# Settings both players should share; each relay reads them from its own PhantomPact.ini and tells the other.
SHARED_SETTINGS = ("coopenemyhealth", "coopenemyposture", "pvp", "pvpdamage", "pvpparryposture", "connect")
HELLO_EVERY = 2.0


def read_ini(path):
    """Key (lowercase) -> value from PhantomPact.ini; ';' and '#' start comments. {} if there's no file."""
    out = {}
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line or line[0] in ";#" or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip().lower()] = value.strip()
    return out


def clean_token(value, limit=32):
    """A peer-sent value made safe for the space-separated status line (no spaces, newlines or '=')."""
    return re.sub(r"[^\w.\-]", "", str(value))[:limit] or "?"


class UdpLink:
    """Plain UDP (Tailscale or LAN IPs). Peers are (ip, port) tuples."""

    def __init__(self, role, peer, port, allow="partner"):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sock.bind(("0.0.0.0", port if role == "host" else 0))
        self.allow = allow
        self.filtered = 0
        # Resolved once (a Tailscale name works too): replies are matched against this exact address.
        self.peer = (socket.gethostbyname(peer), port) if role != "host" else None

    def send(self, addr, data):
        self.sock.sendto(data, addr)

    def receive(self):
        out = []
        for _ in range(MAX_PACKETS_PER_RECEIVE):
            try:
                data, addr = self.sock.recvfrom(65535)
            except BlockingIOError:
                break
            except ConnectionResetError:
                # Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                continue
            if self.peer is not None and addr != self.peer:
                self.filtered += 1      # a client listens to its host's exact address and port only
            elif self.peer is None and not address_allowed(addr[0], self.allow):
                self.filtered += 1
            else:
                out.append((addr, data))
        return out

    def wait(self, seconds):
        """True once a packet is waiting (or False when the time ran out)."""
        return bool(select.select([self.sock], [], [], seconds)[0])

    def candidates(self):
        return []

    def describe(self, addr):
        return f"{addr[0]}:{addr[1]}"

    def describe_self(self):
        return f"UDP {self.sock.getsockname()[1]}"


class SteamLink:
    """Steam P2P through the game's steam_api64.dll. Peers are SteamID64s; only Steam friends are accepted.

    A guest with no host given finds one by pinging every Steam friend who is in Phantom Blade Zero: only a
    Phantom Pact host answers, and the first answer pins it.
    """

    FRIENDS_REFRESH = 5.0

    def __init__(self, role, peer, folder):
        # Loaded by path: the relay runs with python -I, which leaves its own folder off sys.path.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "steam_transport", os.path.join(os.path.dirname(os.path.abspath(__file__)), "steam_transport.py"))
        steam_transport = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(steam_transport)
        dll = steam_transport.find_steam_api(folder)
        if dll is None:
            raise SystemExit("Steam mode: steam_api64.dll not found above " + folder)
        self.st = steam_transport.SteamTransport(dll)
        self.peer = None
        self.wanted = None                # a friend name to look for, case-insensitive
        if role != "host" and peer:
            if peer.isdigit() and len(peer) == 17:
                self.peer = int(peer)
            else:
                self.wanted = peer.strip().lower()
        self._friends, self._friends_at = [], -1e9

    def send(self, addr, data):
        self.st.send(addr, data)

    def receive(self):
        return self.st.receive()

    def wait(self, seconds):
        # Steam has no socket to select on: poll every few ms, cheap next to the 50 ms tick.
        time.sleep(min(seconds, 0.005))
        return True

    def candidates(self):
        now = time.monotonic()
        if now - self._friends_at >= self.FRIENDS_REFRESH:
            self._friends_at = now
            self._friends = [fid for fid, name in self.st.friends_in_game()
                             if self.wanted is None or name.strip().lower() == self.wanted]
        return self._friends

    def describe(self, addr):
        return f"{self.st.friend_name(addr) or addr}"

    def describe_self(self):
        return f"Steam as {self.st.my_name}"


class Relay:
    def __init__(self, role, folder, peer, port, link=None, allow="partner", secret=None, settings=None,
                 version="?"):
        self.role = role
        self.out_path = os.path.join(folder, "net_out.txt")
        self.in_path = os.path.join(folder, "net_in.txt")
        self.events_out_path = os.path.join(folder, "net_events_out.txt")
        self.status_path = os.path.join(folder, "net_status.txt")
        self.inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
        self.link = link or UdpLink(role, peer, port, allow)
        self.auth = Auth(secret, role) if secret else None
        self.rejected = 0                 # packets refused by the secret check (forged, replayed, or no/other secret)
        self.settings = {k: str(v).lower() for k, v in (settings or {}).items() if k in SHARED_SETTINGS}
        self.version = clean_token(version)
        self.partner_version = None
        self.mismatch = []
        self.last_hello = 0.0
        self.out_signature = None         # (mtime, size) of the mod's files when last sent
        self.peer = self.link.peer        # host: learned from the first packet; Steam guest: maybe found later
        self.last_heard = 0.0
        self.rtt_ms = None
        self.last_ping = 0.0
        self.received = 0
        self.sent = 0
        self.acked = {}                   # our session -> highest event id the peer confirmed
        self.events_acked = 0
        self.in_blanked = False           # net_in.txt emptied because the peer went silent

    def send(self, msg, to=None):
        to = to if to is not None else self.peer
        if to is None:
            return
        msg["v"] = PROTOCOL
        data = json.dumps(msg, separators=(",", ":")).encode()
        if self.auth:
            data = self.auth.seal(data)
        try:
            self.link.send(to, data)
            self.sent += 1
        except OSError:
            pass

    def receive_all(self, now):
        for addr, data in self.link.receive():
            # Checked before anything else (before a host takes a sender as its partner): with a secret only
            # validly signed packets count; without one, signed packets mean the partner set a secret we don't have.
            if self.auth:
                data = self.auth.open(data)
                if data is None:
                    self.rejected += 1
                    continue
            elif data.startswith(Auth.MAGIC):
                self.rejected += 1
                continue
            try:
                msg = json.loads(data)
            except (ValueError, RecursionError):
                continue            # (RecursionError: one packet of 60000 "[" used to kill the relay)
            if not isinstance(msg, dict) or msg.get("v") != PROTOCOL:
                continue
            kind = msg.get("t")
            if self.role == "host" and self.peer != addr:
                # A host must not pin to a stale state packet. A candidate has to prove it is a live relay
                # first; the next state packet then uses the address already pinned by ping/hello.
                if kind not in ("ping", "hello"):
                    continue
                # Pinned to the first live peer: another sender is only taken once the current one went silent.
                if self.peer is not None and now - self.last_heard <= PEER_TIMEOUT:
                    continue
                self.peer = addr
                print(f"peer connected: {self.link.describe(addr)}", flush=True)
            elif self.role != "host" and self.peer != addr:
                # A guest still looking for its host pins the first friend that answers a ping; it never
                # answers other guests' pings itself.
                if self.peer is not None or msg.get("t") != "pong":
                    continue
                self.peer = addr
                print(f"found the host: {self.link.describe(addr)}", flush=True)
            self.last_heard = now
            self.received += 1
            kind = msg.get("t")
            if kind == "ping":
                self.send({"t": "pong", "ts": msg.get("ts")})
            elif kind == "pong" and isinstance(msg.get("ts"), (int, float)) and not isinstance(msg["ts"], bool) \
                    and abs(msg["ts"]) < 1e12:
                # (A 400-digit JSON integer here raised OverflowError and killed the relay.)
                self.rtt_ms = (now - msg["ts"]) * 1000.0
            elif kind == "state":
                if isinstance(msg.get("s"), str):
                    write_atomic(self.in_path, msg["s"])
                    self.in_blanked = False
                ev = msg.get("e")
                if isinstance(ev, dict) and isinstance(ev.get("sid"), str) and isinstance(ev.get("l"), list):
                    lines = [line for line in ev["l"] if isinstance(line, str)]
                    _, events = parse_events("\n".join(lines))
                    last = self.inbox.accept(ev["sid"], events)
                    self.send({"t": "ack", "sid": ev["sid"], "id": last})
            elif kind == "ack" and isinstance(msg.get("sid"), str) and isinstance(msg.get("id"), int):
                # Taken as is, even when lower: a restarted peer relay starts its inbox over and acks 0, and
                # only then do we resend the events it lost.
                self.acked[msg["sid"]] = msg["id"]
            elif kind == "hello" and isinstance(msg.get("cfg"), dict):
                self.partner_version = clean_token(msg.get("ver"))
                theirs = {k: clean_token(v).lower() for k, v in msg["cfg"].items() if k in SHARED_SETTINGS}
                self.mismatch = sorted(k for k in self.settings if k in theirs and theirs[k] != self.settings[k])

    def _out_signature(self):
        sig = []
        for path in (self.out_path, self.events_out_path):
            try:
                st = os.stat(path)
                sig.append((st.st_mtime_ns, st.st_size))
            except OSError:
                sig.append(None)
        return tuple(sig)

    def wait(self, seconds):
        """Sleep until the next tick, but handle incoming packets the moment they arrive, and send the mod's
        snapshot or events the moment it writes them (checked every WATCH s) instead of on the next tick."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            if self.link.wait(min(remaining, WATCH)):
                self.receive_all(time.monotonic())
            sig = self._out_signature()
            if sig != self.out_signature:
                self.out_signature = sig
                self.send_state()

    def tick(self, now):
        self.receive_all(now)
        if self.peer is not None and self.last_heard > 0 and now - self.last_heard > PEER_TIMEOUT:
            if not self.in_blanked:
                # The peer is gone: don't leave its last snapshot for the mod to keep applying.
                write_atomic(self.in_path, "")
                self.in_blanked = True
        if now - self.last_ping >= PING_EVERY:
            if self.peer is None and self.role != "host":
                for friend in self.link.candidates():
                    self.send({"t": "ping", "ts": now}, to=friend)
            else:
                self.send({"t": "ping", "ts": now})
            self.last_ping = now
        if self.peer is not None and now - self.last_hello >= HELLO_EVERY:
            self.send({"t": "hello", "ver": self.version, "cfg": self.settings})
            self.last_hello = now
        # Resent every tick even if unchanged, so a dropped packet heals itself (wait() also sends on change).
        self.send_state()

    def send_state(self):
        msg = {"t": "state"}
        snapshot = read_text(self.out_path)
        if snapshot.strip():
            msg["s"] = snapshot[:MAX_SNAPSHOT_BYTES]
        session, events = parse_events(read_complete_lines(self.events_out_path))
        if session is not None:
            acked = self.acked.get(session, 0)
            pending = [line for eid, line in events if eid > acked][:MAX_EVENTS_PER_PACKET]
            # Always include the session (even with nothing pending) so the peer's inbox follows restarts.
            msg["e"] = {"sid": session, "l": pending}
            self.events_acked = acked
        if len(msg) > 1:
            self.send(msg)

    def status(self, now):
        connected = self.peer is not None and now - self.last_heard <= PEER_TIMEOUT
        peer = self.link.describe(self.peer).replace(" ", "_") if self.peer else "-"
        rtt = f"{self.rtt_ms:.0f}" if self.rtt_ms is not None else "-"
        # time= (wall clock) lets the mod tell a running relay from a stale status file before starting another.
        via = "steam" if isinstance(self.link, SteamLink) else "udp"
        return (f"role={self.role} via={via} connected={'yes' if connected else 'no'} peer={peer} "
                f"rtt_ms={rtt} sent={self.sent} received={self.received} "
                f"filtered={getattr(self.link, 'filtered', 0)} rejected={self.rejected} "
                f"auth={'on' if self.auth else 'off'} version={self.version} "
                f"partner_version={self.partner_version or '-'} mismatch={','.join(self.mismatch) or '-'} "
                f"events_acked={self.events_acked} events_in={self.inbox.last_id} time={int(time.time())}")


ECHO_OFFSET_X = 300.0   # cm
ECHO_DELAY = 0.3        # s


def shift_player_line(snapshot, dx):
    """Echo mode: move the "P seq x y z ..." line dx cm along X so the fake friend stands aside."""
    out = []
    for line in snapshot.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0] == "P":
            try:
                parts[2] = f"{float(parts[2]) + dx:.1f}"
            except ValueError:
                pass
            line = " ".join(parts)
        out.append(line)
    return "\n".join(out) + "\n"


def run_echo(folder, seconds):
    """Solo test: feed our own snapshot and events back as the remote player's, shifted and delayed."""
    out_path = os.path.join(folder, "net_out.txt")
    in_path = os.path.join(folder, "net_in.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
    history = collections.deque()
    start = time.monotonic()
    last_status = 0.0
    echoed = 0
    print(f"PBZCoop relay echo, files in {folder}", flush=True)
    try:
        while not (seconds and time.monotonic() - start >= seconds):
            now = time.monotonic()
            snapshot = read_text(out_path)
            session, events = parse_events(read_complete_lines(events_out_path))
            history.append((now, snapshot, session, events))
            while history and now - history[0][0] >= ECHO_DELAY:
                _, snap, sess, evs = history.popleft()
                if snap.strip():
                    write_atomic(in_path, shift_player_line(snap, ECHO_OFFSET_X))
                    echoed += 1
                if sess is not None:
                    inbox.accept(sess, evs)
            if now - last_status >= 1.0:
                line = (f"role=echo connected=yes peer=self rtt_ms={ECHO_DELAY * 1000:.0f} echoed={echoed} "
                        f"events_in={inbox.last_id}")
                write_atomic(status_path, line + "\n")
                print(line, flush=True)
                last_status = now
            time.sleep(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        write_atomic(status_path, "role=echo connected=no stopped=yes\n")


def run_record(folder, path, seconds):
    """Solo two-PC stand-in, part 1: log what this side sends (snapshot changes and new events) with timing.

    Run the mod as host while recording; replay the file later against a client (a fresh game session, so
    runtime names differ just as they would on a second PC)."""
    out_path = os.path.join(folder, "net_out.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    start = time.monotonic()
    last_snapshot, sent_ids, lines, last_status = None, {}, 0, 0.0
    print(f"PBZCoop relay record -> {path}", flush=True)
    with open(path, "w", encoding="utf-8") as rec:
        try:
            while not (seconds and time.monotonic() - start >= seconds):
                now = time.monotonic()
                entry = {"t": round(now - start, 3)}
                snapshot = read_text(out_path)
                if snapshot.strip() and snapshot != last_snapshot:
                    entry["s"] = snapshot
                    last_snapshot = snapshot
                session, events = parse_events(read_complete_lines(events_out_path))
                if session is not None:
                    done = sent_ids.get(session, 0)
                    fresh = [line for eid, line in events if eid > done]
                    if fresh or session not in sent_ids:
                        entry["e"] = {"sid": session, "l": fresh}
                        sent_ids[session] = max([done] + [eid for eid, _ in events])
                if len(entry) > 1:
                    rec.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    lines += 1
                if now - last_status >= 1.0:
                    line = f"role=record connected=yes peer=file recorded={lines}"
                    write_atomic(status_path, line + "\n")
                    print(line, flush=True)
                    last_status = now
                time.sleep(TICK)
        except KeyboardInterrupt:
            pass
    write_atomic(status_path, "role=record connected=no stopped=yes\n")


def run_replay(folder, path, seconds, client_log):
    """Solo two-PC stand-in, part 2: feed a recorded host session to this side (run the mod as client), on the
    recorded timing, and log every event the client sends back."""
    in_path = os.path.join(folder, "net_in.txt")
    events_out_path = os.path.join(folder, "net_events_out.txt")
    status_path = os.path.join(folder, "net_status.txt")
    inbox = EventInbox(os.path.join(folder, "net_events_in.txt"))
    with open(path, "r", encoding="utf-8") as f:
        entries = [json.loads(line) for line in f if line.strip()]
    start = time.monotonic()
    i, last_status, client_seen = 0, 0.0, {}
    print(f"PBZCoop relay replay <- {path} ({len(entries)} entries)", flush=True)
    log = open(client_log, "w", encoding="utf-8") if client_log else None
    try:
        while i < len(entries) or (seconds and time.monotonic() - start < seconds):
            now = time.monotonic() - start
            if seconds and now >= seconds:
                break
            while i < len(entries) and entries[i]["t"] <= now:
                entry = entries[i]
                if "s" in entry:
                    write_atomic(in_path, entry["s"])
                if "e" in entry:
                    _, events = parse_events("\n".join(entry["e"]["l"]))
                    inbox.accept(entry["e"]["sid"], events)
                i += 1
            if log:
                session, events = parse_events(read_complete_lines(events_out_path))
                if session is not None:
                    done = client_seen.get(session, 0)
                    for eid, line in events:
                        if eid > done:
                            log.write(f"{now:.2f} {line}\n")
                            log.flush()
                    client_seen[session] = max([done] + [eid for eid, _ in events])
            if time.monotonic() - start - last_status >= 1.0:
                line = f"role=replay connected=yes peer=file played={i}/{len(entries)} events_in={inbox.last_id}"
                write_atomic(status_path, line + "\n")
                print(line, flush=True)
                last_status = time.monotonic() - start
            time.sleep(TICK)
    except KeyboardInterrupt:
        pass
    finally:
        if log:
            log.close()
        write_atomic(status_path, "role=replay connected=no stopped=yes\n")


ALIVE_TIMEOUT = 30.0     # s without a heartbeat from the mod before a relay the mod started gives up


def fine_timer(on):
    """Windows sleeps in ~15.6 ms steps by default, too coarse for WATCH: ask for 1 ms while the relay runs."""
    if os.name != "nt":
        return
    try:
        import ctypes
        winmm = ctypes.WinDLL("winmm")
        (winmm.timeBeginPeriod if on else winmm.timeEndPeriod)(1)
    except (OSError, AttributeError):
        pass


def game_alive(path, timeout):
    """The mod rewrites its heartbeat file (a unix time) every few seconds while the game runs."""
    # The mod truncates the file, then writes: an empty or unreadable file is a write in progress, not a stop.
    # Read as 0 it used to look 56 years stale, and the relay quit while the game was still running.
    try:
        beat = float(read_text(path).strip())
    except ValueError:
        return True       # caught mid-write
    return time.time() - beat <= timeout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("role", choices=["host", "client", "echo", "record", "replay"])
    ap.add_argument("--file", help="record/replay: the recording (JSON lines)")
    ap.add_argument("--client-log", help="replay: write the events the client sends back to this file")
    ap.add_argument("--dir", required=True, help="the PBZCoop mod folder (where cmd.txt lives)")
    ap.add_argument("--peer", help="client only: the host's Tailscale IP (udp); with --transport steam, the host's "
                                   "Steam name or SteamID64, or nothing to find any friend hosting in the game")
    ap.add_argument("--transport", choices=["udp", "steam"], default="udp")
    ap.add_argument("--allow", choices=["partner", "any"], default="partner",
                    help="host over UDP: take packets only from Tailscale, home-network and Hamachi/Radmin addresses "
                         "(partner, default) or from anywhere (any)")
    ap.add_argument("--ini", help="the player's PhantomPact.ini: Secret (optional, same on both PCs) and the settings "
                                  "both players should share are read from it (the secret stays off the command line)")
    ap.add_argument("--mod-version", default="?", help="the mod's version, told to the partner")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = run until Ctrl+C)")
    ap.add_argument("--alive-file", help="stop once this file (the mod's heartbeat: a unix time) is older than "
                                         "--alive-timeout, i.e. the game was closed")
    ap.add_argument("--alive-timeout", type=float, default=ALIVE_TIMEOUT)
    args = ap.parse_args()
    if args.role == "client" and args.transport == "udp" and not args.peer:
        ap.error("client needs --peer <host IP>")
    os.makedirs(args.dir, exist_ok=True)
    if args.role == "echo":
        run_echo(args.dir, args.seconds)
        return
    if args.role in ("record", "replay"):
        if not args.file:
            ap.error(f"{args.role} needs --file <recording>")
        if args.role == "record":
            run_record(args.dir, args.file, args.seconds)
        else:
            run_replay(args.dir, args.file, args.seconds, args.client_log)
        return

    ini = read_ini(args.ini) if args.ini else {}
    if ini.get("allowanyaddress", "off").lower() in ("on", "yes", "true", "1"):
        # A virtual LAN with unusual addresses (UU Accelerator's multiplayer, ZeroTier...): the player opened it.
        args.allow = "any"
    secret = ini.get("secret", "")
    if secret.upper().startswith("PUT-") or secret.lower() in ("", "off", "none"):
        secret = None
    link = SteamLink(args.role, args.peer, args.dir) if args.transport == "steam" else None
    relay = Relay(args.role, args.dir, args.peer, args.port, link, allow=args.allow, secret=secret,
                  settings=ini, version=args.mod_version)
    print(f"PBZCoop relay {args.role} on {relay.link.describe_self()}, files in {args.dir}"
          f"{', packets signed (Secret set)' if secret else ''}", flush=True)
    fine_timer(True)
    start = time.monotonic()
    last_status = 0.0
    try:
        while True:
            now = time.monotonic()
            relay.tick(now)
            if now - last_status >= 1.0:
                line = relay.status(now)
                write_atomic(relay.status_path, line + "\n")
                print(line, flush=True)
                last_status = now
            if args.seconds and now - start >= args.seconds:
                break
            if args.alive_file and not game_alive(args.alive_file, args.alive_timeout):
                print("the game's heartbeat stopped: game closed, relay exiting", flush=True)
                break
            relay.wait(TICK)
    except KeyboardInterrupt:
        pass
    except Exception:
        # Started with pythonw there's no console, so a crash would leave no trace: keep it next to the status.
        import traceback
        write_atomic(os.path.join(args.dir, "relay_error.txt"), traceback.format_exc())
        raise
    finally:
        fine_timer(False)
        write_atomic(relay.status_path, f"role={args.role} connected=no stopped=yes\n")


if __name__ == "__main__":
    main()
