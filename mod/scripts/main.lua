--[[
    CrystalClear
    Client-side UE4SS Lua mod. Turns on Grain Rot's unused microphone
    noise gate so background noise is stripped from proximity chat.
]]

local MOD_TAG = "[CrystalClear]"
local MOD_VERSION = "1.0.1"
local INIT_GUARD = "__CRYSTAL_CLEAR_INITIALIZED"

local DEFAULT_ENABLED = true
local DEFAULT_SUPPRESSION = 60
local MIN_SUPPRESSION = 0
local MAX_SUPPRESSION = 100
local MAX_GATE_THRESHOLD = 0.16
local DEFAULT_ATTACK = 0.02
local DEFAULT_RELEASE = 0.18
local MIN_TIME = 0.0
local MAX_TIME = 2.0

local APPLY_RETRY_DELAYS_MS = { 500, 1500, 3000, 6000 }
local KEEP_ALIVE_MS = 4000
local HOOK_RETRY_DELAY_MS = 1000
local MAX_HOOK_ATTEMPTS = 6

local HOOK_PATHS = {
    "/Script/Engine.VOIPStatics:SetMicThreshold",
    "/Script/Engine.PlayerController:StartTalking",
    "/Script/Engine.PlayerController:StopTalking",
    "/Script/Engine.PlayerController:ToggleSpeaking",
    "/Script/Engine.GameUserSettings:ApplySettings",
    "/Script/Engine.GameUserSettings:ApplyNonResolutionSettings",
}

if rawget(_G, INIT_GUARD) then
    print(string.format("%s Duplicate entrypoint skipped\n", MOD_TAG))
    return
end
_G[INIT_GUARD] = true

local UEHelpers = nil
do
    local ok, helpers = pcall(require, "UEHelpers")
    if ok then
        UEHelpers = helpers
    end
end

local CFG = {
    enabled = DEFAULT_ENABLED,
    suppression = DEFAULT_SUPPRESSION,
    gate_threshold = nil,
    attack_time = nil,
    release_time = nil,
    verbose = false,
}

local hook_attempts = 0
local hooked_paths = {}
local last_logged_apply = nil
local keep_alive_started = false

local function log(message, ...)
    print(string.format("%s %s\n", MOD_TAG, string.format(message, ...)))
end

local function log_verbose(message, ...)
    if CFG.verbose then
        log(message, ...)
    end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_valid(obj)
    if not obj then
        return false
    end
    local ok, valid = pcall(function()
        return obj.IsValid and obj:IsValid()
    end)
    return ok and valid == true
end

local function clamp(num, lo, hi)
    if num < lo then
        return lo
    end
    if num > hi then
        return hi
    end
    return num
end

local function parse_bool(value, fallback)
    if value == nil then
        return fallback
    end
    local lowered = string.lower(tostring(value))
    if lowered == "1" or lowered == "true" or lowered == "yes" or lowered == "on" then
        return true
    end
    if lowered == "0" or lowered == "false" or lowered == "no" or lowered == "off" then
        return false
    end
    return fallback
end

local function parse_number(value)
    if value == nil or value == "" then
        return nil
    end
    return tonumber(value)
end

local function resolve_mod_dir()
    local src = debug.getinfo(1, "S").source
    local script_dir = src:match("^@?(.+)[/\\][^/\\]+$")
    if not script_dir then
        return nil
    end
    local parent = script_dir:match("^(.+)[/\\][^/\\]+$")
    return parent or script_dir
end

