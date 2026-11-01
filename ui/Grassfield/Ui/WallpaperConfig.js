.pragma library

// Wallpaper settings and rules (Settings > Wallpaper, ADR-0016). Pure functions, no I/O, shared by the Settings app
// (validation of what it writes), the shell (what it reads, the carousel order, the pause policy) and the tests.
// Registered as WallpaperConfig in qmldir (the shell has its own Wallpaper type). Untrusted input: every value read from
// grassfield.json goes through normalize(); an invalid field reads as its default, never as an error.

const SOURCES = ["builtin", "color", "file", "folder", "video", "online"];
// The Grassfield artworks (ADR-0040 step 2, ID-1) and the choice of variant: Time of Day (the Grassfield artwork only),
// Automatic (by the appearance), Light, Dark.
const ARTWORKS = ["grassfield", "meadow", "rows", "ridgeline"];
const ARTWORK_VARIANTS = ["timeOfDay", "automatic", "light", "dark"];
// Online daily pictures (ADR-0016 step 2): the Wikimedia Commons picture of the day and NASA's APOD. A provider is a name here
// and a `fetch <provider>` subcommand of the helper.
const ONLINE_PROVIDERS = ["commons", "apod"];
// Video files the Settings pickers offer (ffprobe decides what it can actually read).
const VIDEO_SUFFIXES = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ogv"];
const FITS = ["fill", "fit", "stretch", "center", "tile"];
// Interval name to milliseconds ("login" changes the picture once, at shell start: 0 means no timer).
const INTERVALS = {"login": 0, "5s": 5000, "1m": 60000, "5m": 300000, "15m": 900000, "30m": 1800000, "1h": 3600000, "1d": 86400000};
const INTERVAL_NAMES = ["login", "5s", "1m", "5m", "15m", "30m", "1h", "1d"];
const MAX_PATH_BYTES = 4096;
const MAX_OUTPUTS = 16;
const MAX_NAME_CHARS = 128;

// A video wallpaper uses fill or fit only (ADR-0016 section 1).
const VIDEO_FITS = ["fill", "fit"];

const WALLPAPER_DEFAULTS = {
    source: "builtin",
    path: "",
    color: "#000000",
    fit: "fill",
    interval: "1h",
    shuffle: true,
    videoOnBattery: false,
    online: {provider: "commons"},
    artwork: "grassfield",
    artworkVariant: "timeOfDay",
    moving: false,
    outputs: []
};

// Helper exit codes (apps/wallpaper-tool) and the failure each one means (ids; the UI translates them).
const EXIT = {OK: 0, USAGE: 2, NOT_FOUND: 3, NOT_REGULAR: 4, TOO_LARGE_FILE: 5, TOO_LARGE_PICTURE: 6, UNREADABLE: 7, UNSUPPORTED: 8, TIMEOUT: 9, WRITE: 10, NETWORK: 11, SKIPPED: 12, BAD_RESPONSE: 13, VIDEO_TOO_LONG: 14, TRANSCODE_FAILED: 15, FFMPEG_MISSING: 16, CANCELLED: 17, MISSING: 127};
const REASONS = {
    3: "not-found",
    4: "not-regular",
    5: "too-large",
    6: "too-large",
    7: "unreadable",
    8: "unsupported",
    9: "timeout",
    10: "write",
    11: "network",
    12: "skipped",
    13: "bad-response",
    14: "video-too-long",
    15: "transcode-failed",
    16: "ffmpeg-missing",
    17: "cancelled",
    127: "helper-missing"
};

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// A list as a real array, or null. The JSON adapter hands out a QVariantList as a sequence object that is not an Array
// (Array.isArray is false; length and indices work; its prototype is the sequence's own, not Object.prototype). A plain
// object, which is what a JSON object such as {"length": 1, "0": {...}} becomes, is NOT a list. At most `cap` items are
// read, so that a hostile length is harmless. Every item is validated by its own rules afterwards.
function asArray(v, cap) {
    if (Array.isArray(v))
        return v.slice(0, cap);
    if (v === null || typeof v !== "object" || Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null)
        return null;
    if (typeof v.length !== "number" || v.length < 0 || Math.floor(v.length) !== v.length)
        return null;
    const out = [];
    const n = Math.min(v.length, cap);
    for (let i = 0; i < n; i++)
        out.push(v[i]);
    // The real length is kept visible to the caller through a property (too-many is decided on it).
    out.realLength = v.length;
    return out;
}

function oneOf(list, v) {
    return typeof v === "string" && list.indexOf(v) >= 0;
}

// UTF-8 length of a string in bytes (surrogate pairs are one 4-byte character; a lone surrogate counts as 3).
function utf8Length(s) {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x80) {
            n += 1;
        } else if (c < 0x800) {
            n += 2;
        } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xdc00 && s.charCodeAt(i + 1) <= 0xdfff) {
            n += 4;
            i++;
        } else {
            n += 3;
        }
    }
    return n;
}

// True when `s` holds a control character (C0, DEL, C1), a line or paragraph separator (U+2028, U+2029) or a bidi
// override or isolate (U+202A-U+202E, U+2066-U+2069) or a directional mark (U+200E, U+200F, U+061C). Tested by code, not by a regular expression, so that the source
// holds no invisible character.
function hasForbiddenChar(s) {
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c <= 0x1f || (c >= 0x7f && c <= 0x9f) || c === 0x061c || c === 0x200e || c === 0x200f || c === 0x2028 || c === 0x2029 || (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069))
            return true;
    }
    return false;
}

// "" when `path` is an acceptable absolute path, else the reason id. Control characters (C0, DEL, C1), the Unicode line and
// paragraph separators and bidi overrides are refused: the path is shown to the user and passed to a process.
function pathProblem(path) {
    if (typeof path !== "string")
        return "not-a-string";
    if (path === "")
        return "empty";
    if (path.charAt(0) !== "/")
        return "not-absolute";
    if (hasForbiddenChar(path))
        return "control-characters";
    if (utf8Length(path) > MAX_PATH_BYTES)
        return "too-long";
    return "";
}

function validPath(path) {
    return pathProblem(path) === "";
}

function validColor(value) {
    return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value);
}

function validDisplay(d) {
    if (!isPlainObject(d))
        return false;
    for (const key of Object.keys(d)) {
        if (["name", "model", "serial"].indexOf(key) < 0)
            return false;
    }
    for (const key of ["name", "model", "serial"]) {
        if (typeof d[key] !== "string" || d[key].length > MAX_NAME_CHARS || /[\u0000-\u001f\u007f-\u009f]/.test(d[key]))
            return false;
    }
    return d.name !== "" || (d.model !== "" && d.serial !== "");
}

// Reason ("" when valid) for one overrides entry: {display: {name, model, serial}, source?, path?, color?, fit?, interval?, shuffle?}.
function outputProblem(entry) {
    if (!isPlainObject(entry))
        return "not-an-object";
    const known = ["display", "source", "path", "color", "fit", "interval", "shuffle"];
    for (const key of Object.keys(entry)) {
        if (known.indexOf(key) < 0)
            return "unknown key " + key;
    }
    if (!validDisplay(entry.display))
        return "display";
    if ("source" in entry && !oneOf(SOURCES, entry.source))
        return "source";
    if ("path" in entry && entry.path !== "" && !validPath(entry.path))
        return "path";
    if ("color" in entry && !validColor(entry.color))
        return "color";
    if ("fit" in entry && !oneOf(FITS, entry.fit))
        return "fit";
    if ("interval" in entry && !oneOf(INTERVAL_NAMES, entry.interval))
        return "interval";
    if ("shuffle" in entry && typeof entry.shuffle !== "boolean")
        return "shuffle";
    return "";
}

