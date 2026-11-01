"""Loopback tests for pbzcoop_net.py (stdlib only): python -I net/test_pbzcoop_net.py

The C++ relay (native/, tools/build-native.ps1) speaks the same packets and files. To test it, set
PBZCOOP_NATIVE_RELAY to native/build/relay_cli.exe: the relay processes these tests start then run on it, for the roles
in PBZCOOP_NATIVE_ROLES (default "host,client"; one role alone tests C++ against Python), and NativeRelay runs too.
"""

import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(HERE, "pbzcoop_net.py")
PORT = 47911
NATIVE = os.environ.get("PBZCOOP_NATIVE_RELAY")
NATIVE_ROLES = os.environ.get("PBZCOOP_NATIVE_ROLES", "host,client").split(",")


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def wait_for(pred, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def event_lines(path):
    return [line for line in read(path).splitlines() if line and line[0].isdigit()]


class RelayLoopback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.a = os.path.join(self.tmp.name, "a")
        self.b = os.path.join(self.tmp.name, "b")
        os.makedirs(self.a)
        os.makedirs(self.b)
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            p.kill()
            p.wait()
        self.tmp.cleanup()

    def start(self, *args):
        command = [NATIVE] if NATIVE and args[0] in NATIVE_ROLES else [sys.executable, "-I", RELAY]
        p = subprocess.Popen([*command, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def test_snapshot_and_events_both_ways(self):
        write(os.path.join(self.a, "net_out.txt"), "P 1 10.0 20.0 30.0 90.0 0 0\nE Mob_1 1 2 3 4 50 100 1\n")
        write(os.path.join(self.b, "net_out.txt"), "P 7 -1.0 -2.0 -3.0 0.0 0 0\n")
        write(os.path.join(self.a, "net_events_out.txt"), "S 111\n1 A attack1\n2 K Mob_1\n")
        write(os.path.join(self.b, "net_events_out.txt"), "S 222\n1 D Mob_1 25\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))

        b_in = os.path.join(self.b, "net_in.txt")
        a_in = os.path.join(self.a, "net_in.txt")
        self.assertTrue(wait_for(lambda: "E Mob_1" in read(b_in)), "host snapshot never reached client")
        self.assertTrue(wait_for(lambda: read(a_in).startswith("P 7")), "client snapshot never reached host")

        b_ev = os.path.join(self.b, "net_events_in.txt")
        a_ev = os.path.join(self.a, "net_events_in.txt")
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 2))
        self.assertEqual(event_lines(b_ev), ["1 A attack1", "2 K Mob_1"])
        self.assertTrue(wait_for(lambda: event_lines(a_ev) == ["1 D Mob_1 25"]))

        # New events append once each, even though the relay resends until acknowledged.
        write(os.path.join(self.a, "net_events_out.txt"), "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n")
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 3))
        time.sleep(0.5)
        self.assertEqual(event_lines(b_ev), ["1 A attack1", "2 K Mob_1", "3 I Chest_2"])

        # The host's mod restarts: a new session starts a fresh inbox, old events are not replayed.
        write(os.path.join(self.a, "net_events_out.txt"), "S 333\n1 A attack2\n")
        self.assertTrue(wait_for(lambda: read(b_ev).startswith("S 333")))
        self.assertTrue(wait_for(lambda: event_lines(b_ev) == ["1 A attack2"]))

    def test_receiving_relay_restart_resends_events(self):
        a_out = os.path.join(self.a, "net_events_out.txt")
        b_ev = os.path.join(self.b, "net_events_in.txt")
        write(os.path.join(self.a, "net_out.txt"), "P 1 0 0 0 0 0 0\n")
        write(a_out, "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n")
        self.start("host", "--dir", self.a, "--port", str(PORT))
        client = self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        self.assertTrue(wait_for(lambda: len(event_lines(b_ev)) == 3))

        # The client's relay restarts mid-session: its inbox starts over and acks 0, which is lower than the 3 the
        # host already had. The host must take it and resend, or event 4 would never be accepted.
        client.kill()
        client.wait()
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT))
        write(a_out, "S 111\n1 A attack1\n2 K Mob_1\n3 I Chest_2\n4 C 50\n")
        # The host only switches to the new client port once the old one was silent for PEER_TIMEOUT (3 s).
        self.assertTrue(wait_for(lambda: event_lines(b_ev) == ["1 A attack1", "2 K Mob_1", "3 I Chest_2", "4 C 50"],
                                 timeout=12.0), read(b_ev))

    def test_echo_shifts_player_only_and_echoes_events(self):
        write(os.path.join(self.a, "net_out.txt"), "P 5 100.0 0.0 0.0 0.0 0 0\nE Mob_1 1.0 2 3 4 50 100 1\n")
        write(os.path.join(self.a, "net_events_out.txt"), "S 9\n1 A attack1\n")
        self.start("echo", "--dir", self.a)
        a_in = os.path.join(self.a, "net_in.txt")
        self.assertTrue(wait_for(lambda: read(a_in).startswith("P 5 400.0")), read(a_in))
        self.assertIn("E Mob_1 1.0 2 3 4 50 100 1", read(a_in))
        self.assertTrue(wait_for(lambda: event_lines(os.path.join(self.a, "net_events_in.txt")) == ["1 A attack1"]))


