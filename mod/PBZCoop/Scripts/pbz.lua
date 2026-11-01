-- PBZCoop game adapter for Phantom Blade Zero: what counts as an enemy, how health is read and changed, how a
-- player's moves are recognised and replayed, and how pickups are found. coop.lua calls these through api.game;
-- every function is optional, and missing ones simply switch that feature off.
--
-- Where the names come from (UE4SS SDK dump of build 26266538, see docs/RECON_NOTES.md):
--   enemies   APBZCharacter_NPC (BIsMonster), health in AttributeSetBase (UBasicAttributeSet.Health/Health_Max),
--             Kill(EPBZDieReason), hits through APBZCharacter::OnDamage
--   bosses    UPBZHUDLayout::RegisterBossHPBar(AActor*) plus FCodexEnemyRow.bIsBoss in DT_CodexEnemyDataTable
--   moves     GAS abilities (GA_Hun_Young_A, ..._AdvancedDash, ...) in the ASC's ActivatableAbilities
--   aggro     the hatred component's AddActorToHatredList
--   items     APBZPickupActor.ItemId, UPBZBackPackSubsystem::AddPropsToBackPack

return function(api)
    local log, valid, distance = api.log, api.valid, api.distance

    local PLAYER_CLASS_PREFIX = "BP_Renewal_Hun"   -- Hun's classes (young/adult); never treated as enemies
    local CODEX_TABLE = "/Game/PBZContent/DataTable/DT_CodexEnemyDataTable.DT_CodexEnemyDataTable"
    local DIE_DAMAGED, DIE_GAME_LOGIC = 1, 3        -- EPBZDieReason
    local SPAWN_ADJUST_ALWAYS = 2                   -- ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn
    local SCALE_MULTIPLY_WITH_ROOT = 1              -- ESpawnActorScaleMethod::MultiplyWithRoot
    local GHOST_AGGRO_CM = 2500                     -- enemies this close to the ghost also hate it
    local PICKUP_WATCH_CM = 500                     -- a vanished pickup this close to the local player was taken by them
    local GHOST_BUSY_S = 0.6                        -- after replaying a move, don't steer the ghost for this long

    local game = { commands = {} }
    local bosses = {}             -- actor address -> true, from RegisterBossHPBar
    local codexBoss = {}          -- class name (without _C) -> bIsBoss, filled lazily
    local syncing = false         -- true while the mod itself changes health, so OnDamage isn't re-reported
    local ghostBusyUntil = 0

    local function className(actor)
        return actor:GetClass():GetFName():ToString()
    end

    local function lib(path)
        return StaticFindObject(path)
    end

    local function worldSubsystem(contextActor, classPath)
        local bl = lib("/Script/Engine.Default__SubsystemBlueprintLibrary")
        local cls = lib(classPath)
        if not valid(bl) or not valid(cls) then
            return nil
        end
        local s = bl:GetWorldSubsystem(contextActor, cls)
        return valid(s) and s or nil
    end

    local function codexRow(name)
        local dt = lib(CODEX_TABLE)
        if not valid(dt) then
            return nil
        end
        local ok, row = pcall(function() return dt:FindRow(name) end)
        return ok and row or nil
    end

    ------------------------------------------------------------------ enemies and health

    local function isEnemy(actor)
        if not valid(actor) then
            return false
        end
        local cn = className(actor)
        if cn:find(PLAYER_CLASS_PREFIX, 1, true) then
            return false
        end
        local ok, monster = pcall(function() return actor.BIsMonster end)
        return (ok and monster == true) or cn:find("^BP_Monster") ~= nil
    end
    game.isEnemy = isEnemy

    -- Enemy ids that are the same on both PCs. Runtime actor names are not (the same placed character was
    -- ..._2147476826 in one session and ..._2147477757 in the next), but enemies come from level-placed
    -- AISpawners whose designer SpawnerID ("ZuoShangyoung_Seq003") is stable, so an enemy made by a spawner is
    -- "sp:<SpawnerID>". Others keep their actor name, and coop.lua falls back to class + position matching.
    -- Scanning every AISpawner is slow, so at most once per ID_REFRESH_S unless forced.
    local ID_REFRESH_S = 1.0
    local spawnerIds = {}
    local idsRefreshedAt = nil
    function game.refreshEnemyIds(force)
        local now = os.clock()
        if not force and idsRefreshedAt ~= nil and now - idsRefreshedAt < ID_REFRESH_S then
            return
        end
        idsRefreshedAt = now
        local refreshed = {}
        for _, s in ipairs(FindAllOf("AISpawner") or {}) do
            pcall(function()
                local a = s.SpawnedAI
                if valid(a) then
                    local sid = s.SpawnerID:ToString()
                    -- Empty/unassigned spawners expose FName_None as the literal "None". Treat it as absent;
                    -- otherwise every such enemy collapses into the same sp:None network key.
                    if sid and sid ~= "" and sid:lower() ~= "none" and not sid:find("%s") then
                        refreshed[a:GetAddress()] = { id = "sp:" .. sid, actor = a }
                    end
                end
            end)
        end
        local activeIds = {}
        for _, entry in pairs(refreshed) do
            activeIds[entry.id] = true
        end
        -- Keep an assigned id while its actor remains valid, even if the spawner clears SpawnedAI on death.
        for addr, entry in pairs(spawnerIds) do
            if refreshed[addr] == nil and not activeIds[entry.id] and valid(entry.actor) then
                refreshed[addr] = entry
                activeIds[entry.id] = true
            end
        end
        spawnerIds = refreshed
    end

    function game.enemyId(actor)
        local entry = spawnerIds[actor:GetAddress()]
        return (entry and entry.id) or actor:GetFName():ToString()
    end

    function game.enemyClass(actor)
        return className(actor)
    end

    -- spawner <SpawnerID|list>: make a level AISpawner spawn its enemy, as the game's encounter scripts do.
    game.commands.spawner = function(id)
        for _, s in ipairs(FindAllOf("AISpawner") or {}) do
            local sid = "?"
            pcall(function() sid = s.SpawnerID:ToString() end)
            if id == nil or id == "" or id == "list" then
                log("  spawner " .. sid)
            elseif sid == id then
                local ok, err = pcall(function() s:ClaimSeqSpawn(false, true, true) end)
                log("ClaimSeqSpawn(" .. sid .. "): " .. tostring(ok) .. " " .. tostring(err))
                return
            end
        end
    end

    -- Cached for ENEMY_CACHE_S: the host and client halves (and aggro) all ask within the same tick.
    -- fresh = true skips the cache.
    local ENEMY_CACHE_S = 0.1
    local enemyCache, enemyCacheAt = nil, nil
    function game.listEnemies(fresh)
        local now = os.clock()
        if not fresh and enemyCache ~= nil and now - enemyCacheAt < ENEMY_CACHE_S then
            return enemyCache
        end
        local out = {}
        for _, ch in ipairs(FindAllOf("PBZCharacter_NPC") or {}) do
            if isEnemy(ch) then
                out[#out + 1] = ch
            end
        end
        enemyCache, enemyCacheAt = out, now
        return out
    end

    function game.getHealth(actor)
        local ok, hp, maxhp = pcall(function()
            local set = actor.AttributeSetBase
            return set.Health.CurrentValue, set.Health_Max.CurrentValue
        end)
        -- A stale actor (e.g. one replaced by a respawn) can hand back an object instead of a number.
        if ok and type(hp) == "number" and type(maxhp) == "number" then
            return hp, maxhp
        end
        return nil, nil
    end

    function game.setHealth(actor, hp)
        local cur = game.getHealth(actor)
        if cur == nil or math.abs(cur - hp) < 0.5 then
            return
        end
        syncing = true
        pcall(function()
            local h = actor.AttributeSetBase.Health
            h.BaseValue = hp
            h.CurrentValue = hp
        end)
        syncing = false
    end

    -- IsDead() stayed false on a thug at 0 HP during its death animation, so health counts too.
    function game.isDead(actor)
        local hp = game.getHealth(actor)
        if hp ~= nil and hp <= 0 then
            return true
        end
        local ok, dead = pcall(function() return actor:IsDead() end)
        return ok and dead == true
    end

    -- A boss that died (or a bell respawn, see coop.lua) leaves the registry, so its next fight is announced again.
    local function forgetBoss(actor)
        pcall(function() bosses[actor:GetAddress()] = nil end)
    end

    function game.resetBosses()
        bosses = {}
    end

    -- Restore each actor's previous floor when the temporary co-op authority lock ends.
    local minHealthOriginals = {}
    function game.setMinHealth(actor, value)
        pcall(function()
            local addr = actor:GetAddress()
            local m = actor.AttributeSetBase.Health_Min
            if value == 0 then
                local original = minHealthOriginals[addr]
                if original and valid(original.actor) then
                    m.BaseValue = original.base
                    m.CurrentValue = original.current
                    minHealthOriginals[addr] = nil
                else
                    minHealthOriginals[addr] = nil
                    m.BaseValue = 0
                    m.CurrentValue = 0
                end
                return
            end
            local original = minHealthOriginals[addr]
            if not original or not valid(original.actor) then
                minHealthOriginals[addr] = { actor = actor, base = m.BaseValue, current = m.CurrentValue }
            end
            m.BaseValue = value
            m.CurrentValue = value
        end)
    end

    function game.kill(actor)
        forgetBoss(actor)
        game.setMinHealth(actor, 0)
        syncing = true
        local ok, err = pcall(function() actor:Kill(DIE_GAME_LOGIC) end)
        syncing = false
        if not ok then
            log("Kill failed: " .. tostring(err))
        end
    end

    -- Posture ("Shachi"): breaking it opens an execution.
    function game.getPosture(actor)
        local ok, v = pcall(function() return actor.AttributeSetBase.Shachi.CurrentValue end)
        return (ok and type(v) == "number") and v or nil
    end

    function game.setPosture(actor, value)
        syncing = true
        pcall(function()
            local s = actor.AttributeSetBase.Shachi
            s.BaseValue = value
            s.CurrentValue = value
        end)
        syncing = false
    end

    -- Host: the client's player hit this enemy. Lower its health and posture; at zero health, let the game run
    -- its death.
    function game.applyDamage(actor, amount, postureDamage)
        local hp = game.getHealth(actor)
        if hp == nil or hp <= 0 then
            return
        end
        local posture = game.getPosture(actor)
        if posture and postureDamage and postureDamage > 0 then
            game.setPosture(actor, math.max(0, posture - postureDamage))
        end
        local left = math.max(0, hp - amount)
        game.setHealth(actor, left)
        if left <= 0 then
            forgetBoss(actor)
            syncing = true
            pcall(function() actor:Kill(DIE_DAMAGED) end)
            syncing = false
        end
    end

    -- A native kill (death by damage) rolls the enemy's loot table (GetCombatLootDataForOwner, owner = the enemy,
    -- at its "Level" attribute). Kill(), which the host uses for the client's killing blow, skips it, so that kill
    -- would pay nothing: the host rolls the same table here. Returns dust and { itemId = count }.
    -- (Prologue enemies are level 0, which pays nothing; "lootlevel <n>" overrides the level for testing.)
    game.lootLevelOverride = nil
    function game.rollLoot(actor)
        local level = game.lootLevelOverride
        if level == nil then
            local ok, v = pcall(function() return actor.AttributeSetBase.Level.CurrentValue end)
            level = (ok and type(v) == "number") and math.floor(v + 0.5) or 0
        end
        local data = {}
        if not pcall(function() actor:GetCombatLootDataBySelf(level, data) end) then
            return 0, {}, level
        end
        local dust = tonumber(data.LootDust) or 0
        local items = {}
        pcall(function()
            data.LootItems:ForEach(function(k, v)
                items[k:get():ToString()] = v:get()
            end)
        end)
        return dust, items, level
    end

    game.commands.lootlevel = function(arg)
        game.lootLevelOverride = tonumber(arg)
        log("Loot level override: " .. tostring(game.lootLevelOverride) .. " (empty = the enemy's own level)")
    end

    function game.isBoss(actor)
        if bosses[actor:GetAddress()] then
            return true
        end
        local cn = className(actor):gsub("_C$", "")
        if codexBoss[cn] == nil then
            local row = codexRow(cn)
            codexBoss[cn] = row ~= nil and row.bIsBoss == true
        end
        return codexBoss[cn]
    end

    -- The HUD registers a boss health bar when a boss fight starts: the surest way to know who the boss is.
    local showingRemoteBoss = false
    pcall(function()
        RegisterHook("/Script/ProjectPBZ.PBZHUDLayout:RegisterBossHPBar", function(_, bossParam)
            local boss = bossParam:get()
            if valid(boss) and not bosses[boss:GetAddress()] then
                bosses[boss:GetAddress()] = true
                log("Boss fight: " .. boss:GetFName():ToString())
                if api.coop and not showingRemoteBoss then
                    -- The same cross-PC id the snapshots use (sp:<SpawnerID> for spawner bosses).
                    game.refreshEnemyIds(true)
                    api.coop.sendEvent("B", game.enemyId(boss))
                end
            end
        end)
    end)

    -- The other player's game started a fight with this boss: show its health bar here too (our copy of the
    -- boss mirrors the host's health, so the bar follows the real fight).
    function game.showBossBar(boss)
        if not valid(boss) or bosses[boss:GetAddress()] then
            return
        end
        local hud = FindFirstOf("PBZHUDLayout")
        if not valid(hud) then
            log("No HUD layout to show the boss bar on.")
            return
        end
        showingRemoteBoss = true
        local ok, err = pcall(function() hud:RegisterBossHPBar(boss) end)
        showingRemoteBoss = false
        bosses[boss:GetAddress()] = true
        log(ok and ("Showing boss bar for " .. boss:GetFName():ToString()) or ("Boss bar failed: " .. tostring(err)))
    end

    -- Boss arenas are sealed by fog walls (BP_FogDoor_C). When the other player's boss fight starts, close the
    -- fog walls near our copy of the boss; when the boss dies, open them.
    local FOG_RADIUS_CM = 6000
    function game.setBossFog(boss, closed)
        if not valid(boss) then
            return 0
        end
        local at = boss:K2_GetActorLocation()
        local n = 0
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local ok, loc = pcall(function() return door:K2_GetActorLocation() end)
            if ok and loc.X and distance(loc, at) <= FOG_RADIUS_CM then
                local fn = closed and "Close By Mob Script" or "OpenByMobScript"
                if pcall(function() door[fn](door) end) then
                    n = n + 1
                end
            end
        end
        if n > 0 then
            log(string.format("%s %d fog wall(s) at %s.", closed and "Closed" or "Opened", n, boss:GetFName():ToString()))
        end
        return n
    end

    -- fog: test helper, list fog walls with distance to player 1 and their state.
    game.commands.fog = function()
        local _, pawn = api.getPlayer1()
        local here = pawn:K2_GetActorLocation()
        for _, door in ipairs(FindAllOf("BP_FogDoor_C") or {}) do
            local st = "?"
            pcall(function() st = tostring(door.bDesiredState) end)
            log(string.format("  %s desired=%s %.0f m", door:GetFName():ToString():sub(-24), st,
                distance(door:K2_GetActorLocation(), here) / 100))
        end
    end

    -- bossbar: test helper, start the boss bar for the nearest boss as if its fight began.
    game.commands.bossbar = function()
        for _, e in ipairs(game.listEnemies()) do
            if game.isBoss(e) and not game.isDead(e) then
                local hud = FindFirstOf("PBZHUDLayout")
                local ok, err = pcall(function() hud:RegisterBossHPBar(e) end)
                log("RegisterBossHPBar(" .. e:GetFName():ToString() .. "): " .. tostring(ok) .. " " .. tostring(err))
                return
            end
        end
        log("No living boss loaded.")
    end

    -- Note: APBZCharacter::OnDamage looked like the place to catch hits, but PBZ calls it natively and a UE4SS
    -- hook never fires, so coop.lua detects hits by watching health and posture drop instead.

    ------------------------------------------------------------------ moves (attacks, dodges, parries)

    -- pcall: for a frame while the game swaps the player (loading, respawn) this call failed once with "UFunction
    -- expected 1 parameters, received 3"; no ability system this tick, try again next one.
    local function abilitySystem(actor)
        local bl = lib("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        if not valid(bl) or not valid(actor) then
            return nil
        end
        local ok, asc = pcall(function() return bl:GetAbilitySystemComponent(actor) end)
        return (ok and valid(asc)) and asc or nil
    end

    local function forEachSpec(asc, fn)
        local ok = pcall(function()
            asc.ActivatableAbilities.Items:ForEach(function(_, elem)
                fn(elem:get())
            end)
        end)
        return ok
    end

    local activeLocal = {}        -- ability class path -> true while active on the local player
    local localMoveAt, ghostMoveAt = -1e9, -1e9   -- os.clock() when the local player / the ghost last started a move

    -- Who caused an enemy's health drop: the local player's swing (a real hit to report) or the ghost's replay
    -- of the other player's swing (that hit is the other PC's, already reported there: counting it here would
    -- double it).
    function game.localMoveRecent(seconds)
        return os.clock() - localMoveAt <= seconds
    end

    function game.ghostMoveRecent(seconds)
        return os.clock() - ghostMoveAt <= seconds
    end

    -- The ghost started one of the partner's moves some other way (a montage, moves.lua): don't steer it while
    -- the move's own motion plays, and count it for the hit attribution above.
    function game.noteGhostMove()
        ghostBusyUntil = os.clock() + GHOST_BUSY_S
        ghostMoveAt = os.clock()
    end

    -- Called every snapshot: any GA_* ability that just became active on the local player is sent as a move.
    function game.watchLocalPlayer(pawn, sendEvent)
        local asc = abilitySystem(pawn)
        if not asc then
            return
        end
        local nowActive = {}
        forEachSpec(asc, function(spec)
            local ability = spec.Ability
            if spec.ActiveCount > 0 and valid(ability) then
                local cls = ability:GetClass()
                local name = cls:GetFName():ToString()
                -- Only Hun's own moves (GA_Hun_Young_A, ..._AdvancedDash, ...); background abilities such as
                -- GA_LocomotionDriver_3DDefault are always active and aren't moves.
                if name:find("^GA_Hun") and not name:find("Passive", 1, true) then
                    local path = cls:GetFullName():gsub("^%S+ ", "")
                    nowActive[path] = true
                    if not activeLocal[path] then
                        -- The facing at the start of the move, so the ghost swings where the player aimed.
                        sendEvent("M", path, string.format("%.1f", pawn:K2_GetActorRotation().Yaw))
                        localMoveAt = os.clock()
                    end
                end
            end
        end)
        activeLocal = nowActive
    end

    -- Replays the remote player's move on the ghost. Gives the ability first if the ghost lacks it.
    local loadTried = {}          -- class path -> true once we tried loading it (a failed load isn't retried)
    function game.playMove(ghost, classPath, yaw)
        local cls = StaticFindObject(classPath)
        if not valid(cls) and not loadTried[classPath] and type(LoadAsset) == "function" then
            -- A move of a weapon the local player doesn't carry isn't in memory yet (other weapons, Phantom Edge).
            loadTried[classPath] = true
            pcall(LoadAsset, classPath)
            cls = StaticFindObject(classPath)
        end
        if not valid(cls) then
            log("Move class not loaded here: " .. classPath)
            return
        end
        local asc = abilitySystem(ghost)
        if not asc then
            return
        end
        if yaw then
            pcall(function() ghost:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false) end)
            game.lastMoveYaw = yaw
        end
        local ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        if not (ok and activated) then
            pcall(function() asc:K2_GiveAbility(cls, 1, -1) end)
            ok, activated = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
        end
        ghostBusyUntil = os.clock() + GHOST_BUSY_S
        ghostMoveAt = os.clock()
        if not (ok and activated) then
            log("Ghost couldn't play " .. classPath:match("([^.]+)$"))
        end
    end

    ------------------------------------------------------------------ hit reactions

    -- Scans every HitreactComponent, so after a miss the same actor isn't scanned again for HITREACT_RETRY_S.
    local HITREACT_RETRY_S = 2.0
    local hitreactMissUntil = {}  -- actor address -> os.clock() before which a lookup returns nil straight away
    local function hitreactComponent(actor)
        local addr = actor:GetAddress()
        if hitreactMissUntil[addr] ~= nil and os.clock() < hitreactMissUntil[addr] then
            return nil
        end
        for _, c in ipairs(FindAllOf("HitreactComponent") or {}) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == addr then
                hitreactMissUntil[addr] = nil
                return c
            end
        end
        hitreactMissUntil[addr] = os.clock() + HITREACT_RETRY_S
        return nil
    end

    local localHitComp, lastHitState = nil, "None"

    -- Called every snapshot: when the local player starts reacting to a hit (stagger, knockdown...), send the
    -- hit state's tag so the other player's ghost of us reacts the same way.
    function game.watchHitState(pawn, sendEvent)
        if not valid(localHitComp) then
            localHitComp = hitreactComponent(pawn)
            if not localHitComp then
                return
            end
        end
        local ok, tag = pcall(function() return localHitComp:GetCurrentHitState().TagName:ToString() end)
        if not ok then
            return
        end
        if tag ~= lastHitState and tag ~= "None" then
            sendEvent("H", tag)
        end
        lastHitState = tag
    end

    local clearHitStateLater      -- defined below with staggerSelf
    local ghostHitComp = nil
    function game.playHitReaction(ghost, tag)
        if not valid(ghostHitComp) or ghostHitComp:GetOwner():GetAddress() ~= ghost:GetAddress() then
            ghostHitComp = hitreactComponent(ghost)
        end
        if ghostHitComp then
            -- Already reacting (on the host, enemies here hit the ghost too): one stagger, not the same one twice.
            local okCur, cur = pcall(function() return ghostHitComp:GetCurrentHitState().TagName:ToString() end)
            if okCur and cur ~= "None" then
                return
            end
            local ok, err = pcall(function() ghostHitComp:ChangeHitState({ TagName = FName(tag) }, nil, false) end)
            if not ok then
                log("Ghost hit reaction failed: " .. tostring(err))
            else
                clearHitStateLater(ghostHitComp, tag)
            end
            ghostBusyUntil = os.clock() + GHOST_BUSY_S
        end
    end

    -- Delayed actions on the game thread. One loop runs them all: a LoopInGameThreadWithDelay callback that returned
    -- true kept running in this UE4SS (the victory screen's hide timer then failed 300 times on a cleared value), so
    -- no loop here relies on stopping itself. game.after(seconds, fn) runs fn once; fn may schedule itself again.
    local timers = {}
    local schedulerStarted = false
    function game.after(seconds, fn)
        timers[#timers + 1] = { at = os.clock() + seconds, fn = fn }
        if not schedulerStarted then
            schedulerStarted = true
            LoopInGameThreadWithDelay(16, function()
                if #timers == 0 then
                    return false
                end
                local now, due, keep = os.clock(), {}, {}
                for _, t in ipairs(timers) do
                    if now >= t.at then
                        due[#due + 1] = t
                    else
                        keep[#keep + 1] = t
                    end
                end
                timers = keep
                for _, t in ipairs(due) do
                    local ok, err = pcall(t.fn)
                    if not ok then
                        log("Timer error: " .. tostring(err))
                    end
                end
                return false
            end)
        end
    end

    -- A hit state set by hand has no animation to end it, and while it lasts the character can't start a move
    -- (a PvP attacker stayed stuck after a parry). Clear it again after a moment, unless something replaced it.
    local HIT_STATE_HOLD_S = 0.9
    clearHitStateLater = function(comp, tag)
        game.after(HIT_STATE_HOLD_S, function()
            if comp:GetCurrentHitState().TagName:ToString() == tag then
                comp:ChangeHitState({ TagName = FName("None") }, nil, false)
            end
        end)
    end

    -- PvP: the local player reacts to a hit the game itself didn't deal (a parried swing).
    function game.staggerSelf(pawn, tag)
        local comp = hitreactComponent(pawn)
        if comp and pcall(function() comp:ChangeHitState({ TagName = FName(tag) }, nil, false) end) then
            clearHitStateLater(comp, tag)
        end
    end

    ------------------------------------------------------------------ PvP victory screen

    -- The game's own death screen (W_PlayerDead: red 殒命 calligraphy over blood, "DEAD"), turned into a golden
    -- 生还 / ALIVE for the duel's winner. Made once and only ever shown and hidden: removing this widget runs the
    -- death flow's "Refresh Monster" (enemies respawn), so it must never be removed. It ignores clicks and isn't
    -- activated, so it takes no input; its Return-to-menu button is hidden.
    local aliveScreen = nil
    local aliveScreenPainted = false
    local aliveHideAt = nil
    local GOLD = { R = 1.0, G = 0.72, B = 0.22, A = 1.0 }

    local function makeAliveScreen()
        local pc = api.getPlayer1()
        local cls = FindObject("WidgetBlueprintGeneratedClass", "W_PlayerDead_C")
        if not valid(pc) or not valid(cls) then
            return nil
        end
        local w = lib("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, cls, pc)
        if not valid(w) then
            return nil
        end
        w:SetVisibility(1)                                    -- collapsed until a duel is won
        w:AddToViewport(500)
        local function try(f) pcall(f) end
        try(function() w:StopAllAnimations() end)
        -- 殒命, DEAD, Return button, days counter, and the blood: the victory screen is clean gold on dark.
        for _, n in ipairs({ "yun", "ming", "Image_89", "ReturnButton", "DiedTimeBox", "Image_48", "NumText",
            "Blood1", "Blood2" }) do
            try(function() w[n]:SetVisibility(1) end)
        end
        try(function() w.red:SetRenderOpacity(0.5) end)       -- the dark backdrop stays, softer
        -- 生 over 还: a gilded ink-brush painting (art/shenghuan.png, painted in Lumina after the screen's own
        -- 殒命), shown in 殒's image slot. 命's slot stays hidden: the two slots overlap by design.
        aliveScreenPainted = false
        try(function()
            local tex = lib("/Script/Engine.Default__KismetRenderingLibrary"):ImportFileAsTexture2D(pc,
                api.modRoot() .. "art/shenghuan.png")
            if valid(tex) then
                w.yun:SetBrushFromTexture(tex, false)
                local b = w.yun.Brush
                b.ImageSize = { X = 380, Y = 380 * tex:Blueprint_GetSizeY() / tex:Blueprint_GetSizeX() }
                w.yun:SetBrush(b)
                -- 殒's slot is offset upward for 殒命's layout; the two stacked characters sit centered without it.
                -- Nudged right: the brush tails sweep out to the right, so the image's middle is right of the
                -- characters' own middle; this puts the characters over ALIVE.
                w.yun:SetRenderTranslation({ X = 28, Y = 0 })
                w.yun:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
                w.yun:SetVisibility(3)
                aliveScreenPainted = true
            end
        end)
        if aliveScreenPainted then
            try(function() w.DeadText:SetVisibility(1) end)
        end
        -- Without the painting: 生 over 还 in the game's ink-brush font (simplified, like the screen's own 殒命;
        -- the font has no traditional 還), standing where 殒命 was.
        try(function()
            if aliveScreenPainted then
                return
            end
            local brush = nil
            for _, f in ipairs(FindAllOf("Font") or {}) do
                if f:GetFName():ToString() == "BaiGeTianXingTi_small_Font" then
                    brush = f
                end
            end
            w.DeadText:SetText(FText("生\n还"))
            w.DeadText:SetColorAndOpacity({ SpecifiedColor = GOLD, ColorUseRule = 0 })
            local f = w.DeadText.Font
            if brush then
                f.FontObject = brush
            end
            f.Size = 200
            -- Gilded brushwork: a thin dark-bronze edge around the gold strokes...
            pcall(function()
                f.OutlineSettings.OutlineSize = 3
                f.OutlineSettings.OutlineColor = { R = 0.18, G = 0.08, B = 0.02, A = 0.9 }
            end)
            w.DeadText:SetFont(f)
            -- ...and ink soaking into the paper below them.
            pcall(function()
                w.DeadText:SetShadowOffset({ X = 6, Y = 8 })
                w.DeadText:SetShadowColorAndOpacity({ R = 0.05, G = 0.0, B = 0.0, A = 0.85 })
            end)
            w.DeadText:SetAutoWrapText(false)
            w.DeadText:SetVisibility(3)
            w.DeadText:GetParent():SetVisibility(3)
        end)
        try(function()
            w.DeadRichText:SetText(FText("A L I V E"))
            w.DeadRichText:SetDefaultColorAndOpacity({ SpecifiedColor = GOLD, ColorUseRule = 0 })
        end)
        return w
    end

    -- ALIVE sits in a language switcher that shows the localized DEAD image by default: switch to the text,
    -- every time (the widget can reset it).
    local function showAliveWord(w)
        pcall(function()
            local sw = w.PBZLanguageWidgetSwitcher_31
            sw:SetVisibility(3)
            sw:SetRenderOpacity(1)
            sw:SetActiveWidget(w.DeadRichText)
            w.DeadRichText:SetVisibility(3)
            w.DeadRichText:SetRenderOpacity(1)
        end)
    end

    -- The winner died (an enemy, a fall) while the victory screen showed: the death screen must not wear it.
    function game.hideAliveScreen()
        if valid(aliveScreen) and aliveHideAt then
            aliveScreen:SetVisibility(1)
            aliveHideAt = nil
        end
    end

    function game.showAliveScreen(seconds)
        if not valid(aliveScreen) then
            aliveScreen = makeAliveScreen()
        end
        if not valid(aliveScreen) then
            return false
        end
        showAliveWord(aliveScreen)
        aliveScreen:SetVisibility(3)                          -- HitTestInvisible: seen, never clicked
        -- The death screen's own entrance (Deadpopup, 5 s): the world darkens and the calligraphy appears exactly
        -- as 殒命 does. It leaves the hidden parts (DEAD, blood, 命) hidden.
        local w, t = aliveScreen, 0
        local animated = aliveScreenPainted
            and pcall(function() w:PlayAnimation(w.Deadpopup, 0, 1, 0, 1, false) end)
        if not animated then
            -- Font fallback: the strokes land, 生还 fading in from 125% to full size, then ALIVE fades in.
            pcall(function()
                w.DeadText:SetRenderOpacity(0)
                w.DeadText:SetRenderScale({ X = 1.25, Y = 1.25 })
                w.DeadRichText:SetRenderOpacity(0)
            end)
            local start = os.clock()
            local function frame()
                t = os.clock() - start
                local a = math.min(1, t / 0.5)
                local ease = 1 - (1 - a) * (1 - a)            -- fast landing, soft settle
                w.DeadText:SetRenderOpacity(ease)
                local s = 1.25 - 0.25 * ease
                w.DeadText:SetRenderScale({ X = s, Y = s })
                w.DeadRichText:SetRenderOpacity(math.max(0, math.min(1, (t - 0.4) / 0.5)))
                if t < 0.9 then
                    game.after(0.016, frame)
                end
            end
            game.after(0, frame)
        end
        -- Hidden again after `seconds`; a new win while it shows restarts the clock (only the last timer hides it).
        aliveHideAt = os.clock() + (seconds or 6)
        local mine = aliveHideAt
        game.after(seconds or 6, function()
            if aliveHideAt == mine then
                aliveScreen:SetVisibility(1)
                aliveHideAt = nil
            end
        end)
        return true
    end

    function game.ghostBusy()
        return os.clock() < ghostBusyUntil
    end

    -- The ghost is a full Hun: make it harmless (the remote player's hits arrive as reported damage) and let
    -- nearby enemies hate it so they fight it as well as the local player.
    function game.setupGhost(ghost)
        local _, pawn = api.getPlayer1()
        local ok, dst = pcall(function() return ghost.AttributeSetBase end)
        if not ok or not dst then
            log("Ghost setup: no AttributeSetBase.")
            return
        end
        pcall(function()
            local atk = dst.Attack
            atk.BaseValue = 0
            atk.CurrentValue = 0
        end)
        local src
        if valid(pawn) then
            pcall(function() src = pawn.AttributeSetBase end)
        end
        if not src then
            log("Ghost setup: local AttributeSetBase unavailable; using default ghost attributes.")
            return
        end
        for _, name in ipairs({ "Health_Max", "Shachi_Max", "Health", "Shachi" }) do
            pcall(function()
                local from, to = src[name], dst[name]
                if from and to and type(from.CurrentValue) == "number" then
                    to.BaseValue = from.CurrentValue
                    to.CurrentValue = from.CurrentValue
                end
            end)
        end
        pcall(function()
            local min = dst.Health_Min
            if min then
                min.BaseValue = 1
                min.CurrentValue = 1
            end
        end)
    end

    -- Every second (host): the ghost stays at full health, since the remote player's real health lives on
    -- their PC, and enemies close to it add it to their hatred list.
    -- (In PvP the ghost's health shows the remote player's real health instead: pvp.lua sets it.)
    function game.ghostAggro(ghost, pvp)
        local _, maxhp = game.getHealth(ghost)
        if maxhp and not pvp then
            game.setHealth(ghost, maxhp)
        end
        local g = ghost:K2_GetActorLocation()
        for _, e in ipairs(game.listEnemies()) do
            local ok, loc = pcall(function() return e:K2_GetActorLocation() end)
            if ok and loc.X and distance(loc, g) <= GHOST_AGGRO_CM and not game.isDead(e) then
                pcall(function()
                    local hm = e.BP_PBZHatredManagerComponent
                    local list = hm.HatredList
                    local already = false
                    list:ForEach(function(_, a)
                        local actor = a:get()
                        if valid(actor) and actor:GetAddress() == ghost:GetAddress() then
                            already = true
                        end
                    end)
                    if not already then
                        hm:AddActorToHatredList(ghost, {})
                    end
                end)
            end
        end
    end

    ------------------------------------------------------------------ bells (rest = enemies respawn)

    -- Resting at a bell (and respawning after death) runs the game mode's "Refresh Monster", which respawns the
    -- regular enemies (bosses the game considers beaten stay dead). When it runs on one PC, the other PC runs
    -- its own, so both worlds respawn together. The hook is registered once gameplay is up (the blueprint must
    -- be loaded first).
    -- The player's respawn after death runs its own "Respawn Refresh Monster" step, which calls the game mode's
    -- Refresh Monster: hooked too, so a death respawn can be told from a bell rest (onRest gets "death"/"bell").
    local REFRESH_FN = "/Game/PBZContent/Blueprint/BP_GameMode_Build.BP_GameMode_Build_C:Refresh Monster"
    local RESPAWN_REFRESH_FN = "/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C:Respawn Refresh Monster"
    local RESPAWN_WINDOW_S = 3.0
    local restHooked, refreshing = false, false
    local respawnRefreshAt = nil

    function game.hookRest(onRest)
        if restHooked or not valid(StaticFindObject(REFRESH_FN)) then
            return restHooked
        end
        if valid(StaticFindObject(RESPAWN_REFRESH_FN)) then
            local okR, errR = pcall(function()
                RegisterHook(RESPAWN_REFRESH_FN, function()
                    respawnRefreshAt = os.clock()
                end)
            end)
            if not okR then
                log("Respawn hook failed (deaths will count as bell rests): " .. tostring(errR))
            end
        end
        local ok, err = pcall(function()
            RegisterHook(REFRESH_FN, function()
                if refreshing then
                    return
                end
                -- Blueprint hooks run after their function, so the respawn step's hook (the caller) only runs
                -- once Refresh Monster (the callee) is done: decide a moment later, when both have reported.
                local at = os.clock()
                game.after(0.5, function()
                    local death = respawnRefreshAt ~= nil and math.abs(respawnRefreshAt - at) <= RESPAWN_WINDOW_S
                    respawnRefreshAt = nil
                    onRest(death and "death" or "bell")
                end)
            end)
        end)
        restHooked = ok
        log(ok and "Bell/respawn hook ready." or ("Bell hook failed: " .. tostring(err)))
        return restHooked
    end

    -- The other player rested: respawn our regular enemies too.
    function game.refreshEnemies()
        local pc = api.getPlayer1()
        local gm = valid(pc) and api.gs():GetGameMode(pc) or nil
        if not valid(gm) then
            return false
        end
        refreshing = true
        local ok, err = pcall(function() gm["Refresh Monster"](gm) end)
        refreshing = false
        if not ok then
            log("Refresh Monster failed: " .. tostring(err))
        end
        return ok
    end

    -- respawnrefresh: test helper, run the respawn's own monster refresh step as if player 1 had died and respawned
    -- (only that step: no save, no days lost, no teleport).
    game.commands.respawnrefresh = function()
        local _, pawn = api.getPlayer1()
        local ok, err = pcall(function() pawn["Respawn Refresh Monster"](pawn) end)
        log("Respawn Refresh Monster: " .. tostring(ok) .. " " .. tostring(err))
    end

    ------------------------------------------------------------------ spectating

    -- While the local player is dead, the camera can follow the other player's ghost. The game's death screen is
    -- dimmed, not removed or hidden (it drives the respawn: removing it runs Refresh Monster, and a hidden widget
    -- may stop ticking), and comes back the moment we stop.
    -- The view comes from a camera of our own placed behind and above the partner every frame, looking at them:
    -- the ghost's own camera can't be used (it follows a controller the ghost doesn't have, so it sat in the
    -- bamboo looking nowhere).
    local spectating = nil        -- the actor the camera follows, or nil
    local spectateCam = nil
    local DEATH_SCREEN_DIM = 0.25
    local CAM_BACK_CM, CAM_UP_CM, CAM_FOLLOW = 380, 170, 0.12   -- behind, above, fraction of the way per frame

    local function deathScreen(pawn)
        local ok, w = pcall(function() return pawn["Death Widget"] end)
        return (ok and valid(w)) and w or nil
    end

    local function camSpot(target)
        local l = target:K2_GetActorLocation()
        local yaw = math.rad(target:K2_GetActorRotation().Yaw)
        return { X = l.X - math.cos(yaw) * CAM_BACK_CM, Y = l.Y - math.sin(yaw) * CAM_BACK_CM, Z = l.Z + CAM_UP_CM }, l
    end

    local function aim(from, at)
        local dx, dy, dz = at.X - from.X, at.Y - from.Y, (at.Z + 60) - from.Z
        return { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0.0 }
    end

    local function followFrame()
        if not (spectating and valid(spectating) and valid(spectateCam)) then
            return
        end
        local want, at = camSpot(spectating)
        local cur = spectateCam:K2_GetActorLocation()
        local a = CAM_FOLLOW
        local pos = { X = cur.X + (want.X - cur.X) * a, Y = cur.Y + (want.Y - cur.Y) * a, Z = cur.Z + (want.Z - cur.Z) * a }
        spectateCam:K2_SetActorLocationAndRotation(pos, aim(pos, at), false, {}, true)
        game.after(0.016, followFrame)
    end

    function game.spectate(target)
        local pc, pawn = api.getPlayer1()
        if not valid(pc) or not valid(pawn) then
            return false
        end
        local follow = valid(target) and target or nil
        if (follow and spectating and follow:GetAddress() == spectating:GetAddress()) or (not follow and not spectating) then
            return true
        end
        local ok = true
        if follow then
            if not valid(spectateCam) then
                local spot, at = camSpot(follow)
                local gs = api.gs()
                local t = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = spot, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
                ok = pcall(function()
                    local cam = gs:BeginDeferredActorSpawnFromClass(pc, StaticFindObject("/Script/Engine.CameraActor"), t,
                        SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
                    spectateCam = gs:FinishSpawningActor(cam, t, SCALE_MULTIPLY_WITH_ROOT)
                    spectateCam:K2_SetActorLocationAndRotation(spot, aim(spot, at), false, {}, true)
                end) and valid(spectateCam)
            end
            ok = ok and pcall(function() pc:SetViewTargetWithBlend(spectateCam, 1.0, 0, 0, false) end)
        else
            ok = pcall(function() pc:SetViewTargetWithBlend(pawn, 0.4, 0, 0, false) end)
            if valid(spectateCam) then
                local cam = spectateCam
                game.after(0.5, function() if valid(cam) and cam ~= spectateCam then cam:K2_DestroyActor() end end)
            end
            spectateCam = nil
        end
        local w = deathScreen(pawn)
        if w then
            pcall(function() w:SetRenderOpacity(follow and ok and DEATH_SCREEN_DIM or 1.0) end)
        end
        local wasFollowing = spectating ~= nil
        spectating = (ok and follow) or nil
        if spectating and not wasFollowing then
            game.after(0.016, followFrame)
        end
        return ok
    end

    function game.isSpectating()
        return spectating ~= nil
    end

    -- rest: test helper, run the game's enemy refresh as if player 1 rested at a bell (the hook sees it).
    game.commands.rest = function()
        local pc = api.getPlayer1()
        local gm = api.gs():GetGameMode(pc)
        local before = #game.listEnemies()
        local ok, err = pcall(function() gm["Refresh Monster"](gm) end)
        log(string.format("Refresh Monster: %s %s (enemies before %d, after %d)", tostring(ok), tostring(err), before,
            #game.listEnemies(true)))
    end

    ------------------------------------------------------------------ currency (dust)

    -- Dust gained locally (kill rewards, pickups) goes to the other player too: shared rewards. Spending isn't
    -- mirrored. Amounts the mod itself added for the other player are not sent back.
    local lastDust, syncedDust = nil, 0

    local function dust(pawn)
        local ok, v = pcall(function() return pawn.ConsciousnessDust end)
        return ok and tonumber(v) or nil
    end

    function game.watchCurrency(pawn, sendEvent)
        local d = dust(pawn)
        if d == nil then
            return
        end
        if lastDust ~= nil then
            local gained = d - lastDust - syncedDust
            if gained > 0 then
                sendEvent("C", gained)
            end
        end
        lastDust, syncedDust = d, 0
    end

    function game.addCurrency(pawn, amount)
        if not valid(pawn) or amount <= 0 then
            return
        end
        local ok = pcall(function() pawn:ChangeDustNumInternal(amount) end)
        if ok then
            syncedDust = syncedDust + amount
            log("Shared dust: +" .. amount)
        end
    end

    ------------------------------------------------------------------ items

    local watched = {}            -- pickup name -> { itemId } for pickups near the local player last tick
    local takenHere = {}          -- pickup name -> true once the local player took it (until the next bell rest)

    local function pickupItemId(p)
        local ok, id = pcall(function() return p.ItemId:ToString() end)
        return ok and id or "?"
    end

    -- Called every few snapshots: pickups that were next to the local player and are now gone were taken by
    -- them. "Gone" includes a destroyed pickup that FindAllOf still returns (it stays valid until garbage
    -- collection, but loses its position) and one the game marked unpickable.
    -- After a map change (or while the pickups are unloaded mid-load: FindAllOf finds none at all) the watched
    -- pickups vanished because the level went away, not because the player took them: report nothing then.
    local PICKUP_JUMP_CM = 1000
    local watchedMap = nil
    function game.watchPickups(pawn, report)
        local here = pawn:K2_GetActorLocation()
        local all = FindAllOf("PBZPickupActor") or {}
        local map = game.mapName(pawn)
        if map ~= watchedMap or (#all == 0 and next(watched) ~= nil) then
            if map ~= watchedMap then
                takenHere = {}    -- pickup names are only unique within a map
            end
            watchedMap = map
            watched = {}
        end
        local present = {}
        for _, p in ipairs(all) do
            if valid(p) then
                local okP, pickable = pcall(function() return p.bIsPickable end)
                local okL, loc = pcall(function() return p:K2_GetActorLocation() end)
                if (not okP or pickable ~= false) and okL and loc.X then
                    present[p:GetFName():ToString()] = { actor = p, loc = loc }
                end
            end
        end
        for name, info in pairs(watched) do
            local now = present[name]
            if now == nil or distance(now.loc, info.loc) > PICKUP_JUMP_CM then
                takenHere[name] = true
                report(name, info.itemId)
                present[name] = nil
            end
        end
        watched = {}
        for name, p in pairs(present) do
            if distance(p.loc, here) <= PICKUP_WATCH_CM then
                watched[name] = { itemId = pickupItemId(p.actor), loc = p.loc }
            end
        end
    end

    -- The other player took this pickup: remove our copy and give us the same item, so loot is shared.
    function game.takeRemotePickup(name, itemId, pawn)
        if takenHere[name] then
            -- Both players grabbed it within the same moment: each already has theirs, as in single-player.
            log("The other player took " .. name .. " too; you already have yours.")
            return
        end
        for _, p in ipairs(FindAllOf("PBZPickupActor") or {}) do
            if valid(p) and p:GetFName():ToString() == name then
                watched[name] = nil
                p:K2_DestroyActor()
                break
            end
        end
        if itemId and itemId ~= "?" and valid(pawn) then
            local bp = worldSubsystem(pawn, "/Script/ProjectPBZ.PBZBackPackSubsystem")
            if bp then
                -- AddPropsToBackPack is the backpack's own entry point; if the item count didn't move (seen in the
                -- prologue map, which keeps its own restricted backpack), fall back to the player's GiveItem.
                local before = game.itemCount(bp, itemId)
                pcall(function() bp:AddPropsToBackPack(1, FName(itemId), true) end)
                local after = game.itemCount(bp, itemId)
                if after <= before then
                    pcall(function() pawn:GiveItem(FName(itemId), 1) end)
                    after = game.itemCount(bp, itemId)
                end
                log(string.format("Shared loot: %s (%d -> %d)", itemId, before, after))
            end
        end
    end

    -- How many of this item the backpack holds (0 if it has no entry).
    function game.itemCount(bp, itemId)
        local n = 0
        pcall(function()
            bp.Inventories:ForEach(function(k, v)
                if k:get():ToString() == itemId then
                    n = v:get().CurrentAmount
                end
            end)
        end)
        return n
    end

    -- Short name of the current map, so a ghost from another map isn't shown in this one.
    -- In a cutscene: the game's own level-sequence manager. The manager is looked up again only every 2 s while
    -- it isn't found (this runs with every snapshot). (From appdoze's PR #5.)
    local seqManager, seqLookupAt = nil, -1e9
    function game.inCutscene()
        if not valid(seqManager) then
            local now = os.clock()
            if now - seqLookupAt < 2.0 then
                return false
            end
            seqLookupAt = now
            seqManager = FindFirstOf("PBZLevelSequenceManager")
            if not valid(seqManager) then
                return false
            end
        end
        local ok, playing = pcall(function() return seqManager:IsInSequence() end)
        return ok and playing == true
    end

    function game.mapName(contextActor)
        local ok, name = pcall(function() return api.gs():GetCurrentLevelName(contextActor, true):ToString() end)
        return ok and name or "?"
    end

    -- Level names can contain a package path, a PIE prefix, or a persistent-level suffix. Those are runtime
    -- details and differ during streaming even when both players are in the same playable area. The normalized key
    -- is sent over the wire; the original name is kept out of the protocol so a transient suffix cannot hide a ghost.
    local function mapKeyName(name)
        local s = tostring(name or "?"):gsub("\\", "/")
        s = s:gsub("^.*[/]", "")
        s = s:gsub("^UEDPIE_%d+_", "")
        s = s:gsub("[_%-]PersistentLevel$", "")
        s = s:gsub("[_%-]persistentlevel$", "")
        return s ~= "" and s or "?"
    end

    game.mapKeyName = mapKeyName
    function game.mapKey(contextActor)
        return mapKeyName(game.mapName(contextActor))
    end

    ------------------------------------------------------------------ test helpers (commands)

    local function spawnAt(cls, loc, yaw)
        local gs = api.gs()
        local pc = api.getPlayer1()
        local t = {
            Rotation = { X = 0.0, Y = 0.0, Z = math.sin(math.rad(yaw) / 2), W = math.cos(math.rad(yaw) / 2) },
            Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        }
        local actor = gs:BeginDeferredActorSpawnFromClass(pc, cls, t, SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
        if not valid(actor) then
            return nil
        end
        actor = gs:FinishSpawningActor(actor, t, SCALE_MULTIPLY_WITH_ROOT)
        if valid(actor) then
            actor:K2_SetActorLocationAndRotation(t.Translation, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false, {}, true)
        end
        return actor
    end

    -- unlockall: every weapon and Phantom Edge weapon into the backpack, for testing moves and skills (PvP).
    -- Weapon ids are the folder names under the player's ability assets (WoodenSword, IronBlade, ...; Phantom
    -- Edge ones under ShachiAbility), read from the asset registry. Changes the save: test saves only.
    game.commands.unlockall = function()
        local _, pawn = api.getPlayer1()
        local bp = lib("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetWorldSubsystem(pawn,
            StaticFindObject("/Script/ProjectPBZ.PBZBackPackSubsystem"))
        local ar = lib("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAssetRegistry()
        local root = "/PBZCombatAsset/ActorData/Players/Hun/Abilities"
        local notWeapons = { BreakEscape = true, Common = true, GameplayBlocker = true, HorseCart = true,
            Passive = true, ShachiAbility = true, SpecialMove = true, Tutorial = true, Unarm = true }
        local function folders(path)
            local paths, out = {}, {}
            ar:GetSubPaths(path, paths, false)
            for _, v in ipairs(paths) do
                local s = v:get()
                s = (type(s) == "string" and s or s:ToString()):match("([^/]+)$")
                out[#out + 1] = s
            end
            return out
        end
        for _, id in ipairs(folders(root)) do
            if not notWeapons[id] and not id:find("^Temp_") then
                pcall(function() bp:AddWeaponItem(FName(id), true, false, false, false) end)
            end
        end
        for _, id in ipairs(folders(root .. "/ShachiAbility")) do
            pcall(function() bp:AddWeaponItem(FName(id), false, false, false, false) end)
        end
        local main, edge = 0, 0
        bp.MainWeaponInfos:ForEach(function() main = main + 1 end)
        bp.ShaqiWeaponInfos:ForEach(function() edge = edge + 1 end)
        log(string.format("Unlocked: %d weapons, %d Phantom Edge weapons.", main, edge))
    end

    -- spawnenemy <codex row> [distance cm]: spawn one of the game's enemies in front of player 1.
    game.commands.spawnenemy = function(args)
        local name, dist = (args or ""):match("^(%S+)%s*(%d*)")
        if not name then
            log("Usage: spawnenemy <codex row, e.g. BP_Monster_MaleThug_Sword_Blue> [distance]")
            return
        end
        local row = codexRow(name)
        if row == nil then
            log("No codex row " .. name)
            return
        end
        local ksl = lib("/Script/Engine.Default__KismetSystemLibrary")
        local cls = ksl:LoadClassAsset_Blocking(row.EnemyClass)
        if not valid(cls) then
            log("Couldn't load class for " .. name)
            return
        end
        local _, pawn = api.getPlayer1()
        local l = pawn:K2_GetActorLocation()
        local yaw = pawn:K2_GetActorRotation().Yaw
        local d = tonumber(dist) or 700
        local at = { X = l.X + math.cos(math.rad(yaw)) * d, Y = l.Y + math.sin(math.rad(yaw)) * d, Z = l.Z + 30 }
        local e = spawnAt(cls, at, yaw + 180)
        if not valid(e) then
            log("Spawn failed for " .. name)
            return
        end
        pcall(function() e:SpawnDefaultController() end)
        local hp, maxhp = game.getHealth(e)
        log(string.format("Spawned %s (%s) hp=%s/%s boss=%s", e:GetFName():ToString(), name, tostring(hp),
            tostring(maxhp), tostring(row.bIsBoss)))
    end

    -- codex [bosses]: list enemy codex rows (or only the bosses).
    game.commands.codex = function(args)
        local dt = lib(CODEX_TABLE)
        local onlyBosses = args == "bosses"
        local names = {}
        dt:ForEachRow(function(rowName, row)
            local n = type(rowName) == "string" and rowName or tostring(rowName:ToString())
            if not onlyBosses or row.bIsBoss then
                names[#names + 1] = n
            end
        end)
        log((onlyBosses and "Boss rows: " or "Enemy rows: ") .. #names)
        for i = 1, #names, 8 do
            log("  " .. table.concat(names, " ", i, math.min(#names, i + 7)))
        end
    end

    -- enemies: every enemy the mod sees, with health and boss flag.
    game.commands.enemies = function()
        local _, pawn = api.getPlayer1()
        local here = valid(pawn) and pawn:K2_GetActorLocation() or nil
        local list = game.listEnemies()
        log("Enemies: " .. #list)
        for _, e in ipairs(list) do
            local hp, maxhp = game.getHealth(e)
            local d = here and distance(e:K2_GetActorLocation(), here) or -1
            log(string.format("  %s hp=%s/%s dead=%s boss=%s %.0f cm", e:GetFName():ToString(), tostring(hp),
                tostring(maxhp), tostring(game.isDead(e)), tostring(game.isBoss(e)), d))
        end
    end

    -- items: pickups near player 1.
    game.commands.items = function()
        local _, pawn = api.getPlayer1()
        local here = pawn:K2_GetActorLocation()
        local all = FindAllOf("PBZPickupActor") or {}
        log("Pickups loaded: " .. #all)
        for _, p in ipairs(all) do
            if valid(p) then
                local d = distance(p:K2_GetActorLocation(), here)
                if d < 5000 then
                    log(string.format("  %s item=%s %.0f cm", p:GetFName():ToString(), pickupItemId(p), d))
                end
            end
        end
    end

    return game
end
