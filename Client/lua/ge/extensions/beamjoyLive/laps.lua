--[[
BeamJoy Live : lap reporting (extension `beamjoyLive_laps`).

Listens to the race updates BeamJoy's server already sends this player ("raceSessionUpdate" for
grid races, "raceFreeroamResult" for freeroam runs) and hands each lap this player completes to
the window, which finds the race on the site and posts the lap to its leaderboard. Laps are the
server's own timings, with each lap's sector splits when the race has sectors.
]]

local M = {
    --- the beamjoy_communications our handlers are registered on (BeamJoy may be reloaded)
    attachedTo = nil,
    --- session id -> laps of ours already handed on
    ---@type table<string, integer>
    seen = {},
}

local function selfName()
    return beamjoyLive_main.selfName()
end

--- JSON arrays can come back keyed by numbers or by strings, depending on how they were encoded
local function at(t, i)
    if type(t) ~= "table" then return nil end
    local v = t[i]
    if v == nil then v = t[tostring(i)] end
    return v
end

local function sectorsOf(lapSectors)
    if type(lapSectors) ~= "table" then return nil end
    local out = {}
    for i = 1, 100 do
        local v = tonumber(at(lapSectors, i))
        if not v then break end
        out[i] = math.floor(v + .5)
    end
    return #out >= 2 and out or nil
end

local function vehicleLabel(model)
    if type(model) ~= "string" or model == "" then return "" end
    if beamjoy_vehicles and beamjoy_vehicles.getModelLabel then
        local ok, label = pcall(beamjoy_vehicles.getModelLabel, model)
        if ok and type(label) == "string" and label ~= "" then return label end
    end
    return model
end

local function currentModel()
    local ok, model = pcall(function()
        local veh = be:getPlayerVehicle(0)
        return veh and veh:getJBeamFilename()
    end)
    return ok and model or nil
end

local function enabled()
    local c = beamjoyLive_main.config
    return c and c.siteUrl ~= "" and c.leaderboards ~= false and beamjoyLive_main.account ~= nil
end

local function handOn(race, lapMs, sectors, model, kind)
    if not enabled() or not race then return end
    beamjoyLive_main.send("BJLLap", {
        course = beamjoyLive_main.course(race),
        lapMs = math.floor(lapMs + .5),
        sectors = sectors,
        vehicle = vehicleLabel(model),
        playerName = selfName(),
        kind = kind,
    })
end

---@param session table BeamJoy's race session payload (services/raceGrid.lua buildSessionPayload)
local function onSessionUpdate(session)
    if type(session) ~= "table" or type(session.participants) ~= "table" then return end
    local me = selfName()
    local mine
    for _, p in ipairs(session.participants) do
        if p.playerName == me then
            mine = p
            break
        end
    end
    if not mine then return end
    local laps = type(mine.lapTimes) == "table" and mine.lapTimes or {}
    local id = tostring(session.id)
    local seen = M.seen[id]
    -- first sight of a session already under way (a rejoin, a reload) : its old laps were posted
    -- then, if at all
    if seen == nil or #laps < seen then
        M.seen[id] = #laps
        return
    end
    if #laps == seen or mine.disqualified then
        M.seen[id] = #laps
        return
    end
    local race = beamjoyLive_main.findRace(session.raceId)
    for i = seen + 1, #laps do
        local ms = tonumber(laps[i])
        if ms and ms > 0 then
            handOn(race, ms, sectorsOf(at(mine.lapSectorHistory, i)), mine.vehicleModel or currentModel(), "grid")
        end
    end
    M.seen[id] = #laps
end

---@param raceId integer
---@param result {timeMs: integer}
local function onFreeroamResult(raceId, result)
    if type(result) ~= "table" or not tonumber(result.timeMs) then return end
    handOn(beamjoyLive_main.findRace(raceId), tonumber(result.timeMs), nil, currentModel(), "freeroam")
end

--- Hooks into BeamJoy's message dispatcher once it exists. Safe to call repeatedly.
function M.attach()
    local comms = beamjoy_communications
    if not comms or not comms.addHandler or M.attachedTo == comms then return end
    comms.addHandler("raceSessionUpdate", onSessionUpdate)
    comms.addHandler("raceFreeroamResult", onFreeroamResult)
    M.attachedTo = comms
end

function M.onServerLeave()
    M.seen = {}
end

-- exposed for tests
M.onSessionUpdate = onSessionUpdate
M.onFreeroamResult = onFreeroamResult

return M
