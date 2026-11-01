# PBZCoop online co-op: how to play, what syncs, how it was tested

## Two copies on one PC: `-allowmultipleinstances`

PBZ refuses a second copy with "Phantom Blade Zero is already running", but its own log says why and how to
turn that off: `[PBZ] Another instance is already running on this machine; exiting. Pass
-allowmultipleinstances to override.` Starting the second copy with that launch option (the game's own switch,
nothing patched) lets two copies run side by side. `tools\pbz-selftest.ps1` passes it.

Live two-copy test, 2026-10-29: one copy in the ASTER second workplace (user Tomato, instance 1, host) and one
in the main session (instance 2, `PBZCOOP_INSTANCE=2`, client), relays on 127.0.0.1:
- each copy showed the other player's Hun (connected, ~16 ms round trip);
- the host's thugs were matched on the client by class + position (different runtime names);
- the client's 6 hits landed in the host's world (sword thug 400 -> 41, hoe thug 340 -> 180), 52 events
  client -> host and 17 host -> client;
- host bell rest -> the client respawned its enemies; host +20 dust -> client 0 -> 20; host material pickup
  -> client 0 -> 1.
Lesson: don't teleport players to far-away areas in a test; with two copies streaming, the floor wasn't loaded
yet and both fell through the world (walk there, or fight near the start).
ASTER isn't needed for tests; it only gives a second person their own screen and input on the same PC.

Single-session two-copy test, same day, no ASTER: `.\tools\pbz-selftest.ps1` started both copies in one Windows
session (copy 2 compiled its shaders once). Host + client connected; the tutorial boss was spawned at the same
spot in both worlds and matched by class + position; the host's boss fight showed the boss bar on the client;
the client's 7 hits drained the host boss's posture step by step (1120 -> 950, mirrored on the client); the
host's kill killed the client's copy. Use this for future tests: `pbz-selftest.ps1`, continue both saves, then
`neton host` in copy 1 and `neton client` in copy 2.

Status on 2026-10-29 (PBZ build 26266538, UE4SS "UE4SS for Phantom Blade Zero 1.0.1"). Everything below was
tested in the real game on one PC. The two-PC test with a friend is still to do: PBZ refuses a second copy on
the same PC, so the host and client paths were each tested against a fake peer over real UDP (see "Testing").

## Play with a friend

