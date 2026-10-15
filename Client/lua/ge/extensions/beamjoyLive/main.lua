--[[
BeamJoy Live : client entry point (extension `beamjoyLive_main`).

Connects BeamJoy-Revived to BeamJoy Web without changing BeamJoy itself : this extension listens
to the same server messages BeamJoy's own modules get (through `beamjoy_communications`), reads
BeamJoy's race cache (`beamjoy_races.data`), and talks to its own window (ui/modModules/bjlive).
Every web request is made by that window (the game's UI can fetch, its Lua can't), with the
token the player got by linking their account.

Lua -> UI : guihooks event "BJLEvent" { event, payload }.
UI -> Lua : beamjoyLive_main.dispatch(event, args).
Server plugin -> Lua : BeamMP events "BJLConfig" and "BJLReporter" (Server/BeamJoyLive/main.lua).
]]

local M = {
    dependencies = { "beamjoyLive_capture", "beamjoyLive_laps", "beamjoyLive_live" },

    VERSION = "1.0.0",
    UI_EVENT = "BJLEvent",
    --- where the link token is kept, in the player's BeamNG user folder (shared by every server)
    ACCOUNT_FILE = "settings/beamjoyLive/account.json",

    --- from the server plugin ; nil until it answers (no plugin : the mod stays idle)
    ---@type {siteUrl: string, leaderboards: boolean, uploads: boolean, liveSessions: boolean, serverName: string}?
    config = nil,
    ---@type {token: string, user: {name: string, slug: string}}?
    account = nil,
    --- this game sends the server's live player list (picked by the server plugin)
    reporter = false,
    serverKey = nil,

    handlers = {},
}

local function log(msg)
    if type(_G.log) == "function" then
        _G.log("I", "beamjoyLive", msg)
    else
        print("[beamjoyLive] " .. msg)
    end
end
M.log = log

--- @return string? the current level's folder name, e.g. "west_coast_usa"
function M.level()
    local ok, level = pcall(getCurrentLevelIdentifier)
    return ok and type(level) == "string" and level ~= "" and level or nil
end

--- the level's display name, e.g. "West Coast, USA"
function M.levelTitle(level)
    level = level or M.level()
    if not level then return nil end
    local ok, title = pcall(function()
        local info = core_levels.getLevelByName(level)
        local t = info and info.title
        if type(t) == "string" and translateLanguage then t = translateLanguage(t, t, true) end
        return t
    end)
    return ok and type(title) == "string" and title ~= "" and title or level
end

function M.selfName()
    local ok, name = pcall(function() return MPConfig.getNickname() end)
    return ok and name or nil
end

--- Sends an event to the window.
function M.send(event, payload)
    guihooks.trigger(M.UI_EVENT, { event = event, payload = payload })
end

