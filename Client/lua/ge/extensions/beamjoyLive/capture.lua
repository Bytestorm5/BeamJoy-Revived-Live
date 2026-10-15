--[[
BeamJoy Live : captures for the site (extension `beamjoyLive_capture`).

  screenshot()    the game's own screenshot (as Ctrl+P takes it), handed to the window as base64
  aerial(raceId)  flies the free camera over a race, looking straight down, and screenshots it.
                  The level's view distance is raised for it ; the camera never goes higher than
                  what's drawn (above that the picture is all sky), so a big race may take several
                  overlapping shots. The window stitches them by their world boxes, so the site
                  can lay the route over the result
  roads()         the level's road graph (`map.getMap()`, the one the game's navigation uses), for
                  the site's road maps. Exact world coordinates, no calibration involved

The UI hides its own window before asking for a picture.
]]

local M = {
    busy = false,
    --- aerials : the lens (vertical field of view, degrees), how high above the ground each shot
    --- is taken, and how much neighbouring shots overlap. Low enough that the level is drawn
    --- under the camera ; a big race takes several shots, stitched by the window
    AERIAL_FOV = 60,
    AERIAL_OVERLAP = .12,
    --- the view distance asked of the level for the shots (put back after)
    AERIAL_VIEW_DISTANCE = 12000,
    --- the camera stays this far inside the view distance it gets, so the frame's far corners
    --- are drawn ; never lower than AERIAL_MIN_ALTITUDE
    AERIAL_VIEW_MARGIN = .8,
    AERIAL_MIN_ALTITUDE = 250,
    --- roads, buildings and trees have their own (shorter) draw distances : higher than this they
    --- thin out even when the terrain is drawn, so bigger races are stitched from several shots
    AERIAL_DETAIL_ALTITUDE = 900,
    --- past this many shots, they're taken from higher up instead (still drawn, less detailed)
    AERIAL_MAX_SHOTS = 36,
    --- the narrowest screen shape shots are framed for (4:3) ; a wider one just overlaps more
    MIN_ASPECT = 4 / 3,
}

local log = function(msg) beamjoyLive_main.log(msg) end

