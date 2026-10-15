"""
Unit tests for the mod's Lua, run outside the game with fakes for the game's and BeamMP's APIs.
Needs Python 3 and lupa (pip install lupa), which bundles LuaJIT (the game's VM) and Lua 5.4
(close to the BeamMP server's).

    python3 tools/lua_tests.py
    BJL_SITE=http://localhost:3000 python3 tools/lua_tests.py   # also the web relay, with curl
"""
import base64
import json
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
        beamjoyLive_main = {
            config = { siteUrl = "https://site", leaderboards = true },
            account = { token = "bjl_x" },
            selfName = function() return "Me" end,
            findRace = function(id) return { id = id, name = "Test", gates = {} } end,
            course = function(race) return { raceId = race.id, name = race.name } end,
            send = function(event, payload) table.insert(sent, { event = event, payload = payload }) end,
        }
        be = { getPlayerVehicle = function() return { getJBeamFilename = function() return "etk800" end } end }
    """)
    m = load_ext(rt, "laps")
    session = rt.eval("""function(id, laps, history, dq)
        return { id = id, raceId = 7, participants = {
            { playerName = "Other", lapTimes = { 1000 } },
            { playerName = "Me", lapTimes = laps, lapSectorHistory = history, vehicleModel = "sunburst", disqualified = dq },
        } }
    end""")
    t = rt.table
    count = rt.eval("function() return #sent end")
    m.onSessionUpdate(session("s1", t(), t()))
    check("laps: nothing sent at the grid", count() == 0)
    m.onSessionUpdate(session("s1", t(91000.4), t(t(30000, 31000, 30000.4))))
    check("laps: first lap handed on", count() == 1, count())
    last = rt.eval("function() return sent[#sent].payload end")()
    check("laps: lap time rounded", last.lapMs == 91000, last.lapMs)
    check("laps: sectors in order", list(last.sectors.values()) == [30000, 31000, 30000], list(last.sectors.values()) if last.sectors else None)
    check("laps: grid kind", last.kind == "grid")
    m.onSessionUpdate(session("s1", t(91000, 90500), t(t(30000, 31000, 30000), rt.table_from({"1": 30000, "2": 30000, "3": 30500}))))
    last = rt.eval("function() return sent[#sent].payload end")()
    check("laps: second lap, string-keyed sectors", count() == 2 and list(last.sectors.values()) == [30000, 30000, 30500])
    m.onSessionUpdate(session("s1", t(91000, 90500), t()))
    check("laps: repeated update sends nothing", count() == 2)
    m.onSessionUpdate(session("s2", t(80000, 81000), t()))
    check("laps: joining a race under way skips its old laps", count() == 2)
    m.onSessionUpdate(session("s2", t(80000, 81000, 82000), t(), True))
    check("laps: disqualified laps aren't sent", count() == 2)
    m.onFreeroamResult(7, rt.eval("{ timeMs = 65432 }"))
    last = rt.eval("function() return sent[#sent].payload end")()
    check("laps: freeroam run", count() == 3 and last.kind == "freeroam" and last.lapMs == 65432)
    rt.execute("beamjoyLive_main.account = nil")
    m.onFreeroamResult(7, rt.eval("{ timeMs = 65432 }"))
    check("laps: not linked, nothing sent", count() == 3)


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
            participants = { { playerName = "Me", currentLap = 2 } } } }
    """)
    m = load_ext(rt, "live")
    snap = {p.name: p for p in m.snapshot().values()}
    check("live: everyone listed", sorted(snap) == ["Bob", "Me", "Watcher"], sorted(snap))
    me = snap["Me"]
    check("live: own car, speed, heading", me.vehicle == "etk800" and abs(me.speed - 5) < 1e-9 and abs(me.heading - 90) < 1e-9, (me.vehicle, me.speed, me.heading))
    check("live: own activity", me.activity == "Racing GP · lap 2/3", me.activity)
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

    def to_server(event, data):
        wire.append(data)
        server.globals()["BJL_onHttp" if event == "BJLHttp" else "BJL_onHttpPart"](1, data)

    def to_client(pid, event, data):
        wire.append(data)
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

    def call(method, path, body="", token=None):
        main.account = client.table_from({"token": token}) if token else None
        rid = random.randint(1, 10**9)
        main.http(rid, method, path, body, "application/json" if body else "")
        for _ in range(300):
            for msg in ui:
                if msg["event"] == "BJLHttpResult" and msg["payload"]["id"] == rid:
                    return msg["payload"]
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
    for path in ["/../etc/passwd", "https://evil.example/x", "/api/x\"y"]:
        got = call("GET", path)
        check(f"relay: refuses {path}", got and got["status"] == 0, got)
    check("relay: no event holds a capital Z", all("Z" not in w for w in wire))
    check("relay: temp files cleaned", sorted(os.listdir(os.path.join(tmp, "tmp"))) == [".keep"], os.listdir(os.path.join(tmp, "tmp")))
    import shutil
    shutil.rmtree(tmp)


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
capture()
live()
server()
if os.environ.get("BJL_SITE"):
    relay(os.environ["BJL_SITE"])
else:
    print("skip relay test (set BJL_SITE to a running BeamJoy Web, e.g. http://localhost:3000)")
print("\n" + ("all passed" if not failures else f"{failures} failed"))
sys.exit(1 if failures else 0)