// "" when `list` is a valid outputs array (at most MAX_OUTPUTS valid entries, no display twice), else the reason.
function outputsProblem(raw) {
    const list = asArray(raw, MAX_OUTPUTS + 1);
    if (list === null)
        return "not-an-array";
    if (list.length > MAX_OUTPUTS || (list.realLength || 0) > MAX_OUTPUTS)
        return "too-many";
    const seen = {};
    for (let i = 0; i < list.length; i++) {
        const why = outputProblem(list[i]);
        if (why !== "")
            return "entry " + i + ": " + why;
        const k = displayKey(list[i].display);
        if (seen[k])
            return "entry " + i + ": duplicate display";
        seen[k] = true;
    }
    return "";
}

// Identity of a display: model and serial when the serial is not empty (the connector can change between boots or ports),
// else the connector name.
function displayKey(d) {
    if (d && d.serial && d.model)
        return "s:" + d.model + "|" + d.serial;
    return "n:" + (d && d.name ? d.name : "");
}

function sameDisplay(a, b) {
    return displayKey(a) === displayKey(b);
}

// Copy of a valid outputs entry with only its known keys (the stored object is never handed on as it is).
function cleanOutput(entry) {
    const out = {display: {name: entry.display.name, model: entry.display.model, serial: entry.display.serial}};
    for (const key of ["source", "path", "color", "fit", "interval", "shuffle"]) {
        if (key in entry)
            out[key] = entry[key];
    }
    return out;
}

// The stored outputs array to the valid entries (an invalid entry or a repeated display is dropped, the list is capped).
function normalizeOutputs(raw) {
    const out = [];
    const list = asArray(raw, 1024);
    if (list === null)
        return out;
    const seen = {};
    for (const entry of list) {
        if (out.length >= MAX_OUTPUTS)
            break;
        if (outputProblem(entry) !== "")
            continue;
        const k = displayKey(entry.display);
        if (seen[k])
            continue;
        seen[k] = true;
        out.push(cleanOutput(entry));
    }
    return out;
}

// A stored "wallpaper" object (any JSON) to the complete, valid settings. Each invalid field reads as its default.
// A source that needs a path (file, folder, video) without a valid one reads as the built-in artwork.
function normalize(raw) {
    const r = isPlainObject(raw) ? raw : {};
    const out = {
        source: oneOf(SOURCES, r.source) ? r.source : WALLPAPER_DEFAULTS.source,
        path: validPath(r.path) ? r.path : WALLPAPER_DEFAULTS.path,
        color: validColor(r.color) ? r.color.toLowerCase() : WALLPAPER_DEFAULTS.color,
        fit: oneOf(FITS, r.fit) ? r.fit : WALLPAPER_DEFAULTS.fit,
        interval: oneOf(INTERVAL_NAMES, r.interval) ? r.interval : WALLPAPER_DEFAULTS.interval,
        shuffle: typeof r.shuffle === "boolean" ? r.shuffle : WALLPAPER_DEFAULTS.shuffle,
        videoOnBattery: typeof r.videoOnBattery === "boolean" ? r.videoOnBattery : WALLPAPER_DEFAULTS.videoOnBattery,
        online: {provider: isPlainObject(r.online) && oneOf(ONLINE_PROVIDERS, r.online.provider) ? r.online.provider : WALLPAPER_DEFAULTS.online.provider},
        artwork: oneOf(ARTWORKS, r.artwork) ? r.artwork : WALLPAPER_DEFAULTS.artwork,
        artworkVariant: oneOf(ARTWORK_VARIANTS, r.artworkVariant) ? r.artworkVariant : WALLPAPER_DEFAULTS.artworkVariant,
        moving: typeof r.moving === "boolean" ? r.moving : WALLPAPER_DEFAULTS.moving,
        outputs: normalizeOutputs(r.outputs)
    };
    return settle(out);
}

// Applies the cross-field rules to one settings object (top level or merged for a display).
function settle(s) {
    const out = Object.assign({}, s);
    if ((out.source === "file" || out.source === "folder" || out.source === "video") && out.path === "")
        out.source = "builtin";
    if (out.source === "video" && VIDEO_FITS.indexOf(out.fit) < 0)
        out.fit = "fill";
    return out;
}

// Effective settings of one display: the top level, overridden by that display's entry (when it has one).
// `display` is {name, model, serial}. Never returns the outputs list.
function resolve(cfg, display) {
    const base = normalize(cfg);
    const out = {
        source: base.source,
        path: base.path,
        color: base.color,
        fit: base.fit,
        interval: base.interval,
        shuffle: base.shuffle,
        videoOnBattery: base.videoOnBattery,
        provider: base.online.provider,
        // The artwork and its variant are chosen for every display (Settings > Wallpaper's Grassfield section, ADR-0040 step 2).
        artwork: base.artwork,
        artworkVariant: base.artworkVariant,
        moving: base.moving
    };
    for (const entry of base.outputs) {
        if (!sameDisplay(entry.display, display))
            continue;
        for (const key of ["source", "path", "color", "fit", "interval", "shuffle"]) {
            if (key in entry)
                out[key] = key === "color" ? entry[key].toLowerCase() : entry[key];
        }
        break;
    }
    return settle(out);
}

// The stored list with the entry of `display` replaced (or added) by the fields in `fields`; a null `fields` removes it.
// Returns a new list; an overflow (more than MAX_OUTPUTS) leaves the list as it was.
function withOutput(list, display, fields) {
    const base = normalizeOutputs(list);
    const next = [];
    let found = false;
    for (const entry of base) {
        if (sameDisplay(entry.display, display)) {
            found = true;
            if (fields !== null)
                next.push(cleanOutput(Object.assign({}, entry, fields, {display: entry.display})));
        } else {
            next.push(entry);
        }
    }
    if (!found && fields !== null) {
        if (next.length >= MAX_OUTPUTS)
            return base;
        next.push(cleanOutput(Object.assign({}, fields, {display: {name: display.name || "", model: display.model || "", serial: display.serial || ""}})));
    }
    return next;
}

// True when the display has a wallpaper of its own: its entry chooses a source or a path (a picture, a video, a colour, the
// artwork). An entry that only sets Fit, Colour, interval or shuffle follows All Displays for the wallpaper itself.
function sourceOverridden(list, display) {
    return normalizeOutputs(list).some(e => sameDisplay(e.display, display) && ("source" in e || "path" in e));
}

