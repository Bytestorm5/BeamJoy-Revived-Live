--[[
BeamJoy Live : the site, through curl (BJL.web).

BeamMP's Lua has no HTTPS, so every site request runs curl (built into Windows 10+ and nearly every
Linux) as a detached process writing to files under tmp/, polled every 200 ms : the server never
waits on the site. The plugin's own requests (laps, live sessions, linking) and the games' relayed
ones (the window's uploads and lookups : the game's UI may only connect to localhost) go the same way.

Relay wire format, both ways : one header event, then the body in parts (BeamMP events are kept
under 20 KB each), escaped (util.escapeWire). Answers to a game are paced : BeamMP's server writes to
a player's connection from more than one thread, and a burst that fills it can garble a packet and
crash that player's launcher (BeamJoy paces its own sends for this). They leave at REPLY_BUDGET bytes
per poll ; the game paces what it sends here the same way (its main.lua). Only the site's /api/
paths are relayed.
]]

local U = BJL.util
local W = {
    --- bytes of body per relay event, before JSON and escaping grow it
    CHUNK = 12000,
    MAX_BODY = 40 * 1024 * 1024,
    MAX_INFLIGHT_PER_PLAYER = 8,
    REQUEST_TIMEOUT_S = 150,
    --- bytes sent to one player per poll (200 ms) : 80 KB/s, well under what BeamJoy's own flow
    --- control leaves room for ; an answer this small goes straight out when none waits
    REPLY_BUDGET = 16000,
    REPLY_SMALL = 4000,
}

local TMP_DIR = BJL.dir .. "tmp/"
--- relayed requests being received (header seen, parts arriving) : "id@player" -> entry
local incoming = {}
--- requests curl is running : key -> {base, startedAt, callback, playerID?}
local running = {}
local seq = 0
local curlOk = nil
--- playerID -> {event, data}[] waiting to be sent, oldest first
local outbox = {}

local function isWindows()
    return package.config:sub(1, 1) == "\\"
end

local function ensureTmp()
    local f = io.open(TMP_DIR .. ".keep", "w")
    if f then
        f:close()
        return true
    end
    if FS and FS.CreateDirectory then pcall(FS.CreateDirectory, TMP_DIR) end
    if isWindows() then
        os.execute('mkdir "' .. TMP_DIR:gsub("/", "\\") .. '" >NUL 2>&1')
    else
        os.execute("mkdir -p '" .. TMP_DIR .. "' >/dev/null 2>&1")
    end
    f = io.open(TMP_DIR .. ".keep", "w")
    if f then f:close() end
    return f ~= nil
end

local function hasCurl()
    if curlOk == nil then
        local ok, r = pcall(os.execute, isWindows() and "curl --version >NUL 2>&1" or "curl --version >/dev/null 2>&1")
        curlOk = ok and (r == true or r == 0)
        if not curlOk then U.log("curl wasn't found on this machine's PATH : the site can't be reached") end
    end
    return curlOk
end