---------------------------------------------------------------------------------------------------
-- base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
    local ok, mime = pcall(require, "mime")
    if ok and type(mime) == "table" and mime.b64 then
        local out = mime.b64(data)
        if type(out) == "string" then return out end
    end
    local bit = require("bit")
    local band, rshift, lshift, bor = bit.band, bit.rshift, bit.lshift, bit.bor
    local out, n = {}, #data
    local chars = {}
    for i = 1, 64 do chars[i - 1] = B64:sub(i, i) end
    for i = 1, n, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = bor(lshift(a, 16), lshift(b or 0, 8), c or 0)
        out[#out + 1] = chars[band(rshift(v, 18), 63)] .. chars[band(rshift(v, 12), 63)] ..
            (b and chars[band(rshift(v, 6), 63)] or "=") .. (c and chars[band(v, 63)] or "=")
    end
    return table.concat(out)
end
M.base64 = base64

---------------------------------------------------------------------------------------------------
-- screenshots

local function shotFiles()
    local set = {}
    local ok, files = pcall(function() return FS:findFiles("/screenshots/", "*", -1, true, false) end)
    if ok and type(files) == "table" then
        for _, f in ipairs(files) do
            local lower = f:lower()
            if lower:find("%.png$") or lower:find("%.jpe?g$") then set[f] = true end
        end
    end
    return set
end

local function readBytes(path)
    local ok, data = pcall(readFile, path)
    if ok and type(data) == "string" and #data > 0 then return data end
    local f = io.open(path, "rb")
    if not f then return nil end
    data = f:read("*a")
    f:close()
    return data
end

local function triggerScreenshot()
    if screenshot and screenshot.doScreenshot then
        local ok = pcall(screenshot.doScreenshot)
        if ok then return true end
    end
    if createScreenshot then
        return (pcall(createScreenshot, "screenshots/beamjoylive_" .. os.time(), "PNG"))
    end
    return false
end

--- Takes a screenshot inside a job and returns its bytes and mime type, or nil and why not.
---@param job NGJob
local function takeShot(job)
    local before = shotFiles()
    if not triggerScreenshot() then return nil, "This game version has no screenshot function." end
    -- up to 10 s for the file to show up
    for _ = 1, 40 do
        job.sleep(.25)
        for f in pairs(shotFiles()) do
            if not before[f] then
                -- wait until the file stops growing
                local last, size = -1, 0
                for _ = 1, 20 do
                    local data = readBytes(f)
                    size = data and #data or 0
                    if size > 0 and size == last then
                        local mime = f:lower():find("%.png$") and "image/png" or "image/jpeg"
                        return data, mime
                    end
                    last = size
                    job.sleep(.25)
                end
            end
        end
    end
    return nil, "The screenshot didn't appear in the screenshots folder."
end

--- best effort : the game's own UI toggle, so menus don't end up in the picture
local function setGameUi(visible)
    pcall(function()
        if ui_visibility and ui_visibility.set then ui_visibility.set(visible) end
    end)
end

function M.screenshot()
    if M.busy then return end
    M.busy = true
    core_jobsystem.create(function(job)
        setGameUi(false)
        job.sleep(.4)
        local data, mimeOrErr = takeShot(job)
        setGameUi(true)
        M.busy = false
        if not data then
            beamjoyLive_main.send("BJLCaptured", { kind = "screenshot", error = mimeOrErr })
        else
            beamjoyLive_main.send("BJLCaptured", {
                kind = "screenshot",
                dataUrl = "data:" .. mimeOrErr .. ";base64," .. base64(data),
            })
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- aerial

local function median(list)
    table.sort(list)
    return list[math.max(1, math.ceil(#list / 2))] or 0
end

--- the world box and ground height a race spans, gates and grid included
local function raceExtent(race)
    local xs, ys, zs = {}, {}, {}
    local function add(p)
        if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
            xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = tonumber(p.x), tonumber(p.y), tonumber(p.z) or 0
        end
    end
    for _, g in ipairs(race.gates or {}) do add(g.pos) end
    for _, s in ipairs(race.startPositions or {}) do add(s.pos) end
    if #xs == 0 then return nil end
    local minX, maxX = math.min(unpack(xs)), math.max(unpack(xs))
    local minY, maxY = math.min(unpack(ys)), math.max(unpack(ys))
    return { minX = minX, maxX = maxX, minY = minY, maxY = maxY, ground = median(zs) }
end

--- Splits the race's area into shots taken from low enough that the level is drawn (one shot from
--- high up only sees sky : past the level's visible distance nothing else is drawn). Each shot is
--- `altitude` above the ground under it, looking straight down with a `fov` (vertical) lens ;
--- neighbours overlap a little. Pure, so it's unit-tested.
---@param ext {minX: number, maxX: number, minY: number, maxY: number}
---@param ceiling number the highest the camera may go and still have the level drawn under it
---@return {area: number[], altitude: number, fov: number, halfHeight: number, centers: number[][]}
function M.planAerial(ext, ceiling)
    local w, h = ext.maxX - ext.minX, ext.maxY - ext.minY
    local margin = math.max(60, .1 * math.max(w, h))
    local area = { ext.minX - margin, ext.minY - margin, ext.maxX + margin, ext.maxY + margin }
    local aw, ah = area[3] - area[1], area[4] - area[2]
    local fov = M.AERIAL_FOV
    local tanHalf = math.tan(math.rad(fov / 2))
    -- one shot when it fits under the ceiling, else as high as the ceiling allows
    local single = math.max(ah / 2, aw / (2 * M.MIN_ASPECT)) / tanHalf
    local altitude = math.max(M.AERIAL_MIN_ALTITUDE, math.min(single, ceiling))
    local nx, ny, stepX, stepY
    for _ = 1, 20 do
        local halfH = altitude * tanHalf
        -- framed for the narrowest common screen ; a wider one just overlaps more
        local tileW, tileH = 2 * halfH * M.MIN_ASPECT, 2 * halfH
        stepX, stepY = tileW * (1 - M.AERIAL_OVERLAP), tileH * (1 - M.AERIAL_OVERLAP)
        nx = math.max(1, math.ceil((aw - tileW) / stepX - 1e-9) + 1)
        ny = math.max(1, math.ceil((ah - tileH) / stepY - 1e-9) + 1)
        if nx * ny <= M.AERIAL_MAX_SHOTS or altitude >= single then break end
        altitude = math.min(single, altitude * 1.25)
    end
    local halfH = altitude * tanHalf
    local tileW, tileH = 2 * halfH * M.MIN_ASPECT, 2 * halfH
    -- shots centred on the area as a whole
    local spanX, spanY = (nx - 1) * stepX + tileW, (ny - 1) * stepY + tileH
    local x0 = area[1] + aw / 2 - spanX / 2 + tileW / 2
    local y0 = area[4] - ah / 2 + spanY / 2 - tileH / 2
    local centers = {}
    for j = 0, ny - 1 do
        for i = 0, nx - 1 do
            centers[#centers + 1] = { x0 + i * stepX, y0 - j * stepY }
        end
    end
    return { area = area, altitude = altitude, fov = fov, halfHeight = halfH, centers = centers }
end

--- the ground's height at a point, or `fallback`
local function groundAt(x, y, fallback)
    local ok, z = pcall(function() return be:getSurfaceHeightBelow(vec3(x, y, 10000)) end)
    z = ok and tonumber(z) or nil
    if not z or z < -1e5 or z > 1e5 then return fallback end
    return z
end

--- Clouds and fog off for the shots (put back after). Each step is best effort.
local function clearSky()
    local restore = {}
    for _, class in ipairs({ "CloudLayer", "BasicClouds" }) do
        local ok, names = pcall(function() return scenetree.findClassObjects(class) end)
        for _, name in ipairs(ok and type(names) == "table" and names or {}) do
            local obj = scenetree.findObject(name)
            local visible = obj and pcall(function() return not obj:isHidden() end)
            if obj and visible then
                local hidden = pcall(function() obj:setHidden(true) end)
                if hidden then restore[#restore + 1] = function() obj:setHidden(false) end end
            end
        end
    end
    local levelInfo = scenetree.findObject("theLevelInfo")
    if levelInfo then
        local fog = tonumber(levelInfo.fogDensity)
        if fog and fog > 0 and pcall(function() levelInfo.fogDensity = 0 end) then
            restore[#restore + 1] = function() levelInfo.fogDensity = fog end
        end
        local visible = tonumber(levelInfo.visibleDistance)
        local want = M.AERIAL_VIEW_DISTANCE
        if visible and visible < want then
            -- the field alone isn't enough : the level applies it to the scene on postApply
            local function apply(v)
                pcall(function() levelInfo.visibleDistance = v end)
                pcall(function() levelInfo:setField("visibleDistance", 0, tostring(v)) end)
                pcall(function() levelInfo:postApply() end)
            end
            apply(want)
            restore[#restore + 1] = function() apply(visible) end
        end
    end
    return function()
        for _, fn in ipairs(restore) do pcall(fn) end
    end
end

--- the view distance the level has now (after clearSky asked for more)
local function viewDistance()
    local levelInfo = scenetree.findObject("theLevelInfo")
    local v = levelInfo and tonumber(levelInfo.visibleDistance)
    return v and v > 0 and v or 1000
end

--- how high the camera may go : with a vertical lens of `fov` and a 16:9 screen, the frame's far
--- corner is about 1.55 x the altitude away at 60 degrees
local function ceilingFor(distance, fov)
    local t = math.tan(math.rad(fov / 2))
    local cornerFactor = math.sqrt(1 + t * t + (t * 16 / 9) ^ 2)
    return math.max(M.AERIAL_MIN_ALTITUDE,
        math.min(M.AERIAL_DETAIL_ALTITUDE, distance * M.AERIAL_VIEW_MARGIN / cornerFactor))
end
M.ceilingFor = ceilingFor

---@param raceId integer
function M.aerial(raceId)
    if M.busy then return end
    local race = beamjoyLive_main.findRace(raceId)
    local ext = race and raceExtent(race)
    if not ext then
        return beamjoyLive_main.send("BJLCaptured", { kind = "aerial", error = "That race has no gates." })
    end
    M.busy = true

    core_jobsystem.create(function(job)
        local prevCam = core_camera.getActiveCamName and core_camera.getActiveCamName() or nil
        local prevFov = core_camera.getFovDeg and core_camera.getFovDeg() or nil
        local restoreSky = clearSky()
        local plan = M.planAerial(ext, ceilingFor(viewDistance(), M.AERIAL_FOV))
        log(string.format("aerial : %d shot(s) from %d m (view distance %d m)", #plan.centers,
            math.floor(plan.altitude), math.floor(viewDistance())))
        local err
        local ok, moveErr = pcall(function()
            core_camera.setByName(0, "free")
            core_camera.setFOV(0, plan.fov)
        end)
        if not ok then err = "Couldn't move the camera : " .. tostring(moveErr) end
        -- straight down, north at the top of the picture
        local rot = quatFromDir(vec3(0, 0, -1), vec3(0, 1, 0))
        setGameUi(false)
        for i, c in ipairs(plan.centers) do
            if err then break end
            local z = groundAt(c[1], c[2], ext.ground) + plan.altitude
            core_camera.setPosRot(0, c[1], c[2], z, rot.x, rot.y, rot.z, rot.w)
            -- terrain and objects stream in for the new view (longer for the first)
            job.sleep(i == 1 and 3 or 1.5)
            local data, mimeOrErr = takeShot(job)
            if not data then
                err = mimeOrErr
            else
                beamjoyLive_main.send("BJLCaptured", {
                    kind = "aerialTile",
                    raceId = raceId,
                    index = i,
                    count = #plan.centers,
                    area = plan.area,
                    dataUrl = "data:" .. mimeOrErr .. ";base64," .. base64(data),
                    -- the window turns this into the shot's box once it knows the picture's shape
                    center = c,
                    halfHeight = plan.halfHeight,
                })
            end
        end
        setGameUi(true)
        restoreSky()
        pcall(function()
            if prevFov then core_camera.setFOV(0, prevFov) end
            if prevCam then core_camera.setByName(0, prevCam) end
        end)
        M.busy = false
        if err then
            log("aerial : " .. err)
            beamjoyLive_main.send("BJLCaptured", { kind = "aerial", raceId = raceId, error = err })
        else
            beamjoyLive_main.send("BJLCaptured", { kind = "aerial", raceId = raceId, done = true, area = plan.area })
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- road map

local function round(n, step)
    return math.floor(n / step + .5) * step
end

--- The level's drivable road graph : nodes [x, y, z, radius] and edges between them.
function M.roadMap()
    local ok, graph = pcall(function() return map.getMap() end)
    if not ok or type(graph) ~= "table" or type(graph.nodes) ~= "table" then return nil end
    local index, nodes, edges = {}, {}, {}
    for name, n in pairs(graph.nodes) do
        local p = n.pos
        if p then
            nodes[#nodes + 1] = { round(p.x, .1), round(p.y, .1), round(p.z, .1), round(tonumber(n.radius) or 3, .1) }
            index[name] = #nodes - 1
        end
    end
    for name, n in pairs(graph.nodes) do
        local a = index[name]
        if a and type(n.links) == "table" then
            for other in pairs(n.links) do
                local b = index[other]
                if b and a < b then edges[#edges + 1] = { a, b } end
            end
        end
    end
    if #nodes < 2 or #edges < 1 then return nil end
    return { v = 1, nodes = nodes, edges = edges }
end

function M.roads()
    local level = beamjoyLive_main.level()
    local roads = level and M.roadMap()
    beamjoyLive_main.send("BJLRoads", { level = level, map = roads })
end

return M
