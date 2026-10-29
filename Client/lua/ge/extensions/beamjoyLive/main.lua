--[[
BeamJoy Live : client entry point (extension `beamjoyLive_main`).

The game's side of BeamJoy Live. The server plugin (Server/BeamJoyLive) does most of the work
through BeamJoy's plugin API : laps to the site, the BeamJoy Live page, the Live page. The game
does what only the game can : keeps the player's link to their site account (and tells the
plugin), runs the window (ui/modModules/bjlive : uploads, screenshots, the aerial camera), uploads
the level's road map, reports freeroam runs and, on one game per server, where every car is.

Lua -> UI : guihooks event "BJLEvent" { event, payload }.
UI -> Lua : beamjoyLive_main.dispatch(event, args).
Server plugin <-> Lua : BeamMP events, JSON escaped by escapeWire (Server/BeamJoyLive/lib) :
  to the plugin   BJLHello, BJLAccount, BJLVehicle, BJLFreeroamLap, BJLLive, BJLHttp*
  from it         BJLConfig, BJLReporter, BJLAccountSet, BJLLapResult, BJLLiveStatus, BJLOpen,
                  BJLOpenUrl, BJLHttpResult/Part (the window's site requests, relayed)
]]

local M = {
    dependencies = { "beamjoyLive_capture", "beamjoyLive_laps", "beamjoyLive_live" },

    VERSION = "2.0.0",
    UI_EVENT = "BJLEvent",
    --- where the link token is kept, in the player's BeamNG user folder (shared by every server)
    ACCOUNT_FILE = "settings/beamjoyLive/account.json",

    --- from the server plugin ; nil until it answers (no plugin : the mod stays idle)
    ---@type {siteUrl: string, leaderboards: boolean, uploads: boolean, liveSessions: boolean, serverName: string}?
    config = nil,
    ---@type {token: string, user: {name: string, slug: string}}?
    account = nil,
    --- this game sends where every car is (picked by the server plugin)
    reporter = false,
    --- the server's page on the site's Live page, once the plugin posted it
    liveUrl = nil,

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
        liveUrl = M.liveUrl,
        beamjoy = beamjoy_races ~= nil,
    }
end

function M.pushState()
    M.send("BJLState", M.state())
end

--- a message from the server plugin (escaped JSON), or nil
local function decodeServer(raw)
    local ok, data = pcall(jsonDecode, M.unescapeWire(type(raw) == "string" and raw or ""))
    return ok and type(data) == "table" and data or nil
end

--- a message to the server plugin
function M.toServer(event, payload)
    if not TriggerServerEvent then return end
    local ok, err = pcall(function() M.queueServer({ { event, M.escapeWire(jsonEncode(payload or {})) } }) end)
    if not ok then log("couldn't send " .. event .. " : " .. tostring(err)) end
end

--- Tells the server plugin which site account this game is linked to : it posts this player's laps
--- as them (the token stays in the server's memory while they're connected).
local function announceAccount()
    M.toServer("BJLAccount", M.account and { token = M.account.token, user = M.account.user } or {})
end

--- the car this player's in, and its name : BeamJoy's events only carry the model
local function reportVehicle(vid)
    local ok, model, label = pcall(function()
        local veh = vid and be:getObjectByID(vid) or be:getPlayerVehicle(0)
        local m = veh and veh:getJBeamFilename()
        local l = m and beamjoy_vehicles and beamjoy_vehicles.getModelLabel and beamjoy_vehicles.getModelLabel(m)
        return m, l
    end)
    if ok and type(model) == "string" and type(label) == "string" and label ~= "" and label ~= "?" then
        M.toServer("BJLVehicle", { model = model, label = label })
    end
end

local function hello()
    if TriggerServerEvent then pcall(TriggerServerEvent, "BJLHello", "") end
end

local function onConfig(raw)
    local data = decodeServer(raw)
    if not data then return end
    data.siteUrl = type(data.siteUrl) == "string" and data.siteUrl:gsub("/+$", "") or ""
    M.config = data
    M.pushState()
    announceAccount()
    reportVehicle()
end

local function onReporter(raw)
    local data = decodeServer(raw)
    if not data then return end
    M.reporter = data.reporter == true
    M.pushState()
end

--- the BeamJoy Live page linked (or unlinked) this game : it keeps the token, like the window's own
local function onAccountSet(raw)
    local data = decodeServer(raw)
    if not data then return end
    if data.clear then
        M.account = nil
    elseif type(data.token) == "string" and data.token ~= "" then
        M.account = { token = data.token, user = type(data.user) == "table" and data.user or {} }
    else
        return
    end
    writeAccount()
    announceAccount()
    M.pushState()
