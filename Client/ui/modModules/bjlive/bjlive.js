// BeamJoy Live : the in-game window (toggle with Shift+F4 by default).
//
// Loaded by the game's UI like BeamJoy's own module (ui/modModules/<name>/<name>.js, an Angular
// module and a component of the same name). Web requests are built here and made by the server
// plugin (the game's UI may only connect to localhost). Lua (lua/ge/extensions/beamjoyLive)
// supplies the game's side : races, laps, screenshots, the road map, the live player list.

const lib = await import("/ui/modModules/bjlive/lib.js");

const bjlive = angular.module("bjlive", []);

bjlive.service("bjlLua", function ($rootScope) {
    /** Calls beamjoyLive_main.dispatch(event, args) in the game's Lua. */
    this.send = (event, ...args) => {
        if (!window.bngApi) return;
        bngApi.engineLua(
            `beamjoyLive_main.dispatch(${bngApi.serializeToLua(event)}, ${bngApi.serializeToLua(args)})`
        );
    };
    /** Lua's guihooks events, inside Angular's digest. */
    this.on = (scope, fn) =>
        scope.$on("$destroy", $rootScope.$on("BJLEvent", (_, data) => $rootScope.$applyAsync(() => fn(data.event, data.payload))));
});

const MAX_IMAGES = 8;
const MAX_RECENT = 10;

