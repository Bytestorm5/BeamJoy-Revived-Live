# BeamJoy Live

A plugin for [BeamJoy-Revived](https://github.com/foodcache3/BeamJoy-Revived) (the BeamMP server
mod) that connects a server to [BeamJoy Web](https://github.com/Bytestorm5/BeamJoy-Web), the race
route catalog. It's built on BeamJoy's [plugin API](https://github.com/foodcache3/BeamJoy-Revived/blob/main/BeamJoyServer/api/README.md):
it doesn't change BeamJoy, it hears BeamJoy's race events and adds to BeamJoy's own windows.

- **Global leaderboards.** Every lap a linked player finishes on a race that's listed on the site
  goes to that route's leaderboard: best lap, and best theoretical lap (their best time in each
  sector, from any lap). The site's leaderboard page updates live. Grid races (from BeamJoy's race
  events) and freeroam runs both count, the laps BeamJoy itself counts: none from a phase kept off
  the leaderboard, a lap the pit lane touched, or a run BeamJoy didn't count (anti-cheat options
  off, not the race's own vehicle rule). Standing starts (timed from the grid) and flying ones (a
  circuit's later laps, an out lap, a flying start, a freeroam run) go on separate boards. A racer
  disqualified after their laps went out has that run's laps withdrawn, and posted again if
  they're reinstated. Racers see the site's answer on BeamJoy's HUD, their site rank beside their
  name on the race HUD, and "Site PB" on their result.
- **A page in BeamJoy's main window** (BeamJoy Live, on its side rail): link your account, your
  laps this session, the site's leaderboard of the race you drove last, and buttons to upload a
  race and open the site.
- **Upload from the game.** Pick a race on the current map, fill in the same details the site's
  form asks for (name, description, surface, tags, video, corners, mod map name and link), take
  screenshots, and publish. The share code is built in game, props and pit lane included.
- **Map backgrounds.** The first linked player to load a level uploads its road network (the
  game's own navigation graph), and the site draws it under every route on that map. Uploads can
  also carry an **aerial**: the camera flies over the race looking straight down, with the level's
  view distance raised and clouds and fog off, and the site lays the route over the picture. The
  camera stays low enough for roads to be drawn (about 900 m at most), so a big race is shot in
  overlapping pieces that the window stitches together; `beamng.log` says how many.
- **Live sessions** (off unless the host turns it on). One player's game sends where everyone
  is, in what and how fast, every 5 seconds; the plugin adds what each racer is doing and posts it
  to the site's Live page.
- **A race option** in BeamJoy's race editor and start menu, "Post laps to the site" (on by
  default), keeps a race's laps off the site.

## Accounts

There's no extra login in game. A player links their site account once:

1. In BeamJoy's main window, **BeamJoy Live** > **Link account** (or **Shift+F4**, the mod's own
   window). It shows a code like `Q3HG-52ND` and opens the site's `/link` page with it filled in.
2. They sign in on the site (Discord) and approve.
3. The game picks up a token a few seconds later and keeps it in the BeamNG user folder
   (`settings/beamjoyLive/account.json`), so it works on every server running BeamJoy Live.

Linked games are listed, and can be unlinked, on the site's **Game** page (`/account`), or with
**Unlink** in game. Their BeamMP login is untouched.

## Install (hosts)

Needs BeamJoy-Revived 2.0 or later (its plugin API; built for its `development` branch's race
phases and pits too, on BeamNG 0.40), and `curl` on the server machine (built into Windows 10 and
later and nearly every Linux): the plugin makes the site requests. From a
[release](https://github.com/Bytestorm5/BeamJoy-Revived-Live/releases) (or `python3 tools/build.py`,
which writes `dist/`):

| File | Goes to |
| --- | --- |
| `BeamJoyLive.zip` | `Resources/Client/` (next to BeamJoy's zip) |
| `BeamJoyLive-server.zip`, unzipped | `Resources/Server/BeamJoyLive/` (`main.lua` and `lib/`) |

Then, in game, BeamJoy's config window has a **BeamJoy Live** tab (staff with BeamJoy's
`EditPluginConfig` permission, admins by default). Changes apply at once.

| Setting | Default | |
| --- | --- | --- |
| Site address | empty | The BeamJoy Web site, e.g. `https://routes.example.com`. **Required**: the plugin stays idle until it's set. **Check the connection** tries it. |
| Lap times | on | Linked players' laps on listed routes go to the site. |
| Race uploads | on | Players can upload races from the game. |
| Live page | off | Share every player's position, car and speed on the site's Live page. |
| Name on the Live page | empty | Empty: the server's own name. |
| Server key | made for you | Identifies this server on the site. A secret: it never leaves the server. |

A `config.json` from BeamJoy Live 1.x is moved into the tab on the first start (it's renamed
`config.json.old`).

## How it fits together

