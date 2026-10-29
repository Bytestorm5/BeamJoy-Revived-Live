--[[
BeamJoy Live : laps to the site's leaderboards (BJL.laps), from BeamJoy's plugin API.

Grid races : BeamJoy's race events. Every lap a linked racer completes (RacerLap) goes to the race's
route on the site, as them (their game's token), unless BeamJoy wouldn't count it either :
  - the phase is kept off the leaderboard (its `leaderboard`), or the race's "Post laps to the site"
    option (this plugin's, in BeamJoy's race editor and start menu) is off ;
  - the pit lane touched the lap (the racer's `pitLaps`) ;
  - the racer is disqualified. Disqualified after their laps went out (RaceControl, RacerOut) : the
    run's laps are withdrawn from the site ; reinstated : posted again ;
  - BeamJoy didn't count the run : a race started with its anti-cheat options off, or without the
    race's own vehicle rule. The API says so with the phase's results (a result without a
    `leaderboardRank`), and the run is withdrawn then.
A lap says how its clock started : standing (from the grid) or flying. A circuit's first lap is
standing unless the racer drove an out lap first (RacerGate's `outLap`) ; a point-to-point run is
flying when its first checkpoint's time is 0 (a flying start's clock starts there).

A run is one racer's laps in one phase of a race session. The site keeps each record as it was
before a run, so a withdrawal puts it back exactly.

Freeroam runs : the API has no event for them, so the player's game reports each finished run
(BJLFreeroamLap) and the plugin posts it, flying.

After each lap : a line on BeamJoy's HUD for a site PB or record (and the first lap of a run), the
racer's site rank beside their name on the race HUD, "Site PB" on their result, and the window and
the BeamJoy Live page get the lap.
]]

local U = BJL.util
local L = {
    --- run key ("<session>#<phase>#<racer>") -> run
    runs = {},
    order = {},
    MAX_RUNS = 500,
    --- playerID -> their freeroam runs' queue (one at a time, in order)
    freeroam = {},
    --- BeamJoy shows plugins' labels on its race HUD (server build 2480 on)
    hudFields = false,
}

local function S() return BJL.settings end
local function C() return BJL.courses end
local function P() return BJL.players end

local function active()
    return S().enabled() and S().values.leaderboards ~= false
end

--- a racer's part of a run key : their racer key (theirs for the event) or their player ID (an API
--- from before racer keys)
local function who(racer)
    if type(racer) ~= "table" then return nil end
    if racer.racerKey ~= nil then return "k" .. tostring(racer.racerKey) end
    if racer.id ~= nil then return "p" .. tostring(racer.id) end
    return nil
end

local function keyOf(sessionId, phaseIndex, racer)
    local w = who(racer)
    if sessionId == nil or not w then return nil end
    return tostring(sessionId) .. "#" .. tostring(tonumber(phaseIndex) or 1) .. "#" .. w
end

local function drop(run)
    L.runs[run.key] = nil
    for i, k in ipairs(L.order) do
        if k == run.key then
            table.remove(L.order, i)
            break
        end
    end
end

---@param data table a race event (sessionId, phaseIndex, raceId, map)
---@param racer table
---@param create boolean?
local function runFor(data, racer, create)
    local key = keyOf(data.sessionId, data.phaseIndex, racer)
    if not key then return nil end
    local run = L.runs[key]
    if not run and create then
        run = {
            key = key,
            -- the run as the site knows it (its records keep what each run changed)
            site = key,
            sessionId = data.sessionId,
            phaseIndex = tonumber(data.phaseIndex) or 1,
            raceId = tonumber(data.raceId),
            map = type(data.map) == "string" and data.map or C().map,
            racerKey = racer.racerKey,
            laps = {},
            posted = false,
            disqualified = false,
            outLap = false,
            --- lap -> its first checkpoint's time (a point-to-point run : 0 is a flying start)
            firstGate = {},
            queue = {},
        }
        L.runs[key] = run
        L.order[#L.order + 1] = key
        while #L.order > L.MAX_RUNS do
            L.runs[table.remove(L.order, 1)] = nil
        end
    end
    if run and racer.id ~= nil then run.playerID = racer.id end
    return run
end

--- runs a run's site requests one after the other : `task(done)`
local function enqueue(run, task)
    run.queue[#run.queue + 1] = task
    if run.busy then return end
    local function nextTask()
        local t = table.remove(run.queue, 1)
        if not t then
            run.busy = false
            if run.final then drop(run) end
            return
        end
        run.busy = true
        local ok, err = pcall(t, nextTask)
        if not ok then
            U.log("a lap task failed : " .. tostring(err))
            nextTask()
        end
    end
    nextTask()
end

local function hud(playerID, text, color)
    if playerID == nil or not U.connected(playerID) then return end
    BJL.BJ.call("hud.message", { playerId = playerID, text = text, color = color, durationS = 6 })
end

--- labels on the racer in the session (their result ; `hud = "only"` : the race HUD only)
local function setFields(run, fields)
    if not run.sessionId then return end
    local params = { sessionId = run.sessionId, fields = fields }
    if run.racerKey ~= nil then params.racerKey = run.racerKey else params.playerId = run.playerID end
    if params.racerKey == nil and params.playerId == nil then return end
    BJL.BJ.call("results.setFields", params)
end

--- standing or flying : how lap `n` of the run started
local function startOf(run, race, n)
    if type(race) == "table" and race.loopable then
        return (n == 1 and not run.outLap) and "standing" or "flying"
    end
    return run.firstGate[n] == 0 and "flying" or "standing"
end
L.startOf = startOf

local function siteHost()
    return (S().values.siteUrl:gsub("^https?://", ""))
end

--- what became of a lap : the racer's HUD, their labels, their game's window, the page
local function report(run, lap, route, res)
    local status = res.status or "posted"
    local entry = {
        name = route and route.title or lap.raceName or "?",
        route = route and { slug = route.slug, title = route.title, url = route.url } or nil,
        lapMs = lap.lapMs,
        start = lap.start,
        status = status,
        rank = res.rank,
        drivers = res.drivers,
        isPB = res.isPB,
        isRecord = res.isRecord,
        error = res.error,
    }
    if status == "posted" then
        local tag = res.isRecord and " · record" or res.isPB and " · PB" or ""
        if res.isPB or not run.told then
            run.told = true
            hud(run.playerID, string.format("Site : %s · P%s of %s%s", U.formatLap(lap.lapMs), tostring(res.rank),
                tostring(res.drivers), tag), res.isRecord and "purple" or res.isPB and "good" or nil)
        end
        if run.sessionId then
            local fields = {}
            if L.hudFields then
                fields[#fields + 1] = { key = "rank", label = "Site", value = "#" .. tostring(res.rank), color = "accent", hud = "only" }
            end
            if res.isRecord and not run.siteRecord then
                run.siteRecord = true
                fields[#fields + 1] = { key = "best", label = siteHost(), value = "Site record", color = "purple" }
            elseif res.isPB and not run.siteRecord and not run.sitePB then
                run.sitePB = true
                fields[#fields + 1] = { key = "best", label = siteHost(), value = "Site PB", color = "good" }
            end
            if #fields > 0 then setFields(run, fields) end
        end
    elseif status == "unlisted" then
        if not run.toldUnlisted then
            run.toldUnlisted = true
            hud(run.playerID, "BeamJoy Live : this race isn't on " .. siteHost() .. ", its laps aren't posted.", "muted")
        end
    elseif status == "failed" then
        hud(run.playerID, "BeamJoy Live : lap not posted (" .. tostring(res.error) .. ")", "bad")
    end
    if run.playerID ~= nil then
        P().toClient(run.playerID, "BJLLapResult", entry)
        if BJL.page then BJL.page.onLap(run.playerID, entry) end
    end
end

---@param run table
---@param lap {lap: integer?, lapMs: integer, sectors: integer[]?, vehicle: string, playerName: string, start: string, raceId: integer, map: string}
local function postLap(run, lap)
    enqueue(run, function(done)
        if run.disqualified then return done() end
        C().route(lap.map, lap.raceId, function(route, why)
            if not route then
                report(run, lap, nil, why == "unlisted" and { status = "unlisted" } or { status = "failed",
                    error = why == "unknown" and "this race isn't in BeamJoy's race data" or "the site didn't answer" })
                return done()
            end
            run.route = route
            local body = {
                route = route.slug,
                lapMs = lap.lapMs,
                sectors = lap.sectors,
                vehicle = lap.vehicle,
                playerName = lap.playerName,
                start = lap.start,
                run = lap.lap and run.site or nil,
                runLap = lap.lap,
            }
            local function attempt(n)
                BJL.web.json("POST", "/api/game/laps", body, run.token, function(status, data)
                    if status == 0 and n < 3 then return U.after(3, function() attempt(n + 1) end) end
                    if status == 200 then
                        run.posted = true
                        report(run, lap, route, data)
                    elseif status == 429 then
                        -- the site has it (an answer lost on the way) : still counts as posted
                        run.posted = true
                        report(run, lap, route, { status = "duplicate" })
                    else
                        report(run, lap, route, { status = "failed", error = BJL.web.errorOf(status, data) })
                    end
                    done()
                end)
            end
            attempt(1)
        end)
    end)
end

--- takes a run's laps back off the site (its records go back to before the run)
local function withdraw(run, why)
    enqueue(run, function(done)
        if not run.posted or not run.route then return done() end
        local route = run.route
        local function attempt(n)
            BJL.web.json("POST", "/api/game/laps/withdraw", { route = route.slug, run = run.site }, run.token,
                function(status, data)
                    if status == 0 and n < 3 then return U.after(3, function() attempt(n + 1) end) end
                    if status == 200 then
                        run.posted = false
                        hud(run.playerID, "BeamJoy Live : your laps on " .. route.title .. " came off the site (" .. why .. ").", "warn")
                        if run.sitePB or run.siteRecord then
                            run.sitePB, run.siteRecord = false, false
                            setFields(run, { { key = "best", value = "" }, { key = "rank", value = "" } })
                        end
                        if run.playerID ~= nil then
                            local entry = { name = route.title, route = { slug = route.slug, title = route.title, url = route.url },
                                status = "withdrawn" }
                            P().toClient(run.playerID, "BJLLapResult", entry)
                            if BJL.page then BJL.page.onLap(run.playerID, entry) end
                        end
                    else
                        U.log("couldn't withdraw run " .. run.site .. " : " .. BJL.web.errorOf(status, data))
                    end
                    done()
                end)
        end
        attempt(1)
    end)
end

local function disqualify(run, why)
    if not run or run.disqualified then return end
    run.disqualified = true
    withdraw(run, why)
end

local function reinstate(run)
    if not run or not run.disqualified then return end
    run.disqualified = false
    for _, lap in ipairs(run.laps) do postLap(run, lap) end
end

---------------------------------------------------------------------------------------------------
-- BeamJoy's race events

local function onGate(d)
    if not active() then return end
    local racer = type(d.racer) == "table" and d.racer or {}
    if not P().account(racer.id) then return end
    local run = runFor(d, racer, true)
    if not run then return end
    if d.outLap then
        run.outLap = true
    elseif tonumber(d.step) == 1 and tonumber(d.lapMs) and tonumber(d.lap) and run.firstGate[tonumber(d.lap)] == nil then
        run.firstGate[tonumber(d.lap)] = tonumber(d.lapMs)
    end
end

local function onLap(d)
    if not active() then return end
    local racer = type(d.racer) == "table" and d.racer or {}
    local account = P().account(racer.id)
    if not account then return end
    local mine = type(d.options) == "table" and d.options[BJL.NAME]
    if type(mine) == "table" and mine.post == false then return end
    if type(d.phase) == "table" and d.phase.leaderboard == false then return end
    local n, ms = tonumber(d.lap), tonumber(d.lapMs)
    if not n or not ms or ms <= 0 then return end
    -- a lap the pit lane touched : BeamJoy leaves it out of best laps and its leaderboard
    if U.contains(racer.pitLaps, n) then return end
    local run = runFor(d, racer, true)
    if not run then return end
    run.token = account.token
    local race = C().race(run.map, run.raceId)
    local sectors = {}
    for i, s in ipairs(U.list(d.sectorsMs)) do sectors[i] = math.floor((tonumber(s) or 0) + .5) end
    local lap = {
        lap = n,
        lapMs = math.floor(ms + .5),
        sectors = #sectors >= 2 and sectors or nil,
        vehicle = P().label(racer.vehicle),
        playerName = U.playerName(racer.id) ~= "" and U.playerName(racer.id) or tostring(racer.name or ""),
        start = startOf(run, race, n),
        raceId = run.raceId,
        map = run.map,
        raceName = d.raceName,
    }
    run.laps[#run.laps + 1] = lap
    if racer.disqualified then return disqualify(run, "disqualified") end
    if not run.disqualified then postLap(run, lap) end
end

--- a phase's final result : runs BeamJoy didn't count come off the site, and the phase's runs are
--- done (nothing can change them now)
local function judge(sessionId, phaseIndex, phase, results)
    phaseIndex = tonumber(phaseIndex) or 1
    local counts = not (type(phase) == "table" and phase.leaderboard == false)
    for _, r in ipairs(U.list(results)) do
        local key = type(r) == "table" and keyOf(sessionId, phaseIndex, r)
        local run = key and L.runs[key]
        if run and counts and r.leaderboardRank == nil then
            disqualify(run, r.disqualified and "disqualified" or "BeamJoy didn't count the run : anti-cheat options off, or not the race's vehicle rule")
        end
    end
    for _, run in pairs(L.runs) do
        if run.sessionId == sessionId and run.phaseIndex == phaseIndex then
            run.final = true
            if not run.busy then drop(run) end
        end
    end
end
L.judge = judge

local function forgetSession(sessionId)
    for _, run in pairs(L.runs) do
        if run.sessionId == sessionId then
            run.final = true
            if not run.busy then drop(run) end
        end
    end
end

--- { raceId, timeMs, model } : a freeroam run the player's game timed
function BJL_onFreeroamLap(playerID, data)
    local msg = type(data) == "string" and U.decode(U.unescapeWire(data))
    if not msg or not active() then return end
    local raceId, ms = tonumber(msg.raceId), tonumber(msg.timeMs)
    if not raceId or not ms or ms <= 0 or ms > 6 * 3600000 then return end
    local account = P().account(playerID)
    if not account then return end
    local map = C().map
    if C().option(map, raceId, "post") == false then return end
    local run = L.freeroam[playerID] or { key = "freeroam#" .. playerID, queue = {}, laps = {} }
    L.freeroam[playerID] = run
    -- each freeroam run is one of its own : its result always shows
    run.playerID, run.token, run.disqualified, run.told = playerID, account.token, false, false
    local race = C().race(map, raceId)
    -- a run starts as the start gate is crossed at speed : a flying start
    postLap(run, {
        lapMs = math.floor(ms + .5),
        vehicle = P().label(msg.model),
        playerName = U.playerName(playerID),
        start = "flying",
        raceId = raceId,
        map = map,
        raceName = race and race.name,
    })
end

function L.forgetPlayer(playerID)
    L.freeroam[playerID] = nil
end

function L.register()
    local BJ = BJL.BJ
    MP.RegisterEvent("BJLFreeroamLap", "BJL_onFreeroamLap")
    -- the race start menu's and race editor's switch, per race
    BJ.raceOptions({
        { id = "site", title = "BeamJoy Live", options = {
            { id = "post", type = "toggle", label = "Post laps to the site", default = true,
                tooltip = "Linked players' laps on this race go to BeamJoy Web's leaderboards" },
        } },
    })
    BJ.onReady(function(info)
        local build = type(info) == "table" and type(info.beamjoy) == "table" and tonumber(info.beamjoy.build)
        L.hudFields = build ~= nil and build >= 2480
    end)
    BJ.on("RacerGate", onGate)
    BJ.on("RacerLap", onLap)
    BJ.on("RacerOut", function(d)
        if d.reason == "disqualified" then disqualify(runFor(d, d.racer or {}, false), "disqualified") end
    end)
    BJ.on("RaceControl", function(d)
        local run = runFor(d, d.racer or {}, false)
        if d.action == "disqualify" then
            disqualify(run, "disqualified")
        elseif d.action == "reinstate" then
            reinstate(run)
        end
    end)
    BJ.on("RacePhaseFinished", function(d)
        judge(d.sessionId, d.phaseIndex, d.phase, d.results)
    end)
    BJ.on("RaceFinished", function(d)
        local phases = U.list(d.phases)
        if #phases > 0 then
            for _, p in ipairs(phases) do
                local phase = type(p.phase) == "table" and p.phase or {}
                judge(d.sessionId, phase.index, phase, p.results)
            end
        else
            judge(d.sessionId, d.phaseIndex, d.phase, d.results)
        end
    end)
    BJ.on("RaceClosed", function(d) forgetSession(d.sessionId) end)
end

BJL.laps = L
return L
