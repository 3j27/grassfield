.pragma library
.import Grassfield.Ui 1.0 as Ui

// grassfield.json (contract version 1) merge and validation logic. Pure functions, no I/O:
// the caller reads the file, passes its text in and writes the returned text back.
// RULES mirrors config/schema/grassfield.schema.json (tests/unit/tst_settingsstore.qml checks the parity).
// Rules: preserve every other key of the file, never write a key outside the schema, refuse a malformed file.

const DEFAULTS = {
    "appearance": "dark",
    "material.transparency": 0.25,
    "material.profile": "balanced",
    "accessibility.reduceTransparency": false,
    "accessibility.reduceMotion": false,
    "dock.magnification": 1.6,
    "dock.magnificationEnabled": false,
    "dock.autohide": false,
    "dock.showRecents": true,
    "dock.minimizeIntoApp": false,
    "desktop.showIcons": true,
    "menubar.showBackground": false,
    "windows.titlebarDoubleClick": "zoom",
    "notifications.dnd": false,
    "notifications.previews": "unlocked",
    "lock.idleMinutes": 5,
    "hotCorners.topLeft": "none",
    "hotCorners.topRight": "none",
    "hotCorners.bottomLeft": "none",
    "hotCorners.bottomRight": "none",
    "accent.color": "multicolor",
    "icons.mode": "default",
    "icons.tint": "accent",
    "icons.folderColor": "theme",
    "pointer.size": Ui.PointerSize.DEFAULT,
    "pointer.outlineColor": Ui.PointerColors.DEFAULT_OUTLINE,
    "pointer.fillColor": Ui.PointerColors.DEFAULT_FILL,
    "wallpaper.source": "builtin",
    "wallpaper.path": "",
    "wallpaper.color": "#000000",
    "wallpaper.fit": "fill",
    "wallpaper.interval": "1h",
    "wallpaper.shuffle": true,
    "wallpaper.videoOnBattery": false,
    "wallpaper.outputs": []
};

const CORNER_ACTIONS = ["none", "overview", "notifications", "apps", "lock"];

// Settable keys (dock.pinned is owned by the Dock and is only preserved).
const RULES = {
    "appearance": {type: "enum", values: ["dark", "light", "auto"]},
    "material.transparency": {type: "number", min: 0, max: 1},
    "material.profile": {type: "enum", values: ["full", "balanced", "reduced"]},
    "accessibility.reduceTransparency": {type: "boolean"},
    "accessibility.reduceMotion": {type: "boolean"},
    "dock.magnification": {type: "number", min: 1, max: 2.5},
    "dock.magnificationEnabled": {type: "boolean"},
    "dock.autohide": {type: "boolean"},
    "dock.showRecents": {type: "boolean"},
    "dock.minimizeIntoApp": {type: "boolean"},
    "desktop.showIcons": {type: "boolean"},
    "menubar.showBackground": {type: "boolean"},
    "windows.titlebarDoubleClick": {type: "enum", values: ["zoom", "minimize", "none"]},
    "notifications.dnd": {type: "boolean"},
    "notifications.previews": {type: "enum", values: ["always", "unlocked", "never"]},
    "lock.idleMinutes": {type: "integer", min: 0, max: 240},
    "hotCorners.topLeft": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.topRight": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.bottomLeft": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.bottomRight": {type: "enum", values: CORNER_ACTIONS},
    // Accent colour; the names mirror ui/Grassfield/Ui/Accent.js NAMES (tests/unit/tst_accent.qml checks the parity).
    "accent.color": {type: "enum", values: ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"]},
    "icons.mode": {type: "enum", values: ["default", "dark", "clear", "tinted"]},
    // "accent" or a #rrggbb colour (schema `pattern`).
    "icons.tint": {type: "tint"},
    // "theme", "accent" or a #rrggbb colour (schema `pattern`).
    "icons.folderColor": {type: "folderColor"},
    // Cursor size in pixels, mirrors ui/Grassfield/Ui/PointerSize.js (the unit test checks the bounds).
    "pointer.size": {type: "integer", min: Ui.PointerSize.MIN, max: Ui.PointerSize.MAX},
    // #rrggbb (schema `pattern`), any colour: like macOS there is no contrast guard.
    "pointer.outlineColor": {type: "pointerColor"},
    "pointer.fillColor": {type: "pointerColor"},
    // ADR-0016: the lists, defaults and the path and outputs rules are local to this file: a JS .import of
    // ui/Grassfield/Ui/WallpaperConfig.js resolves the INSTALLED Grassfield.Ui (older than this tree) and fails. The tests
    // keep them in step with that module: tst_wallpaper (schema, lists) and tests/unit/fixtures/wallpaper-rules.json
    // (cases both implementations must answer alike).
    "wallpaper.source": {type: "enum", values: ["builtin", "color", "file", "folder", "video"]},
    "wallpaper.path": {type: "wallpaperPath"},
    "wallpaper.color": {type: "pointerColor"},
    "wallpaper.fit": {type: "enum", values: ["fill", "fit", "stretch", "center", "tile"]},
    "wallpaper.interval": {type: "enum", values: ["login", "5s", "1m", "5m", "15m", "30m", "1h", "1d"]},
    "wallpaper.shuffle": {type: "boolean"},
    "wallpaper.videoOnBattery": {type: "boolean"},
    "wallpaper.outputs": {type: "wallpaperOutputs"}
};

// ---- wallpaper rules (mirror ui/Grassfield/Ui/WallpaperConfig.js: pathProblem, outputsProblem) ----

function wallpaperUtf8Length(s) {
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

function wallpaperHasForbiddenChar(s) {
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c <= 0x1f || (c >= 0x7f && c <= 0x9f) || c === 0x2028 || c === 0x2029 || (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069))
            return true;
    }
    return false;
}

