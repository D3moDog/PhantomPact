-- The partner's moves on their ghost, as animation montages. (From appdoze's PR #5.)
--
-- Whatever montage your character plays (attacks, guard stance, deflects, executions, weapon and Phantom Edge
-- skills, item use...) is sent as "U <montage path> <position>", and the partner's ghost plays the same montage
-- from that point (plus half the ping) with its AnimInstance's own Montage_Play.
--
-- Montages show what replaying abilities (M events) couldn't: a ghost often can't activate an ability (guard
-- stance, executions, some weapon skills). M is still sent for older partners and used until the first montage
-- arrives. PvP keeps abilities: there the ghost's swings must land real hits.
--
-- Checked here (review of PR #5): only montage folders are accepted, the loaded object must really be an
-- AnimMontage, and new loads are capped per minute, so a partner can't make this game load any asset; the ghost
-- isn't steered while a montage plays (game.noteGhostMove), as for ability replays.

return function(api)
    local log, valid, game = api.log, api.valid, api.game
    local coop = api.coop
    local net = coop.net

    local PATH = "^/[%w_/%-]+%.[%w_%-]+$"
    local ALLOWED_ROOTS = { "^/PBZCombatAsset/", "^/Game/" }
    local MAX_NEW_LOADS_PER_MIN = 30
    local RESTART_S = 0.05          -- the same montage at an earlier position = played again

    local M_FALLBACK_DELAY_S = 0.45
    local MOVE_MATCH_WINDOW_S = 0.45
    local moves = { sent = 0, played = 0, failed = 0, refused = 0, partnerSends = false,
        montageReady = false }
    local pendingAbilities = {}
    local recentMontages = {}
    local last, lastPos = nil, 0
    local cache = {}                -- montage path -> montage object, or false when it can't be loaded here
    local loads, loadsWindow = 0, os.clock()

    local function animOf(actor)
        local ai
        pcall(function() ai = actor.Mesh:GetAnimInstance() end)
        return valid(ai) and ai or nil
    end

    local function pathOf(m)
        return (m:GetFullName():gsub("^%S+ ", ""))
    end

    local function allowedPath(path)
        if not (path and #path <= 256 and path:match(PATH)) then
            return false
        end
        for _, root in ipairs(ALLOWED_ROOTS) do
            if path:match(root) then
                return true
            end
        end
        return false
    end

    local function isMontage(obj)
        local ok, yes = pcall(function()
            return obj:IsA(StaticFindObject("/Script/Engine.AnimMontage"))
        end)
        return ok and yes == true
    end

    -- Sender, every tick: a new montage, or the same one started again, goes to the partner.
    local function watch()
        local _, pawn = api.getPlayer1()
        local ai = valid(pawn) and animOf(pawn)
        if not ai then
            return
        end
        local m = ai:GetCurrentActiveMontage()
        if not valid(m) then
            last = nil
            return
        end
        local addr = m:GetAddress()
        local pos = ai:Montage_GetPosition(m) or 0
        if addr ~= last or pos < lastPos - RESTART_S then
            local path = pathOf(m)
            if allowedPath(path) then
                coop.sendEvent("U", path, string.format("%.2f", pos))
                moves.sent = moves.sent + 1
            end
        end
        last, lastPos = addr, pos
    end

    local function montage(path)
        local m = cache[path]
        if m and valid(m) then
            return m
        end
        if m == false then
            return nil
        end
        m = StaticFindObject(path)
        if not valid(m) and type(LoadAsset) == "function" then
            -- Moves of a weapon the local player doesn't carry aren't in memory yet. Capped, so a flood of
            -- different paths can't stall the game with loads.
            local now = os.clock()
            if now - loadsWindow >= 60 then
                loads, loadsWindow = 0, now
            end
            if loads >= MAX_NEW_LOADS_PER_MIN then
                return nil
            end
            loads = loads + 1
            pcall(LoadAsset, path)
            m = StaticFindObject(path)
        end
        cache[path] = (valid(m) and isMontage(m)) and m or false
        return cache[path] or nil
    end

    local function syncSession()
        if moves.session ~= net.inSession then
            moves.session = net.inSession
            moves.montageReady = false
            pendingAbilities = {}
            recentMontages = {}
        end
    end

    local function family(path, segment)
        return path and path:match("/" .. segment .. "/([^/]+)/") or nil
    end

    local function matchingAbility(path, now)
        local wanted = family(path, "Montage")
        local best
        for i, item in ipairs(pendingAbilities) do
            local age = now - item.at
            local compatible = item.family ~= nil and wanted ~= nil and item.family == wanted
            if not item.family or not wanted then
                compatible = age <= 0.20
            end
            if compatible and age <= MOVE_MATCH_WINDOW_S then
                best = i
                break
            end
        end
        if best then
            table.remove(pendingAbilities, best)
        end
        recentMontages[#recentMontages + 1] = { family = wanted, at = now }
        while recentMontages[1] and now - recentMontages[1].at > MOVE_MATCH_WINDOW_S do
            table.remove(recentMontages, 1)
        end
    end

    local function hasRecentMontage(path, now)
        local wanted = family(path, "Abilities")
        for i = #recentMontages, 1, -1 do
            local item = recentMontages[i]
            local age = now - item.at
            if age > MOVE_MATCH_WINDOW_S then
                table.remove(recentMontages, i)
            else
                local compatible = wanted ~= nil and item.family ~= nil and wanted == item.family
                if not wanted or not item.family then
                    compatible = age <= 0.20
                end
                if age >= 0 and compatible then
                    return true
                end
            end
        end
        return false
    end

    coop.handlers.U = function(rest)
        syncSession()
        local path, pos = (rest or ""):match("^(%S+)%s+(%S+)$")
        pos = tonumber(pos)
        if not (allowedPath(path) and pos and pos == pos and pos >= 0 and pos < 600) then
            moves.refused = moves.refused + 1
            return
        end
        moves.partnerSends = true
        if net.pvp or not valid(net.ghost) or net.ghostHidden then
            return
        end
        local m = montage(path)
        local ai = animOf(net.ghost)
        if not (m and ai) then
            moves.failed = moves.failed + 1
            moves.montageReady = false
            return
        end
        local start = pos + (net.rttMs or 0) / 2000
        local ok, duration = pcall(function() return ai:Montage_Play(m, 1.0, 0, start, true) end)
        if ok and type(duration) == "number" and duration > 0 then
            moves.played = moves.played + 1
            moves.montageReady = true
            matchingAbility(path, os.clock())
            if game.noteGhostMove then
                game.noteGhostMove()
            end
        else
            moves.failed = moves.failed + 1
            moves.montageReady = false
        end
    end

    -- M often arrives just before its U. Buffer each event independently; a matching successful U consumes
    -- only one fallback. Unrelated montages and later moves cannot discard the rest of the queue.
    local replayAbility = coop.handlers.M
    if replayAbility then
        coop.handlers.M = function(rest)
            syncSession()
            moves.partnerSends = true
            local path = (rest or ""):match("^(%S+)")
            if not path or path:find("Passive", 1, true) then
                moves.refused = moves.refused + 1
                return
            end
            if net.ghostHidden or not valid(net.ghost) then
                return
            end
            local now = os.clock()
            if hasRecentMontage(path, now) then
                return
            end
            if #pendingAbilities < 80 then
                pendingAbilities[#pendingAbilities + 1] = { rest = rest, at = now, family = family(path, "Abilities") }
            end
        end
    end

    coop.extraTicks.moves = function()
        syncSession()
        local now = os.clock()
        while pendingAbilities[1] and now - pendingAbilities[1].at >= M_FALLBACK_DELAY_S do
            local pending = table.remove(pendingAbilities, 1)
            if not net.ghostHidden and valid(net.ghost) and replayAbility then
                replayAbility(pending.rest)
            end
        end
        local ok, err = pcall(watch)
        if not ok then
            last = nil
            if err ~= moves.lastError then        -- once per kind of error, not every tick
                moves.lastError = err
                log("moves: " .. tostring(err))
            end
        end
    end

    -- moves: counters
    function moves.command()
        log(string.format("Moves: sent %d, played on the ghost %d, failed %d, refused %d, pending ability fallbacks %d, last montage succeeded: %s, partner sends montages: %s",
            moves.sent, moves.played, moves.failed, moves.refused, #pendingAbilities, tostring(moves.montageReady),
            tostring(moves.partnerSends)))
    end

    return moves
end
