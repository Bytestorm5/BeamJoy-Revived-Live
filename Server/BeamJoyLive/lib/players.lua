--[[
BeamJoy Live : the players' games (BJL.players).

Each game with the client mod says hello, and tells the plugin which site account it's linked to
(its token : the plugin posts that player's laps as them). Tokens stay in memory, for as long as
the player is connected. Games also name the cars they drive (the game knows a model's name,
"ETK 800-Series" for "etk800" ; BeamJoy's events only carry the model).
]]

local U = BJL.util
local P = {
    --- playerID -> true : their game runs BeamJoy Live
    games = {},
    --- playerID -> {token, name, slug} : the site account their game is linked to
    accounts = {},
    --- vehicle model -> its name, as the games report them
    labels = {},
    labelCount = 0,
}

local MAX_LABELS = 2000

local function decodeWire(data)
    if type(data) ~= "string" then return nil end
    return U.decode(U.unescapeWire(data))
end

function P.toClient(playerID, event, payload)
    BJL.web.toClient(playerID, event, payload)
end

function P.sendConfig(playerID)
    P.toClient(playerID, "BJLConfig", BJL.settings.public())
end

function P.broadcastConfig()
    for playerID in pairs(P.games) do P.sendConfig(playerID) end
end

--- a model's name for people ("etk800" -> "ETK 800-Series"), the model itself when no game said
function P.label(model)
    if type(model) ~= "string" or model == "" then return "" end
    return P.labels[model] or model
end

---@return {token: string, name: string?, slug: string?}?
function P.account(playerID)
    return playerID and P.accounts[playerID] or nil
end

--- the linked player with the lowest ID (whose account posts the server's live page), or nil
function P.firstLinked()
    local best
    for playerID in pairs(P.accounts) do
        if U.connected(playerID) and (not best or playerID < best) then best = playerID end
    end
    return best
end

function BJL_onHello(playerID)
    P.games[playerID] = true
    P.sendConfig(playerID)
    if BJL.live then BJL.live.elect() end
    if BJL.live and BJL.live.url then P.toClient(playerID, "BJLLiveStatus", { url = BJL.live.url }) end
end

--- { token?, user? {name, slug} } : the game's link to a site account (no token : unlinked)
function BJL_onAccount(playerID, data)
    local msg = decodeWire(data)
    if not msg then return end
    P.games[playerID] = true
    local token = msg.token
    if type(token) == "string" and token:match("^bjl_[%w%-_]+$") and #token <= 100 then
        local user = type(msg.user) == "table" and msg.user or {}
        P.accounts[playerID] = {
            token = token,
            name = type(user.name) == "string" and user.name:sub(1, 80) or nil,
            slug = type(user.slug) == "string" and user.slug:sub(1, 80) or nil,
        }
    else
        P.accounts[playerID] = nil
    end
    if BJL.live then BJL.live.elect() end
    if BJL.page then BJL.page.refresh(playerID) end
end

--- { model, label } : the car the player's in, and its name
function BJL_onVehicle(playerID, data)
    local msg = decodeWire(data)
    if not msg or type(msg.model) ~= "string" or type(msg.label) ~= "string" then return end
    local model, label = msg.model:sub(1, 64), msg.label:sub(1, 64)
    if model == "" or label == "" or P.labels[model] == label then return end
    if not P.labels[model] then
        if P.labelCount >= MAX_LABELS then return end
        P.labelCount = P.labelCount + 1
    end
    P.labels[model] = label
end

function BJL_onPlayerJoin(playerID)
    P.sendConfig(playerID)
end

function BJL_onPlayerDisconnect(playerID)
    P.games[playerID] = nil
    P.accounts[playerID] = nil
    BJL.web.onPlayerDisconnect(playerID)
    if BJL.page then BJL.page.forget(playerID) end
    if BJL.laps then BJL.laps.forgetPlayer(playerID) end
    if BJL.live then BJL.live.elect() end
end

function P.register()
    MP.RegisterEvent("BJLHello", "BJL_onHello")
    MP.RegisterEvent("BJLAccount", "BJL_onAccount")
    MP.RegisterEvent("BJLVehicle", "BJL_onVehicle")
    MP.RegisterEvent("onPlayerJoin", "BJL_onPlayerJoin")
    MP.RegisterEvent("onPlayerDisconnect", "BJL_onPlayerDisconnect")
end

BJL.players = P
return P
