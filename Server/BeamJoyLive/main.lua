--[[
BeamJoy Live : server plugin (Resources/Server/BeamJoyLive/main.lua)

Connects a BeamJoy-Revived server to BeamJoy Web (BeamJoy Routes). This plugin holds the server's
settings, tells each player's game (the BeamJoyLive.zip client mod) what to do, and relays the
games' requests to the site (see "Web relay" below) : each still carries its player's own token.
Needs curl on the server machine (built into Windows 10+ and nearly every Linux).

Settings live in config.json next to this file, created on first start :
  SiteUrl       the site, e.g. "https://routes.example.com" (required)
  Leaderboards  players' laps on listed routes go to the site's leaderboards (default true)
  Uploads       players can upload races from the game (default true)
  LiveSessions  share every player's position, car and speed on the site's Live page (default
                false : it publishes where people are, so the host opts in)
  ServerName    shown on the Live page (default : the server's own name)
  ServerKey     random, generated once ; identifies this server on the site. Keep it private.

Changes to config.json take effect on the next server restart.
]]

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("(.*/)") or "./"
local CONFIG_PATH = PLUGIN_DIR .. "config.json"

local DEFAULTS = {
    SiteUrl = "",
    Leaderboards = true,
    Uploads = true,
    LiveSessions = false,
    ServerName = "",
    ServerKey = "",
}

local config = {}
--- playerID -> true for players whose game is linked to a site account (they can report)
local candidates = {}
--- playerID of the game that sends the live player list, or nil
local reporter = nil

local function log(msg)
    print("[BeamJoyLive] " .. msg)
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function randomKey()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local out = {}
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    for i = 1, 32 do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return "srv_" .. table.concat(out)
end

--- the server's own name from ServerConfig.toml, without BeamMP's colour codes
local function serverName()
    local ok, name = pcall(function() return MP.Get(MP.Settings.Name) end)
    name = ok and type(name) == "string" and name or "BeamMP server"
    return (name:gsub("%^[%da-fA-Flmnor]", ""))
end

local function loadConfig()
    local raw = readFile(CONFIG_PATH)
    local data = raw and Util.JsonDecode(raw) or nil
    config = {}
    for k, v in pairs(DEFAULTS) do
        if type(data) == "table" and type(data[k]) == type(v) then
            config[k] = data[k]
        else
            config[k] = v
        end
    end
    config.SiteUrl = config.SiteUrl:gsub("/+$", "")
    local changed = type(data) ~= "table"
    if config.ServerKey == "" then
        config.ServerKey = randomKey()
        changed = true
    end
    if changed then
        writeFile(CONFIG_PATH, Util.JsonPrettify and Util.JsonPrettify(Util.JsonEncode(config)) or Util.JsonEncode(config))
    end
    if config.SiteUrl == "" then
        log("SiteUrl is empty in " .. CONFIG_PATH .. " : set it to your BeamJoy Web site to turn the mod on")
    end
end

--- what every game gets ; the server key only goes to the reporter
local function publicConfig()
    return {
        siteUrl = config.SiteUrl,
        leaderboards = config.Leaderboards,
        uploads = config.Uploads,
        liveSessions = config.LiveSessions,
        serverName = config.ServerName ~= "" and config.ServerName or serverName(),
    }
end

local function sendConfig(playerID)
    MP.TriggerClientEvent(playerID, "BJLConfig", Util.JsonEncode(publicConfig()))
end

local function sendReporter(playerID)
    local payload = { reporter = playerID == reporter and config.LiveSessions }
    if payload.reporter then payload.serverKey = config.ServerKey end
    MP.TriggerClientEvent(playerID, "BJLReporter", Util.JsonEncode(payload))
end

--- One game reports the whole server : the linked player with the lowest id. Re-elected when they
--- leave or unlink.
local function elect()
    local best = nil
    for pid in pairs(candidates) do
        if MP.IsPlayerConnected(pid) and (not best or pid < best) then best = pid end
    end
    if best == reporter then return end
    local previous = reporter
    reporter = best
    if previous and MP.IsPlayerConnected(previous) then sendReporter(previous) end
    if reporter then sendReporter(reporter) end
end

---------------------------------------------------------------------------------------------------
-- Web relay
--
-- The game's UI may only connect to localhost (BeamNG's Content Security Policy) and its Lua has
-- no HTTPS, so players' games send their site requests here and this plugin makes them with curl
-- (built into Windows 10+ and nearly every Linux), like BeamJoy's own Discord posts. Each request
-- runs as a detached process writing to files under tmp/, polled every 200 ms, so the server never
-- waits on the site. Only paths under the site's /api/ are relayed.
--
-- Wire format, both ways : one header event, then the body in parts (BeamMP events are kept under
-- 20 KB each). Every event's text is escaped so it never holds a capital Z : the BeamMP launcher
-- drops a player on any packet over 500 bytes containing "Zp".
--
-- Pacing, both ways. BeamMP's server writes to a player's connection from more than one thread,
-- and a burst that fills it can garble a packet and crash that player's launcher (BeamJoy paces
-- its own sends for this, communications/tx.lua). Answers wait per player and leave at
-- REPLY_BUDGET bytes per poll ; the game paces what it sends here the same way (its main.lua).