// "" for an acceptable absolute path, else the reason id.
function wallpaperPathProblem(path) {
    if (typeof path !== "string")
        return "not-a-string";
    if (path === "")
        return "empty";
    if (path.charAt(0) !== "/")
        return "not-absolute";
    if (wallpaperHasForbiddenChar(path))
        return "control-characters";
    if (wallpaperUtf8Length(path) > 4096)
        return "too-long";
    return "";
}

function wallpaperDisplayKey(d) {
    return d.serial && d.model ? "s:" + d.model + "|" + d.serial : "n:" + d.name;
}

function wallpaperOutputProblem(entry) {
    if (!isObject(entry))
        return "not-an-object";
    for (const key of Object.keys(entry)) {
        if (["display", "source", "path", "color", "fit", "interval", "shuffle"].indexOf(key) < 0)
            return "unknown key " + key;
    }
    const d = entry.display;
    if (!isObject(d))
        return "display";
    for (const key of Object.keys(d)) {
        if (["name", "model", "serial"].indexOf(key) < 0)
            return "display";
    }
    for (const key of ["name", "model", "serial"]) {
        if (typeof d[key] !== "string" || d[key].length > 128 || /[\u0000-\u001f\u007f-\u009f]/.test(d[key]))
            return "display";
    }
    if (d.name === "" && !(d.model !== "" && d.serial !== ""))
        return "display";
    if ("source" in entry && RULES["wallpaper.source"].values.indexOf(entry.source) < 0)
        return "source";
    if ("path" in entry && entry.path !== "" && wallpaperPathProblem(entry.path) !== "")
        return "path";
    if ("color" in entry && !Ui.PointerColors.validColor(entry.color))
        return "color";
    if ("fit" in entry && RULES["wallpaper.fit"].values.indexOf(entry.fit) < 0)
        return "fit";
    if ("interval" in entry && RULES["wallpaper.interval"].values.indexOf(entry.interval) < 0)
        return "interval";
    if ("shuffle" in entry && typeof entry.shuffle !== "boolean")
        return "shuffle";
    return "";
}

// "" for a valid outputs array: at most 16 valid entries, no display twice.
function wallpaperOutputsProblem(list) {
    if (!Array.isArray(list))
        return "not-an-array";
    if (list.length > 16)
        return "too-many";
    const seen = {};
    for (let i = 0; i < list.length; i++) {
        const why = wallpaperOutputProblem(list[i]);
        if (why !== "")
            return "entry " + i + ": " + why;
        const k = wallpaperDisplayKey(list[i].display);
        if (seen[k])
            return "entry " + i + ": duplicate display";
        seen[k] = true;
    }
    return "";
}

// Error message for an invalid value, or "" when the value is acceptable for the key.
function validate(path, value) {
    const rule = RULES[path];
    if (!rule)
        return "unknown setting: " + path;
    switch (rule.type) {
    case "enum":
        return rule.values.indexOf(value) >= 0 ? "" : path + ": expected one of " + rule.values.join(", ");
    case "tint":
        return Ui.IconModes.validTint(value) ? "" : path + ": expected accent or a #rrggbb colour";
    case "folderColor":
        return Ui.FolderStyle.validColor(value) ? "" : path + ": expected theme, accent or a #rrggbb colour";
    case "pointerColor":
        return Ui.PointerColors.validColor(value) ? "" : path + ": expected a #rrggbb colour";
    case "wallpaperPath":
        // "" (no path) is valid: the source then reads as the built-in artwork.
        return value === "" || wallpaperPathProblem(value) === "" ? "" : path + ": expected an absolute path without control characters (at most 4096 bytes)";
    case "wallpaperOutputs": {
        const why = wallpaperOutputsProblem(value);
        return why === "" ? "" : path + ": " + why;
    }
    case "boolean":
        return typeof value === "boolean" ? "" : path + ": expected true or false";
    case "integer":
        if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value)
            return path + ": expected an integer";
        return value >= rule.min && value <= rule.max ? "" : path + ": expected " + rule.min + " to " + rule.max;
    case "number":
        if (typeof value !== "number" || !isFinite(value))
            return path + ": expected a number";
        return value >= rule.min && value <= rule.max ? "" : path + ": expected " + rule.min + " to " + rule.max;
    }
    return "unsupported rule";
}

