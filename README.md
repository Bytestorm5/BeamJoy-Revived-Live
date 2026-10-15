# BeamJoy Live

An add-on for [BeamJoy-Revived](https://github.com/foodcache3/BeamJoy-Revived) (the BeamMP server
mod) that connects a server to [BeamJoy Web](https://github.com/Bytestorm5/BeamJoy-Web), the race
route catalog. It doesn't change BeamJoy: it listens to the race messages BeamJoy already sends
and reads BeamJoy's race list.

- **Upload from the game.** Pick a race on the current map, fill in the same details the site's
  form asks for (name, description, surface, tags, video, corners, mod map name and link), take
  screenshots, and publish. The share code is built in game, props included.
- **Global leaderboards.** Every lap you finish on a race that's listed on the site goes to that
  route's leaderboard: best lap, and best theoretical lap (your best time in each sector, from any
  lap). The site's leaderboard page updates live. Grid races and freeroam runs both count.
- **Map backgrounds.** The first linked player to load a level uploads its road network (the
  game's own navigation graph), and the site draws it under every route on that map. Uploads can
  also carry an **aerial**: the camera flies straight above the race and takes a top-down shot,
  which the site lays the route over.
- **Live sessions** (off unless the host turns it on). One linked player's game sends where
  everyone is, in what and how fast, every 5 seconds; the site shows it on its Live page.

## Accounts

There's no extra login in game. A player links their site account once:

1. **Shift+F4** opens the BeamJoy Live window. **Link account** shows a code like `Q3HG-52ND` and
   opens the site's `/link` page with it filled in.
2. They sign in on the site (Discord) and approve.
3. The game picks up a token a few seconds later and keeps it in the BeamNG user folder
   (`settings/beamjoyLive/account.json`), so it works on every server running BeamJoy Live.

Linked games are listed, and can be unlinked, on the site's **Game** page (`/account`), or with
**Unlink** in game. Their BeamMP login is untouched.

## Install (hosts)

Needs BeamJoy-Revived, and `curl` on the server machine (built into Windows 10 and later and
nearly every Linux): the plugin makes the site requests. From a [release](https://github.com/Bytestorm5/BeamJoy-Revived-Live/releases)
(or `python3 tools/build.py`, which writes `dist/`):

| File | Goes to |
| --- | --- |
| `BeamJoyLive.zip` | `Resources/Client/` (next to BeamJoy's zip) |
| `BeamJoyLive-server.zip`, unzipped | `Resources/Server/BeamJoyLive/main.lua` |

Start the server once; it writes `Resources/Server/BeamJoyLive/config.json`:

| Setting | Default | |
| --- | --- | --- |
| `SiteUrl` | `""` | The BeamJoy Web site, e.g. `https://routes.example.com`. **Required**: the mod stays idle until it's set. |
| `Leaderboards` | `true` | Players' laps on listed routes go to the site. |
| `Uploads` | `true` | Players can upload races from the game. |
| `LiveSessions` | `false` | Share every player's position, car and speed on the site's Live page. |
| `ServerName` | `""` | Name on the Live page (empty: the server's own name). |
| `ServerKey` | generated | Identifies this server on the site. Keep it private. |

Changes take effect on the next server restart.

## How it fits together

```
Server/BeamJoyLive/main.lua        BeamMP plugin: settings, picks the live reporter, web relay
Client/                            -> BeamJoyLive.zip
  scripts/beamjoy_live/            loads the extension
  lua/ge/extensions/beamjoyLive/
    main.lua                       bridge to the window and the server plugin, BeamJoy's races,
                                   the relay's client side
    laps.lua                       your laps from BeamJoy's race updates
    capture.lua                    screenshots, the aerial camera, the road network
    live.lua                       the live player list (reporter only)
  ui/modModules/bjlive/            the window (AngularJS, like BeamJoy's UI); builds the requests
```

Neither side of the game can reach the site itself: the game's UI has a Content Security Policy
that only allows localhost, and its Lua has no HTTPS. So the window builds each request, the
game's Lua adds the player's token and sends it to the server plugin in BeamMP events, and the
plugin runs `curl` in the background (temp files under `Resources/Server/BeamJoyLive/tmp/`) and
sends the answer back the same way. Only the site's `/api/` paths are relayed. This means a
player's token passes through the server they're playing on; it can only post laps, uploads and
live data as them, and they can unlink it on the site at any time.

The site's game API is under `/api/game/*` (see BeamJoy Web's `src/app/api/game`).

## Developing

- `python3 tools/lua_tests.py` runs the Lua against fakes of the game's and BeamMP's APIs
  (needs `pip install lupa`): lap detection, base64, road extraction, the live snapshot, the
  server plugin's reporter election, plus a syntax check of every file. With
  `BJL_SITE=http://localhost:3000` it also runs the web relay end to end: the client's Lua, the
  plugin and real `curl` against a running site.
- `tools/ui-harness` runs the window in a normal browser with the game's Lua faked:
  `cd tools/ui-harness && npm install && npm start`, then open
  `http://localhost:4100/?site=http://localhost:3000` against a local BeamJoy Web (`npm run dev`
  with `AUTH_DEV_LOGIN=true`). Buttons at the bottom fake Shift+F4, a finished lap and a live report.
  Add `&relay=1` to send requests the in-game way (through the "Lua" bridge) instead of fetching.

### Not yet tried in the game

Everything above was tested against the real site and with faked game APIs, not inside BeamNG.
These game calls are the ones to check first in a live session:

- `screenshot.doScreenshot()` (falls back to `createScreenshot`), and finding the new file in
  `/screenshots/` with `FS:findFiles`.
- The aerial's framing assumes the free camera's FOV is vertical. If aerials come out stretched
  sideways, it's horizontal: swap the axes in `lib.js` `aerialBounds`.
- `openWebBrowser(url)` to open the link page (falls back to copying the URL; the code can always
  be typed at `<site>/link`).
- The relay on a **Windows** server: the plugin starts each request with
  `start "" /b cmd /c ""<request>.cmd""` (Linux is tested, with curl, by `tools/lua_tests.py`).