def load_relay_module():
    # -I leaves this folder off sys.path, so import the relay by file path.
    import importlib.util
    spec = importlib.util.spec_from_file_location("pbzcoop_net", RELAY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FileReading(unittest.TestCase):
    def test_read_text_tolerates_invalid_utf8(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_out.txt")
            with open(path, "wb") as f:
                f.write(b"P 1 0 0 0 0 0 0 Map\xff\xfe\nE Mob_\xc3 1 2 3 4 50 100 0\n")
            text = relay.read_text(path)
            self.assertTrue(text.startswith("P 1 0 0 0 0 0 0 Map"))
            self.assertIn("E Mob_", text)

    def test_heartbeat_caught_mid_write_is_not_a_closed_game(self):
        # The mod truncates the heartbeat file, then writes the time. Reading in between used to stop the relay
        # while the game ran (seen in the two-copy test: the guest's relay quit 15 s after co-op came on).
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_alive.txt")
            for text in ("", " \n"):
                with open(path, "w") as f:
                    f.write(text)
                self.assertTrue(relay.game_alive(path, 30))
            self.assertTrue(relay.game_alive(os.path.join(tmp, "missing.txt"), 30))
            with open(path, "w") as f:
                f.write(str(int(time.time())))
            self.assertTrue(relay.game_alive(path, 30))
            with open(path, "w") as f:
                f.write(str(int(time.time()) - 60))
            self.assertFalse(relay.game_alive(path, 30))

    def test_failed_writes_never_crash_and_lose_no_events(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_events_in.txt")
            real_replace, real_open = relay.os.replace, open

            def refuse(*_):
                raise OSError(1450, "Insufficient system resources exist to complete the requested service")
            relay.os.replace = refuse
            try:
                self.assertFalse(relay.write_atomic(os.path.join(tmp, "net_in.txt"), "P 1\n"))
            finally:
                relay.os.replace = real_replace

            inbox = relay.EventInbox(path)
            self.assertEqual(inbox.accept("s1", [(1, "1 A x")]), 1)
            relay.append_lines = lambda *_: False          # the disk refuses this time
            self.assertEqual(inbox.accept("s1", [(2, "2 K y")]), 1, "a failed write must not be acknowledged")
            del relay.append_lines                          # back to the module function
            relay.append_lines = load_relay_module().append_lines
            self.assertEqual(inbox.accept("s1", [(2, "2 K y")]), 2)
            self.assertEqual(event_lines(path), ["1 A x", "2 K y"])

    def test_partial_last_event_line_is_held_back(self):
        relay = load_relay_module()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "net_events_out.txt")
            write(path, "S 1\n1 A attack1\n2 D Mob_1 2")
            session, events = relay.parse_events(relay.read_complete_lines(path))
            self.assertEqual(session, "1")
            self.assertEqual(events, [(1, "1 A attack1")])


class RecordReplay(unittest.TestCase):
    def test_recorded_host_replays_to_a_client(self):
        with tempfile.TemporaryDirectory() as tmp:
            host, client = os.path.join(tmp, "host"), os.path.join(tmp, "client")
            os.makedirs(host)
            os.makedirs(client)
            rec = os.path.join(tmp, "host.jsonl")
            write(os.path.join(host, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\nE sp:Boss 1 2 3 0 2900 2900 1 1120 BP_X_C\n")
            write(os.path.join(host, "net_events_out.txt"), "S h1\n1 B sp:Boss\n")
            p = subprocess.Popen([sys.executable, "-I", RELAY, "record", "--dir", host, "--file", rec,
                                  "--seconds", "1.5"], stdout=subprocess.DEVNULL)
            time.sleep(0.6)
            write(os.path.join(host, "net_out.txt"), "P 2 50 0 0 0 0 850 850 M\nE sp:Boss 1 2 3 0 1000 2900 1 0 BP_X_C\n")
            write(os.path.join(host, "net_events_out.txt"), "S h1\n1 B sp:Boss\n2 K sp:Boss\n")
            p.wait(10)

            write(os.path.join(client, "net_events_out.txt"), "S c1\n1 D sp:Boss 80.0 10.0\n")
            log = os.path.join(tmp, "client.txt")
            q = subprocess.Popen([sys.executable, "-I", RELAY, "replay", "--dir", client, "--file", rec,
                                  "--client-log", log], stdout=subprocess.DEVNULL)
            q.wait(10)
            self.assertIn("E sp:Boss 1 2 3 0 1000 2900 1 0 BP_X_C", read(os.path.join(client, "net_in.txt")))
            self.assertEqual(event_lines(os.path.join(client, "net_events_in.txt")), ["1 B sp:Boss", "2 K sp:Boss"])
            self.assertIn("1 D sp:Boss 80.0 10.0", read(log))


class FakeSteamNet:
    """Stands in for Steam's P2P network: messages addressed by SteamID64, delivered in memory."""

    def __init__(self):
        self.inbox = {}

    def link(self, my_id, friends_in_game, peer=None):
        self.inbox.setdefault(my_id, [])
        return FakeSteamLink(self, my_id, friends_in_game, peer)


class FakeSteamLink:
    """The relay's link interface (as SteamLink): send/receive by SteamID64, friends hosting as candidates."""

    def __init__(self, net, my_id, friends_in_game, peer):
        self.net, self.my_id, self.friends, self.peer = net, my_id, friends_in_game, peer

    def send(self, addr, data):
        self.net.inbox.setdefault(addr, []).append((self.my_id, data))

    def receive(self):
        out, self.net.inbox[self.my_id] = self.net.inbox[self.my_id], []
        return out

    def wait(self, seconds):
        time.sleep(min(seconds, 0.002))
        return True

    def candidates(self):
        return list(self.friends)

    def describe(self, addr):
        return f"friend{addr}"

    def describe_self(self):
        return f"Steam as {self.my_id}"


class SteamRelayLogic(unittest.TestCase):
    """The relay over a Steam-style link (everything but Valve's network itself, which needs two accounts)."""

    HOST, GUEST, OTHER = 76561190000000001, 76561190000000002, 76561190000000003

    def run_relays(self, relays, seconds=1.5):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for r in relays:
                r.tick(time.monotonic())
            time.sleep(0.01)

    def folders(self, tmp, *names):
        out = []
        for n in names:
            d = os.path.join(tmp, n)
            os.makedirs(d)
            out.append(d)
        return out

    def test_guest_finds_the_hosting_friend_and_both_directions_flow(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, gd = self.folders(tmp, "host", "guest")
            write(os.path.join(hd, "net_out.txt"), "P 1 10 20 30 0 0 850 850 M\nE sp:Boss 1 2 3 0 2900 2900 1 1120 BP_X_C\n")
            write(os.path.join(hd, "net_events_out.txt"), "S h1\n1 B sp:Boss\n2 K sp:Thug\n")
            write(os.path.join(gd, "net_out.txt"), "P 1 11 21 31 0 0 850 850 M\n")
            write(os.path.join(gd, "net_events_out.txt"), "S g1\n1 D sp:Boss 80.0 10.0 L\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, [self.GUEST]))
            # The guest has two friends in the game; only the host answers pings, so it pins the host.
            guest = relay.Relay("client", gd, None, 0, net.link(self.GUEST, [self.OTHER, self.HOST]))
            self.run_relays([host, guest])
            self.assertEqual(guest.peer, self.HOST)
            self.assertEqual(host.peer, self.GUEST)
            self.assertIn("E sp:Boss", read(os.path.join(gd, "net_in.txt")))
            self.assertIn("P 1 11 21 31", read(os.path.join(hd, "net_in.txt")))
            self.assertEqual(event_lines(os.path.join(gd, "net_events_in.txt")), ["1 B sp:Boss", "2 K sp:Thug"])
            self.assertEqual(event_lines(os.path.join(hd, "net_events_in.txt")), ["1 D sp:Boss 80.0 10.0 L"])

    def test_two_guests_never_pin_each_other_and_the_host_keeps_its_first(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, g1d, g2d = self.folders(tmp, "host", "g1", "g2")
            for d in (hd, g1d, g2d):
                write(os.path.join(d, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, [self.GUEST, self.OTHER]))
            g1 = relay.Relay("client", g1d, None, 0, net.link(self.GUEST, [self.OTHER, self.HOST]))
            self.run_relays([host, g1], 0.6)
            g2 = relay.Relay("client", g2d, None, 0, net.link(self.OTHER, [self.GUEST, self.HOST]))
            self.run_relays([host, g1, g2], 1.5)
            self.assertEqual(g1.peer, self.HOST)
            self.assertEqual(host.peer, self.GUEST)    # pinned to the first guest while it keeps talking
            self.assertNotEqual(g2.peer, self.GUEST)   # a guest never answers another guest's pings
            self.assertIsNone(g2.peer)                 # the busy host doesn't take a second guest

    def test_guest_given_a_steamid_talks_only_to_it(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, gd = self.folders(tmp, "host", "guest")
            write(os.path.join(hd, "net_out.txt"), "P 7 1 2 3 0 0 850 850 M\n")
            write(os.path.join(gd, "net_out.txt"), "P 1 0 0 0 0 0 850 850 M\n")
            host = relay.Relay("host", hd, None, 0, net.link(self.HOST, []))
            guest = relay.Relay("client", gd, None, 0, net.link(self.GUEST, [], peer=self.HOST))
            self.run_relays([host, guest])
            self.assertEqual(guest.peer, self.HOST)
            self.assertIn("P 7 1 2 3", read(os.path.join(gd, "net_in.txt")))


class Security(unittest.TestCase):
    """Optional Secret, sender filter and the crashes a single bad packet used to cause (review of PR #2)."""

    def test_signed_packets_open_and_bad_ones_are_refused(self):
        relay = load_relay_module()
        host, guest = relay.Auth("hunter2-but-longer", "host"), relay.Auth("hunter2-but-longer", "client")
        p = host.seal(b'{"t":"state"}')
        self.assertEqual(guest.open(p), b'{"t":"state"}')
        self.assertIsNone(guest.open(p), "a replayed packet was accepted")
        tampered = bytearray(host.seal(b'{"t":"state","s":"P 1"}'))
        tampered[30] ^= 1
        self.assertIsNone(guest.open(bytes(tampered)), "a tampered packet was accepted")
        self.assertIsNone(host.open(host.seal(b"x")), "a packet bounced back at its sender was accepted")
        other_host = relay.Auth("hunter2-but-longer", "host")
        self.assertIsNone(host.open(other_host.seal(b"x")), "a packet from the same role was accepted")
        self.assertIsNone(relay.Auth("other secret", "client").open(host.seal(b"x")), "wrong secret accepted")
        self.assertIsNone(guest.open(b'{"t":"state"}'), "an unsigned packet was accepted with a secret set")
        # Old enough to be outside the window: refused even though nothing from that session was seen.
        stale = relay.Auth("hunter2-but-longer", "host")
        real_time = relay.time.time
        relay.time.time = lambda: real_time() - relay.Auth.REPLAY_WINDOW_S - 5
        old = stale.seal(b"x")
        relay.time.time = real_time
        self.assertIsNone(guest.open(old), "a packet from minutes ago was accepted")

    def test_partner_addresses_only_by_default(self):
        relay = load_relay_module()
        for ip in ("100.101.102.103", "192.168.1.20", "10.0.0.5", "172.20.1.1", "127.0.0.1", "25.1.2.3", "26.9.9.9"):
            self.assertTrue(relay.address_allowed(ip, "partner"), ip)
        for ip in ("8.8.8.8", "203.0.113.7", "not-an-ip"):
            self.assertFalse(relay.address_allowed(ip, "partner"), ip)
        self.assertTrue(relay.address_allowed("8.8.8.8", "any"))

    def test_one_bad_packet_no_longer_kills_the_relay(self):
        relay = load_relay_module()
        self.assertEqual(relay.parse_events("S 1\n² K x\n" + "9" * 5000 + " K y\n1 K ok\n")[1], [(1, "1 K ok")])
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            r = relay.Relay("host", tmp, None, 0, net.link(1, []))
            net.inbox[1].append((2, b'{"v":2,"t":"pong","ts":' + b"9" * 400 + b"}"))
            net.inbox[1].append((2, b'{"v":2,"t":"pong","ts":true}'))
            r.receive_all(time.monotonic())          # must not raise
            self.assertIsNone(r.rtt_ms)

    def test_host_does_not_pin_to_a_state_packet_before_handshake(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            host = relay.Relay("host", tmp, None, 0, net.link(1, []))
            net.inbox[1].append((2, json_bytes({"v": relay.PROTOCOL, "t": "state", "s": "P 1 0 0 0 0 0 850 850 M\n"})))
            host.receive_all(time.monotonic())
            self.assertIsNone(host.peer, "a stale state packet pinned the host")
            net.inbox[1].append((2, json_bytes({"v": relay.PROTOCOL, "t": "ping", "ts": time.monotonic()})))
            host.receive_all(time.monotonic())
            self.assertEqual(host.peer, 2)

    def test_settings_mismatch_is_reported_and_values_are_cleaned(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            hd, gd = os.path.join(tmp, "h"), os.path.join(tmp, "g")
            os.makedirs(hd)
            os.makedirs(gd)
            host = relay.Relay("host", hd, None, 0, net.link(1, [2]),
                               settings={"coopenemyhealth": "150", "pvp": "Off"}, version="1.3.0")
            guest = relay.Relay("client", gd, None, 0, net.link(2, [1], peer=1),
                                settings={"coopenemyhealth": "200", "pvp": "off"}, version="1.3.0")
            for _ in range(30):
                host.tick(time.monotonic())
                guest.tick(time.monotonic())
                time.sleep(0.01)
            self.assertEqual(host.mismatch, ["coopenemyhealth"])
            self.assertIn("mismatch=coopenemyhealth", host.status(time.monotonic()))
            self.assertEqual(host.partner_version, "1.3.0")
            # A partner's values can't inject keys or lines into net_status.txt.
            net.inbox[1].append((2, json_bytes({"v": 2, "t": "hello", "ver": "1 time=999\nconnected=yes",
                                                "cfg": {"pvp": "on connected=yes"}})))
            host.receive_all(time.monotonic())
            status = host.status(time.monotonic())
            self.assertEqual(status.count("connected="), 1)
            self.assertNotIn("\n", status)
            self.assertNotIn("time=999", status)

    def test_snapshot_goes_out_as_soon_as_the_mod_writes_it(self):
        relay = load_relay_module()
        net = FakeSteamNet()
        with tempfile.TemporaryDirectory() as tmp:
            r = relay.Relay("client", tmp, None, 0, net.link(2, [], peer=1))
            r.wait(0.02)                             # takes the current files as already sent
            net.inbox[1] = []
            write(os.path.join(tmp, "net_out.txt"), "P 5 1 2 3 0 0 850 850 M\n")
            r.wait(0.05)                             # no tick() in between: only the file watch can send it
            sent = [d for _, d in net.inbox.get(1, []) if b"P 5 1 2 3" in d]
            self.assertTrue(sent, "the new snapshot wasn't sent before the next tick")


def json_bytes(obj):
    import json
    return json.dumps(obj).encode()


class SecretLoopback(RelayLoopback):
    """Two real relay processes with a Secret in each player's PhantomPact.ini."""

    def start_pair(self, host_secret, guest_secret):
        write(os.path.join(self.a, "PhantomPact.ini"), f"Role = Host\nSecret = {host_secret}\n")
        write(os.path.join(self.b, "PhantomPact.ini"), f"Role = Guest\nSecret = {guest_secret}\n")
        write(os.path.join(self.a, "net_out.txt"), "P 1 10.0 20.0 30.0 90.0 0 0\n")
        write(os.path.join(self.b, "net_out.txt"), "P 7 -1.0 -2.0 -3.0 0.0 0 0\n")
        self.start("host", "--dir", self.a, "--port", str(PORT + 3), "--ini", os.path.join(self.a, "PhantomPact.ini"))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(PORT + 3),
                   "--ini", os.path.join(self.b, "PhantomPact.ini"))

    def test_same_secret_connects(self):
        self.start_pair("correct horse battery", "correct horse battery")
        self.assertTrue(wait_for(lambda: read(os.path.join(self.b, "net_in.txt")).startswith("P 1")))
        self.assertTrue(wait_for(lambda: "auth=on" in read(os.path.join(self.a, "net_status.txt"))))

    def test_different_secrets_never_connect(self):
        self.start_pair("correct horse battery", "something else")
        self.assertTrue(wait_for(lambda: "rejected=" in read(os.path.join(self.a, "net_status.txt"))
                                 and "rejected=0 " not in read(os.path.join(self.a, "net_status.txt"))))
        self.assertEqual(read(os.path.join(self.b, "net_in.txt")), "")

    def test_allow_any_address_from_the_ini(self):
        relay = load_relay_module()
        seen, real = [], relay.Relay
        relay.Relay = lambda *a, **k: (seen.append(k.get("allow")), real(*a, **k))[1]
        for value, expected in (("On", "any"), ("Off", "partner")):
            ini = os.path.join(self.a, "PhantomPact.ini")
            write(ini, f"Role = Host\nAllowAnyAddress = {value}\n")
            argv = sys.argv
            sys.argv = ["pbzcoop_net.py", "host", "--dir", self.a, "--ini", ini, "--seconds", "0.2",
                        "--port", "47920"]
            try:
                relay.main()
            finally:
                sys.argv = argv
            self.assertEqual(seen[-1], expected, value)

    # The plain loopback tests don't apply to this class.
    test_snapshot_and_events_both_ways = None
    test_receiving_relay_restart_resends_events = None
    test_echo_shifts_player_only_and_echoes_events = None


@unittest.skipUnless(NATIVE, "PBZCOOP_NATIVE_RELAY isn't set")
class NativeRelay(RelayLoopback):
    """What the C++ relay has to get right by itself: it's hand-written parsing of untrusted packets, in the game."""

    def test_bad_packets_dont_stop_it_and_the_partner_still_connects(self):
        import socket
        port = PORT + 4
        write(os.path.join(self.a, "net_out.txt"), "P 1 10.0 20.0 30.0 90.0 0 0\n")
        write(os.path.join(self.b, "net_out.txt"), "P 7 0 0 0 0 0 0\n")
        host = self.start("host", "--dir", self.a, "--port", str(port))
        time.sleep(0.3)
        bad = [
            b"", b"\xff" * 100, b"{", b"[" * 60000, b'{"a":' * 10000, b'"' + b"\\" * 30000, b"PPA1", b"PPA1" + b"x" * 80,
            b"null", b"[]", b"12", b'{"v":3,"t":"ping"}', b'{"t":"ping"}', b'{"v":2}', b'{"v":2,"t":5}',
            b'{"v":2,"t":"ping","ts":"x"}', b'{"v":2,"t":"ping","ts":1e999}', b'{"v":2,"t":"pong","ts":' + b"9" * 400 + b"}",
            b'{"v":2,"t":"pong","ts":true}', b'{"v":2,"t":"state","s":123,"e":{"sid":5,"l":3}}',
            b'{"v":2,"t":"state","e":{"sid":"x","l":[1,null,"99999999999999999999 x","\\ud83d","1 ok"]}}',
            b'{"v":2,"t":"ack","sid":"x","id":1e400}', b'{"v":2,"t":"ack","sid":"x","id":' + b"9" * 400 + b"}",
            b'{"v":2,"t":"hello","ver":{"a":1},"cfg":{"pvp":1}}', b'{"v":2,"t":"hello","cfg":[]}',
        ]
        bad += [b'{"v":2,"t":"ack","sid":"s%d","id":1}' % i for i in range(100)]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            for packet in bad:
                s.sendto(packet, ("127.0.0.1", port))
            time.sleep(0.5)
        self.assertIsNone(host.poll(), "bad packets stopped the relay")
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(port))
        # The fake sender was taken as the partner: it has to go silent for PEER_TIMEOUT first.
        self.assertTrue(wait_for(lambda: read(os.path.join(self.b, "net_in.txt")).startswith("P 1"), timeout=10.0))
        self.assertTrue(wait_for(lambda: read(os.path.join(self.a, "net_in.txt")).startswith("P 7"), timeout=10.0))
        self.assertIsNone(host.poll())

    def test_crlf_and_bad_utf8_from_the_mod_arrive_clean(self):
        port = PORT + 5
        with open(os.path.join(self.a, "net_out.txt"), "wb") as f:
            f.write(b"P 1 0 0 0 0 0 0 Map\xff\r\nE Mob \xe4\xb8\xad 1\r\n")
        with open(os.path.join(self.a, "net_events_out.txt"), "wb") as f:
            f.write(b"S 5\r\n1 A attack\r\n2 K half")      # the last line is still being written
        self.start("host", "--dir", self.a, "--port", str(port))
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(port))
        b_in = os.path.join(self.b, "net_in.txt")
        self.assertTrue(wait_for(lambda: "Mob" in read(b_in)), read(b_in))
        text = read(b_in)
        self.assertNotIn("\r", text)
        self.assertIn("Map�\n", text)
        self.assertIn("Mob 中 1\n", text)
        b_ev = os.path.join(self.b, "net_events_in.txt")
        self.assertTrue(wait_for(lambda: event_lines(b_ev) == ["1 A attack"]), read(b_ev))
        time.sleep(0.3)
        self.assertEqual(event_lines(b_ev), ["1 A attack"])

    def test_settings_handshake_and_versions(self):
        port = PORT + 6
        write(os.path.join(self.a, "PhantomPact.ini"), "Role = Host\nPvP = On\nCoopEnemyHealth = 150\n")
        write(os.path.join(self.b, "PhantomPact.ini"), "Role = Guest\nPvP = Off\nCoopEnemyHealth = 150\n")
        self.start("host", "--dir", self.a, "--port", str(port), "--ini", os.path.join(self.a, "PhantomPact.ini"),
                   "--mod-version", "1.4.0")
        self.start("client", "--dir", self.b, "--peer", "127.0.0.1", "--port", str(port),
                   "--ini", os.path.join(self.b, "PhantomPact.ini"), "--mod-version", "1.3.1")
        a_status = os.path.join(self.a, "net_status.txt")
        self.assertTrue(wait_for(lambda: "mismatch=pvp " in read(a_status), timeout=8.0), read(a_status))
        self.assertIn("connected=yes", read(a_status))
        self.assertIn("version=1.4.0 partner_version=1.3.1", read(a_status))

    def test_stops_on_a_stale_heartbeat_but_not_on_an_empty_one(self):
        alive = os.path.join(self.a, "net_alive.txt")
        write(alive, str(int(time.time())))
        p = self.start("host", "--dir", self.a, "--port", str(PORT + 7), "--alive-file", alive, "--alive-timeout", "2")
        time.sleep(0.5)
        write(alive, "")                       # the mod truncates, then writes
        time.sleep(3)
        self.assertIsNone(p.poll(), "an empty heartbeat file stopped the relay")
        write(alive, str(int(time.time()) - 60))
        self.assertTrue(wait_for(lambda: p.poll() is not None))
        self.assertIn("stopped=yes", read(os.path.join(self.a, "net_status.txt")))

    @unittest.skipUnless("host" in NATIVE_ROLES, "the Python relay reports this as a Python error instead")
    def test_a_port_in_use_is_reported(self):
        import socket
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            s.bind(("0.0.0.0", PORT + 8))
            p = self.start("host", "--dir", self.a, "--port", str(PORT + 8))
            self.assertTrue(wait_for(lambda: p.poll() is not None))
        self.assertIn("couldn't use UDP port", read(os.path.join(self.a, "relay_error.txt")))

    # The plain loopback tests already ran on it through start().
    test_snapshot_and_events_both_ways = None
    test_receiving_relay_restart_resends_events = None
    test_echo_shifts_player_only_and_echoes_events = None


if __name__ == "__main__":
    unittest.main(verbosity=2)
