--[[
BeamJoy Live : the site's Live page (BJL.live), when the host turned it on.

One game (the "reporter", the lowest player ID whose game runs BeamJoy Live) sends where everyone
is, in what and how fast, every few seconds : any game sees every car, the server doesn't. The
plugin adds what BeamJoy knows through its API (who's racing what, on which lap : races.sessions ;
guests' nicknames : players.online ; the map's name) and posts it, as the linked player with the
lowest ID. The server key never leaves the server.
]]

local U = BJL.util
local V = {
    --- the reporting game's player ID, or nil
    reporter = nil,
    --- the server's page on the site, once posted
    url = nil,
    INTERVAL_S = 4,
    lastPost = 0,
    busy = false,
}

local function S() return BJL.settings end
local function P() return BJL.players end

local function on()
    return S().enabled() and S().values.liveSessions == true
end

--- one game reports the whole server : the lowest player ID whose game runs BeamJoy Live
function V.elect()
    local best
    if on() then
        for playerID in pairs(P().games) do
            if U.connected(playerID) and (not best or playerID < best) then best = playerID end
        end
    end
    if best == V.reporter then return end
    local previous = V.reporter
    V.reporter = best
    if previous and U.connected(previous) then P().toClient(previous, "BJLReporter", { reporter = false }) end
    if best then P().toClient(best, "BJLReporter", { reporter = true }) end
end

--- "Racing Highway Loop · Race · lap 2/5" : what a racer's doing, from a BeamJoy session
local function activityOf(session, racer)
    local name = tostring(session.raceName or "a race")
    if (tonumber(session.phaseCount) or 1) > 1 and type(session.phase) == "table" and type(session.phase.name) == "string" then
        name = name .. " · " .. session.phase.name
    end
    local state = session.state
    if state == "GRID" then return "In the lobby for " .. name end
    if state == "COUNTDOWN" then return "On the grid for " .. name end
    if state == "BREAK" then return "Between phases of " .. name end
    if racer.finished or state == "FINISHED" then return "Finished " .. name end
    if racer.dnf then return "Out of " .. name end
    if racer.inPhase == false then return "Watching " .. name end
    local laps, lap = tonumber(session.laps), tonumber(racer.lap)
    if laps and laps > 1 and lap then return string.format("Racing %s · lap %d/%d", name, math.min(lap, laps), laps) end
    return "Racing " .. name
end

--- playerID -> activity, from BeamJoy's race sessions
local function activities(sessions)
    local out = {}
    for _, session in ipairs(U.list(sessions)) do
        for _, racer in ipairs(U.list(session.racers)) do
            if racer.id ~= nil then out[racer.id] = activityOf(session, racer) end
        end
    end
    return out
end

local function post(snapshot, sessions, online)
    local poster = P().account(P().firstLinked())
    if not poster then
        V.busy = false
        return
    end
    -- BeamMP name -> {id, displayName}
    local byName = {}
    for _, p in ipairs(U.list(online)) do
        if type(p.name) == "string" then byName[p.name] = p end
    end
    local doing = activities(sessions)
    local players = {}
    for _, p in ipairs(U.list(snapshot.players)) do
        if type(p) == "table" and type(p.name) == "string" then
            local known = byName[p.name]
            players[#players + 1] = {
                name = known and type(known.displayName) == "string" and known.displayName ~= "" and known.displayName or p.name,
                vehicle = P().label(p.vehicle),
                pos = p.pos,
                speed = tonumber(p.speed),
                heading = tonumber(p.heading),
                spectating = p.spectating == true,
                activity = known and doing[known.id] or "",
            }
            if #players >= 128 then break end
        end
    end
    local body = {
        serverKey = S().values.serverKey,
        serverName = S().serverName(),
        level = BJL.courses.map ~= "" and BJL.courses.map or snapshot.level,
        mapName = BJL.courses.mapLabel ~= "" and BJL.courses.mapLabel or snapshot.mapName,
        players = players,
    }
    BJL.web.json("POST", "/api/game/live", body, poster.token, function(status, data)
        V.busy = false
        if status == 200 and type(data) == "table" and type(data.url) == "string" then
            if data.url ~= V.url then
                V.url = data.url
                for playerID in pairs(P().games) do P().toClient(playerID, "BJLLiveStatus", { url = V.url }) end
            end
        elseif not V.warned then
            V.warned = true
            U.log("couldn't post the live page : " .. BJL.web.errorOf(status, data))
        end
    end)
end

--- { level, mapName, players: [{name, vehicle, pos, speed, heading, spectating}] } from the reporter
function BJL_onLive(playerID, data)
    if playerID ~= V.reporter or not on() or V.busy then return end
    if os.time() - V.lastPost < V.INTERVAL_S then return end
    local snapshot = type(data) == "string" and U.decode(U.unescapeWire(data))
    if type(snapshot) ~= "table" then return end
    V.busy, V.lastPost = true, os.time()
    BJL.BJ.call("races.sessions", {}, function(ok1, sessions)
        BJL.BJ.call("players.online", {}, function(ok2, online)
            local done, err = pcall(post, snapshot, ok1 and sessions and sessions.sessions or {},
                ok2 and online and online.players or {})
            if not done then
                V.busy = false
                U.log("the live page failed : " .. tostring(err))
            end
        end)
    end)
end

function V.register()
    MP.RegisterEvent("BJLLive", "BJL_onLive")
end

BJL.live = V
return V
