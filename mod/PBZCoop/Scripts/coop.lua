-- PBZCoop online co-op: everything that crosses the network. Loaded by main.lua, which passes in its helpers.
--
-- Files shared with net/pbzcoop_net.py (see that file for the transport):
--   net_out.txt / net_in.txt                 snapshot, newest wins, one record per line:
--       P <seq> <x> <y> <z> <yaw> <speed> <hp> <maxhp>      the sender's player
--       E <name> <x> <y> <z> <yaw> <hp> <maxhp> <boss> <posture>   an enemy (host only; boss = 1 for bosses;
--                                                       posture = "Shachi", which breaks into an execution)
--   net_events_out.txt / net_events_in.txt   reliable events: "S <session>" then "<id> <type> <args...>"
--       M <move>             the sender's player started an attack/dodge/special move
--       D <enemy> <hp> <posture> [L]   client -> host: the client's player took this much health/posture off
--                            it; L = a killing blow (the client's copy is held at 1 health, so the host kills it)
--       B <boss>             the sender's game started a boss fight with this enemy
--       R [bell|death]       the sender rested at a bell, or the host died and respawned: enemies respawn on both
--                            PCs (a client's own death respawn isn't sent: only its world refreshes)
--       C <amount>           the sender gained this much dust (currency): shared rewards
--       H <hit state tag>    the sender's player started a hit reaction; their ghost plays the same one
--       K <enemy>            host -> client: this enemy died
--       I <pickup>           this pickup/chest was taken
--
-- Roles: the host's world is the truth for enemies (positions, health, deaths); the client mirrors it and
-- reports its own hits. Each side shows the other's player as a "ghost" Hun steered by movement input.
-- Who decides what (and why) is written up in docs/AUTHORITY.md.
-- "echo" (solo testing) runs as host and also treats its own echoed events as the friend's.

return function(api)
    local log, valid, getPlayer1, fmtVec, distance = api.log, api.valid, api.getPlayer1, api.fmtVec, api.distance
    local modDir, spawnBesidePlayer1, game = api.modDir, api.spawnBesidePlayer1, api.game

    local GHOST_CLASS = "/Script/Engine.DefaultPawn"
    local NET_SEND_MS = 50        -- matches the relay's tick
    local TICK_MS = 16            -- one game-thread tick: steer the ghost; every NET_EVERY ticks exchange state
    local GHOST_SNAP_CM = 600     -- walking ghost further than this from its target teleports instead
    local GHOST_STOP_CM = 60      -- walking ghost closer than this stops and faces the remote player's direction
    local GHOST_MIN_SPEED = 100   -- cm/s, walking ghost's slowest speed while catching up
    local GHOST_MAX_SPEED = 750   -- cm/s, fastest (a bit above P1's 450 jog, so it can catch up)
    local GHOST_SPEED_PER_CM = 3.0  -- speed per cm of distance to the target
    local GHOST_ACCELERATION = 2000 -- cm/s², P1 uses 210 but the ghost must react to network updates quickly
    local GHOST_SMOOTHING = 0.35  -- sphere ghost: fraction of the remaining distance covered per tick
    local MAP_HIDE_DELAY_S = 2.0  -- streaming/PIE map-key changes must persist before hiding a live partner
    local PARTNER_GONE_S = 12.0   -- longer than a loading screen (respawn teleport, streaming), which is silent too
    -- Dead reckoning: the ghost aims where the partner should be now, not where the last snapshot said, by
    -- extending their recent velocity. Capped, so a stop or turn costs at most a short overshoot. Velocity comes
    -- from snapshot numbers (the sender writes one every SNAPSHOT_S), not arrival times, which jitter.
    -- (From appdoze's PR #2.)
    local SNAPSHOT_S = math.max(1, math.floor(NET_SEND_MS / TICK_MS + 0.5)) * TICK_MS / 1000
    local PREDICT_MAX_S = 0.25    -- never extrapolate further ahead than this
    local PREDICT_MAX_CM = 300    -- nor further than this
    local PREDICT_MIN_SPEED = 30  -- cm/s; slower counts as standing (no prediction)
    local PREDICT_MAX_SPEED = 2500 -- cm/s; faster between two snapshots is a teleport, not movement
    local PREDICT_BLEND = 0.5     -- weight of the newest velocity sample (smooths jitter)
    local ENEMY_RADIUS_CM = 6000  -- host shares enemies within this distance of its player
    local ENEMY_SNAP_CM = 400     -- client teleports a mirrored enemy that is further than this from the host's
    local ENEMY_MATCH_CM = 2000   -- client: a same-class enemy this close stands in for a host enemy with another id
    local PICKUP_EVERY = 10       -- snapshots between pickup scans (0.5 s)
    local AGGRO_EVERY = 20        -- snapshots between ghost aggro refreshes (1 s)
    local MOVE_WALKING = 1        -- EMovementMode::MOVE_Walking
    local ECC_PAWN = 2            -- ECollisionChannel::ECC_Pawn
    local ECR_IGNORE = 0          -- ECollisionResponse::ECR_Ignore

    local net = {
        enabled = false,
        role = "host",            -- "host", "client", "echo" or "loop" (see isHost/isClient)
        ghostMode = "clone",
        seq = 0,
        lastRemoteSeq = nil,
        target = nil,             -- { X, Y, Z, Yaw, Speed, Hp, MaxHp } from the latest remote snapshot
        ghost = nil,
        ghostWalks = false,
        session = nil,
        nextEventId = 1,
        inSession = nil,
        inProcessed = 0,
        inOffset = 0,             -- bytes of net_events_in.txt already read
        inTail = "",              -- an incomplete last line (no "\n" yet), finished on a later read
        remoteEnemies = {},       -- client: name -> latest host record
        mapMismatchSince = nil,   -- map mismatch must persist before the ghost is hidden
        deadSent = {},            -- host: enemy name -> true once its death was announced
        pendingDeaths = {},       -- client: host id -> true for a death announced while our copy wasn't loaded
        pendingBosses = {},       -- client: host id -> true for a boss fight announced before our copy was matched
        matchSticky = {},         -- client: host id -> address of the local actor matched to it by class/position
        foggedBosses = {},        -- boss id -> boss actor while we keep its arena's fog walls closed for the other player
        hostKilled = {},          -- client: host id -> true for each death the host announced since the last shared rest
        unsharedHeld = {},        -- client: local-only actor held at Health_Min 1 until the host broadcasts it
        hostBosses = {},          -- client: host id -> true while the host's fight with that boss goes on
        heldAlive = {},           -- client: actor address -> actor held at Health_Min 1 (only the host kills it)
        healTicks = {},           -- client: host id -> snapshots in a row the host's health was clearly above ours
        hostSeen = {},            -- host, PvP: name -> { hp, posture } last tick, to undo the ghost's own hits
        deadSince = nil,          -- os.clock() when the local player died (spectating starts a little later)
        stats = { sent = 0, received = 0, applied = 0, undone = 0 },
    }

    -- "loop" (solo test with the echo relay) plays both parts at once: it shares its enemies like a host and
    -- applies the echoed enemies, deaths and hits like a client, so both halves run in one game.
    local function isHost()
        return net.role ~= "client"
    end

    local function isClient()
        return net.role == "client" or net.role == "loop"
    end

    local function readText(path, mode)
        local f = io.open(path, mode or "r")
        if not f then
            return nil
        end
        local text = f:read("a")
        f:close()
        return text
    end

    local function writeText(path, text)
        local f = io.open(path, "w")
        if f then
            f:write(text)
            f:close()
        end
    end

    -- Write a temp file and rename it into place, so the relay never reads half a snapshot. Windows' rename
    -- won't replace an existing file, hence the remove and second try.
    local function writeAtomic(path, text)
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then
            return
        end
        f:write(text)
        f:close()
        if not os.rename(tmp, path) then
            os.remove(path)
            if not os.rename(tmp, path) then
                os.remove(tmp)    -- the relay had the file open; the next snapshot comes 50 ms later
            end
        end
    end

    -- tonumber that also turns NaN into nil (a NaN position would teleport actors into nowhere).
    local function num(s)
        local n = tonumber(s)
        -- NaN and infinities (e.g. "1e999") from the network are dropped, never applied.
        if n ~= n or n == math.huge or n == -math.huge then
            return nil
        end
        return n
    end

    -- Amounts the other side may ask for in one event. Far above anything the game produces (a boss drops tens
    -- of thousands of dust, a hit deals thousands), but a malformed or forged event can't hand out billions.
    -- (Idea and caps from appdoze's review of the relay, PR #2.)
    local MAX_EVENT_DUST = 1000000
    local MAX_EVENT_DAMAGE = 1000000

    ------------------------------------------------------------------ events

    local function sendEvent(kind, ...)
        if not net.enabled then
            return
        end
        local parts = { tostring(net.nextEventId), kind }
        for _, v in ipairs({ ... }) do
            parts[#parts + 1] = tostring(v)
        end
        local f = io.open(modDir() .. "net_events_out.txt", "a")
        if f then
            f:write(table.concat(parts, " ") .. "\n")
            f:close()
            net.nextEventId = net.nextEventId + 1
            net.stats.sent = net.stats.sent + 1
        end
    end

    local handlers = {}

    -- Reads only the bytes the relay appended since last time (net.inOffset), and only whole lines: a line the
    -- relay is still writing waits in net.inTail until its "\n" arrives.
    local function processEvents()
        local f = io.open(modDir() .. "net_events_in.txt", "rb")
        if not f then
            return
        end
        local size = f:seek("end") or 0
        f:seek("set", 0)
        local session = (f:read("l") or ""):match("^S (%S+)")
        if session ~= net.inSession then
            -- The peer started a new session: a fresh inbox, numbered from 1 again.
            net.inSession = session
            net.inProcessed = 0
            net.inOffset = 0
            net.inTail = ""
        elseif size < net.inOffset then
            -- Same session, but the file shrank: the relay restarted and is rewriting it from event 1. The ids
            -- are the sender's own, so the ones up to inProcessed were already played; re-read from the top.
            net.inOffset = 0
            net.inTail = ""
        end
        local chunk = ""
        if size > net.inOffset then
            f:seek("set", net.inOffset)
            chunk = f:read(size - net.inOffset) or ""
        end
        f:close()
        net.inOffset = net.inOffset + #chunk
        local text = net.inTail .. chunk
        local cut = text:match("^.*()\n")    -- position of the last "\n"
        if cut == nil then
            net.inTail = text
            return
        end
        net.inTail = text:sub(cut + 1)
        for line in text:sub(1, cut):gmatch("[^\r\n]+") do
            local id, kind, rest = line:match("^(%d+) (%S+)%s*(.*)$")
            id = tonumber(id)
            if id ~= nil and id > net.inProcessed then
                net.inProcessed = id
                net.stats.received = net.stats.received + 1
                local h = handlers[kind]
                if h then
                    local ok, err = pcall(h, rest)
                    if not ok then
                        log("event " .. kind .. " error: " .. tostring(err))
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------ ghost (the remote player)

    local function spawnGhost()
        local ghostClass
        if net.ghostMode == "clone" then
            local _, pawn = getPlayer1()
            ghostClass = valid(pawn) and pawn:GetClass() or nil
        end
        if not valid(ghostClass) then
            ghostClass = StaticFindObject(GHOST_CLASS)
        end
        net.ghost = spawnBesidePlayer1(ghostClass)
        if not valid(net.ghost) then
            return
        end
        net.ghostWalks = false
        if net.ghostMode == "clone" then
            -- Steered with movement input (see steerGhost) so the game's own locomotion animations play.
            -- It needs collision for the floor, but should not shove player 1 around.
            net.ghostWalks = pcall(function()
                local cmc = net.ghost.CharacterMovement
                cmc.bRunPhysicsWithNoController = true
                cmc:SetMovementMode(MOVE_WALKING, 0)
            end)
            pcall(function() net.ghost.CapsuleComponent:SetCollisionResponseToChannel(ECC_PAWN, ECR_IGNORE) end)
            if game.setupGhost then
                game.setupGhost(net.ghost)
            end
        end
        if not net.ghostWalks then
            -- Teleported every tick, so its own movement (gravity, root motion) must stay out of the way.
            net.ghost:SetActorEnableCollision(false)
            pcall(function() net.ghost.CharacterMovement:DisableMovement() end)
        end
        local t = net.target
        net.ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
        log("Remote player ghost spawned.")
    end

    -- The ghost disappears while the remote player is dead (health 0) or on another map, and comes back when
    -- they revive or arrive. Map keys are normalized by pbz.lua and a short mismatch debounce covers streaming.
    local function updateGhostVisibility()
        if not valid(net.ghost) or net.target == nil then
            return
        end
        local t = net.target
        local mapKnown = t.Map ~= nil and net.localMap ~= nil and t.Map ~= "?" and net.localMap ~= "?"
        local mapMismatch = mapKnown and t.Map ~= net.localMap
        if mapMismatch then
            net.mapMismatchSince = net.mapMismatchSince or os.clock()
        else
            net.mapMismatchSince = nil
        end
        local otherMap = mapMismatch and os.clock() - net.mapMismatchSince >= MAP_HIDE_DELAY_S
        -- Only "down" after a full second at 0 HP: a single 0 read during a teleport or loading hitch made the
        -- ghost flicker in the first live two-copy test.
        local zero = t.MaxHp ~= nil and t.MaxHp > 0 and t.Hp ~= nil and t.Hp <= 0
        if zero then
            net.zeroSince = net.zeroSince or os.clock()
        else
            net.zeroSince = nil
        end
        local dead = zero and (os.clock() - net.zeroSince) >= 1.0
        local gone = net.partnerGone == true     -- see watchPartner
        -- In a cutscene the partner isn't really playing: their ghost would stand idle in your world.
        local hide = otherMap or dead or gone or t.Cine == true
        if hide ~= net.ghostHidden then
            net.ghostHidden = hide
            pcall(function()
                net.ghost:SetActorHiddenInGame(hide)
                net.ghost:SetActorEnableCollision(net.ghostWalks and not hide)
            end)
            if hide then
                log("Ghost hidden: the other player is " .. (gone and "gone" or dead and "down"
                    or t.Cine and "in a cutscene" or ("on map " .. tostring(t.Map))) .. ".")
            else
                log("Ghost visible again.")
            end
        end
    end

    local function steerGhost()
        if not valid(net.ghost) or net.target == nil then
            return
        end
        if game.ghostBusy and game.ghostBusy(net.ghost) then
            return    -- mid attack/dodge: let the move's own motion play out
        end
        local cur = net.ghost:K2_GetActorLocation()
        local t = net.target
        local v = net.vel
        if v and net.lastRemoteAt and not net.ghostHidden and not net.partnerGone
            and v.X * v.X + v.Y * v.Y >= PREDICT_MIN_SPEED * PREDICT_MIN_SPEED then
            -- How old the partner's position is: time since it arrived plus its trip here (half the round trip
            -- the relay measures, kept in net.rttMs by status.lua).
            local ahead = math.min(os.clock() - net.lastRemoteAt + (net.rttMs or 0) / 2000, PREDICT_MAX_S)
            local px, py = v.X * ahead, v.Y * ahead
            local d = math.sqrt(px * px + py * py)
            if d > PREDICT_MAX_CM then
                px, py = px * PREDICT_MAX_CM / d, py * PREDICT_MAX_CM / d
            end
            t = { X = t.X + px, Y = t.Y + py, Z = t.Z, Yaw = t.Yaw, Speed = t.Speed }
        end
        if net.ghostWalks then
            local dx, dy = t.X - cur.X, t.Y - cur.Y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > GHOST_SNAP_CM or math.abs(t.Z - cur.Z) > GHOST_SNAP_CM then
                -- Too far behind (teleport, fall, cutscene): jump straight there.
                net.ghost:K2_SetActorLocationAndRotation({ X = t.X, Y = t.Y, Z = t.Z },
                    { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
            elseif dist > GHOST_STOP_CM then
                -- PBZ leaves MaxWalkSpeed at 0 on an unpossessed Hun (its locomotion system sets it for players),
                -- so pick the speed here: the further behind, the faster; never slower than the remote player.
                local cmc = net.ghost.CharacterMovement
                local want = math.max(GHOST_MIN_SPEED, dist * GHOST_SPEED_PER_CM, (t.Speed or 0) * 1.05)
                want = math.min(GHOST_MAX_SPEED, want)
                cmc.MaxWalkSpeed = want
                cmc.MaxAcceleration = GHOST_ACCELERATION
                pcall(function() cmc:SetMovementMode(MOVE_WALKING, 0) end)
                net.ghost:AddMovementInput({ X = dx / dist, Y = dy / dist, Z = 0.0 }, 1.0, false)
            else
                net.ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false)
            end
            return
        end
        local a = GHOST_SMOOTHING
        net.ghost:K2_SetActorLocationAndRotation(
            { X = cur.X + (t.X - cur.X) * a, Y = cur.Y + (t.Y - cur.Y) * a, Z = cur.Z + (t.Z - cur.Z) * a },
            { Pitch = 0.0, Yaw = t.Yaw, Roll = 0.0 }, false, {}, true)
    end

    handlers.M = function(rest)
        local path, yaw = rest:match("^(%S+)%s*(%S*)")
        if path and valid(net.ghost) and game.playMove then
            game.playMove(net.ghost, path, tonumber(yaw))
        end
    end

    ------------------------------------------------------------------ enemies

    -- Enemies within ENEMY_RADIUS_CM of the local player, or (second origin) of the other player: the host shares
    -- the enemies around the client too, so a client fighting far from the host still fights the host's enemy
    -- (otherwise it would be the client's own, and could die there while alive for the host).
    local function localEnemies(origin, origin2)
        local out = {}
        if not game.listEnemies then
            return out
        end
        for _, e in ipairs(game.listEnemies()) do
            if valid(e) and e ~= net.ghost then
                local ok, loc = pcall(function() return e:K2_GetActorLocation() end)
                if ok and loc.X ~= nil and (distance(loc, origin) <= ENEMY_RADIUS_CM
                    or (origin2 ~= nil and distance(loc, origin2) <= ENEMY_RADIUS_CM)) then
                    out[#out + 1] = { actor = e, loc = loc }
                end
            end
        end
        return out
    end

    local enemyByName = {}    -- name -> actor, rebuilt every snapshot on both sides

    -- An id both PCs agree on (see game.enemyId): the spawner's designer id when a spawner made the enemy.
    local function enemyName(actor)
        if game.enemyId then
            return game.enemyId(actor)
        end
        return actor:GetFName():ToString()
    end

    local function enemyClass(actor)
        return actor:GetClass():GetFName():ToString()
    end

    -- A health/posture drop right after the ghost replayed a move, while the local player started none, is the
    -- ghost's hit. The ghost is the other player, whose hits arrive as reported damage ("D"); its own native hit
    -- (it only has an Attack stat in PvP) would count the same swing twice.
    local ATTRIBUTION_S = 1.5
    local function ghostsHit()
        return game.ghostMoveRecent and game.ghostMoveRecent(ATTRIBUTION_S)
            and not game.localMoveRecent(ATTRIBUTION_S)
    end

    local function undoHit(actor, prevHp, prevPosture)
        if prevHp and game.setHealth then
            game.setHealth(actor, prevHp)
        end
        if prevPosture and game.setPosture then
            game.setPosture(actor, prevPosture)
        end
        net.stats.undone = net.stats.undone + 1
    end

    -- Host: announce deaths (reliably) and list the rest in the snapshot.
    local function enemySnapshotLines(origin)
        local lines = {}
        enemyByName = {}
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        local hostSeen = {}
        local partner = nil
        local targetMap = net.target and net.target.Map
        local sameMap = targetMap == nil or targetMap == "?" or net.localMap == nil or net.localMap == "?"
            or targetMap == net.localMap
        if net.target ~= nil and not net.partnerGone and sameMap then
            partner = { X = net.target.X, Y = net.target.Y, Z = net.target.Z }
        end
        for _, e in ipairs(localEnemies(origin, partner)) do
            local name = enemyName(e.actor)
            enemyByName[name] = e.actor
            local hp, maxhp = nil, nil
            if game.getHealth then
                hp, maxhp = game.getHealth(e.actor)
            end
            if net.pvp and hp and hp > 0 then
                -- Only in PvP does the ghost carry a real Attack stat, so only then can it hurt enemies here.
                local posture = game.getPosture and game.getPosture(e.actor)
                local prev = net.hostSeen[name]
                if prev and prev.addr == e.actor:GetAddress() and ghostsHit()
                    and ((prev.hp and hp < prev.hp - 0.5) or (prev.posture and posture and posture < prev.posture - 0.5)) then
                    undoHit(e.actor, prev.hp, prev.posture)
                    hp, posture = prev.hp, prev.posture
                end
                hostSeen[name] = { hp = hp, posture = posture, addr = e.actor:GetAddress() }
            end
            local dead = game.isDead and game.isDead(e.actor)
            if dead then
                if not net.deadSent[name] then
                    net.deadSent[name] = true
                    sendEvent("K", name)
                end
            elseif hp ~= nil and maxhp ~= nil then
                -- (No health read = stale actor: left out rather than sent as 0/0, which the client would apply.)
                -- Alive (again, after a bell respawn): its next death must be announced too.
                net.deadSent[name] = nil
                local yaw = e.actor:K2_GetActorRotation().Yaw
                if yaw == yaw and e.loc.X == e.loc.X and e.loc.Y == e.loc.Y and e.loc.Z == e.loc.Z then
                    local boss = game.isBoss and game.isBoss(e.actor) and 1 or 0
                    -- "-" = unknown posture; the client leaves its own alone instead of zeroing it.
                    local posture = game.getPosture and game.getPosture(e.actor)
                    lines[#lines + 1] = string.format("E %s %.1f %.1f %.1f %.1f %.1f %.1f %d %s %s",
                        name, e.loc.X, e.loc.Y, e.loc.Z, yaw, hp, maxhp, boss,
                        posture ~= nil and string.format("%.1f", posture) or "-", enemyClass(e.actor))
                end
            end
        end
        net.hostSeen = hostSeen
        return lines
    end

    -- id is the HOST's id for this enemy (it may differ from our own when matched by class and position).
    -- lethal: our copy is held at 1 health (only the host kills it), so a killing blow can't show its full damage
    -- here; it's sent as lethal and the host kills the enemy.
    local function reportHit(id, enemy, hpDamage, postureDamage, lethal)
        if net.enabled and isClient() and valid(enemy) then
            sendEvent("D", id, string.format("%.1f", hpDamage), string.format("%.1f", postureDamage or 0),
                lethal and "L" or "-")
            net.stats.hitsReported = (net.stats.hitsReported or 0) + 1
        end
    end

    -- Client: which local enemy is each of the host's? Same id first; then the actor this id was matched to
    -- before (sticky, while it's loaded and alive); otherwise the nearest still-unmatched local enemy of the same
    -- class within ENEMY_MATCH_CM (covers enemies whose ids differ between PCs). Ids go in sorted order, so two
    -- same-class enemies pair up the same way every tick (pairs() order is arbitrary). Unmatched local enemies are
    -- intentionally excluded: only host-broadcast entities can be damaged in co-op.
    local function matchRemoteEnemies(locals)
        local byId, byAddr, used, matched = {}, {}, {}, {}
        for _, e in ipairs(locals) do
            e.addr = e.actor:GetAddress()
            byId[enemyName(e.actor)] = e
            byAddr[e.addr] = e
        end
        local ids = {}
        for id in pairs(net.remoteEnemies) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        local function take(id, e)
            matched[id] = e.actor
            used[e.addr] = true
        end
        for _, id in ipairs(ids) do
            local e = byId[id]
            if e and not used[e.addr] then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local e = byAddr[net.matchSticky[id]]
            if matched[id] == nil and e and not used[e.addr] and not (game.isDead and game.isDead(e.actor)) then
                take(id, e)
            end
        end
        for _, id in ipairs(ids) do
            local r = net.remoteEnemies[id]
            if matched[id] == nil and r.Class then
                local best, bestD = nil, ENEMY_MATCH_CM
                for _, e in ipairs(locals) do
                    if not used[e.addr] and enemyClass(e.actor) == r.Class then
                        local d = distance(e.loc, r)
                        if d < bestD then
                            best, bestD = e, d
                        end
                    end
                end
                if best then
                    take(id, best)
                end
            end
        end
        -- Remember the pairings. One whose id skipped this snapshot stays while its actor is still loaded.
        local sticky = {}
        for id, addr in pairs(net.matchSticky) do
            if byAddr[addr] and net.remoteEnemies[id] == nil then
                sticky[id] = addr
            end
        end
        for _, id in ipairs(ids) do
            if matched[id] then
                sticky[id] = matched[id]:GetAddress()
            end
        end
        net.matchSticky = sticky
        -- Do not add unmatched local enemies here. They belong to the guest's independent simulation and are not
        -- valid targets in the host-authoritative session. Keeping them out prevents local-only kills and damage
        -- reports that the host cannot route to an actor in its world.
        return matched
    end

    -- Client: pull its copies of the host's enemies into place and match their health and posture.
    -- The client's own hits are found by watching health/posture drop between ticks (PBZ calls OnDamage
    -- natively, so a UE4SS hook never sees it) and reported to the host. Syncing only ever LOWERS health and
    -- posture: the host's numbers are a round trip old and don't include the client's newest hits yet.
    local seen = {}           -- client: name -> { hp, posture, addr } as left by the previous tick

    -- The other player's boss fight, mirrored on our copy of that boss: boss bar and closed fog walls.
    local function mirrorBossFight(name, actor)
        if game.showBossBar then
            game.showBossBar(actor)
        end
        if game.setBossFog then
            net.foggedBosses[name] = actor
            game.setBossFog(actor, true)
        end
    end

    -- The host's health this many snapshots in a row clearly above ours is a heal (a boss phase that restores
    -- health): taken over. Our copy dips below the host's for a round trip after each of our own hits, which
    -- this must not mistake for a heal, so it waits a full second.
    local HEAL_TICKS = 20
    local HELD_HP = 1             -- the floor the client's copies of host enemies are held at

    -- keep/keepUnshared: address -> actor still held this tick. nil releases every held copy.
    local function releaseHeld(keep, keepUnshared)
        for addr, actor in pairs(net.heldAlive) do
            local retained = (keep and keep[addr]) or (keepUnshared and keepUnshared[addr])
            if not retained and valid(actor) and game.setMinHealth then
                game.setMinHealth(actor, 0)
            end
        end
        for addr, actor in pairs(net.unsharedHeld) do
            local retained = (keepUnshared and keepUnshared[addr]) or (keep and keep[addr])
            if not retained and valid(actor) and game.setMinHealth then
                game.setMinHealth(actor, 0)
            end
        end
        net.heldAlive = keep or {}
        net.unsharedHeld = keepUnshared or {}
    end

    local function applyRemoteEnemies(origin)
        if game.refreshEnemyIds then
            game.refreshEnemyIds()
        end
        local locals = localEnemies(origin)
        enemyByName = matchRemoteEnemies(locals)
        local matchedAddrs, unshared = {}, {}
        for _, actor in pairs(enemyByName) do
            matchedAddrs[actor:GetAddress()] = true
        end
        for _, e in ipairs(locals) do
            if not matchedAddrs[e.addr] and not (game.isDead and game.isDead(e.actor)) then
                if game.setMinHealth then
                    game.setMinHealth(e.actor, HELD_HP)
                end
                unshared[e.addr] = e.actor
            end
        end
        local nextSeen, held = {}, {}
        for name, actor in pairs(enemyByName) do
            local addr = actor:GetAddress()
            if net.pendingDeaths[name] then
                -- The host announced this death while our copy wasn't loaded: kill it now that it is.
                net.pendingDeaths[name] = nil
                if game.kill and not (game.isDead and game.isDead(actor)) then
                    game.kill(actor)
                    log("Host said " .. name .. " died earlier; killed it here now that it's loaded.")
                end
            elseif not (game.isDead and game.isDead(actor)) then
                if net.pendingBosses[name] then
                    -- The host's boss fight started before our copy of the boss was matched: mirror it now.
                    net.pendingBosses[name] = nil
                    log("Host's boss fight with " .. name .. " now matched here.")
                    mirrorBossFight(name, actor)
                end
                local hp = game.getHealth and game.getHealth(actor)
                local posture = game.getPosture and game.getPosture(actor)
                local prev = seen[name]
                if prev and prev.addr ~= addr then
                    prev = nil    -- this id now stands for another actor: its health isn't comparable
                end
                if prev and hp and prev.hp then
                    local dHp = prev.hp - hp
                    local dPosture = (prev.posture and posture) and (prev.posture - posture) or 0
                    if dHp > 0.5 or dPosture > 0.5 then
                        if ghostsHit() then
                            -- The host's swing, replayed here: the host's own world already took it.
                            undoHit(actor, prev.hp, prev.posture)
                            hp, posture = prev.hp, prev.posture
                        else
                            local lethal = net.heldAlive[addr] ~= nil and dHp > 0.5 and hp <= HELD_HP + 0.01
                            reportHit(name, actor, math.max(0, dHp), math.max(0, dPosture), lethal)
                        end
                    end
                end
                local r = net.remoteEnemies[name]
                if r then
                    -- One of the host's enemies: it dies when the host says so ("K"), never on its own here, so a
                    -- killing blow is never played twice and a copy that's a hit ahead doesn't die before the host's.
                    if not net.heldAlive[addr] and game.setMinHealth then
                        game.setMinHealth(actor, HELD_HP)
                    end
                    held[addr] = actor
                    local cur = actor:K2_GetActorLocation()
                    if distance(cur, r) > ENEMY_SNAP_CM then
                        actor:K2_SetActorLocationAndRotation({ X = r.X, Y = r.Y, Z = r.Z },
                            { Pitch = 0.0, Yaw = r.Yaw, Roll = 0.0 }, false, {}, true)
                    end
                    if game.setHealth and r.Hp ~= nil and hp ~= nil and r.Hp < hp - 0.5 then
                        game.setHealth(actor, r.Hp)
                        hp = r.Hp
                    end
                    if game.setHealth and r.Hp ~= nil and hp ~= nil and r.MaxHp
                        and r.Hp > hp + math.max(1, r.MaxHp * 0.05) then
                        net.healTicks[name] = (net.healTicks[name] or 0) + 1
                        if net.healTicks[name] >= HEAL_TICKS then
                            log(string.format("%s healed on the host (%.0f -> %.0f): following.", name, hp, r.Hp))
                            game.setHealth(actor, r.Hp)
                            hp = r.Hp
                            net.healTicks[name] = nil
                        end
                    else
                        net.healTicks[name] = nil
                    end
                    if game.setPosture and r.Posture ~= nil and posture ~= nil and r.Posture < posture - 0.5 then
                        game.setPosture(actor, r.Posture)
                        posture = r.Posture
                    end
                    net.stats.applied = net.stats.applied + 1
                end
                nextSeen[name] = { hp = hp, posture = posture, addr = addr }
            end
        end
        seen = nextSeen
        -- Copies the host stopped sharing (it went out of range, or they're no longer matched) die normally again.
        releaseHeld(held, unshared)
    end

    handlers.K = function(name)
        local actor = enemyByName[name]
        if isClient() then
            net.hostKilled[name] = true
            net.hostBosses[name] = nil
            if valid(actor) then
                if game.kill then
                    game.kill(actor)
                    log("Host says " .. name .. " died; killed it here.")
                end
            else
                -- Not loaded (or not matched) here right now: kill it when it shows up (applyRemoteEnemies).
                net.pendingDeaths[name] = true
                log("Host says " .. name .. " died; not matched here yet, will kill it when it is.")
            end
            net.pendingBosses[name] = nil
        end
        -- A boss whose fight we mirrored is dead: lift the fog walls we closed for it.
        local fogActor = valid(actor) and actor or net.foggedBosses[name]
        if net.foggedBosses[name] and valid(fogActor) and game.setBossFog then
            net.foggedBosses[name] = nil
            game.setBossFog(fogActor, false)
        end
    end

    -- Host: the client's hit killed this enemy. The game's own loot roll didn't run (see game.rollLoot), so it's
    -- rolled here, once. Dust goes to the host like any kill's and reaches the client as shared dust ("C");
    -- items go to the client, who made the kill (as single-player gives them to the killer).
    local function payKillLoot(name, actor)
        local dust, items, level = game.rollLoot(actor)
        local _, pawn = getPlayer1()
        local paid = {}
        if dust > 0 and valid(pawn) and pcall(function() pawn:ChangeDustNumInternal(dust) end) then
            paid[#paid + 1] = dust .. " dust"
        end
        for itemId, count in pairs(items) do
            for _ = 1, math.max(1, math.floor(count)) do
                sendEvent("I", "loot:" .. name, itemId)
            end
            paid[#paid + 1] = itemId .. " x" .. count
        end
        if #paid > 0 then
            log(string.format("Your partner's kill (%s, level %d): %s.", name, level, table.concat(paid, ", ")))
        end
    end

    handlers.D = function(rest)
        local name, amount, posture, lethal = rest:match("^(%S+) (%S+)%s*(%S*)%s*(%S*)")
        -- Checked before anything else: a real number in range (the lethal flag below can't smuggle in more).
        amount = num(amount)
        if amount == nil or amount < 0 or amount > MAX_EVENT_DAMAGE then
            return
        end
        posture = num(posture)
        posture = posture and math.max(0, math.min(posture, MAX_EVENT_DAMAGE)) or 0
        if lethal == "L" then
            amount = math.huge      -- the client's killing blow (its copy can't show the full damage)
        end
        if isHost() and name then
            local actor = enemyByName[name]
            if valid(actor) and game.applyDamage then
                local wasAlive = not (game.isDead and game.isDead(actor))
                game.applyDamage(actor, amount, posture)
                if wasAlive and game.isDead and game.isDead(actor) and game.rollLoot then
                    payKillLoot(name, actor)
                end
                net.stats.hitsApplied = (net.stats.hitsApplied or 0) + 1
                if net.hostSeen[name] then
                    -- A reported hit, not the ghost's: the PvP undo check must take this as the new baseline.
                    net.hostSeen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
                if seen[name] then
                    -- In "loop" mode the client half watches this same enemy: this drop isn't a new local hit.
                    seen[name] = { hp = game.getHealth(actor), posture = game.getPosture and game.getPosture(actor),
                        addr = actor:GetAddress() }
                end
            end
        end
    end

    ------------------------------------------------------------------ items

    handlers.I = function(rest)
        local name, itemId = rest:match("^(%S+)%s*(%S*)")
        if name and game.takeRemotePickup then
            local _, pawn = getPlayer1()
            game.takeRemotePickup(name, itemId, pawn)
        end
    end

    local function reportPickup(name, itemId)
        log("Picked up " .. name .. " (" .. tostring(itemId) .. "), telling the other player.")
        sendEvent("I", name, itemId or "?")
    end

    ------------------------------------------------------------------ bells and currency

    handlers.H = function(tag)
        if valid(net.ghost) and game.playHitReaction and tag and tag ~= "" then
            game.playHitReaction(net.ghost, tag)
        end
    end

    -- Enemies respawn (either player rested): every death can happen again, and so can every boss fight.
    local function forgetDeaths()
        net.deadSent = {}
        net.pendingDeaths = {}
        net.pendingBosses = {}
        net.hostKilled = {}
        net.hostBosses = {}
        if game.resetBosses then
            game.resetBosses()
        end
    end

    -- A death respawn refreshes the dying player's own world (the game does that, as in single-player).
    --   Host died: its world is everyone's truth, so the client's world refreshes too ("R death"): like the host
    --     dying in Elden Ring co-op, the fight starts over for both.
    --   Client died: only the client's world refreshed. The host's world, and its boss fight, go on untouched;
    --     the client's copies of what the host already killed are killed again, and a boss fight the host is
    --     still in is shown again (bar and fog walls).
    local function onLocalRest(kind)
        if kind == "death" and net.role == "client" then
            log("You died and respawned: your world refreshed, the host's goes on. Enemies the host already killed stay dead.")
            local again = 0
            for name in pairs(net.hostKilled) do
                net.pendingDeaths[name] = true
                again = again + 1
            end
            for name in pairs(net.hostBosses) do
                net.pendingBosses[name] = true
            end
            if game.resetBosses then
                game.resetBosses()
            end
            seen = {}
            releaseHeld(nil)
            if again > 0 then
                log(again .. " enemies the host killed will be removed again as they load.")
            end
            return
        end
        if kind == "death" then
            log("You died as host: enemies respawn in both worlds (the host's world is the shared one).")
        else
            log("Rested at a bell (enemies respawned): telling the other player.")
        end
        forgetDeaths()
        sendEvent("R", kind)
    end

    handlers.R = function(kind)
        if kind == "death" then
            log("The host died and respawned: enemies respawn here too.")
        else
            log("The other player rested at a bell: respawning enemies here too.")
        end
        forgetDeaths()
        seen = {}
        if game.refreshEnemies then
            game.refreshEnemies()
        end
    end

    handlers.C = function(amount)
        amount = num(amount)
        local _, pawn = getPlayer1()
        if amount and amount > 0 and amount <= MAX_EVENT_DUST and game.addCurrency then
            game.addCurrency(pawn, amount)
        end
    end

    ------------------------------------------------------------------ bosses

    handlers.B = function(name)
        log("The other player started a boss fight with " .. name .. ".")
        if net.role == "client" then
            net.hostBosses[name] = true
        end
        local actor = enemyByName[name]
        if valid(actor) then
            mirrorBossFight(name, actor)
        elseif isClient() then
            -- Not matched here yet (still loading, or too far from the host's copy): mirror it once it is.
            net.pendingBosses[name] = true
            log("Boss " .. name .. " isn't matched here yet; will show its fight when it is.")
        end
    end

    -- Sync off/restarted: open every fog wall we closed for the other player's boss fights.
    local function reopenFog()
        for _, actor in pairs(net.foggedBosses) do
            if valid(actor) and game.setBossFog then
                pcall(game.setBossFog, actor, false)
            end
        end
        net.foggedBosses = {}
    end

    ------------------------------------------------------------------ snapshot exchange

    local function writeSnapshot()
        local _, pawn = getPlayer1()
        if not valid(pawn) then
            return
        end
        local loc = pawn:K2_GetActorLocation()
        local yaw = pawn:K2_GetActorRotation().Yaw
        -- Occasionally a read comes back incomplete (seen in PBZ while walking); skip that tick. Same for NaN
        -- (x ~= x), which would send the ghost into nowhere.
        if loc.X == nil or loc.Y == nil or loc.Z == nil or yaw == nil
            or loc.X ~= loc.X or loc.Y ~= loc.Y or loc.Z ~= loc.Z or yaw ~= yaw then
            return
        end
        local speed = 0
        local okV, v = pcall(function() return pawn.CharacterMovement.Velocity end)
        if okV and v ~= nil then
            speed = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2)
            if speed ~= speed then
                speed = 0
            end
        end
        local hp, maxhp = 0, 0
        if game.getHealth then
            hp, maxhp = game.getHealth(pawn)
        end
        net.seq = net.seq + 1
        if net.seq % 20 == 1 or net.localMap == nil then
            net.localMap = game.mapKey and game.mapKey(pawn) or (game.mapName and game.mapName(pawn) or "?")
        end
        -- Field 10 is the outfit in appdoze's fork ("-": we don't send one); field 11 is 1 while we're in a
        -- cutscene. Older versions ignore both.
        local cine = game.inCutscene and game.inCutscene() and 1 or 0
        local lines = { string.format("P %d %.1f %.1f %.1f %.1f %.0f %.1f %.1f %s - %d",
            net.seq, loc.X, loc.Y, loc.Z, yaw, speed, hp or 0, maxhp or 0, net.localMap, cine) }
        if isHost() then
            for _, l in ipairs(enemySnapshotLines(loc)) do
                lines[#lines + 1] = l
            end
        end
        writeAtomic(modDir() .. "net_out.txt", table.concat(lines, "\n") .. "\n")
        if game.watchLocalPlayer then
            game.watchLocalPlayer(pawn, sendEvent)
        end
        if game.watchPickups and net.seq % PICKUP_EVERY == 0 then
            game.watchPickups(pawn, reportPickup)
        end
        if game.watchHitState then
            game.watchHitState(pawn, sendEvent)
        end
        if game.watchCurrency and net.seq % PICKUP_EVERY == 5 then
            game.watchCurrency(pawn, sendEvent)
        end
        if game.hookRest and not net.restHooked then
            net.restHooked = game.hookRest(function(kind)
                if net.enabled then
                    onLocalRest(kind)
                end
            end)
        end
        if game.ghostAggro and isHost() and valid(net.ghost) and net.seq % AGGRO_EVERY == 0 then
            game.ghostAggro(net.ghost, net.pvp)
        end
    end

    local function readSnapshot()
        local text = readText(modDir() .. "net_in.txt")
        if text == nil then
            return
        end
        local enemies = {}
        for line in text:gmatch("[^\r\n]+") do
            local kind = line:sub(1, 1)
            if kind == "P" then
                local seq, x, y, z, yaw, speed, hp, maxhp, map, _, cine = line:match(
                    "^P (%d+) (%S+) (%S+) (%S+) (%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)")
                seq = tonumber(seq)
                if seq ~= nil and seq ~= net.lastRemoteSeq then
                    local t = { X = num(x), Y = num(y), Z = num(z), Yaw = num(yaw),
                        Speed = num(speed), Hp = num(hp), MaxHp = num(maxhp),
                        Map = (map ~= nil and map ~= "")
                            and (game.mapKeyName and game.mapKeyName(map) or map) or nil,
                        Cine = cine == "1" }
                    -- A position that doesn't parse (or is NaN) is dropped, not applied.
                    if t.X and t.Y and t.Z and t.Yaw then
                        local prev, steps = net.target, net.lastRemoteSeq and (seq - net.lastRemoteSeq) or 0
                        if prev ~= nil and steps >= 1 and steps <= 20 then
                            local dt = steps * SNAPSHOT_S
                            local vx, vy = (t.X - prev.X) / dt, (t.Y - prev.Y) / dt
                            if vx * vx + vy * vy <= PREDICT_MAX_SPEED * PREDICT_MAX_SPEED then
                                local v, k = net.vel, PREDICT_BLEND
                                net.vel = v and { X = v.X * (1 - k) + vx * k, Y = v.Y * (1 - k) + vy * k }
                                    or { X = vx, Y = vy }
                            else
                                net.vel = nil   -- a teleport: start over
                            end
                        else
                            net.vel = nil       -- first snapshot, or a gap (relay restart, loading)
                        end
                        net.lastRemoteSeq = seq
                        net.lastRemoteAt = os.clock()
                        net.target = t
                    end
                end
            elseif kind == "E" then
                local name, x, y, z, yaw, hp, maxhp, boss, posture, cls = line:match(
                    "^E (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)%s*(%S*)%s*(%S*)")
                if name then
                    local r = { X = num(x), Y = num(y), Z = num(z), Yaw = num(yaw),
                        Hp = num(hp), MaxHp = num(maxhp), Boss = boss == "1", Posture = num(posture),
                        Class = (cls ~= nil and cls ~= "") and cls or nil }
                    -- Unparsable numbers or no health (MaxHp 0) would teleport or zero our copy: ignore the record.
                    if r.X and r.Y and r.Z and r.Yaw and r.Hp and r.MaxHp and r.MaxHp > 0 then
                        enemies[name] = r
                    end
                end
            end
        end
        -- A partner who went silent leaves their last snapshot behind (a relay that died doesn't blank it): their
        -- enemy lines are stale then, and aren't applied.
        net.remoteEnemies = net.partnerGone and {} or enemies
        -- (No ghost before we have a player ourselves: menus, loading screens.)
        if net.target ~= nil and not valid(net.ghost) and valid(select(2, getPlayer1())) then
            spawnGhost()
        end
        updateGhostVisibility()
    end

    ------------------------------------------------------------------ control

    -- Forget everything learned from the other side, so nothing from an earlier session is applied.
    local function clearRemoteState()
        net.remoteEnemies = {}
        net.target = nil
        net.localMap = nil
        net.lastRemoteSeq = nil
        net.lastRemoteAt = nil
        net.partnerGone = false
        net.mapMismatchSince = nil
        net.vel = nil
        net.matchSticky = {}
        net.pendingDeaths = {}
        net.pendingBosses = {}
        net.hostKilled = {}
        net.hostBosses = {}
        net.healTicks = {}
        net.hostSeen = {}
        enemyByName = {}
        seen = {}
    end

    local function destroyGhost()
        if valid(net.ghost) then
            net.ghost:K2_DestroyActor()
        end
        net.ghost = nil
        net.ghostHidden = nil
        net.zeroSince = nil
    end

    local function start(role)
        role = (role ~= nil and role ~= "") and role or "host"
        if role ~= "host" and role ~= "client" and role ~= "echo" and role ~= "loop" then
            log("Usage: neton host|client|echo|loop")
            return
        end
        net.role = role
        net.enabled = true
        if game.spectate then
            game.spectate(nil)
        end
        reopenFog()
        releaseHeld(nil)
        destroyGhost()
        clearRemoteState()
        net.deadSent = {}
        -- A snapshot left over from before is not the peer's current state; the relay rewrites it on the next packet.
        writeText(modDir() .. "net_in.txt", "")
        -- A new event session: the relay forwards it and the peer starts a fresh inbox.
        net.session = tostring(os.time()) .. tostring(math.random(1000, 9999))
        net.nextEventId = 1
        writeText(modDir() .. "net_events_out.txt", "S " .. net.session .. "\n")
        -- Whatever is already in the inbox is from an earlier session: treat it as handled, so only the
        -- peer's next session (a new "S" line from the relay) gets played.
        -- Binary mode, so the length is the byte offset processEvents continues from (only whole lines count).
        local inbox = readText(modDir() .. "net_events_in.txt", "rb") or ""
        local cut = inbox:match("^.*()\n")
        inbox = cut and inbox:sub(1, cut) or ""
        net.inSession = inbox:match("^S (%S+)")
        net.inProcessed = 0
        net.inOffset = #inbox
        net.inTail = ""
        for id in inbox:gmatch("\n(%d+) ") do
            net.inProcessed = math.max(net.inProcessed, tonumber(id))
        end
        log("Online sync on as " .. role .. ". Start net/pbzcoop_net.py with --dir pointing at " .. modDir())
    end

    local function stop()
        net.enabled = false
        if game.spectate then
            game.spectate(nil)
        end
        releaseHeld(nil)
        destroyGhost()
        reopenFog()
        clearRemoteState()
        log("Online sync off.")
    end

    local function ghostDiag()
        local ghost = net.ghost
        if not valid(ghost) then
            log("Ghost diagnostic: no valid remote ghost.")
            return
        end
        local loc = ghost:K2_GetActorLocation()
        local cmc = ghost.CharacterMovement
        local velocity, maxSpeed, mode = nil, nil, nil
        pcall(function() velocity = cmc.Velocity end)
        pcall(function() maxSpeed = cmc.MaxWalkSpeed end)
        pcall(function() mode = cmc.MovementMode end)
        local speed = velocity and math.sqrt((velocity.X or 0)^2 + (velocity.Y or 0)^2 + (velocity.Z or 0)^2) or nil
        local mesh = ghost.Mesh
        local ai
        pcall(function() ai = mesh:GetAnimInstance() end)
        local montage = "-"
        if valid(ai) then
            pcall(function()
                local active = ai:GetCurrentActiveMontage()
                if valid(active) then montage = active:GetFullName() end
            end)
        end
        log(string.format("Ghost diagnostic: loc=%s velocity=%s max_walk=%s movement_mode=%s hidden=%s anim=%s montage=%s",
            fmtVec(loc), speed and string.format("%.1f", speed) or "?", tostring(maxSpeed), tostring(mode),
            tostring(net.ghostHidden), valid(ai) and ai:GetClass():GetFullName() or "none", montage))
        local count = 0
        for _, comp in ipairs(FindAllOf("ActorComponent") or {}) do
            if valid(comp) then
                local ok, owner = pcall(function() return comp:GetOwner() end)
                if ok and valid(owner) and owner:GetAddress() == ghost:GetAddress() then
                    log("  component " .. comp:GetClass():GetFName():ToString() .. " " .. comp:GetFName():ToString())
                    count = count + 1
                end
            end
        end
        log("Ghost components: " .. count)
    end

    local function status()
        local relay = (readText(modDir() .. "net_status.txt") or "no status file (relay not running?)"):gsub("%s+$", "")
        log("Relay: " .. relay)
        local enemyCount = 0
        for _ in pairs(net.remoteEnemies) do
            enemyCount = enemyCount + 1
        end
        local heldCount, unsharedCount = 0, 0
        for _ in pairs(net.heldAlive) do
            heldCount = heldCount + 1
        end
        for _ in pairs(net.unsharedHeld) do
            unsharedCount = unsharedCount + 1
        end
        local snapshotAge = net.lastRemoteAt and math.max(0, os.clock() - net.lastRemoteAt) or -1
        log(string.format("Mod: enabled=%s role=%s sent_seq=%d remote_seq=%s snapshot_age=%.1f ghost=%s hidden=%s local_map=%s remote_map=%s events_sent=%d events_in=%d remote_enemies=%d applied=%d hits_reported=%d hits_applied=%d ghost_hits_undone=%d held=%d unshared=%d",
            tostring(net.enabled), net.role, net.seq, tostring(net.lastRemoteSeq), snapshotAge, tostring(valid(net.ghost)),
            tostring(net.ghostHidden), tostring(net.localMap), tostring(net.target and net.target.Map),
            net.stats.sent, net.stats.received, enemyCount, net.stats.applied, net.stats.hitsReported or 0,
            net.stats.hitsApplied or 0, net.stats.undone, heldCount, unsharedCount))
        if valid(net.ghost) then
            local _, pawn = getPlayer1()
            local g = net.ghost:K2_GetActorLocation()
            log("Ghost at " .. fmtVec(g) .. (valid(pawn) and string.format(", %.0f cm from P1", distance(g, pawn:K2_GetActorLocation())) or ""))
        end
    end

    local NET_EVERY = math.max(1, math.floor(NET_SEND_MS / TICK_MS + 0.5))
    local ERROR_LOG_S = 2.0       -- a failing stage logs at most this often (it would otherwise spam 20x a second)
    local ticks = 0
    local lastErrorLog = {}       -- stage -> os.clock() of its last logged error

    -- Each stage in its own pcall, so one failing (say, a stale enemy) doesn't stop the others.
    local function runStage(stage, fn)
        local ok, err = pcall(fn)
        if not ok then
            local now = os.clock()
            if lastErrorLog[stage] == nil or now - lastErrorLog[stage] >= ERROR_LOG_S then
                lastErrorLog[stage] = now
                log("net error (" .. stage .. "): " .. tostring(err))
            end
        end
    end

    local function clientEnemies()
        local _, pawn = getPlayer1()
        if not valid(pawn) then
            net.mapMismatchSince = nil
            seen = {}
            releaseHeld(nil)
            return
        end
        local t = net.target
        local fresh = t ~= nil and net.lastRemoteAt ~= nil and not net.partnerGone
            and os.clock() - net.lastRemoteAt < PARTNER_GONE_S
        local mapKnown = t ~= nil and t.Map ~= nil and net.localMap ~= nil and t.Map ~= "?" and net.localMap ~= "?"
        if not fresh or not mapKnown then
            net.mapMismatchSince = nil
            seen = {}
            releaseHeld(nil)
            return
        end
        if t.Map ~= net.localMap then
            net.mapMismatchSince = net.mapMismatchSince or os.clock()
            -- Enemy actors from another map must never be matched by class/position in this world.
            net.remoteEnemies = {}
            seen = {}
            releaseHeld(nil)
            return
        end
        net.mapMismatchSince = nil
        applyRemoteEnemies(pawn:K2_GetActorLocation())
    end

    -- No new snapshot for a while: they quit, crashed or lost the connection. Their ghost mustn't stand there
    -- frozen, and nothing may stay locked for a fight that's no longer happening (fog walls, held enemies).
    local function watchPartner()
        local gone = net.lastRemoteAt ~= nil and os.clock() - net.lastRemoteAt >= PARTNER_GONE_S
        if gone and not net.partnerGone then
            net.partnerGone = true
            log("Lost the other player (nothing heard for " .. PARTNER_GONE_S .. " s): fog walls opened, enemies are yours again.")
            reopenFog()
            releaseHeld(nil)
            net.remoteEnemies = {}
            seen = {}
            updateGhostVisibility()
        elseif not gone and net.partnerGone then
            net.partnerGone = false
            log("The other player is back.")
            updateGhostVisibility()
        end
    end

    -- Spectating: a few seconds into our own death (the death screen's entrance plays first), the camera follows
    -- the other player while they're up and on our map; it comes back to us when we respawn or they go down.
    local SPECTATE_AFTER_S = 3.0
    local function watchOwnDeath()
        local _, pawn = getPlayer1()
        if not valid(pawn) or not game.isDead then
            return
        end
        if game.isDead(pawn) then
            if net.deadSince == nil then
                net.deadSince = os.clock()
                if game.hideAliveScreen then
                    game.hideAliveScreen()
                end
            end
            if not game.spectate then
                return
            end
            local partnerUp = valid(net.ghost) and not net.ghostHidden
            if partnerUp and os.clock() - net.deadSince >= SPECTATE_AFTER_S and not game.isSpectating() then
                if game.spectate(net.ghost) then
                    log("You're down: watching the other player until you respawn.")
                end
            elseif not partnerUp and game.isSpectating() then
                game.spectate(nil)
                log("The other player is down or gone too: camera back on you.")
            end
        else
            net.deadSince = nil
            if game.isSpectating and game.isSpectating() then
                game.spectate(nil)
                log("Back on your feet: camera back on you.")
            end
        end
    end

    -- Other modules (pvp.lua) run here every tick while sync is on: name -> function.
    local extraTicks = {}

    local function tick()
        if not net.enabled then
            return
        end
        ticks = ticks + 1
        if ticks % NET_EVERY == 0 then
            runStage("writeSnapshot", writeSnapshot)
            runStage("readSnapshot", readSnapshot)
            runStage("processEvents", processEvents)
            if isClient() then
                runStage("applyRemoteEnemies", clientEnemies)
            end
            runStage("watchOwnDeath", watchOwnDeath)
            runStage("watchPartner", watchPartner)
        end
        runStage("steerGhost", steerGhost)
        for name, fn in pairs(extraTicks) do
            runStage(name, fn)
        end
    end

    -- Everything runs in one loop on the game thread (LoopInGameThreadWithDelay). Never hot-reload the mod
    -- while it runs: UE4SS's Ctrl+R crashed PBZ twice with these loops active.
    if type(LoopInGameThreadWithDelay) == "function" then
        LoopInGameThreadWithDelay(TICK_MS, function()
            tick()
            return false
        end)
        log("Net loop: game thread (LoopInGameThreadWithDelay)")
    else
        log("Net loop: LoopAsync + ExecuteInGameThread (no LoopInGameThreadWithDelay in this UE4SS)")
        LoopAsync(TICK_MS, function()
            if net.enabled then
                ExecuteInGameThread(tick)
            end
            return false
        end)
    end

    return {
        net = net,
        handlers = handlers,       -- event type -> function(rest); other modules add their own types
        extraTicks = extraTicks,
        isHost = isHost,
        sendEvent = sendEvent,
        reportHit = reportHit,
        reportPickup = reportPickup,
        commands = {
            neton = start,
            netoff = stop,
            netstatus = status,
            ghostdiag = ghostDiag,
            -- "ghost clone" (default) or "ghost sphere"; respawns the ghost on the next update.
            ghost = function(mode)
                if mode ~= "clone" and mode ~= "sphere" then
                    log("Usage: ghost clone|sphere (now " .. net.ghostMode .. ")")
                    return
                end
                net.ghostMode = mode
                destroyGhost()
                net.lastRemoteSeq = nil
                log("Ghost look: " .. mode)
            end,
        },
    }
end