Each player needs their own copy of PBZ, UE4SS + PBZCoop installed (`tools\pbz-setup.ps1`), Python 3, and
Tailscale (or any network where the client can reach the host's UDP port 47800).

1. Both: start PBZ and load a save. Be on the same map.
2. Host: `.\tools\pbz-coop.ps1 -Role host`
3. Friend: `.\tools\pbz-coop.ps1 -Role client -Peer <host's Tailscale IP>`
4. Each of you now sees the other as a second Hun. Stop with `.\tools\pbz-coop.ps1 -Stop`.

The launcher starts the relay (`net\pbzcoop_net.py`), waits until you're in gameplay, then sends the mod
`neton <role>`. Link status: `ue4ss\Mods\PBZCoop\net_status.txt`, or the mod command `netstatus`.

Solo testing: `-Role echo` (a fake friend copies your moves 3 m away, 0.3 s late) or `-Role loop` (the same, plus
the client logic runs on the echoed data, so host and client code both run in one game).

## What syncs

| Feature | How | Verified in game |
|---|---|---|
| Friend's character | A real `BP_Renewal_Hun_Young_C` "ghost", steered with movement input so PBZ's own run/walk animations play; snaps if >6 m off | Runs beside you with the real run cycle; follows slopes; stops within ~45 cm |
| Attacks, dodges, jumps | Local `GA_Hun*` ability activations are sent as `M` events; the ghost activates the same ability class | Ghost plays the A/AA/AAA/AAAA light chain, jumps; ~10% of replays are refused mid-combo (busy) |
| Enemies (host truth) | Host lists enemies within 60 m (`E` lines: position, health, posture, boss flag) | Client copy snaps to the host position and drops to the host's health (400 -> 200) and posture |
| Client's hits | Client sees an enemy's health/posture drop that it didn't cause and reports `D <enemy> <hp> <posture>`; host applies it | Client hit `D ... 80.0 93.5` reached the host; host took a thug from 400 to 300 HP / 200 to 150 posture |
| Enemy deaths | Host sends `K <enemy>` once; client kills its copy (`Kill(GameLogic)`) | Thugs and the boss died on the client when the host's died |
| Bosses | Boss = codex `bIsBoss` or the HUD calling `RegisterBossHPBar`; a boss fight sends `B <boss>` and the other side shows the boss health bar | ZuoShang (tutorial boss, 2900 HP) shown with the boss bar; boss health and death synced |
| Aggro on the friend | Host adds the ghost to nearby enemies' hatred lists; ghost does 0 damage itself (hits come as `D`) and stays at full health (the friend's real health is on their PC) | Enemies engage both Huns |
| Items | A pickup next to you that vanishes sends `I <pickup> <itemId>`; the other side removes its copy and gets the same item (shared loot) | Material (`Weapon_Material_01`) pickup -> `I` -> granted on the other side; page, stone, key item and consumable grants each 0 -> 1 with the game's "item acquired" screen |
| Friend down / other map | `P` line carries health and map name; the ghost hides while they're at 0 HP or on another map | Ghost hid at 0 HP and came back |
| Same enemy on both PCs | Enemy id = `sp:<SpawnerID>` only when the level AISpawner has a real designer ID; `None`/empty IDs fall back to the runtime actor name, then the client matches nearest same-class enemy within 20 m. Runtime actor names differ across PCs, so class + position is the fallback for unassigned spawners. | A live host log exposed multiple enemies collapsed to `sp:None`; empty IDs are now rejected so each snapshot record stays distinct. Real tutorial boss with a valid ID remains `sp:ZuoShangyoung_Seq003`. |
| Facing during moves | `M` events carry the attacker's yaw; the ghost turns to it before the move | Moves sent as `M <ability> 34.5` |
| Hit reactions | Local `HitreactComponent` state changes are sent as `H <tag>`; the ghost's hit state is set to the same tag | Thug hits sent `CharacterState.Hitreact.State.Normal` / `.Heavy`; ghost state followed |
| Bells (rest) | The game mode's `Refresh Monster` (bell rest) is hooked; it sends `R` and the other PC runs its own refresh, so regular enemies respawn for both; bosses follow the game's own rules (beaten ones stay dead) | Hook fired, `R` crossed, the other side refreshed and the spawner enemy came back |
| Currency | Dust gained locally (not by sync) is sent as `C <amount>` and added on the other PC: shared rewards. Spending isn't mirrored | +40 earned, `C 40` sent, the other side added 40, no echo loop |
| Boss arena fog walls | On `B` the other PC closes `BP_FogDoor_C` within 60 m of its copy of the boss; on that boss's `K` it opens them | Fog wall rose at the tutorial boss arena entrance and opened on the boss's death |
| Who kills an enemy | The client's copies of host enemies are held at `Health_Min` 1; a client hit reaching that floor goes as `D ... L` and the host kills; only `K` kills the copy | Client's killing blow: host thug 20 -> 0, client copy died on `K` (tools\pvp\coop-scenarios.ps1) |
| Death respawns | The player's `Respawn Refresh Monster` step is hooked: a host death respawn sends `R death` (both refresh), a client's isn't sent (only its world refreshes; it re-kills what the host killed) | Client respawn left the host's half-health boss untouched; the host's later kill reached the client |
| Spectating | 3 s into your death the camera follows the partner's ghost (death screen dimmed), back to you on respawn | View target switched to the ghost and back |

Which PC decides each of these, and how duplicates (double hits, double pickups, echoed events) are prevented:
[AUTHORITY.md](AUTHORITY.md).

