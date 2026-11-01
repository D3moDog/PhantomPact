-- PBZCoop: co-op proof of concept for Phantom Blade Zero (UE4SS Lua mod).
-- Written to be game-agnostic so it can be tested on any UE4/UE5 game first.
--
-- F6  print info about player 1's character
-- F7  list characters near player 1 (finds enemy classes)
-- F8  spawn player 2: a second local player + a copy of player 1's character (F8-F11 need PBZCOOP_DEBUG=1)
-- F9  remove player 2

local VERSION = "1.4.0.1"
local TAG = "[PBZCoop] "
if (os.getenv("PBZCOOP_INSTANCE") or "1") ~= "1" then
    TAG = "[PBZCoop#" .. os.getenv("PBZCOOP_INSTANCE") .. "] "
end
local NEARBY_RADIUS = 5000      -- Unreal units (cm), used by F7
local P2_SPAWN_OFFSET = 200     -- how far beside player 1 to spawn player 2
local P2_CONTROLLER_ID = 1      -- local player index for player 2
-- true: keyboard/mouse drives player 1 and the FIRST gamepad drives player 2,
-- so one person with one controller can test co-op alone.
-- false: player 1 = gamepad 1, player 2 = gamepad 2.
local OFFSET_GAMEPADS = true

-- ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn
local SPAWN_ADJUST_ALWAYS = 2
local SCALE_MULTIPLY_WITH_ROOT = 1   -- ESpawnActorScaleMethod::MultiplyWithRoot (engine default)

local state = {
    p2Controller = nil,
    p2Pawn = nil,
}

local function log(msg)
    print(TAG .. msg .. "\n")
end

-- Safe for anything: a stale reference handed back mid-respawn once had an IsValid that wasn't a function
-- ("attempt to call a string value"), which broke that tick's whole snapshot read.
local function valid(obj)
    if obj == nil or type(obj) == "string" or type(obj) == "number" or type(obj) == "boolean" then
        return false
    end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

local function gameplayStatics()
    return StaticFindObject("/Script/Engine.Default__GameplayStatics")
end

local function applyGamepadOffset()
    local settings = StaticFindObject("/Script/EngineSettings.Default__GameMapsSettings")
    if settings ~= nil and settings:IsValid() then
        settings.bOffsetPlayerGamepadIds = OFFSET_GAMEPADS
    end
end

-- Player 1's controller is the one with ControllerId 0, not just the first one found,
-- because after F8 there are two PlayerControllers.
local function getPlayer1()
    local gs = gameplayStatics()
    local anyPc = FindFirstOf("PlayerController")
    if not valid(gs) or not valid(anyPc) then
        return nil, nil
    end
    local pc = gs:GetPlayerController(anyPc, 0)
    if not valid(pc) then
        return nil, nil
    end
    local pawn = pc.Pawn
    if not valid(pawn) then
        return pc, nil
    end
    return pc, pawn
end

local function fmtVec(v)
    return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- F6: what is the player character made of?
local function dumpPlayer()
    local pc, pawn = getPlayer1()
    if not valid(pc) then
        log("No player controller yet. Load into gameplay first.")
        return
    end
    log("Controller: " .. pc:GetFullName())
    log("Controller class: " .. pc:GetClass():GetFullName())
    if not valid(pawn) then
        log("Controller has no pawn (menu or cutscene?).")
        return
    end
    log("Pawn: " .. pawn:GetFullName())
    log("Pawn class: " .. pawn:GetClass():GetFullName())
    log("Location: " .. fmtVec(pawn:K2_GetActorLocation()))
    local mesh, ai
    pcall(function()
        mesh = pawn.Mesh
        ai = mesh:GetAnimInstance()
    end)
    log("AnimInstance: " .. (valid(ai) and ai:GetClass():GetFullName() or "none"))

    -- Every loaded component whose owner is this pawn. Include likely equipment/weapon/mesh names for online
    -- diagnosis; this remains read-only and never changes the player's inventory or save.
    local count = 0
    local all = FindAllOf("ActorComponent") or {}
    log("Components:")
    for _, comp in ipairs(all) do
        if valid(comp) then
            local ok, owner = pcall(function() return comp:GetOwner() end)
            if ok and valid(owner) and owner:GetAddress() == pawn:GetAddress() then
                local componentClass = comp:GetClass():GetFName():ToString()
                local componentName = comp:GetFName():ToString()
                log(string.format("  %s%s  %s", (componentClass:find("[Ww]eapon") or componentClass:find("[Ee]quip")
                    or componentName:find("[Ww]eapon") or componentName:find("[Ee]quip")) and "EQUIPMENT? " or "",
                    componentClass, componentName))
                count = count + 1
            end
        end
    end
    log("Component count: " .. count)

    local mode = gameplayStatics():GetGameMode(pc)
    if valid(mode) then
        log("Game mode: " .. mode:GetClass():GetFullName())
    end