local function parse_ini(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local values = {}
    for line in file:lines() do
        line = trim(line)
        if line ~= "" and not line:match("^;") and not line:match("^#") then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key and value then
                values[trim(key)] = trim(value)
            end
        end
    end
    file:close()
    return values
end

local function suppression_to_threshold(suppression)
    local t = clamp(suppression, MIN_SUPPRESSION, MAX_SUPPRESSION) / MAX_SUPPRESSION
    return t * MAX_GATE_THRESHOLD
end

local function load_config()
    local mod_dir = resolve_mod_dir()
    local candidates = {}
    if mod_dir then
        local normalized = mod_dir:gsub("\\", "/")
        table.insert(candidates, normalized .. "/config.ini")
        table.insert(candidates, mod_dir .. "\\config.ini")
    end

    local values = nil
    for _, path in ipairs(candidates) do
        values = parse_ini(path)
        if values then
            log_verbose("Loaded config from %s", path)
            break
        end
    end

    if not values then
        log("config.ini not found, using Suppression=%d", DEFAULT_SUPPRESSION)
        CFG.enabled = DEFAULT_ENABLED
        CFG.suppression = DEFAULT_SUPPRESSION
        CFG.verbose = false
        return
    end

    CFG.enabled = parse_bool(values.Enabled, DEFAULT_ENABLED)
    CFG.verbose = parse_bool(values.Verbose, false)

    local suppression = parse_number(values.Suppression)
    if suppression then
        CFG.suppression = math.floor(clamp(suppression, MIN_SUPPRESSION, MAX_SUPPRESSION) + 0.5)
    else
        CFG.suppression = DEFAULT_SUPPRESSION
    end

    local gate = parse_number(values.GateThreshold)
    if gate then
        CFG.gate_threshold = clamp(gate, 0.0, 1.0)
    else
        CFG.gate_threshold = nil
    end

    local attack = parse_number(values.AttackTime)
    if attack then
        CFG.attack_time = clamp(attack, MIN_TIME, MAX_TIME)
    else
        CFG.attack_time = nil
    end

    local release = parse_number(values.ReleaseTime)
    if release then
        CFG.release_time = clamp(release, MIN_TIME, MAX_TIME)
    else
        CFG.release_time = nil
    end
end

local function resolved_settings()
    local threshold = CFG.gate_threshold
    if threshold == nil then
        threshold = suppression_to_threshold(CFG.suppression)
    end
    local attack = CFG.attack_time
    if attack == nil then
        attack = DEFAULT_ATTACK
    end
    local release = CFG.release_time
    if release == nil then
        local t = CFG.suppression / MAX_SUPPRESSION
        release = DEFAULT_RELEASE + (t * 0.07)
    end
    return threshold, attack, release
end

local function get_kismet()
    if UEHelpers then
        local ok, ksl = pcall(function()
            return UEHelpers.GetKismetSystemLibrary()
        end)
        if ok and is_valid(ksl) then
            return ksl
        end
    end
    local ok, ksl = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if ok and is_valid(ksl) then
        return ksl
    end
    return nil
end

local function get_world_context()
    if UEHelpers then
        local ok_pc, pc = pcall(function()
            return UEHelpers.GetPlayerController()
        end)
        if ok_pc and is_valid(pc) then
            return pc
        end
        local ok_world, world = pcall(function()
            return UEHelpers.GetWorld()
        end)
        if ok_world and is_valid(world) then
            return world
        end
        local ok_engine, engine = pcall(function()
            return UEHelpers.GetEngine()
        end)
        if ok_engine and is_valid(engine) then
            return engine
        end
    end

    local fallbacks = { "PlayerController", "GameViewportClient", "World", "Engine" }
    for _, name in ipairs(fallbacks) do
        local ok, obj = pcall(function()
            return FindFirstOf(name)
        end)
        if ok and is_valid(obj) then
            return obj
        end
    end
    return nil
end

local function exec_console(command)
    local ksl = get_kismet()
    local context = get_world_context()
    if not ksl or not context then
        return false, "no world context yet"
    end
    local ok, err = pcall(function()
        ksl:ExecuteConsoleCommand(context, command, nil)
    end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

local function apply_suppression(reason)
    if not CFG.enabled then
        return false
    end

    local threshold, attack, release = resolved_settings()
    local commands = {
        string.format("voice.MicNoiseGateThreshold %0.4f", threshold),
        string.format("voice.MicNoiseAttackTime %0.4f", attack),
        string.format("voice.MicNoiseReleaseTime %0.4f", release),
    }

    local applied = 0
    local last_err = nil
    for _, command in ipairs(commands) do
        local ok, err = exec_console(command)
        if ok then
            applied = applied + 1
        else
            last_err = err
        end
    end

    if applied == 0 then
        log_verbose("Apply skipped (%s): %s", reason or "tick", last_err or "unknown")
        return false
    end

    local fingerprint = string.format("%.4f/%.4f/%.4f", threshold, attack, release)
    if last_logged_apply ~= fingerprint then
        last_logged_apply = fingerprint
        log(
            "Noise gate on (%s). Suppression=%d threshold=%.3f attack=%.3fs release=%.3fs",
            reason or "tick",
            CFG.suppression,
            threshold,
            attack,
            release
        )
    else
        log_verbose("Re-applied noise gate (%s)", reason or "tick")
    end
    return true
end

local function try_register_hooks()
    hook_attempts = hook_attempts + 1
    for _, path in ipairs(HOOK_PATHS) do
        if not hooked_paths[path] then
            local ok, pre_id = pcall(function()
                return RegisterHook(path, function()
                    ExecuteInGameThread(function()
                        apply_suppression("hook " .. path)
                    end)
                end)
            end)
            if ok and pre_id ~= nil then
                hooked_paths[path] = true
                log("Hooked %s", path)
            else
                log_verbose("Hook unavailable: %s", path)
            end
        end
    end
end

local function retry_hooks()
    try_register_hooks()
    if hook_attempts < MAX_HOOK_ATTEMPTS then
        ExecuteWithDelay(HOOK_RETRY_DELAY_MS, function()
            ExecuteInGameThread(retry_hooks)
        end)
    end
end

local function schedule_keep_alive()
    if keep_alive_started then
        return
    end
    keep_alive_started = true
    local function tick()
        ExecuteWithDelay(KEEP_ALIVE_MS, function()
            ExecuteInGameThread(function()
                apply_suppression("keep-alive")
                tick()
            end)
        end)
    end
    tick()
end

local function bootstrap()
    load_config()
    if not CFG.enabled then
        log("v%s loaded, Enabled=0. Microphone left untouched.", MOD_VERSION)
        return
    end

    local threshold, attack, release = resolved_settings()
    log(
        "v%s loading. Suppression=%d (threshold=%.3f attack=%.3fs release=%.3fs)",
        MOD_VERSION,
        CFG.suppression,
        threshold,
        attack,
        release
    )

    apply_suppression("boot")
    try_register_hooks()
    schedule_keep_alive()
end

ExecuteInGameThread(bootstrap)

for _, delay_ms in ipairs(APPLY_RETRY_DELAYS_MS) do
    ExecuteWithDelay(delay_ms, function()
        ExecuteInGameThread(function()
            if CFG.enabled then
                apply_suppression("retry " .. tostring(delay_ms) .. "ms")
                try_register_hooks()
            end
        end)
    end)
end

ExecuteWithDelay(2500, function()
    ExecuteInGameThread(function()
        if CFG.enabled then
            retry_hooks()
        end
    end)
end)
