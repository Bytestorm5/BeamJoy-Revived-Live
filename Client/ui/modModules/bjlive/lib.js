// BeamJoy Live : helpers with no Angular in them (also loaded by tools/ui-harness for testing).

// --- share codes -----------------------------------------------------------------------------
// The same "BJRACE1:" code BeamJoy-Revived's race editor copies (windows/config/races/editor):
// the portable part of the race, numbers rounded to millimetres, gzipped, base64. The site
// decodes it exactly like a pasted code.
export const RACE_SHARE_CODE_PREFIX = "BJRACE1:";

const round3 = (v) => {
    if (typeof v === "number") return Math.round(v * 1000) / 1000;
    if (Array.isArray(v)) return v.map(round3);
    if (v && typeof v === "object") {
        const out = {};
        Object.keys(v).forEach((k) => (out[k] = round3(v[k])));
        return out;
    }
    return v;
};

// Lua tables that should be arrays come through as objects when empty ; the editor's code has
// arrays there
const list = (v) => (Array.isArray(v) ? v : v && typeof v === "object" ? Object.values(v) : []);

export function portableRace(race) {
    const payload = round3({
        name: race.name,
        mode: race.mode,
        loopable: race.loopable,
        freeroam: race.freeroam,
        sectorCount: race.sectorCount,
        manualSectors: race.manualSectors,
        branchingEnabled: race.branchingEnabled,
        oneWayGates: race.oneWayGates,
        gates: list(race.gates),
        startPositions: list(race.startPositions),
        props: list(race.props),
        defaults: race.defaults,
    });
    payload.gates.forEach((g) => delete g.step);
    return payload;
}

const bytesToBase64 = (bytes) => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
};

export async function gzip(text) {
    const stream = new Blob([new TextEncoder().encode(text)]).stream().pipeThrough(new CompressionStream("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function raceShareCode(race) {
    return RACE_SHARE_CODE_PREFIX + bytesToBase64(await gzip(JSON.stringify(portableRace(race))));
}

// --- images ----------------------------------------------------------------------------------

const loadImage = (src) =>
    new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error("Couldn't read the picture."));
        img.src = src;
    });

/** A screenshot as a JPEG data URL no wider/taller than `max`, plus its size. */
export async function downscale(dataUrl, max = 1600, quality = 0.85) {
    const img = await loadImage(dataUrl);
    const scale = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
    const w = Math.round(img.naturalWidth * scale);
    const h = Math.round(img.naturalHeight * scale);
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    canvas.getContext("2d").drawImage(img, 0, 0, w, h);
    return { dataUrl: canvas.toDataURL("image/jpeg", quality), width: w, height: h };
}

/**
 * The world box an aerial covers, from the camera's centre and half the ground height it saw
 * (the game uses a vertical field of view) and the picture's real shape.
 */
export function aerialBounds(center, halfHeight, width, height) {
    const halfWidth = halfHeight * (width / height);
    return [center[0] - halfWidth, center[1] - halfHeight, center[0] + halfWidth, center[1] + halfHeight];
}

// --- formatting ------------------------------------------------------------------------------

