--[[
BeamJoy Live : freeroam runs (extension `beamjoyLive_laps`).

Grid races' laps reach the site from the server plugin, through BeamJoy's plugin API (its race
events). Freeroam runs (a race driven from freeroam through its start gate) have no event there, so
this game passes on the result BeamJoy's server sends it ("raceFreeroamResult") and the plugin posts
it. The time is the server's own.
]]

local M = {
    --- the beamjoy_communications our handler is registered on (BeamJoy may be reloaded)
    attachedTo = nil,
}

local function currentModel()
    local ok, model = pcall(function()
        local veh = be:getPlayerVehicle(0)
        return veh and veh:getJBeamFilename()
    end)
    return ok and model or nil
end

---@param raceId integer
---@param result {timeMs: integer}
local function onFreeroamResult(raceId, result)
    local main = beamjoyLive_main
    local c = main.config
    if not (c and c.siteUrl ~= "" and c.leaderboards ~= false and main.account) then return end
    if type(result) ~= "table" or not tonumber(result.timeMs) or not tonumber(raceId) then return end
    main.toServer("BJLFreeroamLap", { raceId = tonumber(raceId), timeMs = tonumber(result.timeMs), model = currentModel() })
end

--- Hooks into BeamJoy's message dispatcher once it exists. Safe to call repeatedly.
function M.attach()
    local comms = beamjoy_communications
    if not comms or not comms.addHandler or M.attachedTo == comms then return end
    comms.addHandler("raceFreeroamResult", onFreeroamResult)
    M.attachedTo = comms
end

-- exposed for tests
M.onFreeroamResult = onFreeroamResult

return M
