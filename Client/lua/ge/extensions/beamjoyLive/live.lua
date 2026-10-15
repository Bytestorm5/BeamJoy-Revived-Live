--[[
BeamJoy Live : live session reporter (extension `beamjoyLive_live`).

When the host turned LiveSessions on, the server plugin picks one linked player's game to report
for the whole server. That game sends every few seconds who's on, in what, where and how fast :
everything here is what any player's game already sees of the others.
]]

local M = {
    INTERVAL_S = 5,
    last = 0,
}

local function now()
    local ok, socket = pcall(require, "socket")
    return ok and socket.gettime() or os.time()
end

local function vehicleLabel(model)
    if type(model) ~= "string" or model == "" then return "" end
    if beamjoy_vehicles and beamjoy_vehicles.getModelLabel then
        local ok, label = pcall(beamjoy_vehicles.getModelLabel, model)
        if ok and type(label) == "string" and label ~= "" then return label end
    end
    return model
end

--- this player's own race, for the activity line ("Racing <name> · lap 2/5")
local function selfActivity()
    local runner = beamjoy_raceRunner
    local session = runner and runner.session
    if type(session) ~= "table" or session.state ~= "RACE" then return "" end
    local race = beamjoyLive_main.findRace(session.raceId)
    local me = beamjoyLive_main.selfName()
    for _, p in ipairs(type(session.participants) == "table" and session.participants or {}) do
        if p.playerName == me then
            local laps = session.settings and tonumber(session.settings.laps)
            local lap = tonumber(p.currentLap) or 1
            local name = race and race.name or "a race"
            if p.finished then return "Finished " .. name end
            return laps and laps > 1 and string.format("Racing %s · lap %d/%d", name, math.min(lap, laps), laps)
                or ("Racing " .. name)
        end
    end
    return ""
end

--- The game object each player is driving : the vehicle BeamJoy says is current, else their first.
local function playerVehicles()
    local byOwner = {}
    local ok, vehicles = pcall(function() return MPVehicleGE.getVehicles() end)
    if not ok or type(vehicles) ~= "table" then return byOwner end
    for _, v in pairs(vehicles) do
        if v.ownerName and not v.isDeleted and v.gameVehicleID and v.gameVehicleID >= 0 then
            local list = byOwner[v.ownerName] or {}
            list[#list + 1] = v
            byOwner[v.ownerName] = list
        end
    end
    return byOwner
end

local function currentFor(name, list)
    if not list then return nil end
    local players = beamjoy_players and beamjoy_players.players
    local p = players and players[name]
    -- BeamJoy knows this player and says they're in no vehicle : spectating
    if p and p.currentVehicle == nil then return nil end
    if p and p.playerID ~= nil then
        local ok, gid = pcall(MPVehicleGE.getGameVehicleID, tostring(p.playerID) .. "-" .. tostring(p.currentVehicle))
        if ok and gid then
            for _, v in ipairs(list) do
                if v.gameVehicleID == gid then return v end
            end
        end
    end
    return list[1]
end

local function names()
    local out, seen = {}, {}
    local function add(name)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    local players = beamjoy_players and beamjoy_players.players
    if type(players) == "table" then
        for name in pairs(players) do add(name) end
    end
    local ok, list = pcall(function() return MPVehicleGE.getPlayers() end)
    if ok and type(list) == "table" then
        for _, p in pairs(list) do add(p.name) end
    end
    table.sort(out)
    return out
end

local function snapshot()
    local me = beamjoyLive_main.selfName()
    local vehicles = playerVehicles()
    local out = {}
    for _, name in ipairs(names()) do
        local entry = { name = name, vehicle = "", activity = name == me and selfActivity() or "", spectating = true }
        local v = currentFor(name, vehicles[name])
        local obj = v and be:getObjectByID(v.gameVehicleID)
        if obj then
            local pos, vel, dir = obj:getPosition(), obj:getVelocity(), obj:getDirectionVector()
            entry.pos = { pos.x, pos.y, pos.z }
            entry.speed = vel and vel:length() or 0
            entry.heading = dir and (math.deg(math.atan2(dir.x, dir.y)) % 360) or 0
            entry.vehicle = vehicleLabel(v.jbeam)
            entry.spectating = false
        end
        out[#out + 1] = entry
        if #out >= 128 then break end
    end
    return out
end

function M.onUpdate()
    local main = beamjoyLive_main
    local c = main.config
    if not (c and c.liveSessions and main.reporter and main.serverKey and main.account) then return end
    local t = now()
    if t - M.last < M.INTERVAL_S then return end
    M.last = t
    local ok, players = pcall(snapshot)
    if not ok then return main.log("live snapshot failed : " .. tostring(players)) end
    local level = main.level()
    if not level then return end
    main.send("BJLLiveReport", {
        serverKey = main.serverKey,
        serverName = c.serverName,
        level = level,
        mapName = main.levelTitle(level),
        players = players,
    })
end

M.snapshot = snapshot

return M
