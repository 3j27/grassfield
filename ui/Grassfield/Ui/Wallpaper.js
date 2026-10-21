.pragma library

// Wallpaper settings and rules (Settings > Wallpaper, ADR-0016). Pure functions, no I/O, shared by the Settings app
// (validation of what it writes), the shell (what it reads, the carousel order, the pause policy) and the tests.
// Registered as WallpaperConfig in qmldir (the shell has its own Wallpaper type). Untrusted input: every value read from
// grassfield.json goes through normalize(); an invalid field reads as its default, never as an error.

const SOURCES = ["builtin", "color", "file", "folder", "video"];
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
    outputs: []
};

// Helper exit codes (apps/wallpaper-tool) and the failure each one means (ids; the UI translates them).
const EXIT = {OK: 0, USAGE: 2, NOT_FOUND: 3, NOT_REGULAR: 4, TOO_LARGE_FILE: 5, TOO_LARGE_PICTURE: 6, UNREADABLE: 7, UNSUPPORTED: 8, TIMEOUT: 9, WRITE: 10, MISSING: 127};
const REASONS = {
    3: "not-found",
    4: "not-regular",
    5: "too-large",
    6: "too-large",
    7: "unreadable",
    8: "unsupported",
    9: "timeout",
    10: "write",
    127: "helper-missing"
};

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
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
// override or isolate (U+202A-U+202E, U+2066-U+2069). Tested by code, not by a regular expression, so that the source
// holds no invisible character.
function hasForbiddenChar(s) {
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c <= 0x1f || (c >= 0x7f && c <= 0x9f) || c === 0x2028 || c === 0x2029 || (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069))
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
    if (!isObject(d))
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
    if (!isObject(entry))
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
function outputsProblem(list) {
    if (!Array.isArray(list))
        return "not-an-array";
    if (list.length > MAX_OUTPUTS)
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
function normalizeOutputs(list) {
    const out = [];
    if (!Array.isArray(list))
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
    const r = isObject(raw) ? raw : {};
    const out = {
        source: oneOf(SOURCES, r.source) ? r.source : WALLPAPER_DEFAULTS.source,
        path: validPath(r.path) ? r.path : WALLPAPER_DEFAULTS.path,
        color: validColor(r.color) ? r.color.toLowerCase() : WALLPAPER_DEFAULTS.color,
        fit: oneOf(FITS, r.fit) ? r.fit : WALLPAPER_DEFAULTS.fit,
        interval: oneOf(INTERVAL_NAMES, r.interval) ? r.interval : WALLPAPER_DEFAULTS.interval,
        shuffle: typeof r.shuffle === "boolean" ? r.shuffle : WALLPAPER_DEFAULTS.shuffle,
        videoOnBattery: typeof r.videoOnBattery === "boolean" ? r.videoOnBattery : WALLPAPER_DEFAULTS.videoOnBattery,
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
        videoOnBattery: base.videoOnBattery
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

// ---- helper process (apps/wallpaper-tool) ----

// Size "WxH" (physical pixels) of a window: each side at least 1 and at most 16384.
function sizeArg(width, height) {
    const w = Math.max(1, Math.min(16384, Math.round(width)));
    const h = Math.max(1, Math.min(16384, Math.round(height)));
    return w + "x" + h;
}

// Argument vector (no shell) for `prepare`. `--` ends the options, so a path can never be read as an option. Returns
// null for an invalid input (relative path, control characters, bad fit or colour).
function prepareArgs(helper, src, width, height, fit, color, outDir) {
    if (!validPath(src) || !validPath(outDir) || !oneOf(FITS, fit) || !validColor(color))
        return null;
    return [helper, "prepare", "--size", sizeArg(width, height), "--fit", fit, "--color", color.toLowerCase(), "--out", outDir, "--", src];
}

function thumbArgs(helper, src, width, outDir) {
    if (!validPath(src) || !validPath(outDir))
        return null;
    return [helper, "thumb", "--width", String(Math.max(16, Math.min(1024, Math.round(width)))), "--out", outDir, "--", src];
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