// The stored list with the source and path of the display's entry removed (the display follows All Displays again); what it set
// besides (Fit, Colour, interval, shuffle) stays. An entry left with nothing but its display is removed.
function withoutSource(list, display) {
    const out = [];
    for (const entry of normalizeOutputs(list)) {
        if (!sameDisplay(entry.display, display)) {
            out.push(entry);
            continue;
        }
        const kept = Object.assign({}, entry);
        delete kept.source;
        delete kept.path;
        if (Object.keys(kept).some(k => k !== "display"))
            out.push(cleanOutput(kept));
    }
    return out;
}

function intervalMs(name) {
    return oneOf(INTERVAL_NAMES, name) ? INTERVALS[name] : INTERVALS[WALLPAPER_DEFAULTS.interval];
}

// ---- carousel ----

// Deterministic generator (mulberry32) in [0, 1) from an integer seed: the shuffle is stable for a stored seed.
function rng(seed) {
    let a = seed >>> 0;
    return function () {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function byName(a, b) {
    return a < b ? -1 : a > b ? 1 : 0;
}

// The order in which a folder's pictures are shown during one cycle: names sorted (stable), then, with `shuffle`, a
// Fisher-Yates permutation seeded by `seed`. With `avoid` (the picture shown last in the previous cycle) the first
// picture of a shuffled cycle is never `avoid` unless it is the only one: no repeat across the cycle border.
function cycleOrder(files, shuffle, seed, avoid) {
    const list = files.slice().sort(byName);
    if (!shuffle || list.length < 2)
        return list;
    const next = rng(seed);
    for (let i = list.length - 1; i > 0; i--) {
        const j = Math.floor(next() * (i + 1));
        const t = list[i];
        list[i] = list[j];
        list[j] = t;
    }
    if (avoid !== undefined && list[0] === avoid) {
        const t = list[0];
        list[0] = list[list.length - 1];
        list[list.length - 1] = t;
    }
    return list;
}

// Next picture of a carousel. state = {seed, index, last}: `index` is the position in the current cycle. Returns
// {file, state}: when the cycle is over (or the list changed under it) a new cycle starts with seed + 1. Pictures that
// joined the folder appear from the next cycle on; one that was removed is skipped. `bad` is a set {path: true} of files
// that failed this session. With no usable file the result has file "".
function advance(files, shuffle, state, bad) {
    const st = {
        seed: state && typeof state.seed === "number" ? state.seed : 1,
        index: state && typeof state.index === "number" ? state.index : 0,
        last: state && typeof state.last === "string" ? state.last : "",
        avoid: state && typeof state.avoid === "string" ? state.avoid : ""
    };
    const usable = files.filter(f => !(bad && bad[f]));
    if (usable.length === 0)
        return {file: "", state: st};
    // `avoid` is fixed for a whole cycle (the picture that ended the previous one), so the order is the same on every call.
    let order = cycleOrder(usable, shuffle, st.seed, st.avoid);
    if (st.index >= order.length) {
        st.seed += 1;
        st.index = 0;
        st.avoid = st.last;
        order = cycleOrder(usable, shuffle, st.seed, st.avoid);
    }
    const file = order[st.index];
    st.index += 1;
    st.last = file;
    return {file: file, state: st};
}

// The picture a folder wallpaper keeps showing at start instead of advancing (macOS: the wallpaper does not change just
// because the shell restarted). `state` is the stored {last, changedAt, loginKey}; "" means advance. With a timed interval
// the picture stays until the interval has elapsed since the last change; with "login" (intervalMs 0) it stays while the
// login is the same one (`loginKey` names the running login: the compositor's instance, "" when unknown, which always
// advances). A file that vanished from the folder or failed this session is never kept.
function keepPicture(state, intervalMs, now, loginKey, files, bad) {
    if (!state || typeof state.last !== "string" || state.last === "" || files.indexOf(state.last) < 0 || (bad && bad[state.last]))
        return "";
    if (intervalMs > 0)
        return now - (typeof state.changedAt === "number" ? state.changedAt : 0) < intervalMs ? state.last : "";
    return loginKey !== "" && state.loginKey === loginKey ? state.last : "";
}

// ---- online daily pictures: when to fetch (ADR-0016 step 2, pure; the shell service only runs what this decides) ----

const MINUTE_MS = 60000;
const HOUR_MS = 3600000;
const DAY_MS = 86400000;
// The Commons POTD of a UTC date is final shortly after midnight UTC: nothing is asked before 00:10 UTC. NASA's APOD follows US
// Eastern time (midnight there is 04:00 or 05:00 UTC): its day flips at 05:10 UTC all year, so that the entry of the new date
// exists whatever the summer time.
const ONLINE_AFTER_MIDNIGHT_MS = 10 * MINUTE_MS;
const ONLINE_FLIP_MS = {commons: ONLINE_AFTER_MIDNIGHT_MS, apod: 5 * HOUR_MS + 10 * MINUTE_MS};

function onlineFlip(provider) {
    return ONLINE_FLIP_MS[oneOf(ONLINE_PROVIDERS, provider) ? provider : "commons"];
}
// The fetch of a day happens at a random time in this window after 00:10 UTC (spreads the load; no fixed instant).
const ONLINE_WINDOW_MS = 6 * HOUR_MS;
// Wait after the first and the second failure of a day; a third failure waits for the next day.
const ONLINE_BACKOFF_MS = [HOUR_MS, 3 * HOUR_MS];
const ONLINE_MAX_FAILURES = 3;

function pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

// "YYYY-MM-DD" (UTC) of a timestamp.
function utcDate(ms) {
    const d = new Date(ms);
    return d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate());
}

// Milliseconds at 00:00 UTC of a "YYYY-MM-DD" date, NaN when it is not one.
function utcDayStart(date) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(typeof date === "string" ? date : "");
    if (!m)
        return NaN;
    const t = Date.UTC(+m[1], +m[2] - 1, +m[3]);
    return utcDate(t) === date ? t : NaN;
}

// The date of the picture that applies at `ms`: the UTC date of the provider's flip time ago (Commons: 00:10 UTC; APOD: 05:10 UTC).
function onlineDate(ms, provider) {
    return utcDate(ms - onlineFlip(provider));
}

// The persisted scheduler state ({done, failures, failDate, retryAt, slotDate, slotAt}) from anything: a bad field reads as unset.
function onlineStateOf(raw) {
    const r = isPlainObject(raw) ? raw : {};
    const num = v => typeof v === "number" && isFinite(v) && v >= 0 ? v : 0;
    return {
        done: !isNaN(utcDayStart(r.done)) ? r.done : "",
        failures: Math.min(ONLINE_MAX_FAILURES, Math.floor(num(r.failures))),
        failDate: !isNaN(utcDayStart(r.failDate)) ? r.failDate : "",
        retryAt: num(r.retryAt),
        slotDate: !isNaN(utcDayStart(r.slotDate)) ? r.slotDate : "",
        slotAt: num(r.slotAt),
        // The provider this accounting belongs to ("" in a state written before there were two: Commons).
        provider: oneOf(ONLINE_PROVIDERS, r.provider) ? r.provider : ""
    };
}

