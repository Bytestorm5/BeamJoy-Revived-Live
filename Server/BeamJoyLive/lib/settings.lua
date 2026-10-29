--[[
BeamJoy Live : the host's settings (BJL.settings), a tab in BeamJoy's config window (Config >
BeamJoy Live, for staff with BeamJoy's EditPluginConfig permission). BeamJoy stores them and
changes apply at once. A config.json from before this (BeamJoy Live 1.x) is moved there once.
]]

local U = BJL.util
local S = {
    values = {
        siteUrl = "",
        leaderboards = true,
        uploads = true,
        liveSessions = false,
        serverName = "",
        serverKey = "",
    },
    --- the values came from BeamJoy at least once
    loaded = false,
}

S.TAB = {
    title = "BeamJoy Live",
    sections = {
        { id = "site", title = "Site", options = {
            { id = "siteUrl", type = "text", label = "Site address", maxLength = 200,
                placeholder = "https://routes.example.com",
                tooltip = "Your BeamJoy Web site. BeamJoy Live stays off until it's set." },
            { id = "check", type = "button", label = "Check the connection" },
        } },
        { id = "features", title = "What goes to the site", options = {
            { id = "leaderboards", type = "toggle", label = "Lap times", default = true,
                tooltip = "Linked players' laps on listed routes go to the site's leaderboards" },
            { id = "uploads", type = "toggle", label = "Race uploads", default = true,
                tooltip = "Players can upload this server's races to the site" },
            { id = "liveSessions", type = "toggle", label = "Live page", default = false,
                tooltip = "Everyone's position, car and speed on the site's Live page" },
            { id = "serverName", type = "text", label = "Name on the Live page", maxLength = 80,
                placeholder = "This server's own name" },
        } },
        { id = "server", title = "Server", options = {
            { id = "serverKey", type = "text", label = "Server key", secret = true, maxLength = 100,
                tooltip = "Identifies this server on the site. Made for you ; set one only to move a server." },
        } },
    },
}

local LEGACY_FILE = BJL.dir .. "config.json"
local LEGACY_KEYS = { SiteUrl = "siteUrl", Leaderboards = "leaderboards", Uploads = "uploads",
    LiveSessions = "liveSessions", ServerName = "serverName", ServerKey = "serverKey" }

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

--- "https://site.example/" -> "https://site.example" ; anything not http(s) -> ""
local function cleanUrl(v)
    if type(v) ~= "string" then return "" end
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    return v:match("^https?://[%w%-%.:%[%]]+[%w%-%._~/]*$") and v or ""
end

--- the server's own name from ServerConfig.toml, without BeamMP's colour codes
function S.serverName()
    if S.values.serverName ~= "" then return S.values.serverName end
    local ok, name = pcall(function() return MP.Get(MP.Settings.Name) end)
    name = ok and type(name) == "string" and name or "BeamMP server"
    return (name:gsub("%^[%da-fA-Flmnor]", ""))
end

--- what every game gets (the server key stays here)
function S.public()
    return {
        siteUrl = S.values.siteUrl,
        leaderboards = S.values.leaderboards,
        uploads = S.values.uploads,
        liveSessions = S.values.liveSessions,
        serverName = S.serverName(),
    }
end

function S.enabled()
    return S.values.siteUrl ~= ""
end

--- moves a config.json from BeamJoy Live 1.x into the tab, once
local function migrate()
    local raw = U.readFile(LEGACY_FILE)
    local old = raw and U.decode(raw)
    if type(old) ~= "table" then return false end
    local values = {}
    for from, to in pairs(LEGACY_KEYS) do
        if old[from] ~= nil then values[to] = old[from] end
    end
    BJL.BJ.call("config.set", { values = values }, function(ok, err)
        if not ok then return U.log("couldn't move config.json into BeamJoy's config : " .. tostring(err and err.message)) end
        os.rename(LEGACY_FILE, LEGACY_FILE .. ".old")
        U.log("settings moved from config.json to BeamJoy's config window (Config > BeamJoy Live)")
    end)
    return true
end

---@param values table from BeamJoy (secrets included)
function S.apply(values)
    values = type(values) == "table" and values or {}
    local v = {}
    for k, default in pairs(S.values) do
        local given = values[k]
        if type(default) == "boolean" then
            if given == nil then v[k] = S.TAB_DEFAULTS[k] == true else v[k] = given == true end
        else
            v[k] = type(given) == "string" and given or ""
        end
    end
    v.siteUrl = cleanUrl(v.siteUrl)
    v.serverName = v.serverName:sub(1, 80)
    local first = not S.loaded
    S.loaded = true
    if first and v.siteUrl == "" and migrate() then return end
    if v.serverKey == "" then
        v.serverKey = randomKey()
        BJL.BJ.call("config.set", { values = { serverKey = v.serverKey } })
    end
    local before = S.values
    S.values = v
    if first then
        U.log(string.format("site %s, live page %s", v.siteUrl ~= "" and v.siteUrl or "not set (Config > BeamJoy Live)",
            v.liveSessions and "on" or "off"))
    elseif before.siteUrl ~= v.siteUrl then
        U.log("site " .. (v.siteUrl ~= "" and v.siteUrl or "not set"))
    end
    if BJL.players then BJL.players.broadcastConfig() end
    if BJL.live then BJL.live.elect() end
    if BJL.page then BJL.page.refreshAll() end
end

--- the config tab's "Check the connection" : asks the site something any visitor may ask
local function check(by)
    local playerID = type(by) == "table" and tonumber(by.id) or nil
    local function say(text, color)
        if playerID then BJL.BJ.call("hud.message", { text = text, color = color, playerId = playerID, durationS = 8 }) end
        U.log(text)
    end
    if not S.enabled() then return say("BeamJoy Live : set the site address first.", "warn") end
    local map = BJL.courses and BJL.courses.map or ""
    BJL.web.json("GET", "/api/game/levels/" .. (map ~= "" and map or "gridmap_v2"), nil, nil, function(status, data)
        if status == 200 and type(data) == "table" and data.level then
            say("BeamJoy Live : " .. S.values.siteUrl .. " answers.", "good")
        else
            say("BeamJoy Live : " .. S.values.siteUrl .. " didn't answer like BeamJoy Web (" ..
                BJL.web.errorOf(status, data) .. ")", "bad")
        end
    end)
end

function S.register()
    S.TAB_DEFAULTS = {}
    for _, section in ipairs(S.TAB.sections) do
        for _, o in ipairs(section.options) do
            if o.type == "toggle" then S.TAB_DEFAULTS[o.id] = o.default == true end
        end
    end
    BJL.BJ.configTab(S.TAB, function(values) S.apply(values) end)
    BJL.BJ.onConfigAction(function(action, by)
        if action == "check" then check(by) end
    end)
end

BJL.settings = S
return S
