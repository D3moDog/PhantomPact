# Who decides what

Phantom Pact runs two full copies of the single-player game, one per PC. Nothing is shared by default: each game
simulates its own world. The mod then decides, per system, whose copy is the truth and what crosses the network.
The rule of thumb: **sync outcomes, not inputs and not every variable.** A hit is sent as "this much damage",
a kill as "this enemy died", never as raw animation state or per-frame values that the other game already
simulates on its own.

Host = the player whose world is shared (Role = Host). Client = the guest.

## The map

| System | Decided by | Runs where | Crosses the network as | Runs once because |
|---|---|---|---|---|
| Your own player: movement, stamina, healing, items used | **That player** | own PC | snapshot `P` (position, facing, speed, health), 20x/s, newest wins | the other side only steers a ghost toward it, never simulates it |
| Your own hits taken, your death | **That player** | own PC | health in `P`; hit reactions as `H` | the ghost is cosmetic: kept at full health on the host, its health shown, never killed |
| Moves (attacks, dodges, guard) | **That player** | own PC | `M <ability>` and `U <montage> <position>` for a move | The receiver briefly buffers each `M`; a successful same-family `U` consumes only one matching fallback. Missing or unmatched montages leave the ability replay available. |
| Enemy position, health, posture | **Host** | host simulates; client mirrors | snapshot `E` lines from the host, for enemies within 60 m of either player (so a client fighting far from the host still fights the host's enemy) | the client only ever lowers its copy to the host's numbers (or follows a heal the host keeps for 1 s) |
| Enemy AI (which attack it throws) | each world | both | not synced | each world's enemy fights the players in it; outcomes (health, death) are the host's |
| Client hits on enemies | **Client detects, host applies** | client measures its copy's drop, host applies it | reliable `D <enemy> <hp> <posture>` | event ids are acked and played once; a drop caused by the ghost's replay is undone, not reported |
| Enemy death | **Host** | host | reliable `K <enemy>` | the client's copies of host enemies are held at 1 health (Health_Min) so they can't die on their own; a client hit that reaches that floor is sent as lethal (`D ... L`) and the host kills; only `K` kills the copy, once, even if it loads later |
| Enemy spawning | each world's own level | both | not synced (both load the same level) | the mod never spawns enemies; matching pairs the two copies (spawner id, else class + position) |
| Boss fight start | **whoever starts it** | both | `B <boss>` | the receiving side shows the bar and closes the fog walls; its own hook ignores the mirrored start, so it never echoes |
| Boss phases | **Host** (through health) | both run the boss's own phase logic | host health in `E` | phases follow health; a heal on the host reaches the client after 1 s instead of being ignored |
| Bell rest (enemies respawn) | **whoever rests** | both | `R bell` | the receiver's refresh is flagged as mirrored, so it isn't sent back |
| Death respawn | **the one who died** | own PC (the game refreshes your world) | host: `R death`; client: nothing | a client's death leaves the host's world (and fight) alone; the client re-kills what the host killed |
| Pickups | **whoever picks it up** | own PC | reliable `I <pickup> <item>` | the other side removes its copy and gets the item; if both grabbed it in the same moment, nobody gets a second one |
| Dust (currency) | **whoever earns it** | own PC | reliable `C <amount>` | amounts the mod added for the other player are excluded from what it sends back |
| Kill loot | **Host** rolls it | host | dust via `C`; the client's items via `I loot:<enemy>` | the host's own kills roll natively; a client's killing blow (the host's `Kill()` skips the roll) is rolled by the host once, with the game's own table and the enemy's level |
| PvP (duels) | **the defender** | each player's own PC | `V lose`, `V parry` | the loser's own PC decides the death; scores move once per death |
| Events in general | sender | | `<session> <id> ...` | the relay resends until acked; the receiver plays ids in order, once each, per session |

## The duplication cases, one by one