end

-- F7: which classes are the enemies?
local function listNearby()
    local _, pawn = getPlayer1()
    if not valid(pawn) then
        log("No player pawn.")
        return
    end
    local origin = pawn:K2_GetActorLocation()

    -- Enemies might not derive from ACharacter, so fall back to any APawn.
    local baseClass = "Character"
    local found = FindAllOf(baseClass)
    if found == nil or #found <= 1 then
        baseClass = "Pawn"
        found = FindAllOf(baseClass)
    end
    if found == nil then
        log("No Character or Pawn objects found.")
        return
    end

    local entries = {}
    local failed = 0
    for _, ch in ipairs(found) do
        if valid(ch) and ch:GetAddress() ~= pawn:GetAddress() then
            local ok, loc = pcall(function() return ch:K2_GetActorLocation() end)
            if ok then
                table.insert(entries, { actor = ch, dist = distance(origin, loc) })
            else
                failed = failed + 1
            end
        end
    end
    table.sort(entries, function(a, b) return a.dist < b.dist end)

    log(string.format("%d %s objects loaded (%d without a location).", #found, baseClass, failed))

    local counts = {}
    for _, e in ipairs(entries) do
        if e.dist <= NEARBY_RADIUS then
            local className = e.actor:GetClass():GetFName():ToString()
            counts[className] = (counts[className] or 0) + 1
        end
    end
    log("Classes within " .. NEARBY_RADIUS .. " cm:")
    for className, n in pairs(counts) do
        log("  " .. className .. " x" .. n)
    end

    -- The nearest ones regardless of radius, so an empty area still tells us something.
    log("Nearest " .. math.min(15, #entries) .. ":")
    for i = 1, math.min(15, #entries) do
        local e = entries[i]
        log(string.format("  %-45s %8.0f cm  %s", e.actor:GetClass():GetFName():ToString(), e.dist, e.actor:GetFullName()))
    end
end

-- Local player 2. The engine creates its PlayerController and usually splits the screen.
local function ensurePlayer2Controller()
    if valid(state.p2Controller) then
        return state.p2Controller
    end
    local pc = getPlayer1()
    if not valid(pc) then
        log("No player 1 controller.")
        return nil
    end
    -- After a hot reload (Ctrl+R) the mod forgets P2, but the game still has it.
    local existing = gameplayStatics():GetPlayerController(pc, 1)
    if valid(existing) then
        state.p2Controller = existing
        log("Reusing player 2 controller: " .. existing:GetFullName())
        return existing
    end
    applyGamepadOffset()
    local p2pc = gameplayStatics():CreatePlayer(pc, P2_CONTROLLER_ID, true)
    if not valid(p2pc) then
        log("CreatePlayer failed (the game may block extra local players).")
        return nil
    end
    state.p2Controller = p2pc
    log("Created player 2 controller: " .. p2pc:GetFullName())
    return p2pc
end

-- Spawns pawnClass to player 1's right, facing the same way. Returns the actor or nil.
local function spawnBesidePlayer1(pawnClass)
    local pc, pawn = getPlayer1()
    if not valid(pawn) then
        log("No player 1 pawn to spawn beside.")
        return nil
    end
    if not valid(pawnClass) then
        log("Pawn class not found.")
        return nil
    end
    local gs = gameplayStatics()

    local loc = pawn:K2_GetActorLocation()
    local yaw = math.rad(pawn:K2_GetActorRotation().Yaw)
    local side = yaw + math.pi / 2
    local transform = {
        Rotation = { X = 0.0, Y = 0.0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
        Translation = {
            X = loc.X + math.cos(side) * P2_SPAWN_OFFSET,
            Y = loc.Y + math.sin(side) * P2_SPAWN_OFFSET,
            Z = loc.Z,
        },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local actor
    local ok, err = pcall(function()
        -- UE 5.5+ added a TransformScaleMethod parameter to both calls (PBZ is 5.7, Wukong was 5.0).
        local newApi = pcall(function()
            actor = gs:BeginDeferredActorSpawnFromClass(pc, pawnClass, transform, SPAWN_ADJUST_ALWAYS, nil, SCALE_MULTIPLY_WITH_ROOT)
        end)
        if not newApi then
            actor = gs:BeginDeferredActorSpawnFromClass(pc, pawnClass, transform, SPAWN_ADJUST_ALWAYS, nil)
        end
        if not valid(actor) then
            error("BeginDeferredActorSpawnFromClass returned nothing")
        end
        if newApi then
            actor = gs:FinishSpawningActor(actor, transform, SCALE_MULTIPLY_WITH_ROOT)
        else
            actor = gs:FinishSpawningActor(actor, transform)
        end
        if not valid(actor) then
            error("FinishSpawningActor returned nothing")
        end
    end)
    if not ok then
        log("Spawning failed: " .. tostring(err))
        return nil
    end
    log("Spawned: " .. actor:GetFullName())

    -- The spawn transform's position is ignored in Wukong (the actor lands at the world
    -- origin), so place it explicitly, as UE4SS's SplitScreenMod does.
    local target = { X = transform.Translation.X, Y = transform.Translation.Y, Z = transform.Translation.Z }
    local facing = { Pitch = 0.0, Yaw = math.deg(yaw), Roll = 0.0 }
    actor:K2_SetActorLocationAndRotation(target, facing, false, {}, true)
    local actual = actor:K2_GetActorLocation()
    log(string.format("Placed at %s, %.0f cm from player 1.", fmtVec(actual), distance(actual, loc)))
    return actor
end

-- Spawns pawnClass beside player 1 and hands it to player 2.
local function spawnPawnForPlayer2(pawnClass)
    if valid(state.p2Pawn) then
        log("Player 2 already has a character. Press F9 first.")
        return
    end
    local p2pc = ensurePlayer2Controller()
    if not valid(p2pc) then
        return
    end
    state.p2Pawn = spawnBesidePlayer1(pawnClass)
    if not valid(state.p2Pawn) then
        return
    end
    p2pc:Possess(state.p2Pawn)
    if OFFSET_GAMEPADS then
        log("Player 2 now controls it. Keyboard = player 1, first gamepad = player 2.")
    else
        log("Player 2 now controls it. Try moving with gamepad 2.")
    end
end

-- F8: player 2 gets a copy of player 1's character class.
local function spawnPlayer2Clone()
    local _, pawn = getPlayer1()
    if not valid(pawn) then
        log("No player pawn to copy.")
        return
    end
    spawnPawnForPlayer2(pawn:GetClass())
end

-- F10: only create player 2 (split screen, no character). Isolates CreatePlayer itself.
local function createPlayer2Only()
    ensurePlayer2Controller()
end

-- F11: player 2 gets the engine's plain DefaultPawn, which has none of the game's own logic.
local function spawnPlayer2DefaultPawn()
    spawnPawnForPlayer2(StaticFindObject("/Script/Engine.DefaultPawn"))
end

-- Clone of player 1's class with no controller at all: isolates "spawning a unit" from "possessing it".
local function spawnCloneOnly()
    local _, pawn = getPlayer1()
    if not valid(pawn) then
        log("No player pawn to copy.")
        return
    end
    state.extraPawn = spawnBesidePlayer1(pawn:GetClass())
end

-- F9: clean up player 2.
local function removePlayer2()
    if valid(state.extraPawn) then
        state.extraPawn:K2_DestroyActor()
        log("Destroyed uncontrolled clone.")
    end
    state.extraPawn = nil
    if valid(state.p2Pawn) then
        state.p2Pawn:K2_DestroyActor()
        log("Destroyed player 2 character.")
    end
    if valid(state.p2Controller) then
        gameplayStatics():RemovePlayer(state.p2Controller, true)
        log("Removed player 2.")
    end
    state.p2Pawn = nil
    state.p2Controller = nil
end

-- Key callbacks don't run on the game thread; anything touching the world must.
local function onGameThread(fn, name)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then
                log(name .. " error: " .. tostring(err))
            end
        end)
    end
end

RegisterKeyBind(Key.F6, onGameThread(dumpPlayer, "F6"))
RegisterKeyBind(Key.F7, onGameThread(listNearby, "F7"))
-- F8-F11 spawn test pawns into the world: developer builds only (PBZCOOP_DEBUG=1), so a player can't hit one by accident.
local DEV_KEYS = os.getenv("PBZCOOP_DEBUG") == "1"
if DEV_KEYS then
    RegisterKeyBind(Key.F8, onGameThread(spawnPlayer2Clone, "F8"))
    RegisterKeyBind(Key.F9, onGameThread(removePlayer2, "F9"))
    RegisterKeyBind(Key.F10, onGameThread(createPlayer2Only, "F10"))
    RegisterKeyBind(Key.F11, onGameThread(spawnPlayer2DefaultPawn, "F11"))
end

-- Where are player 1 and player 2 right now?
local function where()
    local _, pawn = getPlayer1()
    if valid(pawn) then
        log("P1 at " .. fmtVec(pawn:K2_GetActorLocation()))
    end
    if valid(state.p2Pawn) then
        local p2 = state.p2Pawn:K2_GetActorLocation()
        log("P2 at " .. fmtVec(p2) .. (valid(pawn) and string.format(", %.0f cm from P1", distance(p2, pawn:K2_GetActorLocation())) or ""))
    else
        log("No P2 pawn.")
    end
end

-- Online co-op lives in coop.lua (network, ghost, enemy/item sync) and pbz.lua (what PBZ's enemies, health,
-- moves and items are). PBZ's launcher starts the game with a working directory other than the exe's, so
-- relative paths miss: find files relative to this script (".../PBZCoop/Scripts/main.lua").
local SCRIPT_DIR = ""
do
    local src = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    src = src:gsub("\\", "/")
    SCRIPT_DIR = src:match("^(.*/)") or ""
end
local MOD_DIRS = { "ue4ss/Mods/PBZCoop/", "Mods/PBZCoop/" }
do
    local dir = SCRIPT_DIR:match("^(.*/)Scripts/$")
    if dir then
        table.insert(MOD_DIRS, 1, dir)
    end
end
-- Two copies of the game on one PC (self-test) share the mod folder, so each copy uses its own files:
-- copy 1 (the default) uses the mod folder itself, copy N > 1 uses the "instN" subfolder.
-- tools/pbz-selftest.ps1 sets PBZCOOP_INSTANCE for each copy and creates the folders.
local INSTANCE = tonumber(os.getenv("PBZCOOP_INSTANCE") or "1") or 1

-- Found once, then cached: modDir() runs several times per network tick.
local foundModRoot = nil
local function modRoot()
    if foundModRoot then
        return foundModRoot
    end
    for _, dir in ipairs(MOD_DIRS) do
        local f = io.open(dir .. "enabled.txt", "r")
        if f then
            f:close()
            foundModRoot = dir
            return dir
        end
    end
    return MOD_DIRS[1]
end

-- This copy's file folder (see INSTANCE above).
local function modDir()
    if INSTANCE == 1 then
        return modRoot()
    end
    return modRoot() .. "inst" .. INSTANCE .. "/"
end

local api = {
    log = log,
    valid = valid,
    gs = gameplayStatics,
    getPlayer1 = getPlayer1,
    fmtVec = fmtVec,
    distance = distance,
    modDir = modDir,
    modRoot = modRoot,
    spawnBesidePlayer1 = spawnBesidePlayer1,
    version = VERSION,
}
api.game = dofile(SCRIPT_DIR .. "pbz.lua")(api)
local coop = dofile(SCRIPT_DIR .. "coop.lua")(api)
api.coop = coop
api.status = dofile(SCRIPT_DIR .. "status.lua")(api)
api.partner = dofile(SCRIPT_DIR .. "partner.lua")(api)
api.moves = dofile(SCRIPT_DIR .. "moves.lua")(api)
api.hud = dofile(SCRIPT_DIR .. "hud.lua")(api)
api.pvp = dofile(SCRIPT_DIR .. "pvp.lua")(api)
api.scaling = dofile(SCRIPT_DIR .. "scaling.lua")(api)
local net = coop.net

-- Helpers for the "eval" command, so test snippets can reuse the mod's functions.
PBZ = {
    state = state,
    log = log,
    valid = valid,
    fmtVec = fmtVec,
    distance = distance,
    gs = gameplayStatics,
    getPlayer1 = getPlayer1,
    ensurePlayer2Controller = ensurePlayer2Controller,
    spawnPawnForPlayer2 = spawnPawnForPlayer2,
    spawnBesidePlayer1 = spawnBesidePlayer1,
    removePlayer2 = removePlayer2,
    net = net,
    coop = coop,
    game = api.game,
}

-- Command file: lets a developer drive tests from outside the game. Write one command per line
-- into Mods/PBZCoop/cmd.txt; the mod runs them, then empties the file.
local COMMANDS = {
    info = dumpPlayer,
    nearby = listNearby,
    clone = spawnPlayer2Clone,
    cloneonly = spawnCloneOnly,
    exception = function()
        local panel = FindFirstOf("BP_UI_ExceptionPanel_C")
        local visible = valid(panel) and panel:IsVisible()
        log("Exception panel visible: " .. tostring(visible) ..
            (visible and (" | " .. panel.TextArea:GetText():ToString()) or ""))
    end,
    plain = spawnPlayer2DefaultPawn,
    p2only = createPlayer2Only,
    remove = removePlayer2,
    where = where,
    dumpobjects = function() DumpAllObjects() end,
    sdk = function() GenerateSDK() end,
    actors = function() DumpAllActors() end,
}
for name, fn in pairs(coop.commands) do
    COMMANDS[name] = fn
end
for name, fn in pairs(api.game.commands or {}) do
    COMMANDS[name] = fn
end
COMMANDS.pvp = api.pvp.command
COMMANDS.scale = api.scaling.command
COMMANDS.tips = api.status.command
COMMANDS.partner = api.partner.command
COMMANDS.moves = api.moves.command
COMMANDS.hud = api.hud.command

local function readCommandFile()
    local path = modDir() .. "cmd.txt"
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("a")
    f:close()
    if text == nil or not text:match("%S") then
        return nil
    end
    local w = io.open(path, "w")
    if w then w:close() end
    return text
end

local function runCommand(line)
    local name, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
    if name == nil then
        return
    end
    log("> " .. line)
    if name == "eval" then
        -- Running any Lua from cmd.txt is for development only: any program on the PC can write that file.
        -- Enabled by PBZCOOP_DEBUG=1 or a dev.txt next to the mod (tools\install-mod.ps1 creates it; the release
        -- zip never has one). (From appdoze's PR #2.)
        local devFile = io.open(modRoot() .. "dev.txt", "r")
        if devFile then
            devFile:close()
        end
        if not (DEV_KEYS or devFile) then
            log("eval is off (development only): create dev.txt in the mod folder to enable it.")
            return
        end
        local chunk, err = load(rest, "eval", "t")
        if not chunk then
            log("eval compile error: " .. tostring(err))
            return
        end
        local ok, result = pcall(chunk)
        log("eval " .. (ok and "ok: " or "error: ") .. tostring(result))
        return
    end
    local fn = COMMANDS[name]
    if fn == nil then
        log("Unknown command: " .. name)
        return
    end
    local ok, err = pcall(fn, rest)
    if not ok then
        log(name .. " error: " .. tostring(err))
    end
end

LoopAsync(500, function()
    local text = readCommandFile()
    if text then
        ExecuteInGameThread(function()
            for line in text:gmatch("[^\r\n]+") do
                runCommand(line)
            end
        end)
    end
    return false
end)

log("Loaded (instance " .. INSTANCE .. ", v" .. VERSION .. ", files in " .. modDir() .. "). F6 info | F7 nearby" .. (DEV_KEYS and " | F8 P2 clone | F9 remove P2 | F10 P2 controller only | F11 P2 plain pawn" or "") .. " | cmd.txt enabled")

-- PhantomPact.ini: start the relay and turn co-op on by itself (Role = Host/Guest; Off leaves it to neton).
local okAuto, errAuto = pcall(function() dofile(SCRIPT_DIR .. "autostart.lua")(api) end)
if not okAuto then
    log("Auto-start error: " .. tostring(errAuto))
end