--- a value for curl's config file : quoted, with \ and " escaped, on one line
local function cfgValue(v)
    return '"' .. tostring(v):gsub("[\r\n]", ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function removeFiles(base)
    for _, ext in ipairs({ ".cfg", ".body", ".out", ".status", ".done", ".cmd", ".sh" }) do
        os.remove(base .. ext)
    end
end

local METHODS = { GET = true, POST = true, DELETE = true }
local CONTENT_TYPES = { ["application/json"] = true, ["application/gzip"] = true }

--- A request to the site. `callback(status, body)` runs once it's answered ; status 0 : no answer
--- (body is then a JSON error). `token` : a player's, for what the site does as them.
---@param req {method: string, path: string, body: string?, token: string?, contentType: string?, playerID: integer?}
---@param callback fun(status: integer, body: string)
function W.request(req, callback)
    local site = BJL.settings.values.siteUrl
    local function fail(msg) callback(0, U.encode({ error = msg })) end
    if site == "" then return fail("This server hasn't set its site address.") end
    if not hasCurl() or not ensureTmp() then return fail("The server can't reach the site (no curl).") end
    seq = seq + 1
    local key = string.format("r%s_%d", req.playerID and tostring(req.playerID) or "s", seq)
    local base = TMP_DIR .. key
    local lines = {
        "url = " .. cfgValue(site .. req.path),
        "request = " .. cfgValue(req.method),
        "silent",
        "max-time = 120",
        "output = " .. cfgValue(base .. ".out"),
        "write-out = " .. cfgValue("%{http_code}"),
        "header = " .. cfgValue("User-Agent: BeamJoyLive"),
    }
    if req.token then lines[#lines + 1] = "header = " .. cfgValue("Authorization: Bearer " .. req.token) end
    if req.method ~= "GET" then
        lines[#lines + 1] = "header = " .. cfgValue("Content-Type: " .. (req.contentType or "application/json"))
        lines[#lines + 1] = "data-binary = " .. cfgValue("@" .. base .. ".body")
        if not U.writeFile(base .. ".body", req.body or "") then return fail("The server couldn't write its temp files.") end
    end
    if not U.writeFile(base .. ".cfg", table.concat(lines, "\n") .. "\n") then
        return fail("The server couldn't write its temp files.")
    end
    if isWindows() then
        local w = function(path) return '"' .. path:gsub("/", "\\") .. '"' end
        U.writeFile(base .. ".cmd", table.concat({
            "@curl -K " .. w(base .. ".cfg") .. " > " .. w(base .. ".status") .. " 2>NUL",
            "@ren " .. w(base .. ".status") .. " " .. key .. ".done",
        }, "\r\n") .. "\r\n")
        -- cmd /c ""path"" : cmd drops the outer pair, so a path with spaces or brackets still works
        os.execute('start "" /b cmd /c "' .. w(base .. ".cmd") .. '" >NUL 2>&1')
    else
        local q = function(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
        U.writeFile(base .. ".sh", table.concat({
            "curl -K " .. q(base .. ".cfg") .. " > " .. q(base .. ".status") .. " 2>/dev/null",
            "mv " .. q(base .. ".status") .. " " .. q(base .. ".done"),
        }, "\n") .. "\n")
        os.execute("sh " .. q(base .. ".sh") .. " >/dev/null 2>&1 &")
    end
    running[key] = { base = base, startedAt = os.time(), callback = callback, playerID = req.playerID }
end

--- A JSON request : `callback(status, data)`, data the decoded answer (or {error}).
function W.json(method, path, body, token, callback)
    W.request({ method = method, path = path, body = body ~= nil and U.encode(body) or nil, token = token },
        function(status, text)
            callback(status, U.decode(text) or { error = status == 0 and "The site didn't answer." or ("The site said " .. status .. ".") })
        end)
end

--- the error a site answer carries, for a message
function W.errorOf(status, data)
    if type(data) == "table" and type(data.error) == "string" then return data.error end
    return status == 0 and "The site didn't answer." or ("The site said " .. tostring(status) .. ".")
end

---------------------------------------------------------------------------------------------------
-- to the games

--- sends up to REPLY_BUDGET bytes of what waits for each player (always one event at least)
local function drainReplies()
    for playerID, q in pairs(outbox) do
        if not U.connected(playerID) then
            outbox[playerID] = nil
        else
            local sent = 0
            while #q > 0 and (sent == 0 or sent + #q[1][2] <= W.REPLY_BUDGET) do
                local ev = table.remove(q, 1)
                MP.TriggerClientEvent(playerID, ev[1], ev[2])
                sent = sent + #ev[2]
            end
            if #q == 0 then outbox[playerID] = nil end
        end
    end
end

--- events to a player's game, paced (straight out when small and nothing waits)
local function send(playerID, events)
    local size = 0
    for _, ev in ipairs(events) do size = size + #ev[2] end
    if not outbox[playerID] and size <= W.REPLY_SMALL then
        for _, ev in ipairs(events) do MP.TriggerClientEvent(playerID, ev[1], ev[2]) end
        return
    end
    local q = outbox[playerID] or {}
    for _, ev in ipairs(events) do q[#q + 1] = ev end
    outbox[playerID] = q
end

--- one message (a table, as JSON) to a player's game
function W.toClient(playerID, event, payload)
    if not U.connected(playerID) then return end
    send(playerID, { { event, U.escapeWire(U.encode(payload or {})) } })
end

--- a relayed answer to a player's game, in parts
local function reply(playerID, id, status, body)
    if not U.connected(playerID) then return end
    local parts = U.split(body or "", W.CHUNK)
    local events = { { "BJLHttpResult", U.escapeWire(U.encode({ id = id, status = status, parts = #parts })) } }
    for i, part in ipairs(parts) do
        events[#events + 1] = { "BJLHttpPart", U.escapeWire(U.encode({ id = id, part = i, data = part })) }
    end
    send(playerID, events)
end

local function fail(playerID, id, status, message)
    reply(playerID, id, status, U.encode({ error = message }))
end

local function inflight(playerID)
    local n = 0
    for _, r in pairs(running) do
        if r.playerID == playerID then n = n + 1 end
    end
    return n
end

local function relay(playerID, req, body)
    W.request({ method = req.method, path = req.path, body = body, token = req.token,
        contentType = req.contentType, playerID = playerID }, function(status, text)
        if status == 0 then
            local data = U.decode(text)
            return fail(playerID, req.id, 0, data and data.error or "The site didn't answer.")
        end
        -- a race uploaded from the window : the site's answers about this map's races may change
        if req.method == "POST" and req.path == "/api/game/routes" and status < 300 and BJL.courses then
            BJL.courses.forgetRoutes(BJL.courses.map)
        end
        reply(playerID, req.id, status, text)
    end)
end

--- header : { id, method, path, token?, contentType?, parts }
function BJL_onHttp(playerID, data)
    local ok, req = pcall(Util.JsonDecode, U.unescapeWire(type(data) == "string" and data or ""))
    if not ok or type(req) ~= "table" or type(req.id) ~= "number" then return end
    if BJL.settings.values.siteUrl == "" then return fail(playerID, req.id, 0, "This server hasn't set its site address.") end
    if not METHODS[req.method] or type(req.path) ~= "string" or #req.path > 400 or
        not req.path:match("^/api/[%w%-%._~/%?=&%%]*$") or req.path:find("..", 1, true) then
        return fail(playerID, req.id, 0, "Refused by the server.")
    end
    if req.contentType ~= nil and not CONTENT_TYPES[req.contentType] then req.contentType = nil end
    if type(req.token) ~= "string" or not req.token:match("^bjl_[%w%-_]+$") or #req.token > 100 then req.token = nil end
    if inflight(playerID) >= W.MAX_INFLIGHT_PER_PLAYER then return fail(playerID, req.id, 0, "Too many requests at once.") end
    local parts = tonumber(req.parts) or 0
    if parts == 0 then return relay(playerID, req, "") end
    if parts * W.CHUNK > W.MAX_BODY then return fail(playerID, req.id, 413, "Too large.") end
    incoming[req.id .. "@" .. playerID] = { req = req, parts = {}, expected = parts, got = 0 }
end

--- part : { id, part, data }
function BJL_onHttpPart(playerID, data)
    local ok, msg = pcall(Util.JsonDecode, U.unescapeWire(type(data) == "string" and data or ""))
    if not ok or type(msg) ~= "table" then return end
    local key = tostring(msg.id) .. "@" .. playerID
    local entry = incoming[key]
    if not entry or type(msg.part) ~= "number" or type(msg.data) ~= "string" or entry.parts[msg.part] then return end
    entry.parts[msg.part] = msg.data
    entry.got = entry.got + 1
    if entry.got == entry.expected then
        incoming[key] = nil
        relay(playerID, entry.req, table.concat(entry.parts))
    end
end

--- every 200 ms : answers sent on, finished requests handed back, timers run
function W.poll()
    drainReplies()
    -- what finished, first : a callback may start a request of its own (a run's next lap), and
    -- `running` can't take new keys while it's being walked through
    local finished = {}
    for key, r in pairs(running) do
        local done = U.readFile(r.base .. ".done")
        if done then
            local status = tonumber((done:gsub("%s", ""))) or 0
            finished[#finished + 1] = { key = key, r = r, status = status,
                body = status == 0 and U.encode({ error = "The site didn't answer." }) or (U.readFile(r.base .. ".out") or "") }
        elseif os.time() - r.startedAt > W.REQUEST_TIMEOUT_S then
            finished[#finished + 1] = { key = key, r = r, status = 0, body = U.encode({ error = "The site didn't answer in time." }) }
        end
    end
    for _, f in ipairs(finished) do
        running[f.key] = nil
        removeFiles(f.r.base)
    end
    for _, f in ipairs(finished) do
        local ok, err = pcall(f.r.callback, f.status, f.body)
        if not ok then U.log("a site answer's handler failed : " .. tostring(err)) end
    end
    U.tick()
end

--- requests still running (tests wait on it)
function W.busy()
    return next(running) ~= nil
end

function W.onPlayerDisconnect(playerID)
    for key in pairs(incoming) do
        if key:match("@" .. playerID .. "$") then incoming[key] = nil end
    end
    outbox[playerID] = nil
end

BJL.web = W
return W