// The unsafe-file detection (integers beyond 2^53, duplicate keys, integer-like keys) lives in
// ui/Grassfield/Ui/JsonSafety.js, shared with the shell's merge-before-write. The app edits by
// parsing and re-serializing the whole file; a file with any of those is refused (read-only, same
// banner as a malformed file) instead of being silently altered. Returns "" when safe.
function unsafeReason(text) {
    return Ui.JsonSafety.unsafeReason(text);
}

// Parse the file text. Empty text is a fresh file ({}); anything that is not a JSON object is an error (a translated
// sentence fragment, shown in the Settings banner).
function parse(text) {
    if (text === null || text === undefined || String(text).trim() === "")
        return {ok: true, data: {}, fresh: true, error: ""};
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return {ok: false, data: {}, fresh: false, error: qsTranslate("Store", "the file is not valid JSON (%1)").arg(String(e.message).replace(/[.\s]+$/, ""))};
    }
    if (data === null || typeof data !== "object" || Array.isArray(data))
        return {ok: false, data: {}, fresh: false, error: qsTranslate("Store", "the top level is not a JSON object")};
    const unsafe = unsafeReason(String(text));
    if (unsafe !== "")
        return {ok: false, data: {}, fresh: false, error: qsTranslate("Store", "it cannot be edited safely: %1").arg(unsafe)};
    return {ok: true, data: data, fresh: false, error: ""};
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Value of a dotted path in parsed data, validated; the schema default when absent or invalid.
function read(data, path) {
    let node = data;
    for (const part of path.split(".")) {
        if (!isObject(node))
            return DEFAULTS[path];
        node = node[part];
    }
    return validate(path, node) === "" ? node : DEFAULTS[path];
}

// Set several keys at once (`entries`: {dotted path: value}) in one merged text, so that a reader that watches the file (the
// shell) never sees half of a change: a wallpaper source and its path are written together. Same rules as setValue.
function setValues(text, entries) {
    for (const path of Object.keys(entries)) {
        const bad = validate(path, entries[path]);
        if (bad !== "")
            return {ok: false, text: "", error: bad};
    }
    const parsed = parse(text);
    if (!parsed.ok)
        return {ok: false, text: "", error: parsed.error};
    const data = parsed.data;
    if (parsed.fresh)
        data.version = 1;
    else if (data.version !== 1)
        return {ok: false, text: "", error: qsTranslate("Store", "unsupported contract version: %1").arg(JSON.stringify(data.version))};
    for (const path of Object.keys(entries)) {
        const parts = path.split(".");
        let node = data;
        for (let i = 0; i < parts.length - 1; i++) {
            if (!isObject(node[parts[i]]))
                node[parts[i]] = {};
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = entries[path];
    }
    return {ok: true, text: JSON.stringify(data, null, 2) + "\n", error: ""};
}

// Set `path` to `value` in the current file text. Returns {ok, text, error}. On failure `text` is
// unusable and the file must not be written. Every key already in the file is kept, `version` is
// added to a fresh file. Unknown keys of the file are kept as they are (the shell ignores them).
function setValue(text, path, value) {
    const bad = validate(path, value);
    if (bad !== "")
        return {ok: false, text: "", error: bad};
    const parsed = parse(text);
    if (!parsed.ok)
        return {ok: false, text: "", error: parsed.error};
    const data = parsed.data;
    if (parsed.fresh)
        data.version = 1;
    else if (data.version !== 1)
        return {ok: false, text: "", error: qsTranslate("Store", "unsupported contract version: %1").arg(JSON.stringify(data.version))};
    const parts = path.split(".");
    let node = data;
    for (let i = 0; i < parts.length - 1; i++) {
        if (!isObject(node[parts[i]]))
            node[parts[i]] = {};
        node = node[parts[i]];
    }
    node[parts[parts.length - 1]] = value;
    return {ok: true, text: JSON.stringify(data, null, 2) + "\n", error: ""};
}