--- bytes of body per event, before JSON and escaping grow it
local CHUNK = 12000
local MAX_BODY = 40 * 1024 * 1024
local MAX_INFLIGHT_PER_PLAYER = 8
local REQUEST_TIMEOUT_S = 150
--- bytes sent to one player per poll (200 ms) : 80 KB/s, well under what BeamJoy's own flow
--- control leaves room for ; an answer this small or smaller goes straight out when none waits
local REPLY_BUDGET = 16000
local REPLY_SMALL = 4000

local TMP_DIR = PLUGIN_DIR .. "tmp/"
--- id -> request being received (header seen, parts arriving)
local incoming = {}
--- id -> request curl is running
local running = {}
local seq = 0
local curlOk = nil
--- playerID -> {event, data}[] waiting to be sent, oldest first
local outbox = {}

local function isWindows()
    return package.config:sub(1, 1) == "\\"
end

local function escapeWire(s)
    return (s:gsub("[~Z]", { ["~"] = "~t", ["Z"] = "~z" }))
end

local function unescapeWire(s)
    return (s:gsub("~(.)", { t = "~", z = "Z" }))
end

local function ensureTmp()
    local f = io.open(TMP_DIR .. ".keep", "w")
    if f then
        f:close()
        return true
    end
    if FS and FS.CreateDirectory then pcall(FS.CreateDirectory, TMP_DIR) end
    if isWindows() then
        os.execute('mkdir "' .. TMP_DIR:gsub("/", "\\") .. '" >NUL 2>&1')
    else
        os.execute("mkdir -p '" .. TMP_DIR .. "' >/dev/null 2>&1")
    end
    f = io.open(TMP_DIR .. ".keep", "w")
    if f then f:close() end
    return f ~= nil
end

local function hasCurl()
    if curlOk == nil then
        local ok, r = pcall(os.execute, isWindows() and "curl --version >NUL 2>&1" or "curl --version >/dev/null 2>&1")
        curlOk = ok and (r == true or r == 0)
        if not curlOk then log("curl wasn't found on this machine's PATH : the site can't be reached") end
    end
    return curlOk
end

--- cuts text into pieces of at most `size` bytes, never inside a UTF-8 character
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

--- sends up to REPLY_BUDGET bytes of what waits for each player (always one event at least)
local function drainReplies()
    for playerID, q in pairs(outbox) do
        if not MP.IsPlayerConnected(playerID) then
            outbox[playerID] = nil
        else
            local sent = 0
            while #q > 0 and (sent == 0 or sent + #q[1][2] <= REPLY_BUDGET) do
                local ev = table.remove(q, 1)
                MP.TriggerClientEvent(playerID, ev[1], ev[2])
                sent = sent + #ev[2]
            end
            if #q == 0 then outbox[playerID] = nil end
        end
    end
end