// What to do at `now` (ms): {date, due, at, state}. `date` is the picture to fetch, `due` says "fetch now", `at` is when to look
// again (ms; only a bound: any event re-evaluates), `state` is the state with today's random slot filled in (persist it).
// `cached` is true when a picture is already on disk (nothing cached: no waiting for the day's slot, the first fetch is at once).
// `rand` is a number in [0, 1) for the slot, passed in so that the tests are exact.
function onlineSchedule(rawState, now, cached, rand, provider) {
    const prov = oneOf(ONLINE_PROVIDERS, provider) ? provider : "commons";
    let st = onlineStateOf(rawState);
    // Another provider starts its own accounting (a day done for Commons says nothing about APOD).
    if ((st.provider === "" ? "commons" : st.provider) !== prov)
        st = onlineStateOf({});
    st.provider = prov;
    const flip = onlineFlip(prov);
    const date = onlineDate(now, prov);
    const dayStart = utcDayStart(date);
    const tomorrow = dayStart + DAY_MS + flip;
    if (st.done === date)
        return {date: date, due: false, at: tomorrow, state: st};
    if (st.slotDate !== date) {
        st.slotDate = date;
        st.slotAt = dayStart + flip + Math.floor(Math.max(0, Math.min(0.999999, rand)) * ONLINE_WINDOW_MS);
    }
    const failures = st.failDate === date ? st.failures : 0;
    if (failures >= ONLINE_MAX_FAILURES)
        return {date: date, due: false, at: tomorrow, state: st};
    let at = cached ? st.slotAt : Math.min(st.slotAt, now);
    if (failures > 0)
        at = Math.max(at, st.retryAt);
    return {date: date, due: now >= at, at: at, state: st};
}

// The state after a fetch: "ok" and "skipped" (today's entry cannot be used: not retried today) finish the day; any other
// outcome is a failure with the next wait (1 h, then 3 h, then the next day).
function onlineAfter(rawState, now, date, outcome, provider) {
    const st = onlineStateOf(rawState);
    if (oneOf(ONLINE_PROVIDERS, provider))
        st.provider = provider;
    if (outcome === "ok" || outcome === "skipped") {
        st.done = date;
        st.failures = 0;
        st.failDate = "";
        st.retryAt = 0;
        return st;
    }
    const before = st.failDate === date ? st.failures : 0;
    st.failDate = date;
    st.failures = Math.min(ONLINE_MAX_FAILURES, before + 1);
    st.retryAt = before < ONLINE_BACKOFF_MS.length ? now + ONLINE_BACKOFF_MS[before] : 0;
    return st;
}

// True when an online source applies to some display (the top level or an override), so the shell has to keep the picture.
function onlineWanted(cfg) {
    const base = normalize(cfg);
    if (base.source === "online")
        return true;
    return base.outputs.some(e => e.source === "online");
}

// Failure ids of `fetch` that end the day without a retry (the entry itself cannot be used).
function onlineSkips(exitCode) {
    return exitCode === EXIT.TOO_LARGE_FILE || exitCode === EXIT.TOO_LARGE_PICTURE || exitCode === EXIT.UNSUPPORTED || exitCode === EXIT.SKIPPED;
}

// Argument vectors (no shell) for the helper. `baseUrl` is only passed in a dev session, for the loopback test server.
function fetchArgs(helper, provider, date, outDir, lang, baseUrl) {
    if (!oneOf(ONLINE_PROVIDERS, provider) || !validPath(outDir) || !/^\d{4}-\d{2}-\d{2}$/.test(date) || (lang !== "en" && lang !== "fr"))
        return null;
    const args = [helper, "fetch", provider, "--date", date, "--out", outDir, "--lang", lang];
    if (baseUrl)
        args.push("--base-url", baseUrl);
    return args;
}

function latestArgs(helper, provider, outDir) {
    if (!oneOf(ONLINE_PROVIDERS, provider) || !validPath(outDir))
        return null;
    return [helper, "latest", provider, "--out", outDir];
}

// ---- video pause policy (ADR-0016 section 5; pure, evaluated on every event, never polled) ----

// state = {locked, fullscreen, idle, onBattery, videoOnBattery, reduceMotion, profile}
// Returns {state: "play" | "settle" | "pause", reason}. "settle" is idle with everything else allowing playback: the
// shell eases the rate down and pauses (with Reduce Motion it pauses at once, which is the "pause" state).
function playbackState(s) {
    if (s.locked)
        return {state: "pause", reason: "locked"};
    if (s.fullscreen)
        return {state: "pause", reason: "fullscreen"};
    if (s.reduceMotion)
        return {state: "pause", reason: "reduce-motion"};
    if (s.profile === "reduced")
        return {state: "pause", reason: "reduced-profile"};
    if (s.onBattery && !s.videoOnBattery)
        return {state: "pause", reason: "battery"};
    if (s.idle)
        return {state: "settle", reason: "idle"};
    return {state: "play", reason: ""};
}

// The pause policy's inputs, per output, from what the shell knows (ADR-0016 section 5). `locked` and `onBattery` are session
// wide, `fullscreen` is the output's, `idle` is the IdleMonitor's. Nothing here reads a clock or polls.
function playbackInputs(locked, fullscreen, idle, onBattery, cfg, reduceMotion, profile) {
    return {locked: !!locked, fullscreen: !!fullscreen, idle: !!idle, onBattery: !!onBattery, videoOnBattery: !!(cfg && cfg.videoOnBattery), reduceMotion: !!reduceMotion, profile: profile};
}

// The rate a video settles to when the user is idle, and how long the easing takes (the shell eases 1 -> 0.25 over 2 s, then pauses).
const VIDEO_SETTLE_RATE = 0.25;

// ---- video crash marker (ADR-0016 section 5, "Crash safety") ----

// The marker as stored in wallpaper.json ({path, at}), or null. A path that is not a valid absolute path reads as no marker.
function videoMarkerOf(raw) {
    if (!isPlainObject(raw) || typeof raw.path !== "string" || pathProblem(raw.path) !== "")
        return null;
    return {path: raw.path, at: typeof raw.at === "number" && isFinite(raw.at) ? raw.at : 0};
}

// The markers as stored: one object (older files) or a list of them, at most 16, each valid one as videoMarkerOf.
function videoMarkersOf(raw) {
    const list = Array.isArray(raw) ? raw.slice(0, 16) : (asArray(raw, 16) || [raw]);
    const out = [];
    for (const m of list) {
        const mk = videoMarkerOf(m);
        if (mk)
            out.push(mk);
    }
    return out;
}

// The blocked paths as stored: a string (older files) or a list of paths, at most 16, valid absolute paths only.
function videoBlockedPaths(raw) {
    const list = typeof raw === "string" ? [raw] : (Array.isArray(raw) ? raw.slice(0, 16) : (asArray(raw, 16) || []));
    return list.filter(p => typeof p === "string" && pathProblem(p) === "");
}

// True when the video at `path` must not be played: the shell found a marker for it at start (it died while the video started),
// and the video is still the wallpaper. `blocked` is a path or a list of paths. Another video, another source, or a re-selection
// (a new path) is free to play.
function videoBlocked(blocked, path) {
    if (typeof path !== "string" || path === "")
        return false;
    if (typeof blocked === "string")
        return blocked === path;
    return videoBlockedPaths(blocked).indexOf(path) >= 0;
}

// ---- Cancel of the video preparation (Settings > Wallpaper): what the display showed before, per display ----

