--[[
BeamJoy Live : small helpers the plugin's modules share (BJL.util).
]]

local U = {}

function U.log(msg)
    print("[BeamJoyLive] " .. msg)
end

function U.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function U.writeFile(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

--- JSON text to a table, or nil (BeamMP's own decoder : fast on BeamJoy's big race files)
function U.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, v = pcall(Util.JsonDecode, s)
    if ok and type(v) == "table" then return v end
    return nil
end

--- a table to JSON text (the BeamJoy API helper's encoder : empty tables are arrays, `[]`)
function U.encode(t)
    return BJL.BJ.json.stringify(t)
end

--- Every event text between the plugin and the games is escaped so it never holds a capital Z : the
--- BeamMP launcher drops a player on any packet over 500 bytes containing "Zp".
function U.escapeWire(s)
    return (s:gsub("[~Z]", { ["~"] = "~t", ["Z"] = "~z" }))
end

function U.unescapeWire(s)
    return (s:gsub("~(.)", { t = "~", z = "Z" }))
end

--- cuts text into pieces of at most `size` bytes, never inside a UTF-8 character
function U.split(text, size)
    local parts, i = {}, 1
    while i <= #text do
        local j = math.min(#text, i + size - 1)
        while j < #text and j > i do
            local b = text:byte(j + 1)
            if b < 0x80 or b >= 0xC0 then break end
            j = j - 1
        end
        parts[#parts + 1] = text:sub(i, j)
        i = j + 1
    end
    return parts
end

--- a JSON list as a Lua sequence (decoders differ on empty and string-keyed lists)
function U.list(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for i = 1, 100000 do
        local v = t[i]
        if v == nil then v = t[tostring(i)] end
        if v == nil then break end
        out[i] = v
    end
    return out
end

function U.contains(list, value)
    for _, v in ipairs(U.list(list)) do
        if v == value then return true end
    end
    return false
end

--- 83456 -> "1:23.456", like a timing screen
function U.formatLap(ms)
    ms = math.floor((tonumber(ms) or 0) + .5)
    local s = math.floor(ms / 1000)
    local frac = string.format("%03d", ms % 1000)
    local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
    s = s % 60
    if h > 0 then return string.format("%d:%02d:%02d.%s", h, m, s, frac) end
    if m > 0 then return string.format("%d:%02d.%s", m, s, frac) end
    return string.format("%d.%s", s, frac)
end

--- a player's name as BeamMP has it, "" for nobody
function U.playerName(playerID)
    local ok, name = pcall(MP.GetPlayerName, playerID)
    return ok and type(name) == "string" and name or ""
end

function U.connected(playerID)
    local ok, yes = pcall(MP.IsPlayerConnected, playerID)
    return ok and yes == true
end

-- timers : run `fn` after `seconds` (checked on the plugin's 200 ms tick)
local timers = {}

function U.after(seconds, fn)
    timers[#timers + 1] = { at = os.time() + seconds, fn = fn }
end

function U.tick()
    if #timers == 0 then return end
    local now, due, keep = os.time(), {}, {}
    for _, t in ipairs(timers) do
        if now >= t.at then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timers = keep
    for _, t in ipairs(due) do
        local ok, err = pcall(t.fn)
        if not ok then U.log("a timer failed : " .. tostring(err)) end
    end
end

BJL.util = U
return U
