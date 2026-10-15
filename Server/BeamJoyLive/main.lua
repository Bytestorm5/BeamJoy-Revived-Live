--[[
BeamJoy Live : server plugin (Resources/Server/BeamJoyLive/main.lua)

Connects a BeamJoy-Revived server to BeamJoy Web (BeamJoy Routes). This plugin only holds the
server's settings and tells each player's game (the BeamJoyLive.zip client mod) what to do ; all
web requests are made by the players' games, with each player's own linked account.

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
    local f = io.open(path, "w")
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
    log(string.format("loaded (site %s, live sessions %s)",
        config.SiteUrl ~= "" and config.SiteUrl or "not set", config.LiveSessions and "on" or "off"))
end
