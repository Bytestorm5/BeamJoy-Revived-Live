--[[
BeamJoy Live : live session reporter (extension `beamjoyLive_live`).

When the host turned the Live page on, the server plugin picks one game to report for the whole
server. That game sends the plugin, every few seconds, who's on, in what, where and how fast :
everything here is what any player's game already sees of the others. The plugin adds what each
racer is doing (BeamJoy's plugin API) and posts it to the site.
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

--- to the decimetre : the message stays small
local function round(v)
    return math.floor(v * 10 + .5) / 10
end

local function snapshot()
    local vehicles = playerVehicles()
    local out = {}
    for _, name in ipairs(names()) do
        local entry = { name = name, vehicle = "", spectating = true }
        local v = currentFor(name, vehicles[name])
        local obj = v and be:getObjectByID(v.gameVehicleID)
        if obj then
            local pos, vel, dir = obj:getPosition(), obj:getVelocity(), obj:getDirectionVector()
            entry.pos = { round(pos.x), round(pos.y), round(pos.z) }
            entry.speed = round(vel and vel:length() or 0)
            entry.heading = math.floor((dir and (math.deg(math.atan2(dir.x, dir.y)) % 360) or 0) + .5)
            entry.vehicle = vehicleLabel(v.jbeam)
            entry.spectating = false
        end
        out[#out + 1] = entry
        if #out >= 100 then break end
    end
    return out
end

function M.onUpdate()
    local main = beamjoyLive_main
    local c = main.config
    if not (c and c.liveSessions and main.reporter) then return end
    local t = now()
    if t - M.last < M.INTERVAL_S then return end
    M.last = t
    local ok, players = pcall(snapshot)
    if not ok then return main.log("live snapshot failed : " .. tostring(players)) end
    local level = main.level()
    if not level then return end
    main.toServer("BJLLive", { level = level, mapName = main.levelTitle(level), players = players })
end

M.snapshot = snapshot

return M
