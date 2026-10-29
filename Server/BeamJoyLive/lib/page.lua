--[[
BeamJoy Live : the "BeamJoy Live" page in BeamJoy's main window (BJL.page), a button on its side
rail and a tab in the full window. Each player sees their own : their site account (link it from
here : the plugin asks the site for a code, the player approves it in their browser, and their game
keeps the token), the laps they drove this session and what became of them, the site's leaderboard
of the race they drove last, and buttons to the window's Upload tab and the site.
]]

local U = BJL.util
local G = {
    ID = "live",
    --- playerID -> {opened, link, laps, board, boardAt}
    state = {},
    MAX_LAPS = 6,
    BOARD_SIZE = 10,
    --- seconds between two leaderboard fetches for one player
    BOARD_EVERY = 10,
}

local function S() return BJL.settings end
local function P() return BJL.players end

local function stateOf(playerID)
    local s = G.state[playerID]
    if not s then
        s = { laps = {} }
        G.state[playerID] = s
    end
    return s
end

local function host()
    return (S().values.siteUrl:gsub("^https?://", ""))
end

local STATUS = {
    unlisted = "Not on the site",
    withdrawn = "Withdrawn",
    failed = "Not posted",
    duplicate = "Already posted",
}

local function lapCell(e)
    if e.status == "posted" then
        local tag = e.isRecord and " · record" or e.isPB and " · PB" or ""
        return { text = string.format("P%s/%s%s", tostring(e.rank), tostring(e.drivers), tag),
            color = e.isRecord and "purple" or e.isPB and "good" or nil, align = "right" }
    end
    return { text = STATUS[e.status] or "", color = e.status == "failed" and "bad" or "muted", align = "right" }
end