end

local function onLiveStatus(raw)
    local data = decodeServer(raw)
    if not data then return end
    M.liveUrl = type(data.url) == "string" and data.url or nil
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

--- the race's prop count, weighed like BeamJoy's prop budget. BeamJoy's race cache carries it
--- (`propTotal`) and leaves the props themselves out (fetched when needed, see pushRace) ; an older
--- BeamJoy sends the props
local function propTotal(race)
    if tonumber(race.propTotal) then return tonumber(race.propTotal) end
    if beamjoy_props and beamjoy_props.total then
        local ok, n = pcall(beamjoy_props.total, race.props)
        if ok then return n end
    end
    return type(race.props) == "table" and #race.props or 0
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
            props = propTotal(r),
        }
    end
    table.sort(list, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    M.send("BJLRaces", list)
end

--- The whole race, for the window to build its share code (same fields as BeamJoy's editor).
--- BeamJoy's race cache leaves props out : they're asked for (beamjoy_races.getProps) and the race
--- goes to the window once they're in.
local function pushRace(raceId)
    local race = M.findRace(raceId)
    if not race then return M.send("BJLRace", { id = raceId, missing = true }) end
    local function send(props)
        local copy = {}
        for k, v in pairs(race) do copy[k] = v end
        copy.props = type(props) == "table" and props or {}
        M.send("BJLRace", { id = raceId, race = copy, course = M.course(race) })
    end
    if not (beamjoy_races and beamjoy_races.getProps) then return send(race.props) end
    local ok, props = pcall(beamjoy_races.getProps, raceId, send)
    if not ok then
        log("props of race " .. tostring(raceId) .. " : " .. tostring(props))
        return send(race.props)
    end
    -- here already (or none) ; otherwise `send` runs once they come
    if props then send(props) end
end

function M.onBJRacesChanged()
    pushRaces()
end

---------------------------------------------------------------------------------------------------
-- web relay : the game's UI may only connect to localhost, so its site requests go through the
-- server plugin, which makes them with curl (Server/BeamJoyLive/main.lua, "Web relay"). This side
-- adds the player's token, cuts the body into BeamMP-sized events and puts the answer back
-- together. Every event's text is escaped so it never holds a capital Z (the BeamMP launcher
-- drops a player over a packet of 500+ bytes holding "Zp").

local CHUNK = 12000
--- id -> answer being received
local answers = {}

--- Pacing, as BeamJoy's own sends (its communications/tx.lua) : a big upload's parts all at
--- once overfill the player's connection, which can crash a BeamMP launcher. Events wait in
--- `outbox` and leave at RATE bytes a second, up to BURST at a time ; a small request goes
--- straight out when nothing waits ahead of it. Order is kept.
M.RATE = 400000
M.BURST = 40000
M.SMALL = 4000
---@type string[][] {event, data}, oldest first
local outbox = {}
local allowance = M.BURST

local function drain(dt)
    allowance = math.min(M.BURST, allowance + M.RATE * (tonumber(dt) or 0))
    while #outbox > 0 do
        local size = #outbox[1][2]
        -- a part bigger than what's left waits, unless the budget is full (it would never fit)
        if size > allowance and allowance < M.BURST then break end
        local ev = table.remove(outbox, 1)
        TriggerServerEvent(ev[1], ev[2])
        allowance = allowance - size
    end
end

--- queues one message's events (sent at once when small and nothing waits)
local function queue(events)
    local size = 0
    for _, ev in ipairs(events) do size = size + #ev[2] end
    if #outbox == 0 and size <= M.SMALL then
        for _, ev in ipairs(events) do TriggerServerEvent(ev[1], ev[2]) end
        return
    end
    for _, ev in ipairs(events) do outbox[#outbox + 1] = ev end
    drain(0)
end

local function escapeWire(s)
    return (s:gsub("[~Z]", { ["~"] = "~t", ["Z"] = "~z" }))
end

local function unescapeWire(s)
    return (s:gsub("~(.)", { t = "~", z = "Z" }))
end
M.escapeWire, M.unescapeWire = escapeWire, unescapeWire

local function split(text, size)
    local parts, i = {}, 1
    while i <= #text do
        local j = math.min(#text, i + size - 1)
        while j < #text and j > i do
            local b = text:byte(j + 1)
            if b < 0x80 or b >= 0xC0 then break end
            j = j - 1
        end
        parts[#parts + 1] = text:sub(i, j)
        i = j + 1
    end
    return parts
end

local function answer(id, status, body)
    M.send("BJLHttpResult", { id = id, status = status, body = body })
end

---@param id integer the window's request number
---@param method string GET, POST or DELETE
---@param path string under /api/
---@param body string? JSON text
---@param contentType string?
local function http(id, method, path, body, contentType)
    if not TriggerServerEvent or not M.config then
        return answer(id, 0, '{"error":"Not connected to a server with BeamJoy Live."}')
    end
    local parts = split(type(body) == "string" and body or "", CHUNK)
    local events = { { "BJLHttp", escapeWire(jsonEncode({
        id = id,
        method = method,
        path = path,
        token = M.account and M.account.token or nil,
        contentType = contentType ~= "" and contentType or nil,
        parts = #parts,
    })) } }
    for i, part in ipairs(parts) do
        events[#events + 1] = { "BJLHttpPart", escapeWire(jsonEncode({ id = id, part = i, data = part })) }
    end
    queue(events)
end

local function onHttpResult(raw)
    local ok, msg = pcall(jsonDecode, unescapeWire(raw or ""))
    if not ok or type(msg) ~= "table" or not msg.id then return end
    local parts = tonumber(msg.parts) or 0
    if parts == 0 then return answer(msg.id, msg.status, "") end
    answers[msg.id] = { status = msg.status, expected = parts, got = 0, parts = {} }
end

local function onHttpPart(raw)
    local ok, msg = pcall(jsonDecode, unescapeWire(raw or ""))
    if not ok or type(msg) ~= "table" then return end
    local entry = answers[msg.id]
    if not entry or type(msg.part) ~= "number" or entry.parts[msg.part] then return end
    entry.parts[msg.part] = msg.data or ""
    entry.got = entry.got + 1
    if entry.got == entry.expected then
        answers[msg.id] = nil
        answer(msg.id, entry.status, table.concat(entry.parts))
    end
end
M.onHttpResult, M.onHttpPart, M.http = onHttpResult, onHttpPart, http
M.drainRelay = drain
M.relayBacklog = function() return #outbox end
M.queueServer = queue

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
        announceAccount()
        M.pushState()
    end,
    clearAccount = function()
        M.account = nil
        writeAccount()
        announceAccount()
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
    http = http,
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

--- what the server plugin passes on to the window as it is
local function forward(event)
    return function(raw)
        local data = decodeServer(raw)
        if data then M.send(event, data) end
    end
end

local registered = false
local function registerServerEvents()
    if registered or not AddEventHandler then return end
    AddEventHandler("BJLConfig", onConfig)
    AddEventHandler("BJLReporter", onReporter)
    AddEventHandler("BJLAccountSet", onAccountSet)
    AddEventHandler("BJLLiveStatus", onLiveStatus)
    -- a lap of this player's, posted (or not) by the plugin : the window's Times tab
    AddEventHandler("BJLLapResult", forward("BJLLapResult"))
    -- the BeamJoy Live page's buttons
    AddEventHandler("BJLOpen", forward("BJLOpen"))
    AddEventHandler("BJLOpenUrl", function(raw)
        local data = decodeServer(raw)
        if data then openUrl(data.url) end
    end)
    AddEventHandler("BJLHttpResult", onHttpResult)
    AddEventHandler("BJLHttpPart", onHttpPart)
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

function M.onVehicleSwitched(_, newId)
    if M.config then reportVehicle(newId) end
end

function M.onUpdate(dtReal)
    if #outbox > 0 then drain(dtReal) end
end

--- the client mod's files go with the server : what's loaded of ours is unloaded too. Leaving a
--- server reloads Lua since BeamNG 0.40, which would try to load every extension still loaded
--- again, from files no longer mounted (BeamJoy does the same for its own, main.lua)
M.EXTENSIONS = { "beamjoyLive_live", "beamjoyLive_laps", "beamjoyLive_capture", "beamjoyLive_main" }

function M.onServerLeave()
    answers = {}
    outbox = {}
    M.config = nil
    M.reporter = false
    M.liveUrl = nil
    M.send("BJLUnload", {})
    if extensions and extensions.unload then
        for _, name in ipairs(M.EXTENSIONS) do pcall(extensions.unload, name) end
    end
end

return M
