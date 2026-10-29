--[[
BeamJoy Live : which site route a BeamJoy race is (BJL.courses).

The site knows a race by its course : the map and its gates, in order. BeamJoy's plugin API lists
races without their gates, so they're read from BeamJoy's own race file for the map
(Resources/Server/BeamJoyData/db/activities/<map>_races.json ; BeamJoy's API README allows plugins
to read its files). Read once per map, again after BeamJoy's RacesChanged. The site's answer (a route,
or none) is kept per race until the race changes.
]]

local U = BJL.util
local C = {
    --- the map BeamJoy runs (its level name, "west_coast_usa") and its name for people
    map = "",
    mapLabel = "",
    --- map -> {raceId -> race}
    races = {},
    --- map -> {raceId -> route|false} : the site's answer (false : not on the site)
    routes = {},
    --- "map#raceId" -> callbacks waiting for the site's answer
    waiting = {},
}

local function racesFile(map)
    return BJL.serverDir .. "BeamJoyData/db/activities/" .. map .. "_races.json"
end

local function validMap(map)
    return type(map) == "string" and map:match("^[%w_%-%.]+$") ~= nil and not map:find("..", 1, true)
end

--- a map's races, from BeamJoy's file (cached)
---@return table<integer, table>
function C.racesOf(map)
    if not validMap(map) then return {} end
    if C.races[map] then return C.races[map] end
    local byId = {}
    local raw = U.readFile(racesFile(map))
    local list = raw and U.decode(raw)
    if raw and not list then U.log("couldn't read BeamJoy's races for " .. map) end
    for _, race in ipairs(U.list(list)) do
        if type(race) == "table" and tonumber(race.id) then byId[tonumber(race.id)] = race end
    end
    C.races[map] = byId
    return byId
end

---@return table? BeamJoy's race
function C.race(map, raceId)
    return C.racesOf(map)[tonumber(raceId) or -1]
end

--- what the site matches a race by : its map and its gates, in order
function C.course(map, raceId)
    local race = C.race(map, raceId)
    if not race then return nil end
    local gates = {}
    for i, g in ipairs(U.list(race.gates)) do
        local p = type(g) == "table" and g.pos or {}
        gates[i] = { tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0 }
    end
    if #gates == 0 then return nil end
    return {
        raceId = race.id,
        name = race.name,
        level = map,
        mapName = map == C.map and C.mapLabel ~= "" and C.mapLabel or map,
        loopable = race.loopable == true,
        gates = gates,
    }
end

--- this plugin's race option for a race, as set in BeamJoy's race editor (freeroam runs : the
--- grid's come with each race event)
function C.option(map, raceId, key)
    local race = C.race(map, raceId)
    local plugins = race and type(race.defaults) == "table" and race.defaults.plugins
    local mine = type(plugins) == "table" and plugins[BJL.NAME]
    if type(mine) == "table" then return mine[key] end
    return nil
end

--- The site's route for a race : `callback(route, why)`, route {slug, title, url, sectors}, or nil
--- and why : "unlisted" (not on the site), "unknown" (not in BeamJoy's race file) or "error" (no
--- answer from the site).
function C.route(map, raceId, callback)
    raceId = tonumber(raceId)
    local known = C.routes[map] and C.routes[map][raceId]
    if known ~= nil then return callback(known or nil, not known and "unlisted" or nil) end
    local course = raceId and C.course(map, raceId)
    if not course then
        U.log(string.format("race %s isn't in BeamJoy's race file for %s", tostring(raceId), tostring(map)))
        return callback(nil, "unknown")
    end
    local key = map .. "#" .. raceId
    if C.waiting[key] then
        table.insert(C.waiting[key], callback)
        return
    end
    C.waiting[key] = { callback }
    BJL.web.json("POST", "/api/game/routes/match", course, nil, function(status, data)
        local waiting = C.waiting[key] or {}
        C.waiting[key] = nil
        local route
        if status == 200 and type(data) == "table" then
            route = type(data.route) == "table" and data.route or false
            C.routes[map] = C.routes[map] or {}
            C.routes[map][raceId] = route
        else
            U.log(string.format("couldn't match %s / race %d : %s", map, raceId, BJL.web.errorOf(status, data)))
        end
        for _, fn in ipairs(waiting) do
            local ok, err = pcall(fn, route or nil, route == nil and "error" or (not route and "unlisted") or nil)
            if not ok then U.log("a route callback failed : " .. tostring(err)) end
        end
    end)
end

--- a map's races were added, edited or deleted : read again, asked again
local function forget(map)
    C.races[map] = nil
    C.routes[map] = nil
end
C.forget = forget

--- a route uploaded from a game : that map's answers may have changed
function C.forgetRoutes(map)
    C.routes[map] = nil
end

local function setMap(map, label)
    if type(map) ~= "string" then return end
    C.map = map
    C.mapLabel = type(label) == "string" and label or map
end

function C.register()
    local BJ = BJL.BJ
    BJ.onReady(function(info)
        local m = type(info) == "table" and info.map or {}
        setMap(m.name, m.label)
        C.races, C.routes = {}, {}
    end)
    BJ.on("MapChanged", function(data)
        setMap(data and data.to, data and data.to)
        BJ.call("maps.list", {}, function(ok, result)
            if not ok then return end
            for _, m in ipairs(U.list(result.maps)) do
                if m.name == C.map and type(m.label) == "string" then C.mapLabel = m.label end
            end
        end)
    end)
    BJ.on("RacesChanged", function(data)
        if data and type(data.map) == "string" then forget(data.map) end
    end)
end

BJL.courses = C
return C