---@return table[] the page's blocks for one player
function G.blocksFor(playerID)
    local values = S().values
    if not S().enabled() then
        return {
            { type = "heading", text = "BeamJoy Live", sub = "Not set up on this server yet." },
            { type = "text", text = "Staff : Config > BeamJoy Live, the site address.", color = "muted" },
        }
    end
    local s = stateOf(playerID)
    local account = P().account(playerID)
    local blocks = {}
    local function add(b) blocks[#blocks + 1] = b end

    if account then
        add({ type = "heading", text = "BeamJoy Live", sub = "Linked to " .. host() .. " as " .. (account.name or "your account") })
        local items = {}
        if values.uploads then items[#items + 1] = { id = "upload", label = "Upload a race", style = "primary" } end
        items[#items + 1] = { id = "site", label = "Open the site" }
        items[#items + 1] = { id = "unlink", label = "Unlink", style = "danger",
            confirm = "Unlink this game from " .. (account.name or "your account") .. " ? Your laps stop going to the site." }
        add({ type = "buttons", items = items })
    elseif s.link and s.link.status == "waiting" then
        add({ type = "heading", text = "Link your account", sub = "Sign in at " .. host() .. "/link and enter this code" })
        add({ type = "text", text = s.link.userCode, size = "xl", display = true, bold = true })
        add({ type = "buttons", items = {
            { id = "linkpage", label = "Open the link page", style = "primary" },
            { id = "cancel", label = "Cancel" },
        } })
    else
        add({ type = "heading", text = "BeamJoy Live", sub = "Your laps on " .. host() .. "'s leaderboards" })
        if s.link and s.link.status == "expired" then add({ type = "text", text = "The code expired.", color = "warn" }) end
        if s.link and s.link.status == "error" then add({ type = "text", text = s.link.error, color = "bad" }) end
        add({ type = "buttons", items = { { id = "link", label = "Link account", style = "primary" } } })
    end

    if values.leaderboards and (account or #s.laps > 0) then
        add({ type = "divider" })
        add({ type = "heading", text = "Your laps", sub = "This session" })
        if #s.laps == 0 then
            add({ type = "text", text = "None yet. Finish a lap of a race that's on the site.", color = "muted" })
        else
            local rows = {}
            for _, e in ipairs(s.laps) do
                rows[#rows + 1] = { cells = { e.name or "?", { text = e.lapMs and U.formatLap(e.lapMs) or "–", align = "right" }, lapCell(e) } }
            end
            add({ type = "table", columns = { { label = "Race" }, { label = "Lap", align = "right" }, { label = "Site", align = "right" } },
                rows = rows })
        end
    end

    local board = s.board
    if board and type(board.entries) == "table" then
        add({ type = "divider" })
        local both = type(board.boards) == "table" and (tonumber(board.boards.standing) or 0) > 0 and
            (tonumber(board.boards.flying) or 0) > 0
        add({ type = "heading", text = board.route.title,
            sub = "Site leaderboard" .. (both and (board.start == "flying" and " · flying start" or " · standing start") or "") })
        local rows = {}
        for _, e in ipairs(U.list(board.entries)) do
            rows[#rows + 1] = { cells = { tostring(e.rank), tostring(e.name or ""), { text = U.formatLap(e.bestLapMs), align = "right" } },
                you = account ~= nil and account.slug ~= nil and e.userSlug == account.slug or nil }
        end
        if #rows == 0 then
            add({ type = "text", text = "No times.", color = "muted" })
        else
            add({ type = "table", columns = { { label = "#" }, { label = "Driver" }, { label = "Best lap", align = "right" } }, rows = rows })
        end
        add({ type = "buttons", items = { { id = "board", label = "Open the leaderboard" } } })
    end

    if values.liveSessions then
        add({ type = "divider" })
        add({ type = "text", text = "Everyone's position on this server shows on the site's Live page.", color = "muted" })
        add({ type = "buttons", items = { { id = "live", label = "Open Live" } } })
    end
    return blocks
end

--- the player's own page, if they've opened it (it follows them while it's open)
function G.refresh(playerID)
    local s = G.state[playerID]
    if not s or not s.opened or not U.connected(playerID) then return end
    BJL.BJ.updatePage(G.ID, G.blocksFor(playerID), { playerID })
end

function G.refreshAll()
    for playerID in pairs(G.state) do G.refresh(playerID) end
end

function G.forget(playerID)
    G.state[playerID] = nil
end

local function openUrl(playerID, url)
    if type(url) == "string" and url:match("^https?://") then P().toClient(playerID, "BJLOpenUrl", { url = url }) end
end

--- the site's leaderboard for the route of a lap the player drove
local function loadBoard(playerID, route, start)
    local s = stateOf(playerID)
    if s.boardBusy or (s.board and s.board.route.slug == route.slug and s.board.start == start and
            os.time() - (s.boardAt or 0) < G.BOARD_EVERY) then
        return
    end
    s.boardBusy = true
    local path = string.format("/api/routes/%s/leaderboard?size=%d%s", route.slug, G.BOARD_SIZE,
        start and ("&start=" .. start) or "")
    BJL.web.json("GET", path, nil, nil, function(status, data)
        s.boardBusy = false
        if status ~= 200 or type(data) ~= "table" then return end
        s.board = { route = route, start = data.start or start, entries = U.list(data.entries), boards = data.boards }
        s.boardAt = os.time()
        G.refresh(playerID)
    end)
end

--- a lap of the player's : posted, or not (laps.lua's report)
function G.onLap(playerID, entry)
    local s = stateOf(playerID)
    table.insert(s.laps, 1, entry)
    while #s.laps > G.MAX_LAPS do table.remove(s.laps) end
    if entry.route and (entry.status == "posted" or entry.status == "duplicate" or entry.status == "withdrawn") then
        if entry.status == "withdrawn" then s.boardAt = 0 end
        loadBoard(playerID, entry.route, entry.start or (s.board and s.board.start))
    end
    G.refresh(playerID)
end

---------------------------------------------------------------------------------------------------
-- linking from the page (the site's device-code flow, run by the plugin for the player)

local function pollLink(playerID, deviceCode)
    local s = G.state[playerID]
    if not s or not s.link or s.link.deviceCode ~= deviceCode or not U.connected(playerID) then return end
    BJL.web.json("POST", "/api/game/link/poll", { deviceCode = deviceCode }, nil, function(status, data)
        s = G.state[playerID]
        if not s or not s.link or s.link.deviceCode ~= deviceCode then return end
        if type(data) == "table" and data.status == "linked" and type(data.token) == "string" then
            s.link = nil
            -- the game keeps the token (in the player's BeamNG folder) and tells the plugin
            P().toClient(playerID, "BJLAccountSet", { token = data.token, user = data.user })
            BJL.BJ.call("hud.message", { playerId = playerID, color = "good",
                text = "BeamJoy Live : linked to " .. tostring(type(data.user) == "table" and data.user.name or host()) .. "." })
            return G.refresh(playerID)
        end
        if (type(data) == "table" and data.status == "expired") or os.time() > (s.link.expiresAt or 0) then
            s.link = { status = "expired" }
            return G.refresh(playerID)
        end
        U.after(s.link.interval or 3, function() pollLink(playerID, deviceCode) end)
    end)
end

local function startLink(playerID)
    local s = stateOf(playerID)
    s.link = { status = "starting" }
    BJL.web.json("POST", "/api/game/link", { playerName = U.playerName(playerID) }, nil, function(status, data)
        if status ~= 200 or type(data) ~= "table" or type(data.deviceCode) ~= "string" then
            s.link = { status = "error", error = BJL.web.errorOf(status, data) }
            return G.refresh(playerID)
        end
        s.link = {
            status = "waiting",
            userCode = tostring(data.userCode),
            verifyUrl = data.verifyUrl,
            deviceCode = data.deviceCode,
            interval = math.max(2, math.min(10, tonumber(data.interval) or 3)),
            expiresAt = os.time() + (tonumber(data.expiresIn) or 600),
        }
        openUrl(playerID, s.link.verifyUrl)
        G.refresh(playerID)
        U.after(s.link.interval, function() pollLink(playerID, data.deviceCode) end)
    end)
end

local function unlink(playerID)
    local account = P().account(playerID)
    if account then
        -- the site forgets the token ; the game forgets it either way
        BJL.web.json("DELETE", "/api/game/me", nil, account.token, function() end)
    end
    P().accounts[playerID] = nil
    P().toClient(playerID, "BJLAccountSet", { clear = true })
    G.refresh(playerID)
end

local ACTIONS = {
    link = startLink,
    cancel = function(playerID)
        stateOf(playerID).link = nil
        G.refresh(playerID)
    end,
    linkpage = function(playerID)
        local link = stateOf(playerID).link
        openUrl(playerID, link and link.verifyUrl)
    end,
    unlink = unlink,
    upload = function(playerID) P().toClient(playerID, "BJLOpen", { tab = "upload" }) end,
    site = function(playerID) openUrl(playerID, S().values.siteUrl) end,
    board = function(playerID)
        local board = stateOf(playerID).board
        if board and board.route.url then
            openUrl(playerID, board.route.url .. "/leaderboard" .. (board.start and ("?start=" .. board.start) or ""))
        end
    end,
    live = function(playerID) openUrl(playerID, BJL.live and BJL.live.url or (S().values.siteUrl .. "/live")) end,
}

function G.register()
    local BJ = BJL.BJ
    BJ.page({
        id = G.ID,
        title = "BeamJoy Live",
        label = "Site",
        icon = "globe",
        where = "both",
        order = 10,
        blocks = { { type = "heading", text = "BeamJoy Live", sub = "Your laps on the site's leaderboards" } },
    })
    BJ.onPageOpened(function(pageId, by)
        if pageId ~= G.ID or type(by) ~= "table" or not tonumber(by.id) then return end
        local playerID = tonumber(by.id)
        stateOf(playerID).opened = true
        G.refresh(playerID)
    end)
    BJ.onPageAction(function(pageId, action, _, by)
        if pageId ~= G.ID or type(by) ~= "table" or not tonumber(by.id) then return end
        local fn = ACTIONS[action]
        if fn then fn(tonumber(by.id)) end
    end)
end

BJL.page = G
return G
