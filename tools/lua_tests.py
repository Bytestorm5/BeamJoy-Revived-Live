"""
Tests for the mod's Lua, run outside the game with fakes for the game's and BeamMP's APIs.
Needs Python 3 and lupa (pip install lupa), which bundles LuaJIT (the game's VM) and Lua 5.4
(close to the BeamMP server's).

The server plugin talks to BeamJoy through BeamJoy's own API helper (BeamJoyAPI.lua, shipped with
BeamJoy-Revived, GPL : not copied here). These tests load the real one from a BeamJoy-Revived
checkout and play BeamJoy's side of the protocol, and the site's :

    BJ_REPO=../BeamJoy-Revived python3 tools/lua_tests.py
    BJ_REPO=... BJL_SITE=http://localhost:3000 python3 tools/lua_tests.py             # + the web relay, with curl
    BJ_REPO=... BJL_SITE=... BJL_TOKEN=bjl_... python3 tools/lua_tests.py             # + plugin laps on a real site
"""
import base64
import json
import math
import os
import random
import shutil
import sys
import time

from lupa import luajit21, lua54

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "Client/lua/ge/extensions/beamjoyLive")
PLUGIN = os.path.join(ROOT, "Server/BeamJoyLive")
failures = 0


def check(name, cond, detail=""):
    global failures
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        failures += 1


def load_ext(rt, name):
    src = open(os.path.join(EXT, name + ".lua"), encoding="utf-8").read()
    return rt.execute(src)


def lua_to_py(v):
    if hasattr(v, "items"):
        d = dict(v.items())
        if d and all(isinstance(k, int) for k in d):
            return [lua_to_py(d[k]) for k in sorted(d)]
        return {str(k): lua_to_py(x) for k, x in d.items()}
    return v


def py_to_lua(rt, v):
    if isinstance(v, dict):
        return rt.table_from({k: py_to_lua(rt, x) for k, x in v.items()})
    if isinstance(v, list):
        return rt.table_from([py_to_lua(rt, x) for x in v])
    return v


def unescape(s):
    return s.replace("~z", "Z").replace("~t", "~")


def escape(s):
    return s.replace("~", "~t").replace("Z", "~z")


def find_bj_repo():
    for path in [os.environ.get("BJ_REPO"), os.path.join(ROOT, "..", "BeamJoy-Revived"), os.path.join(ROOT, "..", "beamjoy-revived")]:
        if path and os.path.exists(os.path.join(path, "BeamJoyServer/api/BeamJoyAPI.lua")):
            return path
    return None


def syntax():
    for base, dirs, files in os.walk(ROOT):
        # this repo's own Lua : not node_modules, temp folders, or a BeamJoy checkout (.beamjoy in CI)
        dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
        for f in files:
            if not f.endswith(".lua"):
                continue
            path = os.path.join(base, f)
            rt = lua54.LuaRuntime() if "/Server/" in path else luajit21.LuaRuntime()
            err = rt.eval("function(s, n) local f, e = load(s, n) return e end")(open(path, encoding="utf-8").read(), "@" + f)
            check("syntax " + os.path.relpath(path, ROOT), err is None, err)


# --- the game's side -----------------------------------------------------------------------------

