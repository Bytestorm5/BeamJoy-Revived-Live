--[[
BeamJoy Live : lap reporting (extension `beamjoyLive_laps`).

Listens to the race updates BeamJoy's server already sends this player ("raceSessionUpdate" for
grid races, "raceFreeroamResult" for freeroam runs) and hands each lap this player completes to
the window, which finds the race on the site and posts the lap to its leaderboard. Laps are the
server's own timings, with each lap's sector splits when the race has sectors.

Only laps BeamJoy would put on its own leaderboard are posted : not from a phase kept off it, not
a lap the pit lane touched, not from a race started with the anti-cheat options off or without the
race's own vehicle rule, not while disqualified. Each lap says how its clock started (standing :
from the grid ; flying : at a line crossed at speed), and which run it's from (the session's
phase) : when the racer is disqualified later in that phase, the window withdraws the run's laps
from the site, and posts them again if they're reinstated.
]]

local M = {
    --- the beamjoy_communications our handlers are registered on (BeamJoy may be reloaded)
    attachedTo = nil,
    --- run ("<session id>#<phase>") -> what's known of it
    ---@type table<string, {seen: integer, laps: table[], posted: boolean, disqualified: boolean, course: table?}>
    runs = {},
    --- session id -> its settings and phases, from the last full update (gate-crossing updates
    --- leave them out)
    ---@type table<string, {settings: table?, phases: table?}>
    sessions = {},
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

local function list(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for i = 1, 10000 do
        local v = at(t, i)
        if v == nil then break end
        out[i] = v
    end
    return out
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

---@param lap {lapMs: integer, sectors: integer[]?, vehicle: string, start: string, run: string?, runLap: integer?}
local function handOn(course, lap)
    if not enabled() or not course then return end
    beamjoyLive_main.send("BJLLap", {
        course = course,
        lapMs = lap.lapMs,
        sectors = lap.sectors,
        vehicle = lap.vehicle,
        playerName = selfName(),
        start = lap.start,
        run = lap.run,
        runLap = lap.runLap,
        -- read by older sites, which had no `start`
        kind = lap.run and "grid" or "freeroam",
    })
end

local function withdraw(course, run)
    if not enabled() or not course then return end
    beamjoyLive_main.send("BJLWithdraw", { course = course, run = run })
end

---------------------------------------------------------------------------------------------------
-- BeamJoy's rules (services/raceGrid.lua's trySubmitTime)

--- Why the race as started can't go on a leaderboard, or nil when it can.
---@param race table? BeamJoy's race
---@param settings table? the session's settings
---@param phase table? the phase being run
---@return string?
function M.excluded(race, settings, phase)
    if type(phase) == "table" and phase.leaderboard == false then return "phase off the leaderboard" end
    if type(settings) ~= "table" then return "settings unknown" end
    -- started with an anti-cheat option off
    if not (settings.disableNodegrabber == true and settings.disableCameras == true and
            settings.disableGravityChange == true) then
        return "anti-cheat off"
    end
    -- a race with its own vehicle rule, started under another
    if type(race) == "table" and race.vehicleRestrictionMode ~= nil and race.vehicleRestrictionMode ~= "free" and
        settings.vehicleRestrictionStartMode ~= "raceDefined" then
        return "vehicle rule not the race's"
    end
    return nil
end

--- How lap `n` of a grid race started : a circuit's first lap from the grid is standing, unless the
--- race begins with an out lap ; a point-to-point run is standing unless it's a flying start.
function M.startOf(race, settings, n)
    settings = type(settings) == "table" and settings or {}
    if type(race) == "table" and race.loopable then
        return (n == 1 and settings.outLap ~= true) and "standing" or "flying"
    end
    return settings.flyingStart == true and "flying" or "standing"
end

local function isPitLap(participant, n)
    for _, l in ipairs(list(participant.pitLaps)) do
        if tonumber(l) == n then return true end
    end
    return false
end

---------------------------------------------------------------------------------------------------

local function postRun(run)
    for _, lap in ipairs(run.laps) do handOn(run.course, lap) end
    run.posted = #run.laps > 0
end

---@param session table BeamJoy's race session payload (services/raceGrid.lua buildSessionPayload)
local function onSessionUpdate(session)
    if type(session) ~= "table" or type(session.participants) ~= "table" or session.id == nil then return end
    local id = tostring(session.id)
    local known = M.sessions[id] or {}
    M.sessions[id] = known
    if type(session.settings) == "table" then known.settings = session.settings end
    if type(session.phases) == "table" then known.phases = session.phases end
    -- joined (or reloaded) between full updates : BeamJoy's own copy of the session has them
    local own = beamjoy_raceRunner and beamjoy_raceRunner.session
    if type(own) == "table" and tostring(own.id) == id then
        known.settings = known.settings or (type(own.settings) == "table" and own.settings or nil)
        known.phases = known.phases or (type(own.phases) == "table" and own.phases or nil)
    end

    local me = selfName()
    local mine
    for _, p in ipairs(list(session.participants)) do
        if p.playerName == me then
            mine = p
            break
        end
    end
    if not mine then return end

    local phaseIndex = tonumber(session.phaseIndex) or 1
    local key = id .. "#" .. phaseIndex
    local laps = list(mine.lapTimes)
    local run = M.runs[key]
    if not run then
        -- one run at a time is all that can still change : earlier ones are final
        M.runs = {}
        M.sessions = { [id] = known }
        -- a phase already under way (a rejoin, a reload) : its earlier laps were posted then, if at all
        run = { seen = #laps, laps = {}, posted = false, disqualified = mine.disqualified == true }
        M.runs[key] = run
    end

    local race = beamjoyLive_main.findRace(session.raceId)
    run.course = run.course or (race and beamjoyLive_main.course(race))
    local phase = type(known.phases) == "table" and at(known.phases, phaseIndex) or nil
    local excluded = M.excluded(race, known.settings, phase)

    if #laps < run.seen then run.seen = #laps end
    for n = run.seen + 1, #laps do
        local ms = tonumber(laps[n])
        if ms and ms > 0 and not excluded and not isPitLap(mine, n) then
            local lap = {
                lapMs = math.floor(ms + .5),
                sectors = sectorsOf(at(mine.lapSectorHistory, n)),
                vehicle = vehicleLabel(mine.vehicleModel or currentModel()),
                start = M.startOf(race, known.settings, n),
                run = key,
                runLap = n,
            }
            run.laps[#run.laps + 1] = lap
            if not run.disqualified then
                handOn(run.course, lap)
                run.posted = true
            end
        end
    end
    run.seen = #laps

    -- disqualified (staff, a plugin, a judged result) after laps went out : taken back ; reinstated :
    -- posted again
    local dq = mine.disqualified == true
    if dq and not run.disqualified then
        run.disqualified = true
        if run.posted then
            withdraw(run.course, key)
            run.posted = false
        end
    elseif not dq and run.disqualified then
        run.disqualified = false
        postRun(run)
    end
end

---@param raceId integer
---@param result {timeMs: integer}
local function onFreeroamResult(raceId, result)
    if type(result) ~= "table" or not tonumber(result.timeMs) then return end
    local race = beamjoyLive_main.findRace(raceId)
    -- a run starts as the start gate is crossed at speed : a flying start
    handOn(race and beamjoyLive_main.course(race), {
        lapMs = math.floor(tonumber(result.timeMs) + .5),
        vehicle = vehicleLabel(currentModel()),
        start = "flying",
    })
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
    M.runs = {}
    M.sessions = {}
end

-- exposed for tests
M.onSessionUpdate = onSessionUpdate
M.onFreeroamResult = onFreeroamResult

return M