**Duplicate enemy damage.** Your swing hits your copy of the enemy. That drop is reported once (`D`) and applied
once on the host. Your ghost in the other world replays the swing for show. In co-op the ghost's Attack is 0, so it
does no damage (measured: 600 to 600 health). In PvP the ghost needs a real Attack to hit the other player. Its
hits on enemies did land (measured: 600 to 536, and they were reported as the receiver's own). Now a drop that
follows a ghost replay, with no local move started, is undone instead of reported. That check is on the client for
every copy, and on the host in PvP.

**Duplicate item pickups.** Both players can grab the same item in the same 100 ms. Each then also receives the
other's `I`. The pickup you took yourself is remembered per map, and the other's `I` for it then only removes
nothing and grants nothing.

**Duplicate enemy spawning.** The mod spawns no enemies. Both games load the same level, and the client pairs
each host enemy with its own copy. Bell refreshes are mirrored once (`R`), never echoed back.

**Conflicting player movement.** Each player is only ever moved by their own game. The ghost walks toward the
received position and is the only thing moved by the network. Ghost collision ignores pawns, so it never pushes.

**Repeated animation events.** A move is sent when it starts, not every tick. A hit reaction already playing
on the ghost isn't restarted by the same hit arriving over the network. On the host, enemies hit the ghost too.

**Desynchronized boss phases.** Phases follow health, and the host owns health. Before, the client only ever
lowered its copy, so a boss that healed in a phase stayed low on the client and could die there first. Now a heal
the host keeps for a second is followed, and the client's copy can't die before the host's anyway.

**Multiple executions of the same game event.** Every event has a session and an id. It is resent until acked,
and played once in order. A killing blow on the client doesn't kill its copy locally (Health_Min 1). The host's
`K` does, so death animations, drops and boss-beaten logic run once per world, at the host's word.

## Deaths, spectating, and the boss fight

- **You die (either role):** the death screen plays. After 3 s, the camera follows your partner while they're
  up and on your map. It comes back to you when you respawn, or sooner if they go down too. The death screen is
  dimmed, not removed: removing it would run the game's monster refresh.
- **The client dies while the host fights a boss:** the client's game respawns it at its bell and refreshes the
  client's world, as single-player would. The host's world isn't touched, so the host's boss fight goes on. When
  the host wins, `K` reaches the client and kills its copy of the boss. Enemies the host had already killed are
  killed again in the client's refreshed world.
- **The host dies while the client fights a boss:** the host's world is everyone's truth, and the host's game
  refreshes it. So both worlds refresh and the fight starts over, as when the host dies in Elden Ring co-op.
  Until the host respawns, the host's boss keeps fighting the client's ghost, and the client's hits still land.
  The client can finish the boss in that window.

- **Your partner vanishes** (quits, crashes, loses the connection): after 12 s with nothing heard (longer than a loading screen), their ghost
  hides instead of standing frozen. Fog walls closed for their fight open, and the enemies held for the host go
  back to normal. Their last snapshot is ignored even if a crashed relay left it on disk.

## What can't be checked in the prologue

The tested save is in the prologue. The game blocks respawns there (`RespawnSequenceBlockTag`, "first teleport
into the ambush forest"), and kills there pay no dust. Checked by calling the respawn's own refresh step, not by a
real respawn:

- a real death respawn that refreshes the world. Checked instead (tools\pvp\respawn-check.ps1, with the save
  restored after): real PvP deaths on both sides, spectating on a real death, and the game's own `Respawn` bringing
  the player back (850 HP, camera back). UE4SS hooks also see calls made inside blueprints: `Respawn` calling
  `Respawn Recover Attributes` and `Respawn Set Transform`, and `Respawn Refresh Monster` calling the game mode's
  `Refresh Monster` (which is what tells a death from a bell rest). In the prologue `Respawn` skips the monster
  refresh and the save. Elsewhere that step exists to refresh monsters, and its path into the mod is verified.
- kill loot on a real later-game enemy. What was found instead: a native kill rolls the enemy's loot table
  (`GetCombatLootDataForOwner`, owner = the dying enemy, at its `Level` attribute). The host's `Kill()` for the
  client's killing blow skipped that roll, so the kill paid nobody. The host now rolls the same table itself, once:
  dust goes to the host and reaches the client as shared dust, and items go to the client, who made the kill.
  Prologue enemies are level 0, which pays nothing. At a forced level 1 the table paid 99 dust (146 at level 3,
  270 at level 10), and the scenario test checks that the client's kill pays both players the same amount.
- whether a boss killed by reported damage counts as beaten for the host's save

## Who may talk to the relay

Everything below holds for both relays: the C++ one players run (`native/`, inside the game) and the Python fallback.
They share packets and files, and the same tests run them against each other. The C++ one parses packets from the
network inside the game process, so it limits JSON nesting, keeps a bounded list of ack sessions, and is tested with
malformed packets.

Raised by appdoze (issue #1 / PR #2) and reworked from their code:

- **Sender filter.** The host relay only takes packets from addresses a partner can have: Tailscale, home networks,
  this PC, and Hamachi/Radmin. `AllowAnyAddress = On` in the ini (or `--allow any`) lifts the filter, for virtual
  LANs with other address ranges (UU Accelerator's multiplayer, ZeroTier). A guest only listens to its host's exact address
  and port. Refused packets count as `filtered=` in net_status.txt.
- **Optional `Secret`**, the same on both PCs. Every packet is HMAC-signed with a scrypt-stretched key, and the
  relay refuses a packet when:
  - it is unsigned, or its signature is wrong;
  - it comes from its own role or session (bounced back at its sender);
  - it is more than two minutes old or ahead;
  - its counter isn't newer than the last one from that session (a replay).

  Without a secret, signed packets are refused too, so a mismatch never half-works. Refused packets count as
  `rejected=`. The relay reads the secret from the ini itself; it never appears on a command line.
- **Event values.** NaN and infinity are dropped. Dust and damage are capped per event, and the cap is checked
  before the lethal flag turns a hit into `math.huge`.
- **One bad packet can't kill the relay.** Odd event ids, a huge ping timestamp, and floods are all handled: at
  most 256 packets are read per receive.
- **Settings handshake.** Each relay tells the other its mod version and the settings both should share. Any
  difference shows as `mismatch=` and as an in-game tip. The partner's values are cleaned before they go into the
  status line.
- **`eval`** in cmd.txt runs only with dev.txt or `PBZCOOP_DEBUG=1`. The developer install creates dev.txt, and
  the release zip has none.

## Executions and late joins

- **Executions** (`GA_SimpleExecution_Young` and the other execution abilities) aren't sent as moves. Only
  `GA_Hun_*` moves are, so the ghost never replays one. A paired execution animation would grab the other world's
  copy of the enemy and could hit it a second time. The partner sees the enemy fall when the host's `K` arrives.
  Measured: five client swings took a thug from 600 to 68 in both worlds, with five reports and five applied.
- **Joining late or rejoining:** events are kept for the whole host session and resent until the client acks them.
  A client that rejoins with its inbox on disk only plays what it hasn't seen. A first join mid-session plays the
  host's whole backlog once: deaths (`K`), rests, shared items and dust from before it joined. That's the same
  "shared rewards" rule, applied late, not a duplicate.

## Known limits

- Co-op combat is same-map and host-authoritative. The host sends only loaded enemies near either player's position; the client applies and reports only enemies present in that host snapshot. A guest-local enemy that has no host record is intentionally ignored for shared damage, so it cannot create a local-only kill or reward.
- The player ghost's weapon/outfit is not yet part of the protocol. Move montages are synchronized, but a different equipped weapon can still leave the ghost holding the wrong weapon or empty hands. The PBZ equipment component/function must be identified in a live UE4SS dump before adding ghost-only equipment application; do not guess an `Equip*` call because inventory APIs can mutate saves.
- The ghost's locomotion is driven by CharacterMovement. If a game update changes the Hun locomotion driver or AnimBP requirements, a runtime probe of CharacterMovement velocity and AnimInstance is required; the relay cannot manufacture a missing PBZ animation state.
- A montage that cannot load/play leaves its matching ability (`M`) fallback available after a short wait. The `moves` command reports pending fallbacks and the last montage result.

- If both players swing at the same enemy within the same 1.5 s in PvP, the ghost's replay can't be told from your
  own hit, so that drop is reported. It's harmless outside PvP, where the ghost does no damage.
- Enemy AI isn't synced: each world's copy picks its own attacks. Its position snaps back if it drifts over 4 m.
- `Connect = Steam` is tested up to Valve's network: the Python relay's logic in unit tests, and the C++ relay reaching
  Steam inside both games. Two real accounts haven't connected through it yet; steps are in
  [STEAM_TEST.md](STEAM_TEST.md).
- Over Steam, the C++ relay's session handling runs on code the unit tests can't reach, since it needs a running game.