// The map of what each display showed before a video was chosen: {key: {source, path, overridden}}, `key` being "all" or a
// display key. Returns a new map with `was` recorded for `key`; a video chosen again (the one already on screen) records nothing.
function rememberPrevious(map, key, was, chosenPath) {
    const next = Object.assign({}, isPlainObject(map) ? map : {});
    if (was.source === "video" && was.path === chosenPath)
        return next;
    next[key] = {source: was.source, path: was.path, overridden: !!was.overridden};
    return next;
}

// What Cancel does on the page, which shows the display `key` ("all" or a display key; `isDisplay`, `overridden`: that display has
// a wallpaper of its own). Cancel acts on the SCOPE the choice was made in, never on the display the picker happens to show:
//   - a display that follows All Displays (`overridden` false) inherits the All Displays choice: any entry of its own is stale (it
//     was made before the display went back to following All) and is dropped; Cancel undoes the All Displays choice ("all" scope) and
//     never creates an override for the display; without an All Displays entry there is nothing to undo ("none");
//   - otherwise the entry of `key` exists: the choice was made for that scope; it is undone there;
//   - otherwise (nothing recorded): "none" for a display (nothing to undo here), "artwork" for All Displays.
// Returns {action, scope, fields, map}. `action`: "follow-all" (a display that had no wallpaper of its own: remove its override),
// "restore" (write `fields`, source and path, in `scope`: "all" = the top level, "display" = the display's entry), "artwork" or
// "none". `map` is the map without the entry that was used; no other entry is touched.
function cancelPlan(map, key, isDisplay, overridden, currentSource, currentPath) {
    const all = Object.assign({}, isPlainObject(map) ? map : {});
    let scopeKey = key;
    let scope = isDisplay ? "display" : "all";
    if (isDisplay && !overridden) {
        delete all[key];
        if (!all.all)
            return {action: "none", scope: "all", fields: null, map: all};
        scopeKey = "all";
        scope = "all";
    }
    const was = all[scopeKey];
    delete all[scopeKey];
    if (!was)
        return {action: isDisplay ? "none" : "artwork", scope: scope, fields: null, map: all};
    if (scope === "display" && !was.overridden)
        return {action: "follow-all", scope: scope, fields: null, map: all};
    if (was.source === "video" && was.path === currentPath && currentSource === "video")
        return {action: "artwork", scope: scope, fields: null, map: all};
    return {action: "restore", scope: scope, fields: {source: was.source, path: was.path}, map: all};
}

// The map without the entry of `key` (the display went back to following All Displays: what it showed before a video was
// chosen there is no longer what Cancel would restore).
function forgetPrevious(map, key) {
    const next = Object.assign({}, isPlainObject(map) ? map : {});
    delete next[key];
    return next;
}

// ---- the aspect rule of the online pictures (ADR-0016 step 2) ----

// A daily picture within +-35 % of the output's aspect ratio is Filled, any other (a panorama, a portrait) is Fitted on the
// picture's mean colour. Returns {fit, color}; `mean` is the sidecar's "#rrggbb" (anything else reads black).
function onlineFit(picWidth, picHeight, outWidth, outHeight, mean) {
    const color = validColor(mean) ? mean.toLowerCase() : "#000000";
    if (!(picWidth > 0 && picHeight > 0 && outWidth > 0 && outHeight > 0))
        return {fit: "fill", color: color};
    const ratio = (picWidth / picHeight) / (outWidth / outHeight);
    return {fit: ratio >= 0.65 && ratio <= 1.35 ? "fill" : "fit", color: color};
}

// ---- helper process (apps/wallpaper-tool) ----

// Size "WxH" (physical pixels) of a window: each side at least 1 and at most 16384.
function sizeArg(width, height) {
    const w = Math.max(1, Math.min(16384, Math.round(width)));
    const h = Math.max(1, Math.min(16384, Math.round(height)));
    return w + "x" + h;
}

// Argument vector (no shell) for `prepare`. `--` ends the options, so a path can never be read as an option. Returns
// null for an invalid input (relative path, control characters, bad fit or colour).
// `stripRows` (the menu bar's height in output pixels) and `cacheMaxBytes` are optional (0 or undefined: the helper's own).
// `keepFiles` are the prepared pictures on screen: the helper never prunes them from the cache.
function prepareArgs(helper, src, width, height, fit, color, outDir, stripRows, cacheMaxBytes, keepFiles) {
    if (!validPath(src) || !validPath(outDir) || !oneOf(FITS, fit) || !validColor(color))
        return null;
    const args = [helper, "prepare", "--size", sizeArg(width, height), "--fit", fit, "--color", color.toLowerCase(), "--out", outDir];
    if (stripRows > 0)
        args.push("--strip-rows", String(Math.max(1, Math.min(512, Math.round(stripRows)))));
    if (cacheMaxBytes > 0)
        args.push("--cache-max-bytes", String(Math.round(cacheMaxBytes)));
    for (const k of keepFiles || []) {
        if (validPath(k))
            args.push("--keep", k);
    }
    args.push("--", src);
    return args;
}

function thumbArgs(helper, src, width, outDir) {
    if (!validPath(src) || !validPath(outDir))
        return null;
    return [helper, "thumb", "--width", String(Math.max(16, Math.min(1024, Math.round(width)))), "--out", outDir, "--", src];
}

// `probe`: the video's duration, size, codec (one JSON object). Null for an invalid path.
function probeArgs(helper, src) {
    if (!validPath(src))
        return null;
    return [helper, "probe", "--", src];
}

// `transcode` (ADR-0016 W7): H.264 at most `width` x `height` physical pixels, the poster composed with `fit` and `color`, the
// statistics of the menu bar strip. Prints {"progress":f} lines, then one result object. `maxSeconds` and `maxBytes` are optional.
function transcodeArgs(helper, src, width, height, fit, color, outDir, stripRows, cacheMaxBytes, keepFiles, maxSeconds, maxBytes) {
    if (!validPath(src) || !validPath(outDir) || !oneOf(FITS, fit) || !validColor(color))
        return null;
    const args = [helper, "transcode", "--size", sizeArg(width, height), "--fit", fit, "--color", color.toLowerCase(), "--out", outDir];
    if (stripRows > 0)
        args.push("--strip-rows", String(Math.max(1, Math.min(512, Math.round(stripRows)))));
    if (cacheMaxBytes > 0)
        args.push("--cache-max-bytes", String(Math.round(cacheMaxBytes)));
    if (maxSeconds > 0)
        args.push("--max-seconds", String(Math.max(1, Math.min(600, Math.round(maxSeconds)))));
    if (maxBytes > 0)
        args.push("--max-bytes", String(Math.round(maxBytes)));
    for (const k of keepFiles || []) {
        if (validPath(k))
            args.push("--keep", k);
    }
    args.push("--", src);
    return args;
}

// Reads the lines a transcode printed (or part of them): {progress: 0..1 | -1, result: object | null}. A line that is not JSON is
// ignored; a progress line never counts as the result.
function transcodeOutput(text) {
    let progress = -1;
    let result = null;
    for (const line of String(text).split("\n")) {
        if (line === "")
            continue;
        let o = null;
        try {
            o = JSON.parse(line);
        } catch (e) {
            continue;
        }
        if (!isPlainObject(o))
            continue;
        if (typeof o.code === "number")
            result = o;
        else if (typeof o.progress === "number" && o.progress >= 0 && o.progress <= 1)
            progress = o.progress;
    }
    return {progress: progress, result: result};
}