Not synced: enemy AI targets in the client world are its own (positions/health are pulled to the host's);
cutscenes; dialogue; chests other than `PBZPickupActor` pickups; spending currency.

Known limits found in testing:
- Item ids are the `ItemId` field of `DT_InventoryData` rows (ASCII, e.g. `Weapon_Material_01`, `Item_001`,
  `K_07001`, `I_10001`, `Page_XC_04`), not the row names (Chinese display names such as `铸造金属`), which the
  backpack silently ignores. Pickups carry the real `ItemId`, so sharing uses the right ids; tests granted a
  material, a stone, a key item and a consumable (each 0 -> 1, with the game's "item acquired" screen), and a
  material pickup went through the full pickup -> `I` event -> grant round trip.
- Not yet tested with two real PCs and two players. PBZ blocks a second copy on one PC (its own
  `PBZ_SingleInstance_Mutex` plus a second check that looks DRM-related, which we don't touch), and Sandboxie
  can't run it, so both roles were tested against fake peers over real UDP. A real session needs the second PC
  (desktop-gfqd042 on Tailscale) with a Steam account that owns PBZ.

## Protocol (net\pbzcoop_net.py, protocol 2)

Files in the mod folder, shared by the mod and the relay:

- `net_out.txt` / `net_in.txt`, newest wins, sent every 50 ms:
  - `P <seq> <x> <y> <z> <yaw> <speed> <hp> <maxhp> <map>`
  - `E <id> <x> <y> <z> <yaw> <hp> <maxhp> <boss> <posture> <class>` (host only)
- `net_events_out.txt` / `net_events_in.txt`, reliable and ordered (resent until acknowledged):
  `S <session>` then `<id> <type> <args>` with types `M` move (+yaw), `D` hit (hp, posture), `K` death,
  `B` boss fight, `I` pickup (+item id), `H` hit reaction, `R` bell rest, `C` currency.
  A new `neton` starts a new session; the peer's inbox starts fresh, and old events are never replayed.

Enemy ids: `sp:<SpawnerID>` when a level AISpawner made the enemy (same on both PCs); otherwise the actor
name, with the client matching by class + nearest position.

## Testing without a second PC: record and replay

PBZ won't run twice on one PC, so the closest stand-in for a friend is a recorded real host:

1. `.\tools\pbz-coop.ps1 -Role record` and play as host (fight, boss, rest, loot). The relay writes everything
   the host sends, with timing, to `logs\host-recording.jsonl`. `-Stop` when done.
2. Restart the game (a fresh process: runtime actor names change, like on another PC), go to the same place.
3. `.\tools\pbz-coop.ps1 -Role replay` and play as client: the recorded host plays against you; the events
   your client sends back are logged to `logs\host-recording.client.txt`.

Result on 2026-10-29: the host session (tutorial boss from its level spawner: boss fight, 20 moves, kill, bell
rest, +30 dust, a material pickup) replayed into a fresh client session. The client's boss had another runtime
name (`_2147475370` vs `_2147474438`) and was matched by `sp:ZuoShangyoung_Seq003`; the client showed the boss
bar, closed and then opened the arena fog wall, killed its boss on the host's kill, refreshed enemies on the
bell rest, got the dust (0 -> 30) and the material (0 -> 1), and showed the host's Hun replaying its attacks.
All 25 events arrived.

The other direction too: a client session hitting the spawner boss was recorded (29 moves, 7 hits sent as
`D sp:ZuoShangyoung_Seq003 ...`), then replayed into a fresh host session whose boss had yet another runtime
name: the host applied all 7 hits to its boss (posture 1120 -> 959, exactly the recorded 161) and showed the
client's Hun. What replay can't show: either side reacting live to the other (see the bot test below).

## Live test with a bot friend

`net\pbzcoop_bot.py` is a scripted remote player that speaks the client protocol through a normal client relay
and reacts live: it reads the host's snapshot, runs to the nearest enemy, attacks (moves + hits), moves on when
the host reports a death, follows the host otherwise, and reacts to boss fights and bell rests.

    .\tools\pbz-coop.ps1 -Role host
    python -I net\pbzcoop_net.py client --dir logs\bot --peer 127.0.0.1
    python -I net\pbzcoop_bot.py --dir logs\bot --seconds 70

Result on 2026-10-29 (host game + bot over UDP, 70 s, while the host also fought): the bot's Hun ran to and
fought each thug on the host's screen; the host applied 57 bot hits, all three thugs died and each death reached
the bot, which switched targets; the host rested at a bell, the bot saw it, the game respawned the tutorial
boss from its spawner and the bot engaged it as `sp:ZuoShangyoung_Seq003`, taking it from 2900 to 1100 HP, live.

## Testing

- Relay: `python -I net\test_pbzcoop_net.py` (loopback host+client: snapshots both ways, events exactly once in
  order despite resends, session restart, echo shifting; record -> replay round trip). 3 tests, passing.
- In game, solo, `-Role loop` + test commands:
  - `spawnenemy <codex row> [cm]` spawns any of the 177 codex enemies in front of you (`codex bosses` lists
    the 75 bosses); `spawner <SpawnerID|list>` makes a level spawner spawn its enemy (the game's own path);
    `enemies`, `items`, `bossbar` (starts the boss bar for the nearest boss), `rest` (runs the bell refresh),
    `fog` (lists fog walls).
  - A 40 s fight against three thugs: 37 moves, 12 hits reported/applied, 3 deaths synced, no errors.
  - Final 30 s regression with everything on: 31 moves (with facing), 8 hits, 4 deaths, 5 hit reactions,
    1 boss fight, no errors.
- Host path over real UDP: the mod as host + a fake client relay fed by hand (`P`, `D`, `M`): ghost shown, hit
  applied, client received `E` lines and `K`.
- Client path over real UDP: the mod as client + a fake host relay: enemy pulled to the host position and
  health/posture, client hits sent as `D`, host `K` killed the client copy.

## Lessons (PBZ specifics)

- Never hot-reload (Ctrl+R) in PBZ: both crashes on launch day happened at a hot reload with the mod's loops
  running. Hot reload is off (`EnableHotReloadSystem = 0`); reinstall and restart the game instead.
- The net loop runs on the game thread (`LoopInGameThreadWithDelay`).
- `APBZCharacter::OnDamage` is called natively: a UE4SS hook never fires. Hits are detected from health drops.
- An unpossessed Hun has `MaxWalkSpeed = 0`; the mod sets it while steering the ghost.
- `IsDead()` stays false at 0 HP during the death animation; health counts too.
- A destroyed actor stays valid in `FindAllOf` until garbage collection but loses its position.
- World subsystems aren't found by `FindFirstOf`; use `SubsystemBlueprintLibrary:GetWorldSubsystem`.
  `PBZSpawnSubsystem` doesn't exist on the prologue map; enemies are spawned by class from the codex table.
- `DataTable:FindRow` / `ForEachRow` work in this UE4SS; codex rows give each enemy's class and boss flag.
- Killing an enemy type the save hasn't met yet (a new codex entry) autosaves the game. Tests only kill the thug
  and the tutorial boss, which the test save already knows; `coop-scenarios.ps1` checks the save's hash. Removing
  `W_PlayerDead` and a real death respawn (`Save Game on Respawn`) autosave too.
- In the prologue, kills pay no dust and drop nothing, whatever the enemy (bandit, scavenger and GuiChai checked):
  loot there comes from scripted encounters. The prologue also never starts a respawn: a real death shows no
  death widget, and the player stays down.

## PvP (`pvp.lua`, `PvP = On`)

**Who decides a hit: the defender.** In each world the partner's ghost is made hostile to the local player
(`FactionComponent:SetFactionRelationOverride(other, Hostile=2, true)` on both) and gets a full stat block
(the ghost spawns with 0/0 health, which counts as dead; it gets a copy of the local player's 223 attributes,
so both fighters are equal, Attack scaled by `PvPDamage`). Its replayed moves then hit the local player through
the game's own combat: damage, posture, hit reactions, block, deflect and perfect dodge all apply natively. Your
hits on the ghost in your own world are only for show; they land in the partner's world.

- **Deaths are real** (since 1.1.1; 1.1.0 held health at 1 with `Health_Min`): a death within 8 s of the partner's
  last hit sends `V lose` and counts as their win; dying to an enemy doesn't. The prologue area never lets the
  player die (`GA_Tutorial_Health_Passive` heals from ~0 to ~690 in 1.5 s), so there the kill is scored but
  nobody respawns. With that heal removed (test only), a PvP death did not run the enemy refresh and the
  partner's enemy stayed alive, but the prologue then never offers a respawn (it isn't built for deaths), so a
  bell respawn still needs a save past the first bell (this save's revive point is "Start", no bell activated).
  A killing blow can land within one tick: a partner swing still in progress also counts as their kill.

## Co-op difficulty (`scaling.lua`)

While the partner's ghost is in this world, every enemy is scaled once: `Health_Max`/`Health` by
`CoopEnemyHealth`% and `Shachi_Max`/`Shachi` by `CoopEnemyPosture`% (default 150/130), keeping its current share.
Both worlds scale the same enemy by the same factor, so the host's numbers (which the guest's copies follow down)
match. Tested: one thug 400 -> 600 health and 200 -> 260 posture in both worlds; the guest's hit (-200) reached the
host and the host's kill reached the guest; co-op e2e still passes.
- **Relay robustness:** Windows refused a rename once (WinError 1450) and killed the relay; writes now retry and
  skip instead, and the event inbox only acknowledges events it managed to write.
- **Parry reward:** the game's deflect leaves the attacker untouched, so the mod judges it on the defender's side:
  the guard (`GA_Hun_*_Stance`, right mouse) was up during the ghost's attack, the defender was within 3.5 m, and
  the swing cost neither health nor posture (a held block costs posture). Then `V parry <posture>`: the attacker
  loses posture and gets a heavy hit reaction (`CharacterState.Hitreact.State.Normal.Heavy`).
- **Hit states set by hand must be cleared** (`clearHitStateLater`, 0.9 s): without the animation that normally
  ends them, a character stays in the hit state and can't start any move (a parried attacker and the ghost both
  got stuck in testing).
- **Other weapons:** a move of a weapon the local player doesn't carry isn't in memory; `playMove` loads it with
  `LoadAsset(classPath)` once. (`KismetSystemLibrary:LoadClassAsset_Blocking` with a hand-built soft path broke
  the mod's command loop; don't.)
- **Attack values far from normal break hits:** Attack 1500 on the ghost made its swings stop registering.
- **Test command `unlockall`:** every weapon (13) and Phantom Edge weapon (20) into the backpack. Weapon ids are
  the folder names under `/PBZCombatAsset/ActorData/Players/Hun/Abilities` (Phantom Edge: `.../ShachiAbility`),
  read with the asset registry (`GetSubPaths`); `ApplyForcedWeaponLoadout(id, level, false)` equips one.

**Tests (two copies, attacks triggered through the mod, defender with real input):** plain hit 850 -> 786, held
block (no damage, posture 300 -> 209), timed parry rewarded (tap 150 ms after the swing arrives; attacker posture
300 -> 240, attacker recovers), Iron Blade light (-64) and heavy (-83) attacks, round end (loser stays alive,
`WON`/`lost` on both, both heal). Not done yet: executions (the ghost's posture is kept full), showing the
partner's guard pose (the ghost can't play `GA_Hun_Young_Stance`), Phantom Edge weapons and weapon skills like
`GA_Hun_Iron_C` (activates but didn't hit; may not be a strike).
