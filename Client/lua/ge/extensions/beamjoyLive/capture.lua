--[[
BeamJoy Live : captures for the site (extension `beamjoyLive_capture`).

  screenshot()    the game's own screenshot (as Ctrl+P takes it), handed to the window as base64
  aerial(raceId)  flies the free camera straight above a race, looking down, and screenshots it.
                  The window works out the world box the picture covers, so the site can lay
                  the route over it
  roads()         the level's road graph (`map.getMap()`, the one the game's navigation uses), for
                  the site's road maps. Exact world coordinates, no calibration involved

The UI hides its own window before asking for a picture.
]]

local M = {
    busy = false,
    --- vertical field of view used for aerials, degrees
    AERIAL_FOV = 40,
    --- the widest the aerial lens may go when a route is too big for AERIAL_FOV
    AERIAL_FOV_MAX = 75,
    --- above this the far plane and terrain detail fall apart ; bigger routes widen the lens instead
    AERIAL_MAX_ALTITUDE = 4000,
    --- screen shape the aerial is framed for ; the window measures the real one from the picture
    ASSUMED_ASPECT = 16 / 9,
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

---@param raceId integer
function M.aerial(raceId)
    if M.busy then return end
    local race = beamjoyLive_main.findRace(raceId)
    local ext = race and raceExtent(race)
    if not ext then
        return beamjoyLive_main.send("BJLCaptured", { kind = "aerial", error = "That race has no gates." })
    end
    M.busy = true

    local w, h = ext.maxX - ext.minX, ext.maxY - ext.minY
    local margin = math.max(60, .12 * math.max(w, h))
    -- half the ground height the picture must show, for the assumed screen shape
    local needHalf = math.max((h + 2 * margin) / 2, (w + 2 * margin) / (2 * M.ASSUMED_ASPECT))
    local fov = M.AERIAL_FOV
    local altitude = needHalf / math.tan(math.rad(fov / 2))
    if altitude > M.AERIAL_MAX_ALTITUDE then
        fov = math.min(M.AERIAL_FOV_MAX, 2 * math.deg(math.atan(needHalf / M.AERIAL_MAX_ALTITUDE)))
        altitude = needHalf / math.tan(math.rad(fov / 2))
    end
    local cx, cy = (ext.minX + ext.maxX) / 2, (ext.minY + ext.maxY) / 2
    local camZ = ext.ground + altitude

    core_jobsystem.create(function(job)
        local prevCam = core_camera.getActiveCamName and core_camera.getActiveCamName() or nil
        local prevFov = core_camera.getFovDeg and core_camera.getFovDeg() or nil
        local levelInfo = scenetree.findObject("theLevelInfo")
        local prevVisible = levelInfo and tonumber(levelInfo.visibleDistance) or nil

        local ok, err = pcall(function()
            if levelInfo and prevVisible and prevVisible < altitude + 1500 then
                levelInfo.visibleDistance = altitude + 1500
            end
            core_camera.setByName(0, "free")
            core_camera.setFOV(0, fov)
            -- straight down, north at the top of the picture
            local rot = quatFromDir(vec3(0, 0, -1), vec3(0, 1, 0))
            core_camera.setPosRot(0, cx, cy, camZ, rot.x, rot.y, rot.z, rot.w)
        end)
        local data, mimeOrErr
        if ok then
            setGameUi(false)
            -- terrain and objects stream in for the new view
            job.sleep(2.5)
            data, mimeOrErr = takeShot(job)
            setGameUi(true)
        else
            mimeOrErr = "Couldn't move the camera : " .. tostring(err)
            log(mimeOrErr)
        end

        pcall(function()
            if levelInfo and prevVisible then levelInfo.visibleDistance = prevVisible end
            if prevFov then core_camera.setFOV(0, prevFov) end
            if prevCam then core_camera.setByName(0, prevCam) end
        end)
        M.busy = false

        if not data then
            return beamjoyLive_main.send("BJLCaptured", { kind = "aerial", raceId = raceId, error = mimeOrErr })
        end
        beamjoyLive_main.send("BJLCaptured", {
            kind = "aerial",
            raceId = raceId,
            dataUrl = "data:" .. mimeOrErr .. ";base64," .. base64(data),
            -- the window turns this into the covered box once it knows the picture's shape
            center = { cx, cy },
            halfHeight = altitude * math.tan(math.rad(fov / 2)),
        })
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
