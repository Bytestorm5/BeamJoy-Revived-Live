--[[
BeamJoy Live : server plugin (Resources/Server/BeamJoyLive/main.lua)

Connects a BeamJoy-Revived server to BeamJoy Web (BeamJoy Routes), through BeamJoy's plugin API
(Resources/Server/BeamJoyServer/api ; needs BeamJoy-Revived 2.0 or later) :

  lib/settings.lua  the host's settings, a tab in BeamJoy's config window (Config > BeamJoy Live)
  lib/laps.lua      laps to the site's leaderboards, from BeamJoy's race events
  lib/courses.lua   which site route a BeamJoy race is (its gates, from BeamJoy's race files)
  lib/page.lua      the "BeamJoy Live" page in BeamJoy's main window : account, laps, leaderboard
  lib/live.lua      the site's Live page, with BeamJoy's race sessions and player names
  lib/players.lua   the players' games (the client mod) : their site accounts, car names
  lib/web.lua       the site, through curl ; the games' requests relayed (the window's uploads)

Every player downloads the client mod (Resources/Client/BeamJoyLive.zip) : it does what only the
game can (screenshots, the aerial camera, the level's road map, where every car is, freeroam runs)
and keeps the player's link to their site account.

BeamMP runs the .lua files at the top of a plugin's folder only : lib/ is loaded from here.
]]

local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local CODE_DIR = here:match("(.*/)") or "./"
--- tests point these elsewhere
local paths = rawget(_G, "BJL_PATHS") or {}

BJL = {
    NAME = "BeamJoyLive",
    VERSION = "2.0.0",
    --- this plugin's folder : config.json from 1.x, tmp/
    dir = paths.data or CODE_DIR,
    --- Resources/Server/ : BeamJoy's API helper and its data
    serverDir = paths.server or (here:match("^(.*/)[^/]+/[^/]+$") or (CODE_DIR .. "../")),
}

for _, name in ipairs({ "util", "web", "settings", "players", "courses", "laps", "page", "live" }) do
    dofile(CODE_DIR .. "lib/" .. name .. ".lua")
end

function BJL_poll()
    BJL.web.poll()
end

function onInit() ---@diagnostic disable-line
    local helper = BJL.serverDir .. "BeamJoyServer/api/BeamJoyAPI.lua"
    local ok, BJ = pcall(dofile, helper)
    if not ok or type(BJ) ~= "table" or not BJ.init then
        BJL.util.log("BeamJoy-Revived's plugin API wasn't found (" .. helper .. ") : BeamJoy Live needs " ..
            "BeamJoy-Revived 2.0 or later, and stays off")
        return
    end
    BJL.BJ = BJ
    BJ.init(BJL.NAME)
    MP.RegisterEvent("BJLHttp", "BJL_onHttp")
    MP.RegisterEvent("BJLHttpPart", "BJL_onHttpPart")
    MP.RegisterEvent("BJLPoll", "BJL_poll")
    MP.CreateEventTimer("BJLPoll", 200)
    BJL.players.register()
    BJL.settings.register()
    BJL.courses.register()
    BJL.laps.register()
    BJL.page.register()
    BJL.live.register()
    BJL.util.log("loaded (v" .. BJL.VERSION .. "), waiting for BeamJoy")
end