function listArgs(helper, folder, max) {
    if (!validPath(folder))
        return null;
    return [helper, "list", "--max", String(Math.max(1, Math.min(100000, Math.round(max)))), "--", folder];
}

// Failure id for a helper exit code (0 and unknown codes: "" and "failed").
function reasonOf(exitCode) {
    if (exitCode === 0)
        return "";
    return REASONS[exitCode] || "failed";
}

// ---- tone from the strip statistics (menu bar legibility, ADR-0016 section 7) ----

function linear(c) {
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

// WCAG contrast ratio of two relative luminances.
function contrast(a, b) {
    const hi = Math.max(a, b);
    const lo = Math.min(a, b);
    return (hi + 0.05) / (lo + 0.05);
}

// Worst-case contrast of white and of black text over a strip, from the strip's luminance percentiles
// (p5 = the darkest 5 %, p95 = the lightest 5 %, relative luminance 0..1): white text is worst over the lightest pixels,
// black text over the darkest ones.
function stripContrast(p5, p95) {
    return {white: contrast(1, Math.max(0, Math.min(1, p95))), black: contrast(0, Math.max(0, Math.min(1, p5)))};
}

// ---- paths of the shell and the dev guard (ADR-0016 sections 1 and 2) ----

// A path with "." and ".." segments and repeated slashes resolved, lexically (no symlinks); "" for a relative path.
function normalizePath(path) {
    if (typeof path !== "string" || path.charAt(0) !== "/")
        return "";
    const out = [];
    for (const part of path.split("/")) {
        if (part === "" || part === ".")
            continue;
        if (part === "..")
            out.pop();
        else
            out.push(part);
    }
    return "/" + out.join("/");
}

// True when `path` is `dir` or below it (both normalized first).
function isUnder(path, dir) {
    const p = normalizePath(path);
    const d = normalizePath(dir);
    if (p === "" || d === "")
        return false;
    return p === d || p.indexOf(d === "/" ? "/" : d + "/") === 0;
}

// "" when `path` may be used as a wallpaper source in this session. A dev session (GRASSFIELD_DEV=1) accepts only paths
// under <repo>/.dev/, so that no photo of the owner can appear in a nested capture (ADR-0016 section 1).
function sourceProblem(path, dev, repoRoot) {
    const why = pathProblem(path);
    if (why !== "")
        return why;
    if (dev && !isUnder(path, repoRoot + "/.dev"))
        return "outside-dev";
    return "";
}

// env = {dev, repoRoot, home, xdgCache, picturesDir}: where the helper, its cache and the pictures section live.
function toolPath(env) {
    return env.dev ? env.repoRoot + "/.dev/build/grassfield-wallpaper" : "/usr/lib/grassfield/grassfield-wallpaper";
}

// Extra environment for the helper: Qt applications print a warning at start when the locale is not UTF-8, and the systemd
// user session often has none (no LANG). env = {lcAll, lcCtype, lang}, the session's values (empty when unset). The session's
// own UTF-8 locale is kept; otherwise LC_ALL=C.UTF-8 (the glibc locale that always exists, and the one Qt falls back to).
function toolEnvironment(env) {
    const utf8 = /utf-?8/i;
    const effective = env.lcAll || env.lcCtype || env.lang || "";
    return utf8.test(effective) ? {} : {"LC_ALL": "C.UTF-8"};
}

function cacheRoot(env) {
    if (env.dev)
        return env.repoRoot + "/.dev/cache/wallpapers";
    return (env.xdgCache ? env.xdgCache : env.home + "/.cache") + "/grassfield/wallpapers";
}

function picturesRoot(env) {
    if (env.dev)
        return env.picturesDir ? env.picturesDir : env.repoRoot + "/.dev/wallpapers";
    return env.picturesDir ? env.picturesDir : env.home + "/Pictures";
}

// ---- the attribution's links (CC BY 4.0 section 3(a)(1)(C) wants the licence name with its URI or a link) ----

// Characters that draw nothing or reorder text: controls, soft hyphen, fillers, bidi, zero-width, variation selectors, specials.
const HIDDEN = /[\u0000-\u001f\u007f-\u009f\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f\u2028-\u202e\u2060-\u206f\u2800\u3164\ufe00-\ufe0f\ufeff\uffa0\ufff9-\ufffd]/;

// The address a link may open: https, no white space and no hidden character, at most 2048 characters; "" otherwise. The helper
// already refuses anything else; this is the second check at the point where the address becomes a command argument.
function linkOf(url) {
    if (typeof url !== "string" || url.length === 0 || url.length > 2048)
        return "";
    if (!/^https:\/\/[^\s\/]+/.test(url) || /\s/.test(url) || HIDDEN.test(url))
        return "";
    return url;
}

// An address for reading: no scheme, percent-escapes decoded ("File%3AX%20y.jpg" reads "File:X y.jpg"). When decoding fails or
// would produce a hidden or reordering character (%0A, %E2%80%AE), the address stays as it was written.
function displayUrl(url) {
    const bare = (typeof url === "string" ? url : "").replace(/^https?:\/\//, "");
    let decoded = bare;
    try {
        decoded = decodeURIComponent(bare);
    } catch (e) {
        return bare;
    }
    return HIDDEN.test(decoded) ? bare : decoded;
}

// ---- the shipped photographs (ADR-0040 step 2c) ----
// photos.json beside the pictures (packaging/arch/wallpaper-photos.json, installed under /usr/share/grassfield/wallpapers/photos):
// read by Settings > Wallpaper, later by the desktop's About This Wallpaper. A file installed by the package, still read as
// untrusted: an entry with a field missing or of the wrong shape is left out, never shown half.
const PHOTO_ID = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const MAX_PHOTOS = 64;
const MAX_PHOTO_TEXT = 512;

function photoText(s) {
    return typeof s === "string" && s.length > 0 && s.length <= MAX_PHOTO_TEXT && !HIDDEN.test(s);
}

// [{id, path, name: {en, fr}, author, credit, licenseShort, licenseUrl, sourceUrl}] from the manifest's text, the pictures at
// `dir` + "/" + id + ".jpg"; [] for anything that is not a manifest. Each id once, at most MAX_PHOTOS.
function parsePhotos(text, dir) {
    let doc = null;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!doc || !Array.isArray(doc.photos) || validPath(dir) === false)
        return [];
    const out = [];
    const seen = {};
    for (const p of doc.photos) {
        if (out.length >= MAX_PHOTOS)
            break;
        if (!p || typeof p.id !== "string" || !PHOTO_ID.test(p.id) || p.id.length > 64 || seen[p.id])
            continue;
        if (!p.name || !photoText(p.name.en) || !photoText(p.name.fr))
            continue;
        if (!photoText(p.author) || !photoText(p.credit) || !photoText(p.licenseShort))
            continue;
        if (linkOf(p.licenseUrl) === "" || linkOf(p.sourceUrl) === "")
            continue;
        seen[p.id] = true;
        out.push({id: p.id, path: dir.replace(/\/+$/, "") + "/" + p.id + ".jpg", name: {en: p.name.en, fr: p.name.fr}, author: p.author, credit: p.credit,
            licenseShort: p.licenseShort, licenseUrl: p.licenseUrl, sourceUrl: p.sourceUrl});
    }
    return out;
}

// A photograph's name in the language of `lang` (a locale name such as "fr_FR"): French for French, English otherwise.
function photoName(photo, lang) {
    return typeof lang === "string" && /^fr(?:[_-]|$)/.test(lang) ? photo.name.fr : photo.name.en;
}

// The photograph shown from `path`, or null.
function photoAt(photos, path) {
    return Array.isArray(photos) ? (photos.find(p => p.path === path) || null) : null;
}

// What "About This Wallpaper" shows for a photograph: the fields of an online entry (title, author, sourceUrl, licenseShort,
// licenseUrl), so one view serves both.
function photoAbout(photo, lang) {
    return photo ? {title: photoName(photo, lang), author: photo.author, sourceUrl: photo.sourceUrl, licenseShort: photo.licenseShort, licenseUrl: photo.licenseUrl} : null;
}

// What the desktop's "About This Wallpaper" shows for one output (ADR-0040 step 2c): `out` is the output's report (WallpaperState
// .outputs[name]: {source, state, path}), `online` the online picture's ({entry}), `photos` the shipped list (parsePhotos). The
// online picture's attribution while that output shows it, ready; the photograph's while it shows one of the list, ready; null
// otherwise (the menu then has no About This Wallpaper).
function aboutEntryOf(out, online, photos, lang) {
    if (!out || out.state !== "ready")
        return null;
    if (out.source === "online")
        return online && online.entry ? online.entry : null;
    if (out.source === "file" && typeof out.path === "string" && out.path !== "")
        return photoAbout(photoAt(photos, out.path), lang);
    return null;
}

// ---- the artwork's variant (ADR-0040 section 2, IQ-W1 C) ----
// The variant GrassfieldArtwork draws for `artwork` under the user's `choice` (wallpaper.artworkVariant), the appearance
// (`dark`) and the phase of the day (TimeOfDay, "" while it is not known). Grassfield: Time of Day is the phase in the
// appearance's set (Evening until the phase is known); Automatic is Day in the light appearance and Evening in the dark one;
// Light is the light Day; Dark the dark Evening. The other artworks follow the appearance (Time of Day reads as Automatic)
// unless Light or Dark is chosen.
function artworkVariantFor(artwork, choice, dark, phase) {
    const c = oneOf(ARTWORK_VARIANTS, choice) ? choice : WALLPAPER_DEFAULTS.artworkVariant;
    const set = dark ? "dark" : "light";
    if (artwork !== "grassfield" && oneOf(ARTWORKS, artwork))
        return c === "light" || c === "dark" ? c : set;
    if (c === "light")
        return "day.light";
    if (c === "dark")
        return "evening.dark";
    if (c === "automatic")
        return dark ? "evening.dark" : "day.light";
    return (["dawn", "day", "evening", "night"].indexOf(phase) >= 0 ? phase : "evening") + "." + set;
}

// ---- the first frame and the ground (ADR-0040 step 3, ID-2 and ID-3), the lock's backdrop (step 4a, ID-7) ----
const HEX = /^#[0-9a-fA-F]{6}$/;
const STILL_NAME = /^[0-9a-f]{32}\.(jpg|png)$/;
const ART_VARIANT = /^((dawn|day|evening|night)\.)?(light|dark)$/;

// wallpaper.json "shown": per output, the last wallpaper that output showed. A picture {kind: "picture", file, strip, image,
// mean, video} (`file` the prepared picture, or a video's poster with `video` true), the artwork {kind: "art"} or a colour
// {kind: "color", color}; every record also names the artwork and variant the output would draw instead (`artwork`,
// `variant`): the lock's fallback. Written by the desktop when a wallpaper is on screen; read back by the desktop's first
// frame (stillOf) and by the lock (lockBackdropOf). At most 16 outputs.
function shownRecord(saved, output) {
    const all = isPlainObject(saved) && isPlainObject(saved.shown) ? saved.shown : {};
    const r = typeof output === "string" && Object.prototype.hasOwnProperty.call(all, output) ? all[output] : null;
    return isPlainObject(r) ? r : null;
}

// `file` when it is a plain cache name ("<32 hex>.jpg|png") directly in one of `dirs` (each an absolute path), else "".
function cacheFile(file, dirs) {
    if (typeof file !== "string")
        return "";
    const slash = file.lastIndexOf("/");
    if (slash < 0 || !STILL_NAME.test(file.substring(slash + 1)))
        return "";
    const dir = file.substring(0, slash);
    return dirs.some(d => validPath(d) && d.replace(/\/+$/, "") === dir) ? file : "";
}

// The last picture shown on `output` ({file, strip, image, mean}) for the desktop's first frame, or null. The file must be one
// of the helper's own prepared pictures (a plain cache name in `preparedDir`): the shell decodes nothing else (ADR-0016). A
// video's poster is not one (it waits for the feed). The statistics are kept only when they have the helper's shape.
function stillOf(saved, output, preparedDir) {
    const s = shownRecord(saved, output);
    if (s === null || s.kind !== "picture" || s.video === true)
        return null;
    const file = cacheFile(s.file, [preparedDir]);
    if (file === "")
        return null;
    const stats = v => isPlainObject(v) && typeof v.mean === "number" && typeof v.p5 === "number" && typeof v.p95 === "number" ? v : null;
    const strip = isPlainObject(s.strip) && stats(s.strip.all) ? s.strip : null;
    return {file: file, strip: strip, image: stats(s.image), mean: typeof s.mean === "string" && HEX.test(s.mean) ? s.mean : ""};
}

// The stored state with `output`'s record set from the description now on screen (`art`: {artwork, variant}, what the output
// would draw instead). A new object; at most 16 outputs are kept (the newest).
function withShown(saved, output, desc, art) {
    const base = isPlainObject(saved) ? saved : {};
    const a = isPlainObject(art) ? art : {};
    const r = {kind: "art", artwork: typeof a.artwork === "string" ? a.artwork : "grassfield", variant: typeof a.variant === "string" ? a.variant : "evening.dark"};
    let keep = true;
    if (desc && desc.kind === "picture" && typeof desc.url === "string" && desc.url.indexOf("file://") === 0) {
        r.kind = "picture";
        r.file = desc.url.substring(7);
        r.video = typeof desc.video === "string" && desc.video !== "";
        r.strip = desc.strip || null;
        r.image = desc.image || null;
        r.mean = typeof desc.mean === "string" ? desc.mean : "";
    } else if (desc && desc.kind === "color" && validColor(desc.color)) {
        r.kind = "color";
        r.color = desc.color;
    } else if (desc && desc.kind === "art") {
        if (typeof desc.artwork === "string")
            r.artwork = desc.artwork;
        if (typeof desc.variant === "string")
            r.variant = desc.variant;
    } else {
        keep = false;
    }
    // A fresh object, `output` last (the engine keeps a deleted key's place when it is added again): the oldest go first.
    const old = isPlainObject(base.shown) ? base.shown : {};
    const names = Object.keys(old).filter(n => n !== output);
    const shown = {};
    for (const n of names.slice(Math.max(0, names.length - (keep ? 15 : 16))))
        shown[n] = old[n];
    if (keep)
        shown[output] = r;
    return Object.assign({}, base, {shown: shown});
}

// What the lock draws behind its scrim on `output` (ADR-0040 step 4a, ID-7): {kind: "picture", file} (the prepared picture or a
// video's poster: a plain cache name in `preparedDir` or `videoDir`), {kind: "color", color} or {kind: "art"}, each with the
// artwork and variant to draw when the picture cannot be (the default for anything unknown); null when the output never showed
// anything. The lock still checks the file itself (a regular file of bounded size whose real path is in the cache).
function lockBackdropOf(saved, output, preparedDir, videoDir) {
    const r = shownRecord(saved, output);
    if (r === null)
        return null;
    const out = {kind: "art", file: "", color: "", artwork: ARTWORKS.indexOf(r.artwork) >= 0 ? r.artwork : "grassfield", variant: typeof r.variant === "string" && ART_VARIANT.test(r.variant) ? r.variant : "evening.dark"};
    if (r.kind === "picture") {
        out.file = cacheFile(r.file, [preparedDir, videoDir]);
        if (out.file !== "")
            out.kind = "picture";
    } else if (r.kind === "color" && validColor(r.color)) {
        out.kind = "color";
        out.color = r.color;
    }
    return out;
}

// The lock's check of a still (ADR-0040 step 4a, shell/security/lock/LockStill.qml), pure. `text` is what
// `realpath -m -- <preparedDir> <videoDir> <file>` printed: three lines, each path with its symbolic links resolved. The
// file's real path when it is a plain cache name directly in the real prepared or video folder, else "".
function lockStillReal(text) {
    const lines = typeof text === "string" ? text.split("\n").filter(l => l !== "") : [];
    if (lines.length !== 3)
        return "";
    return cacheFile(lines[2], [lines[0], lines[1]]);
}

// `stat --printf %f|%s`: the raw mode in hexadecimal and the size (no word, so no locale changes it). True for a regular
// file of 1 to `maxBytes` bytes.
function lockStillStatOk(text, maxBytes) {
    const m = typeof text === "string" ? text.trim().match(/^([0-9a-fA-F]{1,8})\|(\d{1,20})$/) : null;
    if (!m)
        return false;
    const size = Number(m[2]);
    return (parseInt(m[1], 16) & 0xF000) === 0x8000 && size > 0 && size <= maxBytes;
}

// ---- the moving Grassfield artwork (ADR-0040 step 9, as the integrator decided in the review of e067f26f) ----
// Its clouds move on the lock screen only, as macOS's moving wallpapers do; the desktop draws them still. The position is in
// milliseconds of motion (Artwork.cloudX, Artwork.lightAt), one per output: 0 until a lock moved them.

// Where the clouds rest on `output` in a map {<output>: ms} (WallpaperState.motion): 0 for anything that is not a finite
// number of at least 0.
function motionIn(map, output) {
    const v = isPlainObject(map) && typeof output === "string" ? map[output] : 0;
    return typeof v === "number" && isFinite(v) && v >= 0 ? v : 0;
}

// The map with `output` resting at `at` (a new object; the map itself unchanged when either is not valid).
function withMotion(map, output, at) {
    const base = isPlainObject(map) ? map : {};
    if (typeof output !== "string" || output === "" || typeof at !== "number" || !isFinite(at) || at < 0)
        return base;
    const out = Object.assign({}, base);
    out[output] = at;
    return out;
}

// Where the lock's clouds come to rest when its release fade starts (`at`: where they are). Moving, they slow down linearly to
// a stop within the fade (`fadeMs`; Easing.OutQuad, whose starting speed is the running one, one ms of motion per ms): they
// rest half the fade further on. Not moving, or no fade (Reduce Motion): where they are.
function lockMotionRest(at, moving, fadeMs) {
    const a = typeof at === "number" && isFinite(at) && at >= 0 ? at : 0;
    return moving === true && typeof fadeMs === "number" && isFinite(fadeMs) && fadeMs > 0 ? a + fadeMs / 2 : a;
}

// What a wallpaper window shows as its first frame, before it maps (ADR-0040 ID-3): "feed" (the feed's first result, final:
// it carries the phase and the appearance too), "still" (the output's last picture from wallpaper.json, until that result),
// or "wait" (nothing yet: the window stays unmapped, at most wallpaper.firstShowTimeoutMs, then the artwork). A phase or an
// appearance known before the feed's first result changes nothing; nothing is chosen before wallpaper.json was read.
function firstFrameChoice(feedSeen, stateReady, hasStill) {
    if (!stateReady)
        return "wait";
    if (feedSeen)
        return "feed";
    return hasStill ? "still" : "wait";
}

// The ground of `output` in `grounds` ({output name: "#RRGGBB"}), else `fallback`.
function groundFor(grounds, output, fallback) {
    return isPlainObject(grounds) && typeof output === "string" && Object.prototype.hasOwnProperty.call(grounds, output) && HEX.test(grounds[output]) ? grounds[output] : fallback;
}

// The stored state with display `key`'s carousel position set; every other key (the last wallpaper shown) kept. A new object.
function withCarousel(saved, key, state) {
    const base = isPlainObject(saved) ? saved : {};
    const all = Object.assign({}, isPlainObject(base.displays) ? base.displays : {});
    all[key] = state;
    return Object.assign({}, base, {displays: all});
}

// The text of wallpaper.json: the carousel positions, the last wallpaper shown per output, the video crash markers
// ([{path, at}], one per path) and the blocked videos; the empty ones left out.
function stateText(saved, startingBy, blocked, now) {
    const s = isPlainObject(saved) ? saved : {};
    const o = {displays: isPlainObject(s.displays) ? s.displays : {}};
    if (isPlainObject(s.shown) && Object.keys(s.shown).length > 0)
        o.shown = s.shown;
    const starting = [];
    const by = isPlainObject(startingBy) ? startingBy : {};
    for (const owner of Object.keys(by)) {
        if (!starting.some(m => m.path === by[owner]))
            starting.push({path: by[owner], at: now});
    }
    if (starting.length > 0)
        o.videoStarting = starting;
    const list = asArray(blocked, 16);
    if (list !== null && list.length > 0)
        o.videoBlocked = list;
    return JSON.stringify(o, null, 2) + "\n";
}

// The ground of a description (ADR-0040 ID-2): a picture's mean colour, a colour itself, the artwork's ground; `fallback` (the
// static default, session.ground) for anything else.
function groundOf(desc, artGround, fallback) {
    if (desc && desc.kind === "picture" && typeof desc.mean === "string" && HEX.test(desc.mean))
        return desc.mean.toUpperCase();
    if (desc && desc.kind === "color" && typeof desc.color === "string" && HEX.test(desc.color))
        return desc.color.toUpperCase();
    if (desc && desc.kind === "art" && typeof artGround === "string" && HEX.test(artGround))
        return artGround.toUpperCase();
    return fallback;
}
