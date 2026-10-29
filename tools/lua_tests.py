"""
Unit tests for the mod's Lua, run outside the game with fakes for the game's and BeamMP's APIs.
Needs Python 3 and lupa (pip install lupa), which bundles LuaJIT (the game's VM) and Lua 5.4
(close to the BeamMP server's).

    python3 tools/lua_tests.py
    BJL_SITE=http://localhost:3000 python3 tools/lua_tests.py   # also the web relay, with curl
    BJL_SITE=... BJL_TOKEN=bjl_... python3 tools/lua_tests.py   # and a paced upload, laps, a withdrawal
"""
import base64
import json
import math
import os
import random
import sys

from lupa import luajit21, lua54

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXT = os.path.join(ROOT, "Client/lua/ge/extensions/beamjoyLive")
failures = 0


def check(name, cond, detail=""):
    global failures
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        failures += 1


def load_ext(rt, name):
    src = open(os.path.join(EXT, name + ".lua"), encoding="utf-8").read()
    return rt.execute(src)


def syntax():
    for base, _, files in os.walk(ROOT):
        if "node_modules" in base:
            continue
        for f in files:
            if not f.endswith(".lua"):
                continue
            path = os.path.join(base, f)
            rt = lua54.LuaRuntime() if "/Server/" in path else luajit21.LuaRuntime()
            err = rt.eval("function(s, n) local f, e = load(s, n) return e end")(open(path, encoding="utf-8").read(), "@" + f)
            check("syntax " + os.path.relpath(path, ROOT), err is None, err)