--- sends a result to a player's game, in parts
local function reply(playerID, id, status, body)
    if not MP.IsPlayerConnected(playerID) then return end
    local parts = split(body or "", CHUNK)
    local events = { { "BJLHttpResult", escapeWire(Util.JsonEncode({ id = id, status = status, parts = #parts })) } }
    local size = #events[1][2]
    for i, part in ipairs(parts) do
        events[#events + 1] = { "BJLHttpPart", escapeWire(Util.JsonEncode({ id = id, part = i, data = part })) }
        size = size + #events[#events][2]
    end
    if not outbox[playerID] and size <= REPLY_SMALL then
        for _, ev in ipairs(events) do MP.TriggerClientEvent(playerID, ev[1], ev[2]) end
        return
    end
    local q = outbox[playerID] or {}
    for _, ev in ipairs(events) do q[#q + 1] = ev end
    outbox[playerID] = q
end

local function fail(playerID, id, status, message)
    reply(playerID, id, status, Util.JsonEncode({ error = message }))
end

--- a value for curl's config file : quoted, with \ and " escaped, on one line
local function cfgValue(v)
    return '"' .. tostring(v):gsub("[\r\n]", ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function removeFiles(base)
    for _, ext in ipairs({ ".cfg", ".body", ".out", ".status", ".done", ".cmd", ".sh" }) do
        os.remove(base .. ext)
    end
end

--- writes the request's files and starts curl in the background
local function start(playerID, req, body)
    seq = seq + 1
    local key = string.format("r%d_%d", playerID, seq)
    local base = TMP_DIR .. key
    local lines = {
        "url = " .. cfgValue(config.SiteUrl .. req.path),
        "request = " .. cfgValue(req.method),
        "silent",
        "max-time = 120",
        "output = " .. cfgValue(base .. ".out"),
        "write-out = " .. cfgValue("%{http_code}"),
        "header = " .. cfgValue("User-Agent: BeamJoyLive"),
    }
    if req.token then lines[#lines + 1] = "header = " .. cfgValue("Authorization: Bearer " .. req.token) end
    if req.method ~= "GET" then
        lines[#lines + 1] = "header = " .. cfgValue("Content-Type: " .. (req.contentType or "application/json"))
        lines[#lines + 1] = "data-binary = " .. cfgValue("@" .. base .. ".body")
        if not writeFile(base .. ".body", body) then return fail(playerID, req.id, 0, "The server couldn't write its temp files.") end
    end
    if not writeFile(base .. ".cfg", table.concat(lines, "\n") .. "\n") then
        return fail(playerID, req.id, 0, "The server couldn't write its temp files.")
    end
    if isWindows() then
        local w = function(path) return '"' .. path:gsub("/", "\\") .. '"' end
        writeFile(base .. ".cmd", table.concat({
            "@curl -K " .. w(base .. ".cfg") .. " > " .. w(base .. ".status") .. " 2>NUL",
            "@ren " .. w(base .. ".status") .. " " .. key .. ".done",
        }, "\r\n") .. "\r\n")
        -- cmd /c ""path"" : cmd drops the outer pair, so a path with spaces or brackets still works
        os.execute('start "" /b cmd /c "' .. w(base .. ".cmd") .. '" >NUL 2>&1')
    else
        local q = function(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
        writeFile(base .. ".sh", table.concat({
            "curl -K " .. q(base .. ".cfg") .. " > " .. q(base .. ".status") .. " 2>/dev/null",
            "mv " .. q(base .. ".status") .. " " .. q(base .. ".done"),
        }, "\n") .. "\n")
        os.execute("sh " .. q(base .. ".sh") .. " >/dev/null 2>&1 &")
    end
    running[req.id .. "@" .. playerID] = { playerID = playerID, id = req.id, base = base, startedAt = os.time() }
end

local function inflight(playerID)
    local n = 0
    for _, r in pairs(running) do
        if r.playerID == playerID then n = n + 1 end
    end
    return n
end

local METHODS = { GET = true, POST = true, DELETE = true }
local CONTENT_TYPES = { ["application/json"] = true, ["application/gzip"] = true }

--- header : { id, method, path, token?, contentType?, parts }
function BJL_onHttp(playerID, data)
    local ok, req = pcall(Util.JsonDecode, unescapeWire(data or ""))
    if not ok or type(req) ~= "table" or type(req.id) ~= "number" then return end
    if config.SiteUrl == "" then return fail(playerID, req.id, 0, "This server hasn't set its SiteUrl.") end
    if not METHODS[req.method] or type(req.path) ~= "string" or #req.path > 400 or
        not req.path:match("^/api/[%w%-%._~/%?=&%%]*$") or req.path:find("..", 1, true) then
        return fail(playerID, req.id, 0, "Refused by the server.")
    end
    if req.contentType ~= nil and not CONTENT_TYPES[req.contentType] then req.contentType = nil end
    if type(req.token) ~= "string" or not req.token:match("^bjl_[%w%-_]+$") or #req.token > 100 then req.token = nil end
    if not hasCurl() or not ensureTmp() then return fail(playerID, req.id, 0, "The server can't reach the site (no curl).") end
    if inflight(playerID) >= MAX_INFLIGHT_PER_PLAYER then return fail(playerID, req.id, 0, "Too many requests at once.") end
    local parts = tonumber(req.parts) or 0
    if parts == 0 then return start(playerID, req, "") end
    if parts * CHUNK > MAX_BODY then return fail(playerID, req.id, 413, "Too large.") end
    incoming[req.id .. "@" .. playerID] = { req = req, parts = {}, expected = parts, got = 0 }
end

--- part : { id, part, data }
function BJL_onHttpPart(playerID, data)
    local ok, msg = pcall(Util.JsonDecode, unescapeWire(data or ""))
    if not ok or type(msg) ~= "table" then return end
    local key = tostring(msg.id) .. "@" .. playerID
    local entry = incoming[key]
    if not entry or type(msg.part) ~= "number" or type(msg.data) ~= "string" or entry.parts[msg.part] then return end
    entry.parts[msg.part] = msg.data
    entry.got = entry.got + 1
    if entry.got == entry.expected then
        incoming[key] = nil
        start(playerID, entry.req, table.concat(entry.parts))
    end
end

function BJL_pollHttp()
    drainReplies()
    for key, r in pairs(running) do
        local done = readFile(r.base .. ".done")
        if done then
            running[key] = nil
            local status = tonumber((done:gsub("%s", ""))) or 0
            local body = readFile(r.base .. ".out") or ""
            removeFiles(r.base)
            if status == 0 then
                fail(r.playerID, r.id, 0, "The site didn't answer.")
            else
                reply(r.playerID, r.id, status, body)
            end
        elseif os.time() - r.startedAt > REQUEST_TIMEOUT_S then
            running[key] = nil
            removeFiles(r.base)
            fail(r.playerID, r.id, 0, "The site didn't answer in time.")
        end
    end
end

local function dropPlayerRequests(playerID)
    for key in pairs(incoming) do
        if key:match("@" .. playerID .. "$") then incoming[key] = nil end
    end
    outbox[playerID] = nil
end

function BJL_onHello(playerID)
    sendConfig(playerID)
    sendReporter(playerID)
end

--- data : "1" when the game is linked to a site account, "0" otherwise
function BJL_onCanReport(playerID, data)
    candidates[playerID] = data == "1" or nil
    elect()
end

function BJL_onPlayerJoin(playerID)
    sendConfig(playerID)
end

function BJL_onPlayerDisconnect(playerID)
    candidates[playerID] = nil
    dropPlayerRequests(playerID)
    if reporter == playerID then
        reporter = nil
        elect()
    end
end

function onInit() ---@diagnostic disable-line
    loadConfig()
    MP.RegisterEvent("BJLHello", "BJL_onHello")
    MP.RegisterEvent("BJLCanReport", "BJL_onCanReport")
    MP.RegisterEvent("onPlayerJoin", "BJL_onPlayerJoin")
    MP.RegisterEvent("onPlayerDisconnect", "BJL_onPlayerDisconnect")
    MP.RegisterEvent("BJLHttp", "BJL_onHttp")
    MP.RegisterEvent("BJLHttpPart", "BJL_onHttpPart")
    MP.RegisterEvent("BJLHttpPoll", "BJL_pollHttp")
    MP.CreateEventTimer("BJLHttpPoll", 200)
    log(string.format("loaded (site %s, live sessions %s)",
        config.SiteUrl ~= "" and config.SiteUrl or "not set", config.LiveSessions and "on" or "off"))
end