bjlive.component("bjlive", {
    templateUrl: "/ui/modModules/bjlive/app.html",
    controller: function ($scope, $timeout, $interval, bjlLua) {
        const ctrl = this;
        ctrl.lib = lib;
        ctrl.open = false;
        ctrl.tab = "account";
        ctrl.state = null; // from Lua : config, account, level, levelTitle, selfName, reporter
        ctrl.races = [];
        ctrl.recent = []; // this session's posted laps, newest first (bounded)
        ctrl.link = null; // { userCode, verifyUrl, deviceCode, expiresAt, status, error }
        ctrl.notice = null;

        const siteBase = () => (ctrl.state && ctrl.state.config && ctrl.state.config.siteUrl) || "";
        // The game's UI may only connect to localhost, so requests go through the server plugin;
        // a page that can reach the site itself (tools/ui-harness) sets BJL_DIRECT_FETCH.
        const relay = lib.relayTransport((...args) => bjlLua.send("http", ...args));
        const transport = window.BJL_DIRECT_FETCH
            ? lib.fetchTransport(siteBase, () => (ctrl.state && ctrl.state.account && ctrl.state.account.token) || null)
            : relay;
        const site = lib.createSite(siteBase, transport);
        ctrl.site = site;

        ctrl.siteUrl = (path = "") => ((ctrl.state && ctrl.state.config && ctrl.state.config.siteUrl) || "") + path;
        ctrl.openUrl = (url) => bjlLua.send("openUrl", url);
        ctrl.configured = () => !!(ctrl.state && ctrl.state.config && ctrl.state.config.siteUrl);
        ctrl.linked = () => !!(ctrl.state && ctrl.state.account);
        ctrl.vanilla = () => !!(ctrl.state && lib.VANILLA_LEVELS.includes(ctrl.state.level));

        // --- window ----------------------------------------------------------------------------
        const POS_KEY = "bjlive.windowPos";
        ctrl.pos = (() => {
            try {
                const p = JSON.parse(localStorage.getItem(POS_KEY));
                if (p && typeof p.x === "number" && typeof p.y === "number") return p;
            } catch (e) {}
            return { x: Math.max(16, window.innerWidth - 460), y: 120 };
        })();
        ctrl.toggle = (open = !ctrl.open) => {
            ctrl.open = open;
            bjlLua.send("setWindowOpen", open);
            if (open) bjlLua.send("ready");
        };
        ctrl.startDrag = (e) => {
            if (e.button !== 0 || e.target.closest("button")) return;
            const dx = e.clientX - ctrl.pos.x;
            const dy = e.clientY - ctrl.pos.y;
            const move = (ev) =>
                $scope.$applyAsync(() => {
                    ctrl.pos = {
                        x: Math.min(Math.max(0, ev.clientX - dx), window.innerWidth - 120),
                        y: Math.min(Math.max(0, ev.clientY - dy), window.innerHeight - 40),
                    };
                });
            const up = () => {
                window.removeEventListener("mousemove", move);
                window.removeEventListener("mouseup", up);
                try {
                    localStorage.setItem(POS_KEY, JSON.stringify(ctrl.pos));
                } catch (err) {}
            };
            window.addEventListener("mousemove", move);
            window.addEventListener("mouseup", up);
        };
        const flash = (text, kind = "info") => {
            ctrl.notice = { text, kind };
            $timeout.cancel(ctrl.noticeTimer);
            ctrl.noticeTimer = $timeout(() => (ctrl.notice = null), 6000);
        };

        // --- account ---------------------------------------------------------------------------
        let pollTimer = null;
        const stopPolling = () => {
            if (pollTimer) $timeout.cancel(pollTimer);
            pollTimer = null;
        };
        ctrl.startLink = async () => {
            stopPolling();
            ctrl.link = { status: "starting" };
            try {
                const res = await site.startLink(ctrl.state.selfName || "");
                $scope.$applyAsync(() => {
                    ctrl.link = { ...res, status: "waiting", expiresAt: Date.now() + res.expiresIn * 1000 };
                });
                ctrl.openUrl(res.verifyUrl);
                const poll = async () => {
                    if (!ctrl.link || ctrl.link.deviceCode !== res.deviceCode) return;
                    try {
                        const r = await site.pollLink(res.deviceCode);
                        if (r.status === "linked") {
                            ctrl.link = null;
                            bjlLua.send("saveAccount", r.token, r.user);
                            $scope.$applyAsync(() => (ctrl.tab = "upload"));
                            bjlLua.send("notify", `Linked to ${r.user.name}.`, "success");
                            return;
                        }
                        if (r.status === "expired") {
                            $scope.$applyAsync(() => (ctrl.link = { status: "expired" }));
                            return;
                        }
                    } catch (e) {
                        // a hiccup ; keep polling until the code expires
                    }
                    if (Date.now() < ctrl.link.expiresAt) pollTimer = $timeout(poll, (res.interval || 3) * 1000);
                    else $scope.$applyAsync(() => (ctrl.link = { status: "expired" }));
                };
                pollTimer = $timeout(poll, (res.interval || 3) * 1000);
            } catch (e) {
                $scope.$applyAsync(() => (ctrl.link = { status: "error", error: e.message }));
            }
        };
        ctrl.cancelLink = () => {
            stopPolling();
            ctrl.link = null;
        };
        ctrl.unlink = async () => {
            try {
                await site.unlink();
            } catch (e) {
                // revoked on the site already, or offline : forget it here either way
            }
            bjlLua.send("clearAccount");
        };
        // A token revoked on the site (Account page) : drop it.
        const checkAccount = async () => {
            if (!ctrl.linked() || !ctrl.configured()) return;
            try {
                const me = await site.me();
                $scope.$applyAsync(() => (ctrl.me = me.user));
            } catch (e) {
                if (e.status === 401) bjlLua.send("clearAccount");
            }
        };

        // --- races & upload --------------------------------------------------------------------
        ctrl.form = null; // the upload form for the picked race
        ctrl.pickRace = (id) => {
            ctrl.form = { raceId: id, loading: true, images: [], aerial: null, errors: {} };
            bjlLua.send("requestRace", id);
        };
        const matches = new Map(); // course key -> Promise<route|null>
        const courseKey = (c) => `${c.level}|${c.raceId}|${c.gates.length}|${(c.gates[0] || []).join(",")}|${(c.gates[c.gates.length - 1] || []).join(",")}`;
        const matchCourse = (course, fresh = false) => {
            const key = courseKey(course);
            if (fresh || !matches.has(key)) {
                matches.set(
                    key,
                    site
                        .match(course)
                        .then((r) => r.route)
                        .catch((e) => {
                            matches.delete(key);
                            throw e;
                        })
                );
            }
            return matches.get(key);
        };
        const onRace = async ({ id, race, course, missing }) => {
            if (!ctrl.form || ctrl.form.raceId !== id) return;
            if (missing) {
                ctrl.form = null;
                return flash("That race is gone.", "error");
            }
            Object.assign(ctrl.form, {
                loading: false,
                race,
                course,
                title: race.name || "",
                description: "",
                surface: "asphalt",
                tags: "",
                videoUrl: "",
                corners: "",
                mapName: (ctrl.state && ctrl.state.levelTitle) || "",
                mapDownloadUrl: "",
                listed: undefined,
            });
            try {
                const route = await matchCourse(course, true);
                $scope.$applyAsync(() => (ctrl.form && ctrl.form.raceId === id ? (ctrl.form.listed = route) : null));
            } catch (e) {
                $scope.$applyAsync(() => ctrl.form && (ctrl.form.listed = null));
            }
        };
        ctrl.capture = (kind) => {
            if (!ctrl.form) return;
            ctrl.form.capturing = kind;
            ctrl.hiddenForCapture = true;
            // the window hides itself, then Lua takes the picture
            $timeout(() => bjlLua.send(kind === "aerial" ? "captureAerial" : "captureScreenshot", ctrl.form.raceId), 150);
        };
        const onCaptured = async (c) => {
            ctrl.hiddenForCapture = false;
            if (!ctrl.form) return;
            ctrl.form.capturing = null;
            if (c.error) return flash(c.error, "error");
            try {
                if (c.kind === "aerial") {
                    const img = await lib.downscale(c.dataUrl, 2048, 0.8);
                    const bounds = lib.aerialBounds(c.center, c.halfHeight, img.width, img.height);
                    $scope.$applyAsync(() => (ctrl.form.aerial = { dataUrl: img.dataUrl, bounds }));
                } else {
                    // kept small : uploads travel through the server in BeamMP-sized pieces
                    const img = await lib.downscale(c.dataUrl, 1280, 0.8);
                    $scope.$applyAsync(() => {
                        if (ctrl.form.images.length < MAX_IMAGES) ctrl.form.images.push(img.dataUrl);
                    });
                }
            } catch (e) {
                $scope.$applyAsync(() => flash(e.message, "error"));
            }
        };
        ctrl.removeImage = (i) => ctrl.form.images.splice(i, 1);
        ctrl.upload = async () => {
            const f = ctrl.form;
            if (!f || f.uploading) return;
            f.uploading = true;
            f.errors = {};
            try {
                const res = await site.upload({
                    shareCode: await lib.raceShareCode(f.race),
                    title: f.title,
                    description: f.description,
                    surface: f.surface,
                    tags: f.tags,
                    videoUrl: f.videoUrl,
                    cornersOverride: f.corners === "" || f.corners == null ? undefined : Number(f.corners),
                    level: ctrl.state.level,
                    mapName: f.mapName,
                    mapDownloadUrl: f.mapDownloadUrl,
                    images: f.images,
                    aerial: f.aerial ? { data: f.aerial.dataUrl, bounds: f.aerial.bounds } : undefined,
                });
                $scope.$applyAsync(() => {
                    f.uploading = false;
                    f.done = res;
                    matches.delete(courseKey(f.course));
                });
                bjlLua.send("notify", `Uploaded "${f.title}".`, "success");
            } catch (e) {
                $scope.$applyAsync(() => {
                    f.uploading = false;
                    f.errors = (e.body && e.body.errors) || { form: e.message };
                });
            }
        };
        ctrl.replaceAerial = async () => {
            const f = ctrl.form;
            if (!f || !f.listed || !f.aerial) return;
            f.uploading = true;
            try {
                await site.replaceAerial(f.listed.slug, { data: f.aerial.dataUrl, bounds: f.aerial.bounds });
                $scope.$applyAsync(() => {
                    f.uploading = false;
                    flash("Aerial updated on the site.", "success");
                });
            } catch (e) {
                $scope.$applyAsync(() => {
                    f.uploading = false;
                    flash(e.message, "error");
                });
            }
        };

        // --- laps -------------------------------------------------------------------------------
        ctrl.board = null; // { route, entries } for the race last driven
        let lapQueue = Promise.resolve();
        const loadBoard = async (route) => {
            try {
                const b = await site.leaderboard(route.slug, "lap", 10);
                $scope.$applyAsync(() => (ctrl.board = { route, ...b }));
            } catch (e) {}
        };
        ctrl.refreshBoard = () => ctrl.board && loadBoard(ctrl.board.route);
        const onLap = (lap) => {
            lapQueue = lapQueue.then(async () => {
                const entry = { name: lap.course.name, lapMs: lap.lapMs, at: Date.now() };
                try {
                    const route = await matchCourse(lap.course);
                    if (!route) {
                        entry.status = "unlisted";
                    } else {
                        entry.route = route;
                        let res;
                        for (let attempt = 0; ; attempt++) {
                            try {
                                res = await site.lap({
                                    route: route.slug,
                                    lapMs: lap.lapMs,
                                    sectors: lap.sectors || undefined,
                                    vehicle: lap.vehicle,
                                    playerName: lap.playerName,
                                    kind: lap.kind,
                                });
                                break;
                            } catch (e) {
                                if (e.status !== 0 || attempt >= 2) throw e;
                                await new Promise((r) => setTimeout(r, 3000));
                            }
                        }
                        Object.assign(entry, { status: "posted", ...res });
                        const tag = res.isRecord ? " · new record!" : res.isPB ? " · new PB" : "";
                        bjlLua.send(
                            "notify",
                            `${lib.formatLap(lap.lapMs)} on ${route.title} · P${res.rank} of ${res.drivers}${tag}`,
                            res.isRecord || res.isPB ? "success" : "info"
                        );
                        loadBoard(route);
                    }
                } catch (e) {
                    entry.status = "failed";
                    entry.error = e.message;
                }
                $scope.$applyAsync(() => {
                    ctrl.recent.unshift(entry);
                    ctrl.recent.length = Math.min(ctrl.recent.length, MAX_RECENT);
                });
            });
        };

        // --- road map & live session ------------------------------------------------------------
        const roadsChecked = new Set();
        const checkRoads = async () => {
            const level = ctrl.state && ctrl.state.level;
            if (!level || roadsChecked.has(level) || !ctrl.linked() || !ctrl.configured()) return;
            roadsChecked.add(level);
            try {
                const info = await site.level(level);
                if (!info.roads) bjlLua.send("requestRoads");
            } catch (e) {
                roadsChecked.delete(level);
            }
        };
        const onRoads = async ({ level, map }) => {
            if (!map || !level) return;
            try {
                await site.uploadRoads(level, map);
            } catch (e) {
                roadsChecked.delete(level);
            }
        };
        let liveBusy = false;
        ctrl.liveStatus = null;
        const onLiveReport = async (payload) => {
            if (liveBusy) return;
            liveBusy = true;
            try {
                const res = await site.live(payload);
                $scope.$applyAsync(() => (ctrl.liveStatus = { ok: true, url: res.url, at: Date.now() }));
            } catch (e) {
                $scope.$applyAsync(() => (ctrl.liveStatus = { ok: false, error: e.message, at: Date.now() }));
            }
            liveBusy = false;
        };

        // --- Lua events -------------------------------------------------------------------------
        let hinted = false;
        let lastToken = null;
        bjlLua.on($scope, (event, payload) => {
            switch (event) {
                case "BJLState": {
                    ctrl.state = payload;
                    const token = (payload && payload.account && payload.account.token) || null;
                    if (!token) {
                        ctrl.me = null;
                        lastToken = null;
                    } else if (token !== lastToken && ctrl.configured()) {
                        lastToken = token;
                        checkAccount();
                    }
                    if (ctrl.configured() && !hinted) {
                        hinted = true;
                        if (!ctrl.linked()) bjlLua.send("notify", "BeamJoy Live : press Shift+F4 to link your account.", "info");
                    }
                    checkRoads();
                    break;
                }
                case "BJLRaces":
                    ctrl.races = Array.isArray(payload) ? payload : [];
                    break;
                case "BJLRace":
                    onRace(payload);
                    break;
                case "BJLCaptured":
                    onCaptured(payload);
                    break;
                case "BJLLap":
                    onLap(payload);
                    break;
                case "BJLRoads":
                    onRoads(payload);
                    break;
                case "BJLLiveReport":
                    onLiveReport(payload);
                    break;
                case "BJLHttpResult":
                    relay.deliver(payload || {});
                    break;
                case "BJLToggle":
                    ctrl.toggle();
                    break;
                case "BJLUnload":
                    ctrl.state = null;
                    ctrl.open = false;
                    stopPolling();
                    break;
            }
        });

        ctrl.$onInit = () => {
            // Lua may have pushed its state before this window existed : ask again.
            $timeout(() => bjlLua.send("ready"), 300);
        };
        ctrl.$onDestroy = stopPolling;
    },
});

// The game's UI creates <bjlive> for this module like it does <beamjoy>. Should a game version
// not, mount it ourselves once Angular is up.
bjlive.run(function ($rootScope, $compile, $timeout) {
    $timeout(() => {
        if (document.querySelector("bjlive")) return;
        const el = angular.element("<bjlive></bjlive>");
        document.body.appendChild(el[0]);
        $compile(el)($rootScope);
    }, 3000);
});