def client_laps():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        sent = {}
        beamjoyLive_main = {
            config = { siteUrl = "https://site", leaderboards = true },
            account = { token = "bjl_x" },
            toServer = function(event, payload) table.insert(sent, { event = event, payload = payload }) end,
        }
        be = { getPlayerVehicle = function() return { getJBeamFilename = function() return "etk800" end } end }
    """)
    m = load_ext(rt, "laps")
    m.onFreeroamResult(7, rt.eval("{ timeMs = 65432 }"))
    last = rt.eval("sent[1]")
    check("laps: a freeroam run goes to the plugin", last is not None and last.event == "BJLFreeroamLap" and
          last.payload.raceId == 7 and last.payload.timeMs == 65432 and last.payload.model == "etk800")
    rt.execute("beamjoyLive_main.account = nil")
    m.onFreeroamResult(7, rt.eval("{ timeMs = 65432 }"))
    check("laps: not linked, nothing sent", rt.eval("#sent") == 1)


def main_ext():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.globals().json_encode = lambda t: json.dumps(lua_to_py(t))
    rt.globals().json_decode = lambda s: py_to_lua(rt, json.loads(s))
    rt.execute("""
        ui, toServer, unloaded, written = {}, {}, {}, {}
        guihooks = { trigger = function(_, data) table.insert(ui, data) end }
        jsonEncode, jsonDecode = json_encode, json_decode
        jsonWriteFile = function(path, data) written[path] = data end
        FS = { removeFile = function(_, path) written[path] = false end }
        handlers = {}
        AddEventHandler = function(e, fn) handlers[e] = fn end
        TriggerServerEvent = function(e, data) table.insert(toServer, { event = e, size = #data, data = data }) end
        getCurrentLevelIdentifier = function() return "italy" end
        extensions = { unload = function(name) table.insert(unloaded, name) end }
        local race = { id = 5, name = "R", gates = { { pos = { x = 1, y = 2, z = 3 } } }, propTotal = 12, propsRev = "r1" }
        propsCallback = nil
        beamjoy_races = {
            data = { race, { id = 6, name = "Old", gates = {}, props = { {}, {}, {} } } },
            getProps = function(id, onLoaded)
                if id == 5 then propsCallback = onLoaded return nil end
                return {}
            end,
        }
        beamjoy_vehicles = { getModelLabel = function(m) return m == "etk800" and "ETK 800-Series" or "?" end }
        beamjoyLive_laps = { attach = function() end }
        be = { getPlayerVehicle = function() return { getJBeamFilename = function() return "etk800" end } end,
               getObjectByID = function() return { getJBeamFilename = function() return "etk800" end } end }
    """)
    m = load_ext(rt, "main")
    m.dispatch("requestRaces")
    races = rt.eval("function() for _, d in ipairs(ui) do if d.event == 'BJLRaces' then return d.payload end end end")()
    counts = {r.name: r.props for r in races.values()}
    check("main: prop counts from the cache's propTotal, or the props", counts == {"R": 12, "Old": 3}, counts)
    rt.execute("ui = {}")
    m.dispatch("requestRace", rt.table(5))
    check("main: a race waits for its props", rt.eval("#ui") == 0)
    rt.execute("propsCallback({ { model = 'cone' }, { model = 'cone' } })")
    race = rt.eval("ui[1] and ui[1].payload.race")
    check("main: the race goes to the window with its props", race is not None and len(race.props) == 2, race)
    check("main: the cache's race isn't changed", rt.eval("beamjoy_races.data[1].props") is None)

    # the plugin's messages
    m.onBJClientReady()
    from_server = lambda event, payload: rt.eval(f"handlers[{json.dumps(event)}]")(escape(json.dumps(payload)))
    sent = lambda: [(e.event, json.loads(unescape(e.data)) if e.event != "BJLHello" else None) for e in rt.eval("toServer").values()]
    rt.execute("toServer = {}")
    from_server("BJLConfig", {"siteUrl": "https://site.example/", "leaderboards": True, "liveSessions": True})
    got = dict(sent())
    check("main: the config is taken, slash trimmed", m.config.siteUrl == "https://site.example")
    check("main: the plugin hears which account (none) and the car's name",
          got.get("BJLAccount") == [] or got.get("BJLAccount") == {}, got)
    check("main: car name sent", got.get("BJLVehicle") == {"model": "etk800", "label": "ETK 800-Series"}, got)
    rt.execute("toServer = {}")
    from_server("BJLAccountSet", {"token": "bjl_from_page", "user": {"name": "Pat", "slug": "pat"}})
    check("main: an account set by the BeamJoy page is kept", m.account.token == "bjl_from_page" and
          rt.eval("written['settings/beamjoyLive/account.json'].token") == "bjl_from_page")
    check("main: and the plugin told", dict(sent()).get("BJLAccount", {}).get("token") == "bjl_from_page", sent())
    rt.execute("ui = {}")
    from_server("BJLLapResult", {"name": "Loop", "status": "posted", "rank": 2})
    check("main: lap results go to the window", rt.eval("ui[1] and ui[1].event") == "BJLLapResult")
    from_server("BJLAccountSet", {"clear": True})
    check("main: unlinked from the page", m.account is None)

    # pacing : a big request leaves a burst at a time
    rt.execute("toServer = {}")
    m.http(1, "POST", "/api/x", "y" * 200000, "application/json")
    first = rt.eval("#toServer")
    sent_bytes = rt.eval("function() local n = 0 for _, e in ipairs(toServer) do n = n + e.size end return n end")
    check("main: a big request isn't sent all at once", 0 < first < 10 and sent_bytes() <= m.BURST + 13000, (first, sent_bytes()))
    for _ in range(20):
        m.onUpdate(0.1)
    check("main: then drains at the budget", rt.eval("#toServer") == 18 and m.relayBacklog() == 0, rt.eval("#toServer"))
    rt.execute("toServer = {}")
    m.http(2, "GET", "/api/y", "", "")
    check("main: a small request goes straight out", rt.eval("#toServer") == 1)

    m.onServerLeave()
    unloaded = list(rt.eval("unloaded").values())
    check("main: leaving unloads every extension of ours", sorted(unloaded) == sorted(["beamjoyLive_live", "beamjoyLive_laps", "beamjoyLive_capture", "beamjoyLive_main"]), unloaded)


def capture():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        beamjoyLive_main = { log = function() end, level = function() return "test_level" end,
            send = function(e, p) last = { event = e, payload = p } end }
        package.preload["mime"] = function() error("no mime here") end
        map = { getMap = function() return { nodes = {
            a = { pos = { x = 1.04, y = 2, z = 3 }, radius = 4.56, links = { b = {}, c = {} } },
            b = { pos = { x = 10, y = 2, z = 3 }, radius = 3, links = { a = {} } },
            c = { pos = { x = 1, y = 20, z = 3 }, radius = 2, links = { a = {}, missing = {} } },
        } } end }
    """)
    m = load_ext(rt, "capture")
    for n in [0, 1, 2, 3, 4, 5, 100, 1000]:
        data = bytes(random.getrandbits(8) for _ in range(n))
        got = m.base64(data)
        check(f"base64 {n} bytes", got == base64.b64encode(data).decode(), got[:20])
    rm = m.roadMap()
    nodes = [list(n.values()) for n in rm.nodes.values()]
    edges = sorted(tuple(e.values()) for e in rm.edges.values())
    check("roads: three nodes", len(nodes) == 3, nodes)
    check("roads: rounded", [1.0, 2.0, 3.0, 4.6] in [[round(v, 3) for v in n] for n in nodes], nodes)
    check("roads: each link once, unknown nodes dropped", len(edges) == 2, edges)


def client_live():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        sent = {}
        beamjoyLive_main = { selfName = function() return "Me" end, config = { liveSessions = true }, reporter = true,
            level = function() return "italy" end, levelTitle = function() return "Italy" end,
            toServer = function(e, p) table.insert(sent, { event = e, payload = p }) end, log = print }
        local function v3(x, y, z) return { x = x, y = y, z = z, length = function(s) return math.sqrt(s.x*s.x + s.y*s.y + s.z*s.z) end } end
        local objects = {
            [11] = { getPosition = function() return v3(10.04, 20, 30) end, getVelocity = function() return v3(3, 4, 0) end, getDirectionVector = function() return v3(1, 0, 0) end },
            [12] = { getPosition = function() return v3(-5, 0, 1) end, getVelocity = function() return v3(0, 0, 0) end, getDirectionVector = function() return v3(0, -1, 0) end },
        }
        be = { getObjectByID = function(_, id) return objects[id] end }
        MPVehicleGE = {
            getVehicles = function() return {
                { ownerName = "Me", gameVehicleID = 11, jbeam = "etk800" },
                { ownerName = "Bob", gameVehicleID = 12, jbeam = "pessima" },
                { ownerName = "Bob", gameVehicleID = 13, jbeam = "pigeon", isDeleted = true },
            } end,
            getGameVehicleID = function(s) return s == "1-0" and 11 or nil end,
            getPlayers = function() return { { name = "Me" }, { name = "Bob" }, { name = "Watcher" } } end,
        }
        beamjoy_players = { players = { Me = { playerID = 1, currentVehicle = 0 }, Watcher = { playerID = 3 } } }
    """)
    m = load_ext(rt, "live")
    snap = {p.name: p for p in m.snapshot().values()}
    check("live: everyone listed", sorted(snap) == ["Bob", "Me", "Watcher"], sorted(snap))
    me = snap["Me"]
    check("live: own car, speed, heading, rounded", me.vehicle == "etk800" and abs(me.speed - 5) < 1e-9 and me.heading == 90 and
          list(me.pos.values())[0] == 10.0, (me.vehicle, me.speed, me.heading))
    bob = snap["Bob"]
    check("live: deleted vehicles skipped", bob.vehicle == "pessima" and bob.heading == 180, (bob.vehicle, bob.heading))
    check("live: no vehicle is spectating", snap["Watcher"].spectating and snap["Watcher"].pos is None)
    m.onUpdate()
    check("live: the reporter sends the plugin its snapshot", rt.eval("sent[1] and sent[1].event") == "BJLLive" and
          rt.eval("sent[1].payload.level") == "italy")


def aerial():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("beamjoyLive_main = { log = function() end }")
    m = load_ext(rt, "capture")

    def plan(w, h, ceiling):
        p = m.planAerial(rt.table_from({"minX": 0, "maxX": w, "minY": 0, "maxY": h}), ceiling)
        centers = [tuple(c.values()) for c in p.centers.values()]
        return p, centers

    def covers(p, centers, aspect):
        area = list(p.area.values())
        hw, hh = p.halfHeight * aspect, p.halfHeight
        for i in range(51):
            for j in range(51):
                x = area[0] + (area[2] - area[0]) * i / 50
                y = area[1] + (area[3] - area[1]) * j / 50
                if not any(abs(x - cx) <= hw + 1e-6 and abs(y - cy) <= hh + 1e-6 for cx, cy in centers):
                    return False
        return True

    p, c = plan(300, 200, 900)
    check("aerial: a small race is one shot", len(c) == 1 and p.altitude <= 900, (len(c), p.altitude))
    p, c = plan(4000, 3000, 900)
    check("aerial: a big race stays under the ceiling", p.altitude <= 900 + 1e-6 and len(c) > 1, (len(c), p.altitude))
    check("aerial: shots cover the area on 4:3", covers(p, c, 4 / 3))
    check("aerial: and on 16:9", covers(p, c, 16 / 9))
    p, c = plan(30000, 30000, 600)
    check("aerial: a huge race is capped in shots, from higher up", len(c) <= 36 and p.altitude > 600 and covers(p, c, 4 / 3), (len(c), p.altitude))
    check("aerial: ceiling from a short view distance", abs(m.ceilingFor(1000, 60) - 1000 * 0.8 / (1 + math.tan(math.pi / 6) ** 2 * (1 + (16 / 9) ** 2)) ** 0.5) < 0.01, m.ceilingFor(1000, 60))
    check("aerial: ceiling capped for detail", m.ceilingFor(20000, 60) == 900)


# --- the server plugin, with BeamJoy's API helper ------------------------------------------------

class Plugin:
    """The server plugin in a Lua 5.4 state, BeamJoy's API helper loaded from a BeamJoy-Revived
    checkout, BeamJoy's side of the API played here. `site(method, path, body, token)` answers the
    plugin's site requests (or None : real curl)."""

    def __init__(self, bj_repo, name, legacy_config=None, races=None, site=None, build=2488, map_name="testmap"):
        self.tmp = os.path.join(ROOT, "tools", ".tmp-" + name)
        shutil.rmtree(self.tmp, ignore_errors=True)
        self.server = os.path.join(self.tmp, "server")
        self.data = os.path.join(self.tmp, "plugin")
        os.makedirs(os.path.join(self.server, "BeamJoyServer/api"))
        os.makedirs(os.path.join(self.server, "BeamJoyData/db/activities"))
        os.makedirs(self.data)
        if bj_repo:
            shutil.copy(os.path.join(bj_repo, "BeamJoyServer/api/BeamJoyAPI.lua"), os.path.join(self.server, "BeamJoyServer/api/"))
        if legacy_config is not None:
            json.dump(legacy_config, open(os.path.join(self.data, "config.json"), "w"))
        for map_, list_ in (races or {}).items():
            json.dump(list_, open(os.path.join(self.server, "BeamJoyData/db/activities", f"{map_}_races.json"), "w"))
        self.map = map_name
        self.build = build
        self.site = site
        self.requests = []      # what the plugin asked the site
        self.calls = []         # what the plugin asked BeamJoy : (method, params)
        self.config_tab = None
        self.config_values = {}
        self.sessions = []
        self.online = []
        self.to_client = []     # (playerID, event, payload)
        rt = self.rt = lua54.LuaRuntime(unpack_returned_tuples=True)
        g = rt.globals()
        g.json_encode = lambda t: json.dumps(lua_to_py(t))
        g.json_decode = lambda s: py_to_lua(rt, json.loads(s))
        g.py_global_event = self._global_event
        g.py_client_event = lambda pid, e, d: self.to_client.append((pid, e, json.loads(unescape(d)) if e.startswith("BJL") else d))
        rt.execute(f"""
            clock = 1000000
            os.time = function() return clock end
            events, connected = {{}}, {{}}
            MP = {{
                Settings = {{ Name = 1 }},
                Get = function() return "^lMy ^4Server" end,
                RegisterEvent = function(e, fn) events[e] = events[e] or {{}} ; table.insert(events[e], fn) end,
                CreateEventTimer = function() end,
                TriggerGlobalEvent = function(e, data) py_global_event(e, data) end,
                TriggerClientEvent = function(pid, e, data) py_client_event(pid, e, data) return true end,
                IsPlayerConnected = function(pid) return connected[pid] == true end,
                GetPlayerName = function(pid) return connected[pid] and ("P" .. pid) or "" end,
            }}
            Util = {{ JsonEncode = json_encode, JsonDecode = json_decode }}
            FS = {{ CreateDirectory = function() end }}
            BJL_PATHS = {{ data = {json.dumps(self.data + "/")}, server = {json.dumps(self.server + "/")} }}
            function fire(e, ...)
                for _, fn in ipairs(events[e] or {{}}) do _G[fn](...) end
            end
        """)
        if site is not None:
            rt.globals().py_site = self._site
        rt.execute(f"dofile({json.dumps(os.path.join(PLUGIN, 'main.lua'))})")
        if site is not None:
            # the site, answered here : requests wait for the next poll, like curl's
            rt.execute("""
                siteQueue = {}
                BJL.web.request = function(req, cb) table.insert(siteQueue, { req = req, cb = cb }) end
                function flushSite()
                    for _ = 1, 50 do
                        if #siteQueue == 0 then return end
                        local q = siteQueue
                        siteQueue = {}
                        for _, r in ipairs(q) do
                            local status, body = py_site(r.req.method, r.req.path, r.req.body or "", r.req.token or "")
                            r.cb(status, body)
                        end
                    end
                end
            """)
        rt.execute("onInit()")

    # BeamJoy's side
    def _global_event(self, event, data):
        if event != "BJAPI_Request":
            return
        req = json.loads(data)
        method, params = req["method"], req.get("params") or {}
        self.calls.append((method, params))
        result = self._answer(method, params)
        self.fire("BJAPI_Response", json.dumps({"v": 1, "id": req["id"], "to": req["from"], "ok": True, "result": result}))

    def _defaults(self):
        values = {}
        for section in (self.config_tab or {}).get("sections", []):
            for o in section.get("options", []):
                if o.get("type") != "button":
                    values[o["id"]] = o.get("default", "" if o.get("type") == "text" else None)
        values.update(self.config_values)
        return values

    def _answer(self, method, params):
        if method == "server.info":
            return {"api": 1, "instance": "i1", "beamjoy": {"version": "2.0.1", "build": self.build},
                    "map": {"name": self.map, "label": "Test Map"}, "players": 2, "methods": [], "events": []}
        if method == "config.register":
            self.config_tab = params
            return {"values": self._defaults()}
        if method == "config.get":
            return {"values": self._defaults()}
        if method == "config.set":
            known = set(self._defaults())
            changed = [k for k, v in params["values"].items() if k in known and self.config_values.get(k) != v]
            self.config_values.update({k: v for k, v in params["values"].items() if k in known})
            if changed:
                self.emit("ConfigChanged", {"plugin": "BeamJoyLive", "values": {}, "changed": changed, "by": "plugin:BeamJoyLive"})
            return {"values": self._defaults(), "changed": changed}
        if method == "races.sessions":
            return {"sessions": self.sessions}
        if method == "players.online":
            return {"players": self.online}
        if method == "maps.list":
            return {"maps": [{"name": self.map, "label": "Test Map"}]}
        return {}

    def fire(self, event, *args):
        self.rt.globals().fire(event, *args)

    def emit(self, event, data):
        self.fire("BJAPI_" + event, json.dumps({"v": 1, "event": event, "instance": "i1", "data": data}))

    def save_config(self, **values):
        """staff saving the config tab"""
        self.config_values.update(values)
        self.emit("ConfigChanged", {"plugin": "BeamJoyLive", "values": {}, "changed": list(values), "by": "Staff"})

    # the site
    def _site(self, method, path, body, token):
        data = json.loads(body) if body else None
        self.requests.append((method, path, data, token or None))
        status, answer = self.site(method, path, data, token or None)
        return status, json.dumps(answer)

    def flush(self):
        if self.site is not None:
            self.rt.execute("flushSite()")

    def connect(self, pid, token=None, user=None):
        self.rt.execute(f"connected[{pid}] = true")
        self.fire("BJLHello", pid, "")
        payload = {"token": token, "user": user} if token else {}
        self.fire("BJLAccount", pid, escape(json.dumps(payload)))

    def tick(self, seconds=0):
        self.rt.execute(f"clock = clock + {seconds}")
        self.fire("BJLPoll")
        self.flush()

    def calls_of(self, method):
        return [p for m, p in self.calls if m == method]

    def requests_to(self, path, method="POST"):
        return [r for r in self.requests if r[1] == path and r[0] == method]

    def client_events(self, pid, event):
        return [p for (i, e, p) in self.to_client if i == pid and e == event]

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


CIRCUIT_GATES = [{"pos": {"x": 0, "y": 0, "z": 0}}, {"pos": {"x": 100, "y": 0, "z": 0}}, {"pos": {"x": 100, "y": 50, "z": 0}}]
TEST_RACES = {"testmap": [
    {"id": 7, "name": "Loop", "loopable": True, "gates": CIRCUIT_GATES, "defaults": {}},
    {"id": 8, "name": "Sprint", "loopable": False, "gates": CIRCUIT_GATES[:2], "defaults": {}},
    {"id": 9, "name": "Kept off", "loopable": False, "gates": CIRCUIT_GATES[:2], "defaults": {"plugins": {"BeamJoyLive": {"post": False}}}},
    {"id": 10, "name": "Unlisted", "loopable": True, "gates": CIRCUIT_GATES[1:], "defaults": {}},
]}


def fake_site(method, path, data, token):
    if path == "/api/game/routes/match":
        slug = {3: "loop", 2: "sprint"}.get(len(data["gates"])) if data["gates"][0] == [0, 0, 0] else None
        return 200, {"route": {"slug": slug, "title": slug.title(), "url": f"https://site.example/routes/{slug}", "sectors": 3} if slug else None}
    if path == "/api/game/laps":
        return 200, {"isPB": True, "isRecord": data["lapMs"] < 90000, "bestLapMs": data["lapMs"], "theoreticalMs": None,
                     "rank": 1, "drivers": 4, "start": data["start"]}
    if path == "/api/game/laps/withdraw":
        return 200, {"withdrawn": 1}
    if path == "/api/game/live":
        return 200, {"slug": "my-server", "url": "https://site.example/live/my-server"}
    if path == "/api/game/link":
        return 200, {"userCode": "Q3HG-52ND", "deviceCode": "dev123", "verifyUrl": "https://site.example/link?code=Q3HG-52ND",
                     "expiresIn": 600, "interval": 3}
    if path == "/api/game/link/poll":
        return 200, {"status": "linked", "token": "bjl_tok2", "user": {"name": "Two", "slug": "two"}}
    if path.startswith("/api/routes/") and "/leaderboard" in path:
        return 200, {"start": "flying", "boards": {"standing": 1, "flying": 2},
                     "entries": [{"rank": 1, "name": "One", "userSlug": "one", "bestLapMs": 89000}]}
    if path.startswith("/api/game/levels/"):
        return 200, {"level": path.rsplit("/", 1)[1], "roads": False}
    if path == "/api/game/me":
        return 200, {"ok": True}
    return 404, {"error": "Not found."}


def plugin(bj_repo):
    p = Plugin(bj_repo, "plugin", legacy_config={"SiteUrl": "https://site.example/", "LiveSessions": False, "ServerKey": "srv_legacy"},
               races=TEST_RACES, site=fake_site)
    try:
        plugin_tests(p)
    finally:
        p.close()
    # BeamJoy without its API (before 2.0) : the plugin stays off
    q = Plugin(None, "noapi", site=fake_site)
    check("plugin: without BeamJoy's API it stays off", q.rt.eval("BJL.BJ") is None)
    q.close()
    # BeamJoy 2.0.1 (server build 2478) : no labels on the race HUD yet
    r = Plugin(bj_repo, "old", legacy_config={"SiteUrl": "https://site.example"}, races=TEST_RACES, site=fake_site, build=2478)
    try:
        r.connect(1, "bjl_tok1", {"name": "One", "slug": "one"})
        r.emit("RacerLap", lap_event("S9", 7, 1, 91000, racer={"id": 1, "name": "One", "vehicle": "etk800"}, phase=None))
        r.flush()
        fields = [f for c in r.calls_of("results.setFields") for f in c["fields"]]
        check("plugin: on BeamJoy 2.0.1, no race HUD labels (it would keep them on results)",
              fields and all("hud" not in f for f in fields), fields)
        check("plugin: on BeamJoy 2.0.1, racers are known by player ID", r.requests_to("/api/game/laps")[0][2]["run"] == "S9#1#p1")
    finally:
        r.close()


def lap_event(session, race_id, lap, ms, racer=None, phase=1, sectors=None, options=None, phase_info=None, map_name="testmap"):
    racer = racer or {"id": 1, "racerKey": 1, "name": "One", "vehicle": "etk800"}
    d = {"sessionId": session, "raceId": race_id, "raceName": "Race " + str(race_id), "map": map_name, "racer": racer,
         "lap": lap, "lapMs": ms, "sectorsMs": sectors or [], "options": options or {}, "phaseCount": 1}
    if phase is not None:
        d["phaseIndex"] = phase
        d["phase"] = phase_info or {"index": phase, "name": "Race", "leaderboard": True}
    return d


def gate_event(session, race_id, lap, step, lap_ms=None, out_lap=False, racer=None):
    racer = racer or {"id": 1, "racerKey": 1, "name": "One"}
    d = {"sessionId": session, "raceId": race_id, "map": "testmap", "phaseIndex": 1, "racer": racer, "gate": step,
         "step": step, "lap": lap}
    if lap_ms is not None:
        d["lapMs"] = lap_ms
    if out_lap:
        d["outLap"] = True
    return d


def plugin_tests(p):
    # settings : config.json moved into BeamJoy's config tab
    check("plugin: a config tab in BeamJoy's config window", p.config_tab is not None and p.config_tab["title"] == "BeamJoy Live")
    check("plugin: config.json moved there", p.config_values.get("siteUrl") == "https://site.example/" and
          p.config_values.get("serverKey") == "srv_legacy" and os.path.exists(os.path.join(p.data, "config.json.old")) and
          not os.path.exists(os.path.join(p.data, "config.json")), p.config_values)
    check("plugin: the site address cleaned", p.rt.eval("BJL.settings.values.siteUrl") == "https://site.example")
    check("plugin: the BeamJoy Live page registered", any(c.get("id") == "live" for c in p.calls_of("pages.register")))
    opts = p.calls_of("raceOptions.register")
    check("plugin: a race option to keep a race's laps off the site",
          opts and opts[0]["sections"][0]["options"][0]["id"] == "post", opts)

    p.connect(1, "bjl_tok1", {"name": "One", "slug": "one"})
    p.connect(2)
    config = p.client_events(1, "BJLConfig")
    check("plugin: a game gets the config (no server key)", config and config[-1]["siteUrl"] == "https://site.example" and
          "serverKey" not in config[-1] and config[-1]["serverName"] == "My Server", config)
    p.fire("BJLVehicle", 1, escape(json.dumps({"model": "etk800", "label": "ETK 800-Series"})))

    # a circuit : lap 1 standing, lap 2 flying, from BeamJoy's race events
    p.emit("RacerGate", gate_event("S1", 7, 1, 1, 4200))
    p.emit("RacerLap", lap_event("S1", 7, 1, 91000.4, sectors=[30000, 31000, 30000]))
    p.flush()
    match = p.requests_to("/api/game/routes/match")
    check("plugin: the race's course from BeamJoy's race file", match and match[0][2]["gates"] == [[0, 0, 0], [100, 0, 0], [100, 50, 0]] and
          match[0][2]["level"] == "testmap" and match[0][2]["mapName"] == "Test Map", match)
    laps = p.requests_to("/api/game/laps")
    first = laps[0][2] if laps else {}
    check("plugin: the lap posted as the racer", laps and laps[0][3] == "bjl_tok1", laps)
    check("plugin: lap, sectors, car name, player name", first.get("lapMs") == 91000 and first.get("sectors") == [30000, 31000, 30000] and
          first.get("vehicle") == "ETK 800-Series" and first.get("playerName") == "P1" and first.get("route") == "loop", first)
    check("plugin: a circuit's first lap from the grid is standing", first.get("start") == "standing" and
          first.get("run") == "S1#1#k1" and first.get("runLap") == 1, first)
    huds = p.calls_of("hud.message")
    check("plugin: the racer sees the site's answer on BeamJoy's HUD", huds and huds[-1]["playerId"] == 1 and "P1 of 4" in huds[-1]["text"], huds)
    fields = p.calls_of("results.setFields")
    check("plugin: their site rank beside their name on the race HUD, and Site PB on their result",
          fields and fields[-1]["racerKey"] == 1 and {f["key"]: f.get("hud") for f in fields[-1]["fields"]} == {"rank": "only", "best": None}, fields)
    check("plugin: the game's window hears it", p.client_events(1, "BJLLapResult")[-1]["status"] == "posted")

    p.emit("RacerLap", lap_event("S1", 7, 2, 89500))
    p.flush()
    laps = p.requests_to("/api/game/laps")
    check("plugin: a circuit's later laps are flying ; the route asked once", laps[-1][2]["start"] == "flying" and
          laps[-1][2]["runLap"] == 2 and len(p.requests_to("/api/game/routes/match")) == 1)

    n = len(p.requests_to("/api/game/laps"))
    p.emit("RacerLap", lap_event("S1", 7, 3, 99000, racer={"id": 1, "racerKey": 1, "name": "One", "pitLaps": [3]}))
    p.emit("RacerLap", lap_event("S1", 7, 1, 95000, racer={"id": 2, "racerKey": 2, "name": "Two"}))
    p.emit("RacerLap", lap_event("S7", 7, 1, 95000, phase_info={"index": 1, "name": "Practice", "leaderboard": False}))
    p.emit("RacerLap", lap_event("S8", 7, 1, 95000, options={"BeamJoyLive": {"post": False}}))
    p.flush()
    check("plugin: no pit laps, unlinked racers, phases off the leaderboard, races with the option off",
          len(p.requests_to("/api/game/laps")) == n, p.requests_to("/api/game/laps")[n:])

    # disqualified by staff (or a plugin), reinstated
    p.emit("RaceControl", {"sessionId": "S1", "phaseIndex": 1, "racer": {"id": 1, "racerKey": 1}, "action": "disqualify", "by": "staff:Ann"})
    p.flush()
    w = p.requests_to("/api/game/laps/withdraw")
    check("plugin: disqualified, the run's laps are withdrawn", w and w[0][2] == {"route": "loop", "run": "S1#1#k1"} and w[0][3] == "bjl_tok1", w)
    check("plugin: and the racer's site labels taken off", [f["value"] for f in p.calls_of("results.setFields")[-1]["fields"]] == ["", ""])
    p.emit("RacerLap", lap_event("S1", 7, 4, 88000, racer={"id": 1, "racerKey": 1, "name": "One", "disqualified": True}))
    p.flush()
    check("plugin: no laps while disqualified", len(p.requests_to("/api/game/laps")) == n)
    p.emit("RaceControl", {"sessionId": "S1", "phaseIndex": 1, "racer": {"id": 1, "racerKey": 1}, "action": "reinstate", "by": "staff:Ann"})
    p.flush()
    again = [r[2]["runLap"] for r in p.requests_to("/api/game/laps")[n:]]
    check("plugin: reinstated, the run's counted laps go again", again == [1, 2, 4], again)

    # BeamJoy's verdict at the phase's end : a run it didn't count comes off the site
    w0 = len(p.requests_to("/api/game/laps/withdraw"))
    p.emit("RacePhaseFinished", {"sessionId": "S1", "phaseIndex": 1, "phase": {"index": 1, "leaderboard": True},
                                 "results": [{"racerKey": 1, "id": 1, "finished": True, "leaderboardRank": None}]})
    p.flush()
    check("plugin: a run BeamJoy didn't count (anti-cheat off, vehicle rule) is withdrawn",
          len(p.requests_to("/api/game/laps/withdraw")) == w0 + 1)
    check("plugin: the phase's runs are done", p.rt.eval("BJL.laps.runs['S1#1#k1']") is None)

    # an out lap first : the first lap is flying ; a point-to-point flying start
    p.emit("RacerGate", gate_event("S2", 7, 1, 2, out_lap=True))
    p.emit("RacerLap", lap_event("S2", 7, 1, 90000))
    p.emit("RacerGate", gate_event("S3", 8, 1, 1, 0))
    p.emit("RacerLap", lap_event("S3", 8, 1, 40000))
    p.emit("RacerGate", gate_event("S4", 8, 1, 1, 5300))
    p.emit("RacerLap", lap_event("S4", 8, 1, 47000))
    p.flush()
    starts = [r[2]["start"] for r in p.requests_to("/api/game/laps")[-3:]]
    check("plugin: after an out lap flying ; point-to-point flying and standing starts", starts == ["flying", "flying", "standing"], starts)
    w0 = len(p.requests_to("/api/game/laps/withdraw"))
    p.emit("RaceFinished", {"sessionId": "S4", "phaseIndex": 1, "results": [{"racerKey": 1, "id": 1, "leaderboardRank": 3}]})
    p.flush()
    check("plugin: a run BeamJoy counted stays", len(p.requests_to("/api/game/laps/withdraw")) == w0)

    # a race that isn't on the site
    huds = len(p.calls_of("hud.message"))
    p.emit("RacerLap", lap_event("S5", 10, 1, 90000))
    p.emit("RacerLap", lap_event("S5", 10, 2, 90000))
    p.flush()
    check("plugin: an unlisted race : told once, nothing posted", len(p.calls_of("hud.message")) == huds + 1 and
          p.client_events(1, "BJLLapResult")[-1]["status"] == "unlisted")

    # a race missing from BeamJoy's race file : said plainly, not "not on the site"
    p.emit("RacerLap", lap_event("S10", 99, 1, 90000))
    p.flush()
    last = p.client_events(1, "BJLLapResult")[-1]
    check("plugin: a race BeamJoy's file doesn't have : not posted, said so", last["status"] == "failed" and "race data" in last["error"], last)

    # freeroam runs, reported by the game
    n = len(p.requests_to("/api/game/laps"))
    p.fire("BJLFreeroamLap", 1, escape(json.dumps({"raceId": 8, "timeMs": 41000, "model": "etk800"})))
    p.fire("BJLFreeroamLap", 1, escape(json.dumps({"raceId": 9, "timeMs": 41000, "model": "etk800"})))
    p.fire("BJLFreeroamLap", 2, escape(json.dumps({"raceId": 8, "timeMs": 41000, "model": "etk800"})))
    p.flush()
    fr = p.requests_to("/api/game/laps")[n:]
    check("plugin: a freeroam run posted flying, no run ; not when the race's option is off or unlinked",
          len(fr) == 1 and fr[0][2]["start"] == "flying" and "run" not in fr[0][2] and fr[0][2]["route"] == "sprint", fr)
    huds = len(p.calls_of("hud.message"))
    p.fire("BJLFreeroamLap", 1, escape(json.dumps({"raceId": 8, "timeMs": 42000, "model": "etk800"})))
    p.flush()
    check("plugin: every freeroam run's result shows on the HUD", len(p.calls_of("hud.message")) == huds + 1)

    # the BeamJoy Live page
    p.emit("PageOpened", {"plugin": "BeamJoyLive", "page": "live", "by": {"id": 1, "name": "P1"}})
    page = [c for c in p.calls_of("pages.update") if c.get("players") == [1]]
    texts = json.dumps(page[-1]["blocks"]) if page else ""
    check("plugin: a player's own page : their account, laps and the route's board",
          "Linked to site.example as One" in texts and "Your laps" in texts and "Upload a race" in texts, texts[:300])
    p.emit("PageAction", {"plugin": "BeamJoyLive", "page": "live", "action": "upload", "values": {}, "by": {"id": 1, "name": "P1"}})
    check("plugin: Upload opens the game's window", p.client_events(1, "BJLOpen")[-1] == {"tab": "upload"})
    # linking from the page
    p.emit("PageOpened", {"plugin": "BeamJoyLive", "page": "live", "by": {"id": 2, "name": "P2"}})
    p.emit("PageAction", {"plugin": "BeamJoyLive", "page": "live", "action": "link", "values": {}, "by": {"id": 2, "name": "P2"}})
    p.flush()
    page2 = json.dumps([c for c in p.calls_of("pages.update") if c.get("players") == [2]][-1]["blocks"])
    check("plugin: Link account shows the code and opens the link page", "Q3HG-52ND" in page2 and
          p.client_events(2, "BJLOpenUrl")[-1]["url"].endswith("code=Q3HG-52ND") and
          p.requests_to("/api/game/link")[-1][2] == {"playerName": "P2"}, page2[:200])
    p.tick(3)
    got = p.client_events(2, "BJLAccountSet")
    check("plugin: once approved, the game gets its token", got and got[-1]["token"] == "bjl_tok2", got)
    p.fire("BJLAccount", 2, escape(json.dumps({"token": "bjl_tok2", "user": {"name": "Two", "slug": "two"}})))
    p.emit("PageAction", {"plugin": "BeamJoyLive", "page": "live", "action": "unlink", "values": {}, "by": {"id": 2, "name": "P2"}})
    p.flush()
    check("plugin: Unlink forgets the token on the site and in the game", p.requests_to("/api/game/me", "DELETE")[-1][3] == "bjl_tok2" and
          p.client_events(2, "BJLAccountSet")[-1] == {"clear": True})

    # the config tab's button
    p.emit("ConfigAction", {"plugin": "BeamJoyLive", "action": "check", "by": {"id": 1, "name": "P1"}})
    p.flush()
    check("plugin: Check the connection answers on the HUD", "answers" in p.calls_of("hud.message")[-1]["text"])

    # the Live page : off, then turned on in the config tab
    check("plugin: no reporter while the Live page is off", not p.client_events(1, "BJLReporter"))
    p.save_config(liveSessions=True)
    rep = p.client_events(1, "BJLReporter")
    check("plugin: turned on, the lowest player ID reports", rep and rep[-1] == {"reporter": True}, rep)
    p.sessions = [{"sessionId": "S6", "raceName": "Loop", "state": "RACE", "laps": 5, "phaseCount": 1,
                   "racers": [{"id": 1, "lap": 2, "finished": False, "inPhase": True}]}]
    p.online = [{"id": 1, "name": "P1", "displayName": "P1"}, {"id": 2, "name": "P2", "displayName": "Nick", "guest": True}]
    snap = {"level": "testmap", "players": [{"name": "P1", "vehicle": "ETK 800-Series", "pos": [1, 2, 3], "speed": 10, "heading": 90},
                                             {"name": "P2", "spectating": True}]}
    p.fire("BJLLive", 1, escape(json.dumps(snap)))
    p.flush()
    live = p.requests_to("/api/game/live")
    body = live[-1][2] if live else {}
    players = {x["name"]: x for x in body.get("players", [])}
    check("plugin: the plugin posts the Live page with its server key, as a linked player",
          live and live[-1][3] == "bjl_tok1" and body.get("serverKey") == "srv_legacy" and body.get("mapName") == "Test Map", body)
    check("plugin: with what each racer's doing, and guests' nicknames",
          players.get("P1", {}).get("activity") == "Racing Loop · lap 2/5" and "Nick" in players, players)
    check("plugin: every game learns the page's address", p.client_events(1, "BJLLiveStatus")[-1]["url"].endswith("/live/my-server"))
    p.fire("BJLLive", 2, escape(json.dumps(snap)))
    p.flush()
    check("plugin: only the reporter's snapshots count", len(p.requests_to("/api/game/live")) == len(live))

    # games' requests relayed (the window) : refused paths
    p.fire("BJLHttp", 1, escape(json.dumps({"id": 5, "method": "GET", "path": "/../etc/passwd", "parts": 0})))
    res = p.client_events(1, "BJLHttpResult")
    check("plugin: the relay refuses paths outside /api/", res and res[-1]["id"] == 5 and res[-1]["status"] == 0, res)

    p.fire("onPlayerDisconnect", 1)
    check("plugin: a player who left is forgotten", p.rt.eval("BJL.players.accounts[1]") is None)


def relay(site, bj_repo):
    """The web relay end to end: the client's Lua, the server plugin, real curl, a real site."""
    p = Plugin(bj_repo, "relay", legacy_config={"SiteUrl": site, "ServerKey": "srv_relaytest"},
               races={"west_coast_usa": [harness_race()]}, map_name="west_coast_usa")
    client = luajit21.LuaRuntime(unpack_returned_tuples=True)
    wire = []  # every event text, both ways
    sent_this_poll = [0, 0]  # bytes the plugin sent since the last poll, the most in one poll

    def to_server(event, data):
        wire.append(data)
        p.fire(event, 1, data)

    p.rt.execute("connected[1] = true")
    original = p.rt.globals().py_client_event

    def to_client(pid, event, data):
        wire.append(data)
        sent_this_poll[0] += len(data)
        sent_this_poll[1] = max(sent_this_poll[1], sent_this_poll[0])
        if event == "BJLHttpResult":
            main.onHttpResult(data)
        elif event == "BJLHttpPart":
            main.onHttpPart(data)
        original(pid, event, data)

    p.rt.globals().py_client_event = to_client
    ui = []
    client.globals().TriggerServerEvent = to_server
    client.globals().json_encode = lambda t: json.dumps(lua_to_py(t))
    client.globals().json_decode = lambda t: py_to_lua(client, json.loads(t))
    client.globals().ui_event = lambda name, payload: ui.append({"event": name, "payload": lua_to_py(payload)})
    client.execute("""
        jsonEncode, jsonDecode = json_encode, json_decode
        guihooks = { trigger = function(_, data) ui_event(data.event, data.payload) end }
    """)
    main = load_ext(client, "main")
    main.config = client.table_from({"siteUrl": site})

    def call(method, path, body="", token=None, content_type=None):
        main.account = client.table_from({"token": token}) if token else None
        rid = random.randint(1, 10**9)
        main.http(rid, method, path, body, content_type or ("application/json" if body else ""))
        for _ in range(600):
            for msg in ui:
                if msg["event"] == "BJLHttpResult" and msg["payload"]["id"] == rid:
                    return msg["payload"]
            main.onUpdate(0.05)
            sent_this_poll[0] = 0
            p.fire("BJLPoll")
            time.sleep(0.05)
        return None

    try:
        got = call("GET", "/api/routes/highway-endurance/leaderboard?size=2")
        check("relay: GET through curl", got and got["status"] in (200, 404) and json.loads(got["body"]), got and got["status"])
        gates = [[1000 + i * 3.5, -2000 + (i % 7) * 1.25, 100.5] for i in range(1800)]
        body = json.dumps({"level": "west_coast_usa", "loopable": False, "mapName": "Zpeed Zone", "gates": gates})
        got = call("POST", "/api/game/routes/match", body)
        check(f"relay: POST in {len(body) // 12000 + 1} parts", got and got["status"] == 200 and json.loads(got["body"]) == {"route": None}, got)
        got = call("GET", "/api/game/me", token="bjl_not-a-real-token")
        check("relay: token carried (site says 401)", got and got["status"] == 401, got and got["status"])
        token = os.environ.get("BJL_TOKEN")
        if token:
            level = f"relay_test_{random.randint(1, 10**6)}"
            nodes = [[round(i * 1.5, 1), round((i % 97) * 2.5, 1), 10.0, 3.0] for i in range(9000)]
            roads = json.dumps({"v": 1, "nodes": nodes, "edges": [[i, i + 1] for i in range(len(nodes) - 1)]})
            got = call("POST", f"/api/game/levels/{level}/roads", roads, token=token)
            check(f"relay: {len(roads) // 1000} KB upload", got and got["status"] in (200, 201), got and (got["status"], got["body"][:200]))
            sent_this_poll[1] = 0
            got = call("GET", f"/api/levels/{level}/roads")
            back = got and got["status"] == 200 and json.loads(got["body"])
            check("relay: big answer, whole", back and len(back["nodes"]) == len(nodes), got and got["status"])
            check("relay: answer paced (16 KB a poll, one part over at most)", sent_this_poll[1] <= 16000 + 13000, sent_this_poll[1])
            plugin_laps_on_site(p, token)
        else:
            print("skip relay upload and plugin lap tests (set BJL_TOKEN to a game token on that site)")
        for path in ["/../etc/passwd", "https://evil.example/x", "/api/x\"y"]:
            got = call("GET", path)
            check(f"relay: refuses {path}", got and got["status"] == 0, got)
        check("relay: no event holds a capital Z", all("Z" not in w for w in wire))
        # what's still on its way (the page's leaderboard after a lap) finishes first
        for _ in range(200):
            if not p.rt.eval("BJL.web.busy()"):
                break
            p.fire("BJLPoll")
            time.sleep(0.05)
        check("relay: temp files cleaned", sorted(os.listdir(os.path.join(p.data, "tmp"))) == [".keep"], os.listdir(os.path.join(p.data, "tmp")))
    finally:
        p.close()


def harness_race():
    race = json.load(open(os.path.join(ROOT, "tools/ui-harness/fixtures/race.json")))
    race["id"] = 1
    return race


def plugin_laps_on_site(p, token):
    """BeamJoy's race events -> the plugin -> real curl -> the site (the UI harness's race must be listed)."""
    p.fire("BJLAccount", 1, escape(json.dumps({"token": token, "user": {"name": "Relay", "slug": "relay"}})))
    session = f"relay{random.randint(1, 10**9)}"

    def wait(cond):
        for _ in range(200):
            p.fire("BJLPoll")
            if cond():
                return True
            time.sleep(0.05)
        return False

    results = lambda: p.client_events(1, "BJLLapResult")
    before = len(results())
    p.emit("RacerLap", lap_event(session, 1, 1, 301000, racer={"id": 1, "racerKey": 1, "name": "Relay", "vehicle": "sbr"},
                                 map_name="west_coast_usa"))
    ok = wait(lambda: len(results()) > before)
    last = results()[-1] if ok else {}
    check("plugin on the site: a lap from BeamJoy's events posted", ok and last.get("status") in ("posted", "unlisted"), last)
    if last.get("status") == "unlisted":
        print("     (the UI harness's Harness Oval isn't on that site : upload it from the harness to test posting)")
        return
    check("plugin on the site: as standing, the site's rank back", last.get("start") == "standing" and last.get("rank"), last)
    p.emit("RaceControl", {"sessionId": session, "phaseIndex": 1, "map": "west_coast_usa", "racer": {"id": 1, "racerKey": 1},
                           "action": "disqualify"})
    ok = wait(lambda: results()[-1].get("status") == "withdrawn")
    check("plugin on the site: disqualified, withdrawn", ok)


syntax()
client_laps()
main_ext()
capture()
client_live()
aerial()
bj = find_bj_repo()
if bj:
    plugin(bj)
    if os.environ.get("BJL_SITE"):
        relay(os.environ["BJL_SITE"], bj)
    else:
        print("skip relay test (set BJL_SITE to a running BeamJoy Web, e.g. http://localhost:3000)")
else:
    print("FAIL server plugin tests need a BeamJoy-Revived checkout for its API helper (set BJ_REPO)")
    failures += 1
print("\n" + ("all passed" if not failures else f"{failures} failed"))
sys.exit(1 if failures else 0)