export function formatLap(ms) {
    if (typeof ms !== "number") return "–";
    const neg = ms < 0;
    let t = Math.abs(Math.round(ms));
    const msPart = String(t % 1000).padStart(3, "0");
    t = Math.floor(t / 1000);
    const s = t % 60;
    const m = Math.floor(t / 60) % 60;
    const h = Math.floor(t / 3600);
    const body = h
        ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}.${msPart}`
        : m
          ? `${m}:${String(s).padStart(2, "0")}.${msPart}`
          : `${s}.${msPart}`;
    return (neg ? "-" : "") + body;
}

/** Base-game levels (the site lists these maps by itself ; others need a name and a link). */
export const VANILLA_LEVELS = [
    "west_coast_usa", "east_coast_usa", "italy", "utah", "jungle_rock_island", "johnson_valley",
    "industrial", "hirochi_raceway", "automation_test_track", "small_island", "derby",
    "driver_training", "gridmap_v2", "smallgrid",
];

export const SURFACES = [
    ["asphalt", "Asphalt"],
    ["gravel", "Gravel"],
    ["dirt", "Dirt"],
    ["mixed", "Mixed"],
    ["offroad", "Off-road"],
    ["snow", "Snow / ice"],
];

// --- the site --------------------------------------------------------------------------------

export class SiteError extends Error {
    constructor(message, status, body) {
        super(message);
        this.status = status;
        this.body = body;
    }
}

/** JSON with every non-ASCII character escaped, so it can be cut into pieces anywhere. */
export const asciiJson = (value) =>
    JSON.stringify(value).replace(/[\u007f-￿]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));

/**
 * Plain fetch, for a page allowed to connect to the site (the UI harness). The game's UI isn't:
 * its Content Security Policy only allows localhost, so in game requests go through the relay.
 */
export function fetchTransport(getBase, getToken) {
    return async ({ method, path, body, contentType, timeout }) => {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), timeout);
        const headers = {};
        const token = getToken();
        if (token) headers.Authorization = `Bearer ${token}`;
        if (body !== undefined) headers["Content-Type"] = contentType || "application/json";
        try {
            const res = await fetch(getBase() + path, { method, headers, body, signal: ctrl.signal });
            return { status: res.status, text: await res.text() };
        } catch (e) {
            return { status: 0, text: JSON.stringify({ error: e.name === "AbortError" ? "The site didn't answer in time." : "Couldn't reach the site." }) };
        } finally {
            clearTimeout(timer);
        }
    };
}

/**
 * Through the server plugin (Server/BeamJoyLive/main.lua, "Web relay"): `send` hands the request
 * to the game's Lua, which adds the player's token; `deliver` is called with each answer.
 */
export function relayTransport(send) {
    const pending = new Map();
    const transport = ({ method, path, body, contentType, timeout }) =>
        new Promise((resolve) => {
            let id;
            do id = Math.floor(Math.random() * 1e9) + 1;
            while (pending.has(id));
            const timer = setTimeout(() => {
                pending.delete(id);
                resolve({ status: 0, text: JSON.stringify({ error: "The site didn't answer in time." }) });
            }, timeout + 10000);
            pending.set(id, (status, text) => {
                clearTimeout(timer);
                pending.delete(id);
                resolve({ status, text });
            });
            send(id, method, path, body || "", contentType || "");
        });
    transport.deliver = ({ id, status, body }) => {
        const done = pending.get(id);
        if (done) done(Number(status) || 0, body || "");
    };
    return transport;
}

/** BeamJoy Web's game API, over a transport (see above). */
export function createSite(getBase, transport) {
    const request = async (method, path, body, { timeout = 20000 } = {}) => {
        if (!getBase()) throw new SiteError("This server hasn't set up BeamJoy Live.", 0);
        const res = await transport({ method, path, body: body === undefined ? undefined : asciiJson(body), timeout });
        let data = null;
        try {
            data = JSON.parse(res.text);
        } catch (e) {
            data = null;
        }
        if (res.status === 0) throw new SiteError((data && data.error) || "Couldn't reach the site.", 0);
        if ((res.status < 200 || res.status >= 300) && !(data && data.status === "expired")) {
            const fieldErrors = data && data.errors ? Object.values(data.errors).join(" ") : null;
            throw new SiteError(fieldErrors || (data && data.error) || `The site said ${res.status}.`, res.status, data);
        }
        return data;
    };
    return {
        startLink: (playerName) => request("POST", "/api/game/link", { playerName }),
        pollLink: (deviceCode) => request("POST", "/api/game/link/poll", { deviceCode }),
        me: () => request("GET", "/api/game/me"),
        unlink: () => request("DELETE", "/api/game/me"),
        match: (course) => request("POST", "/api/game/routes/match", course),
        upload: (body) => request("POST", "/api/game/routes", body, { timeout: 120000 }),
        replaceAerial: (slug, body) =>
            request("POST", `/api/game/routes/${encodeURIComponent(slug)}/aerial`, body, { timeout: 60000 }),
        lap: (body) => request("POST", "/api/game/laps", body),
        leaderboard: (slug, sort = "lap", size = 10) =>
            request("GET", `/api/routes/${encodeURIComponent(slug)}/leaderboard?sort=${sort}&size=${size}`),
        level: (level) => request("GET", `/api/game/levels/${encodeURIComponent(level)}`),
        uploadRoads: (level, map) =>
            request("POST", `/api/game/levels/${encodeURIComponent(level)}/roads`, map, { timeout: 120000 }),
        live: (body) => request("POST", "/api/game/live", body, { timeout: 8000 }),
    };
}