--- In-game notice (BeamJoy's toasts when it's there, the game's own messages otherwise).
function M.notify(msg, kind)
    if toast and toast[kind or "info"] then
        pcall(toast[kind or "info"], msg, "BeamJoy Live", 6)
    elseif ui_message then
        pcall(ui_message, msg, 6, "beamjoyLive")
    end
end

local function readAccount()
    local ok, data = pcall(jsonReadFile, M.ACCOUNT_FILE)
    if ok and type(data) == "table" and type(data.token) == "string" then
        M.account = { token = data.token, user = type(data.user) == "table" and data.user or {} }
    else
        M.account = nil
    end
end

local function writeAccount()
    if M.account then
        pcall(jsonWriteFile, M.ACCOUNT_FILE, M.account, true)
    else
        pcall(function() FS:removeFile(M.ACCOUNT_FILE) end)
    end
end

--- Everything the window shows that comes from the game.
function M.state()
    local level = M.level()
    return {
        version = M.VERSION,
        config = M.config,
        account = M.account,
        level = level,
        levelTitle = M.levelTitle(level),
        selfName = M.selfName(),
        reporter = M.reporter,
        beamjoy = beamjoy_races ~= nil,
    }
end

function M.pushState()
    M.send("BJLState", M.state())
end

--- Tells the server plugin whether this game can report live sessions (it's linked).
local function announceLink()
    if TriggerServerEvent then
        pcall(TriggerServerEvent, "BJLCanReport", M.account and "1" or "0")
    end
end

local function hello()
    if TriggerServerEvent then pcall(TriggerServerEvent, "BJLHello", "") end
end

local function onConfig(raw)
    local ok, data = pcall(jsonDecode, raw)
    if not ok or type(data) ~= "table" then return end
    data.siteUrl = type(data.siteUrl) == "string" and data.siteUrl:gsub("/+$", "") or ""
    M.config = data
    M.pushState()
    announceLink()
end

local function onReporter(raw)
    local ok, data = pcall(jsonDecode, raw)
    if not ok or type(data) ~= "table" then return end
    M.reporter = data.reporter == true
    M.serverKey = M.reporter and data.serverKey or nil
    M.pushState()
end

---------------------------------------------------------------------------------------------------
-- races (BeamJoy's cache for the current map)

local function racesOnMap()
    return (beamjoy_races and type(beamjoy_races.data) == "table") and beamjoy_races.data or {}
end

function M.findRace(raceId)
    for _, r in ipairs(racesOnMap()) do
        if r.id == raceId then return r end
    end
end

local function propTotal(props)
    if beamjoy_props and beamjoy_props.total then
        local ok, n = pcall(beamjoy_props.total, props)
        if ok then return n end
    end
    return type(props) == "table" and #props or 0
end

--- What the site needs to recognise a race : its map and its gates, in order.
function M.course(race)
    local gates = {}
    for i, g in ipairs(race.gates or {}) do
        local p = g.pos or {}
        gates[i] = { tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0 }
    end
    local level = M.level()
    return {
        raceId = race.id,
        name = race.name,
        level = level,
        mapName = M.levelTitle(level),
        loopable = race.loopable == true,
        gates = gates,
    }
end

local function pushRaces()
    local list = {}
    for _, r in ipairs(racesOnMap()) do
        list[#list + 1] = {
            id = r.id,
            name = r.name,
            author = r.author,
            loopable = r.loopable == true,
            gates = type(r.gates) == "table" and #r.gates or 0,
            props = propTotal(r.props),
        }
    end
    table.sort(list, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    M.send("BJLRaces", list)
end

--- The whole race, for the window to build its share code (same fields as BeamJoy's editor).
local function pushRace(raceId)
    local race = M.findRace(raceId)
    if not race then return M.send("BJLRace", { id = raceId, missing = true }) end
    M.send("BJLRace", { id = raceId, race = race, course = M.course(race) })
end

function M.onBJRacesChanged()
    pushRaces()
end

---------------------------------------------------------------------------------------------------
-- UI calls

local function openUrl(url)
    if type(url) ~= "string" or not url:match("^https?://") then return end
    local ok = pcall(openWebBrowser, url)
    if not ok then
        pcall(function() ui_imgui.SetClipboardText(url) end)
        M.notify("Link copied to the clipboard : " .. url)
    end
end

M.handlers = {
    ready = function()
        M.pushState()
        pushRaces()
    end,
    saveAccount = function(token, user)
        if type(token) ~= "string" or token == "" then return end
        M.account = { token = token, user = type(user) == "table" and user or {} }
        writeAccount()
        announceLink()
        M.pushState()
    end,
    clearAccount = function()
        M.account = nil
        writeAccount()
        announceLink()
        M.pushState()
    end,
    openUrl = openUrl,
    requestRaces = pushRaces,
    requestRace = pushRace,
    notify = function(msg, kind) M.notify(tostring(msg), kind) end,
    captureScreenshot = function() beamjoyLive_capture.screenshot() end,
    captureAerial = function(raceId) beamjoyLive_capture.aerial(raceId) end,
    requestRoads = function() beamjoyLive_capture.roads() end,
    setWindowOpen = function(open) M.windowOpen = open == true end,
}

--- Entry point for the window's calls.
function M.dispatch(event, args)
    local fn = M.handlers[event]
    if not fn then return end
    local ok, err = xpcall(function()
        if type(args) == "table" then fn(unpack(args)) else fn() end
    end, debug.traceback)
    if not ok then log("UI call " .. tostring(event) .. " failed : " .. tostring(err)) end
end

function M.toggleWindow()
    M.send("BJLToggle", {})
end

---------------------------------------------------------------------------------------------------
-- lifecycle

local registered = false
local function registerServerEvents()
    if registered or not AddEventHandler then return end
    AddEventHandler("BJLConfig", onConfig)
    AddEventHandler("BJLReporter", onReporter)
    registered = true
end

function M.onExtensionLoaded()
    setExtensionUnloadMode(M, "manual")
    readAccount()
    registerServerEvents()
    log("loaded (v" .. M.VERSION .. ")")
end

--- BeamJoy's own "everything is ready" hook : the server and the UI can both hear us now.
function M.onBJClientReady()
    registerServerEvents()
    beamjoyLive_laps.attach()
    hello()
    M.pushState()
end

function M.onWorldReadyState(state)
    if state == 2 then
        registerServerEvents()
        beamjoyLive_laps.attach()
        hello()
    end
end

function M.onClientStartMission()
    M.pushState()
    pushRaces()
end

function M.onServerLeave()
    M.config = nil
    M.reporter = false
    M.serverKey = nil
    M.send("BJLUnload", {})
end

return M