def laps():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        sent = {}
        races = {
            [7] = { id = 7, name = "Circuit", loopable = true, gates = {} },
            [8] = { id = 8, name = "Sprint", gates = {} },
            [9] = { id = 9, name = "Single car", gates = {}, vehicleRestrictionMode = "single" },
        }
        beamjoyLive_main = {
            config = { siteUrl = "https://site", leaderboards = true },
            account = { token = "bjl_x" },
            selfName = function() return "Me" end,
            findRace = function(id) return races[id] end,
            course = function(race) return { raceId = race.id, name = race.name } end,
            send = function(event, payload) table.insert(sent, { event = event, payload = payload }) end,
        }
        be = { getPlayerVehicle = function() return { getJBeamFilename = function() return "etk800" end } end }
        CLEAN = { disableNodegrabber = true, disableCameras = true, disableGravityChange = true }
        function settings(extra)
            local s = { disableNodegrabber = true, disableCameras = true, disableGravityChange = true }
            for k, v in pairs(extra or {}) do s[k] = v end
            return s
        end
    """)
    m = load_ext(rt, "laps")
    # a session update : `opts` adds settings / phases / phaseIndex (full update) or leaves them out (slim)
    session = rt.eval("""function(id, raceId, laps, history, opts)
        opts = opts or {}
        return { id = id, raceId = raceId, settings = opts.settings, phases = opts.phases, phaseIndex = opts.phaseIndex,
            participants = {
                { playerName = "Other", lapTimes = { 1000 } },
                { playerName = "Me", lapTimes = laps, lapSectorHistory = history, vehicleModel = "sunburst",
                  disqualified = opts.dq, pitLaps = opts.pitLaps },
            } }
    end""")
    t = rt.table
    opts = lambda **kw: rt.table_from(kw)
    clean = rt.eval("settings()")
    count = rt.eval("function() return #sent end")
    last = lambda: rt.eval("function() return sent[#sent] end")()

    m.onSessionUpdate(session("s1", 7, t(), t(), opts(settings=clean)))
    check("laps: nothing sent at the grid", count() == 0)
    m.onSessionUpdate(session("s1", 7, t(91000.4), t(t(30000, 31000, 30000.4))))
    check("laps: first lap handed on (settings kept from the full update)", count() == 1, count())
    lap = last().payload
    check("laps: lap time rounded", lap.lapMs == 91000, lap.lapMs)
    check("laps: sectors in order", list(lap.sectors.values()) == [30000, 31000, 30000], list(lap.sectors.values()) if lap.sectors else None)
    check("laps: a circuit's first lap from the grid is standing", lap.start == "standing", lap.start)
    check("laps: the run and its lap number", lap.run == "s1#1" and lap.runLap == 1, (lap.run, lap.runLap))
    m.onSessionUpdate(session("s1", 7, t(91000, 90500), t(t(30000, 31000, 30000), rt.table_from({"1": 30000, "2": 30000, "3": 30500}))))
    lap = last().payload
    check("laps: second lap, string-keyed sectors", count() == 2 and list(lap.sectors.values()) == [30000, 30000, 30500])
    check("laps: a circuit's later laps are flying", lap.start == "flying" and lap.runLap == 2, (lap.start, lap.runLap))
    m.onSessionUpdate(session("s1", 7, t(91000, 90500), t()))
    check("laps: repeated update sends nothing", count() == 2)

    m.onSessionUpdate(session("s1", 7, t(91000, 90500, 92000), t(), opts(pitLaps=t(3, 4))))
    check("laps: a pit lap isn't sent", count() == 2)
    m.onSessionUpdate(session("s1", 7, t(91000, 90500, 92000, 93000, 89000), t(), opts(pitLaps=t(3, 4))))
    check("laps: the lap after the pit lane's is", count() == 3 and last().payload.runLap == 5, count())

    # disqualified after laps went out : withdrawn, then posted again when reinstated
    m.onSessionUpdate(session("s1", 7, t(91000, 90500, 92000, 93000, 89000), t(), opts(pitLaps=t(3, 4), dq=True)))
    w = last()
    check("laps: disqualified, the run is withdrawn", count() == 4 and w.event == "BJLWithdraw" and w.payload.run == "s1#1", (count(), w.event))
    m.onSessionUpdate(session("s1", 7, t(91000, 90500, 92000, 93000, 89000, 88000), t(), opts(pitLaps=t(3, 4), dq=True)))
    check("laps: no laps while disqualified", count() == 4)
    m.onSessionUpdate(session("s1", 7, t(91000, 90500, 92000, 93000, 89000, 88000), t(), opts(pitLaps=t(3, 4))))
    reposted = [rt.eval(f"function() return sent[{i}].payload.runLap end")() for i in range(5, count() + 1)]
    check("laps: reinstated, every counted lap of the run goes again", reposted == [1, 2, 5, 6], reposted)

    # the next phase of the same session : its own run, its own lap numbers
    phases = t(rt.table_from({"name": "Practice", "leaderboard": False}), rt.table_from({"name": "Race"}))
    before = count()
    m.onSessionUpdate(session("s1", 7, t(), t(), opts(settings=rt.eval("settings({ outLap = true })"), phases=phases, phaseIndex=1)))
    m.onSessionUpdate(session("s1", 7, t(70000), t(), opts(phaseIndex=1)))
    check("laps: a phase kept off the leaderboard sends nothing", count() == before, count() - before)
    m.onSessionUpdate(session("s1", 7, t(), t(), opts(phaseIndex=2)))
    m.onSessionUpdate(session("s1", 7, t(69000), t(), opts(phaseIndex=2)))
    lap = last().payload
    check("laps: next phase, its own run", count() == before + 1 and lap.run == "s1#2" and lap.runLap == 1, (count() - before, lap.run))
    check("laps: after an out lap, the first lap is flying", lap.start == "flying", lap.start)

    # point-to-point : standing, or flying with a flying start
    before = count()
    m.onSessionUpdate(session("s3", 8, t(), t(), opts(settings=clean)))
    m.onSessionUpdate(session("s3", 8, t(50000), t()))
    check("laps: a point-to-point run is standing", count() == before + 1 and last().payload.start == "standing")
    m.onSessionUpdate(session("s4", 8, t(), t(), opts(settings=rt.eval("settings({ flyingStart = true })"))))
    m.onSessionUpdate(session("s4", 8, t(48000), t()))
    check("laps: a flying start is flying", count() == before + 2 and last().payload.start == "flying")

    # BeamJoy's own rules for what reaches a leaderboard
    before = count()
    m.onSessionUpdate(session("s5", 8, t(), t(), opts(settings=rt.eval("settings({ disableNodegrabber = false })"))))
    m.onSessionUpdate(session("s5", 8, t(50000), t()))
    check("laps: node grabber allowed, nothing sent", count() == before)
    m.onSessionUpdate(session("s6", 9, t(), t(), opts(settings=rt.eval("settings({ vehicleRestrictionStartMode = 'free' })"))))
    m.onSessionUpdate(session("s6", 9, t(50000), t()))
    check("laps: the race's vehicle rule not used, nothing sent", count() == before)
    m.onSessionUpdate(session("s7", 9, t(), t(), opts(settings=rt.eval("settings({ vehicleRestrictionStartMode = 'raceDefined' })"))))
    m.onSessionUpdate(session("s7", 9, t(50000), t()))
    check("laps: the race's own vehicle rule, sent", count() == before + 1)
    m.onSessionUpdate(session("s8", 8, t(60000, 61000), t()))
    check("laps: joining a race under way skips its old laps", count() == before + 1)
    m.onSessionUpdate(session("s8", 8, t(60000, 61000, 62000), t()))
    check("laps: unknown settings (no full update yet), nothing sent", count() == before + 1)
    rt.execute("beamjoy_raceRunner = { session = { id = 's8', settings = settings() } }")
    m.onSessionUpdate(session("s8", 8, t(60000, 61000, 62000, 63000), t()))
    check("laps: settings from BeamJoy's own copy of the session", count() == before + 2 and last().payload.runLap == 4)

    m.onFreeroamResult(8, rt.eval("{ timeMs = 65432 }"))
    lap = last().payload
    check("laps: freeroam run, flying, no run", lap.start == "flying" and lap.kind == "freeroam" and lap.lapMs == 65432 and lap.run is None)
    rt.execute("beamjoyLive_main.account = nil")
    before = count()
    m.onFreeroamResult(8, rt.eval("{ timeMs = 65432 }"))
    check("laps: not linked, nothing sent", count() == before)


def main_ext():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        ui, toServer, unloaded = {}, {}, {}
        guihooks = { trigger = function(_, data) table.insert(ui, data) end }
        -- as long as the real encoding, near enough
        jsonEncode = function(t) return string.rep("x", #(t.data or "") + 60) end
        TriggerServerEvent = function(e, data) table.insert(toServer, { event = e, size = #data }) end
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

    # pacing : a big request leaves a burst at a time
    m.config = rt.table_from({"siteUrl": "https://site"})
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


def live():
    rt = luajit21.LuaRuntime(unpack_returned_tuples=True)
    rt.execute("""
        beamjoyLive_main = { selfName = function() return "Me" end, findRace = function() return { name = "GP" } end }
        local function v3(x, y, z) return { x = x, y = y, z = z, length = function(s) return math.sqrt(s.x*s.x + s.y*s.y + s.z*s.z) end } end
        local objects = {
            [11] = { getPosition = function() return v3(10, 20, 30) end, getVelocity = function() return v3(3, 4, 0) end, getDirectionVector = function() return v3(1, 0, 0) end },
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
        beamjoy_raceRunner = { session = { state = "RACE", raceId = 1, settings = { laps = 3 },
            phases = { { name = "Qualifying" }, { name = "Race" } }, phaseIndex = 2,
            participants = { { playerName = "Me", currentLap = 2 } } } }
    """)
    m = load_ext(rt, "live")
    snap = {p.name: p for p in m.snapshot().values()}
    check("live: everyone listed", sorted(snap) == ["Bob", "Me", "Watcher"], sorted(snap))
    me = snap["Me"]
    check("live: own car, speed, heading", me.vehicle == "etk800" and abs(me.speed - 5) < 1e-9 and abs(me.heading - 90) < 1e-9, (me.vehicle, me.speed, me.heading))
    check("live: own activity, with the phase", me.activity == "Racing GP · Race · lap 2/3", me.activity)
    bob = snap["Bob"]
    check("live: deleted vehicles skipped", bob.vehicle == "pessima" and abs(bob.heading - 180) < 1e-9, (bob.vehicle, bob.heading))
    check("live: no vehicle is spectating", snap["Watcher"].spectating and snap["Watcher"].pos is None)


def server():
    rt = lua54.LuaRuntime(unpack_returned_tuples=True)
    tmp = os.path.join(ROOT, "tools", ".tmp-plugin")
    os.makedirs(tmp, exist_ok=True)
    cfg = os.path.join(tmp, "config.json")
    if os.path.exists(cfg):
        os.remove(cfg)
    rt.globals().json_encode = lambda t: json.dumps(lua_to_py(t))
    rt.globals().json_decode = lambda s: py_to_lua(rt, json.loads(s))
    rt.execute("""
        events, toClient, connected = {}, {}, {}
        MP = {
            Settings = { Name = 1 },
            Get = function() return "^lMy ^4Server" end,
            RegisterEvent = function(e, fn) events[e] = fn end,
            CreateEventTimer = function() end,
            TriggerClientEvent = function(pid, e, data) table.insert(toClient, { pid = pid, event = e, data = data }) end,
            IsPlayerConnected = function(pid) return connected[pid] == true end,
            GetPlayerName = function(pid) return "P" .. pid end,
        }
        Util = { JsonEncode = json_encode, JsonDecode = json_decode }
    """)
    src = open(os.path.join(ROOT, "Server/BeamJoyLive/main.lua"), encoding="utf-8").read()
    src = src.replace('local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\\\", "/"):match("(.*/)") or "./"',
                      f'local PLUGIN_DIR = "{tmp}/"')
    rt.execute(src)
    rt.execute("onInit()")
    saved = json.load(open(cfg))
    check("plugin: config written with a server key", saved["ServerKey"].startswith("srv_") and saved["LiveSessions"] is False)
    saved["SiteUrl"] = "https://site.example/"
    saved["LiveSessions"] = True
    json.dump(saved, open(cfg, "w"))
    rt.execute("onInit()")
    g = rt.globals()
    rt.execute("connected[1] = true; connected[3] = true; toClient = {}")
    g.BJL_onHello(3)
    msgs = rt.eval("toClient")
    first = json.loads(msgs[1].data)
    check("plugin: hello gets config, colour codes stripped, slash trimmed", first["siteUrl"] == "https://site.example" and first["serverName"] == "My Server", first)
    rt.execute("toClient = {}")
    g.BJL_onCanReport(3, "1")
    g.BJL_onCanReport(1, "1")
    reporters = [(m.pid, json.loads(m.data)) for m in rt.eval("toClient").values() if m.event == "BJLReporter"]
    final = {pid: d for pid, d in reporters}
    check("plugin: lowest linked player reports", final[1].get("reporter") is True and final[1].get("serverKey") == saved["ServerKey"] and final[3].get("reporter") is False, reporters)
    rt.execute("toClient = {}; connected[1] = nil")
    g.BJL_onPlayerDisconnect(1)
    reporters = [(m.pid, json.loads(m.data)) for m in rt.eval("toClient").values() if m.event == "BJLReporter"]
    check("plugin: reporter re-elected on leave", reporters and reporters[-1][0] == 3 and reporters[-1][1]["reporter"] is True, reporters)
    rt.execute("toClient = {}")
    g.BJL_onCanReport(3, "0")
    check("plugin: nobody left to report", rt.eval("#toClient") == 1 and json.loads(rt.eval("toClient[1].data"))["reporter"] is False)
    os.remove(cfg)
    os.rmdir(tmp)


def relay(site):
    """The web relay end to end: the client's Lua, the server plugin, real curl, a real site."""
    client = luajit21.LuaRuntime(unpack_returned_tuples=True)
    server = lua54.LuaRuntime(unpack_returned_tuples=True)
    tmp = os.path.join(ROOT, "tools", ".tmp-relay")
    os.makedirs(tmp, exist_ok=True)
    json.dump({"SiteUrl": site, "ServerKey": "srv_relaytest"}, open(os.path.join(tmp, "config.json"), "w"))
    wire = []  # every event text, both ways
    sent_this_poll = [0, 0]  # bytes the plugin sent since the last poll, the most in one poll

    def to_server(event, data):
        wire.append(data)
        server.globals()["BJL_onHttp" if event == "BJLHttp" else "BJL_onHttpPart"](1, data)

    def to_client(pid, event, data):
        wire.append(data)
        sent_this_poll[0] += len(data)
        sent_this_poll[1] = max(sent_this_poll[1], sent_this_poll[0])
        if event == "BJLHttpResult":
            main.onHttpResult(data)
        elif event == "BJLHttpPart":
            main.onHttpPart(data)

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

    server.globals().json_encode = lambda t: json.dumps(lua_to_py(t))
    server.globals().json_decode = lambda t: py_to_lua(server, json.loads(t))
    server.globals().to_client = to_client
    server.execute("""
        MP = {
            Settings = { Name = 1 }, Get = function() return "Relay test" end,
            RegisterEvent = function() end, CreateEventTimer = function() end,
            TriggerClientEvent = function(pid, e, data) to_client(pid, e, data) end,
            IsPlayerConnected = function() return true end, GetPlayerName = function() return "P1" end,
        }
        Util = { JsonEncode = json_encode, JsonDecode = json_decode }
    """)
    src = open(os.path.join(ROOT, "Server/BeamJoyLive/main.lua"), encoding="utf-8").read()
    src = src.replace('local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\\\", "/"):match("(.*/)") or "./"',
                      f'local PLUGIN_DIR = "{tmp}/"')
    server.execute(src)
    server.execute("onInit()")

    import time

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
            server.globals().BJL_pollHttp()
            time.sleep(0.05)
        return None

    got = call("GET", "/api/routes/highway-endurance/leaderboard?size=2")
    check("relay: GET through curl", got and got["status"] == 200 and "entries" in json.loads(got["body"]), got and got["status"])
    gates = [[1000 + i * 3.5, -2000 + (i % 7) * 1.25, 100.5] for i in range(1800)]
    body = json.dumps({"level": "west_coast_usa", "loopable": False, "mapName": "Zpeed Zone", "gates": gates})
    got = call("POST", "/api/game/routes/match", body)
    check(f"relay: POST in {len(body) // 12000 + 1} parts", got and got["status"] == 200 and json.loads(got["body"]) == {"route": None}, got)
    got = call("GET", "/api/game/me", token="bjl_not-a-real-token")
    check("relay: token carried (site says 401)", got and got["status"] == 401, got and got["status"])
    token = os.environ.get("BJL_TOKEN")
    if token:
        # a big upload goes paced, and a big answer comes back paced
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
        # a lap with its run, a resend, and the run withdrawn
        lap = {"route": "rinky-dink", "lapMs": 25000, "start": "standing", "run": f"relay{random.randint(1, 10**9)}#1", "runLap": 1}
        got = call("POST", "/api/game/laps", json.dumps(lap), token=token)
        check("relay: lap posted", got and got["status"] == 200 and json.loads(got["body"])["start"] == "standing", got)
        got = call("POST", "/api/game/laps", json.dumps(lap), token=token)
        check("relay: resent lap refused", got and got["status"] == 429, got and got["status"])
        got = call("POST", "/api/game/laps/withdraw", json.dumps({"route": "rinky-dink", "run": lap["run"]}), token=token)
        check("relay: run withdrawn", got and got["status"] == 200 and json.loads(got["body"])["withdrawn"] == 1, got)
    else:
        print("skip relay upload and lap tests (set BJL_TOKEN to a game token on that site)")
    for path in ["/../etc/passwd", "https://evil.example/x", "/api/x\"y"]:
        got = call("GET", path)
        check(f"relay: refuses {path}", got and got["status"] == 0, got)
    check("relay: no event holds a capital Z", all("Z" not in w for w in wire))
    check("relay: temp files cleaned", sorted(os.listdir(os.path.join(tmp, "tmp"))) == [".keep"], os.listdir(os.path.join(tmp, "tmp")))
    import shutil
    shutil.rmtree(tmp)


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
        # every point of the area on a 50 x 50 grid lies in some shot
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


syntax()
laps()
main_ext()
capture()
live()
server()
aerial()
if os.environ.get("BJL_SITE"):
    relay(os.environ["BJL_SITE"])
else:
    print("skip relay test (set BJL_SITE to a running BeamJoy Web, e.g. http://localhost:3000)")
print("\n" + ("all passed" if not failures else f"{failures} failed"))
sys.exit(1 if failures else 0)