```
Server/BeamJoyLive/                BeamMP plugin, through BeamJoy's plugin API
  main.lua                         loads BeamJoy's API helper (BeamJoyServer/api/BeamJoyAPI.lua) and lib/
  lib/settings.lua                 the config tab
  lib/laps.lua                     laps from BeamJoy's race events (RacerLap, RacerGate, RacerOut,
                                   RaceControl, RacePhaseFinished, RaceFinished), the race option,
                                   HUD messages and labels
  lib/courses.lua                  which site route a race is: its gates, from BeamJoy's race file
  lib/page.lua                     the BeamJoy Live page in BeamJoy's main window, linking
  lib/live.lua                     the Live page: the reporter's positions + races.sessions, players.online
  lib/players.lua                  the games: their site accounts (tokens, in memory), car names
  lib/web.lua                      the site through curl; the games' requests relayed
Client/                            -> BeamJoyLive.zip, what only the game can do
  scripts/beamjoy_live/            loads the extension
  lua/ge/extensions/beamjoyLive/
    main.lua                       the account link, the window, the server plugin's messages, the relay
    laps.lua                       freeroam runs (BeamJoy's API has no event for them)
    capture.lua                    screenshots, the aerial camera, the road network
    live.lua                       where every car is (on the reporting game)
  ui/modModules/bjlive/            the window (AngularJS, like BeamJoy's UI): uploads, your laps
```

What BeamJoy's plugin API doesn't give comes from elsewhere: a race's gates from BeamJoy's race
file (`BeamJoyData/db/activities/<map>_races.json`, which the API's README lets plugins read),
whether a run counted from its phase's results (a result without a `leaderboardRank`), how a lap
started from the gate events (an out lap's are flagged; a flying start's first checkpoint has a
time of 0), car names, freeroam runs and where every car is from the players' games.

The plugin posts laps and the Live page itself, with the player's token: each game tells the
plugin which account it's linked to, and the plugin keeps the token in memory while they're
connected. The window's requests (uploads, its leaderboards) can't go to the site from the game
(the game's UI only allows localhost, its Lua has no HTTPS), so the game's Lua sends them to the
plugin in BeamMP events and the plugin runs `curl` (temp files under
`Resources/Server/BeamJoyLive/tmp/`). Both sides pace big messages (about 400 KB/s from the game,
80 KB/s per player from the plugin), as BeamJoy does: a burst that fills a player's connection
can crash their BeamMP launcher. Only the site's `/api/` paths are relayed. A player's token
reaches the server they're playing on; it can only post laps, uploads and live data as them, and
they can unlink it on the site at any time.

The site's game API is under `/api/game/*` (see BeamJoy Web's `src/app/api/game`).

## Developing

- `python3 tools/lua_tests.py` runs the Lua against fakes of the game's and BeamMP's APIs (needs
  `pip install lupa`), and the server plugin against BeamJoy's real API helper, BeamJoy's side of
  the API and the site played by the test: set `BJ_REPO` to a BeamJoy-Revived checkout (CI checks
  out its `main` and `development`). It covers the config tab and moving config.json, laps from
  race events and BeamJoy's rules (phases, pit laps, starts, disqualification, BeamJoy's own
  verdict), the page and linking, the Live page, the relay's pacing, props fetched on demand,
  unloading on leave, base64, road extraction, the aerial plan, plus a syntax check of every file.
  With `BJL_SITE=http://localhost:3000` it also runs the relay end to end with real `curl`; add
  `BJL_TOKEN=bjl_…` (a game token on that site) for a paced upload and answer, and laps from race
  events posted and withdrawn on the real site (the UI harness's Harness Oval must be listed).
- `tools/ui-harness` runs the window in a normal browser with the game's Lua faked:
  `cd tools/ui-harness && npm install && npm start`, then open
  `http://localhost:4100/?site=http://localhost:3000` against a local BeamJoy Web (`npm run dev`
  with `AUTH_DEV_LOGIN=true`). Buttons at the bottom fake Shift+F4, a finished lap and a
  disqualification (the page plays the plugin's part), and the BeamJoy page's Upload button.
  Add `&relay=1` to send requests the in-game way (through the "Lua" bridge) instead of fetching.

### Not yet tried in the game

Everything above was tested against the real site, BeamJoy's real API helper and faked game,
BeamMP and BeamJoy sides, not inside BeamNG on a live BeamJoy server. These are the ones to check
first:

- BeamJoy's race events, its page, config tab, race option and HUD labels with a real BeamJoy
  server (`development` and 2.0.1).
- `screenshot.doScreenshot()` (falls back to `createScreenshot`), and finding the new file in
  `/screenshots/` with `FS:findFiles`.
- The aerial's framing assumes the free camera's FOV is vertical. If aerials come out stretched
  sideways, it's horizontal: swap the axes in `lib.js` `aerialBounds`.
- Raising the view distance for aerials (`theLevelInfo.visibleDistance` + `postApply`) and hiding
  `CloudLayer` / `BasicClouds`. If the raise doesn't take, the aerial still works, in more shots.
- `openWebBrowser(url)` to open the link page (falls back to copying the URL; the code can always
  be typed at `<site>/link`).
- Fetching a race's props for an upload (`beamjoy_races.getProps`, BeamJoy 2.0's race cache
  leaves them out) and unloading the mod's extensions when leaving a server (BeamNG 0.40 reloads
  Lua then).
- The relay on a **Windows** server: the plugin starts each request with
  `start "" /b cmd /c ""<request>.cmd""` (Linux is tested, with curl, by `tools/lua_tests.py`).
