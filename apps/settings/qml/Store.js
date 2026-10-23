.pragma library
.import Grassfield.Ui 1.0 as Ui
// The wallpaper rules live in ui/Grassfield/Ui/WallpaperConfig.js, once. They are imported WITHOUT a version: a versioned
// .import resolves the installed (older) Grassfield.Ui and does not find a module added since, the unversioned one resolves
// the tree's own (QML_IMPORT_PATH, -import).
.import Grassfield.Ui as Tree

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
    "accessibility.increaseContrast": false,
    "accessibility.textSize": 1,
    "dock.size": 48,
    "dock.position": "bottom",
    "dock.magnification": 1.6,
    "dock.magnificationEnabled": false,
    "dock.autohide": false,
    "dock.showRecents": true,
    "dock.minimizeIntoApp": false,
    "dock.animateOpening": true,
    "dock.showIndicators": true,
    "dock.minimizeEffect": "funnel",
    "desktop.showIcons": true,
    "menubar.showBackground": false,
    "menubar.autoHide": "fullscreen",
    "menubar.showNowPlaying": true,
    "menubar.showSearch": true,
    "windows.titlebarDoubleClick": "zoom",
    "windows.tilingEdges": true,
    "windows.tilingMenuBar": true,
    "windows.tilingMargins": true,
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
    "wallpaper.source": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.source,
    "wallpaper.path": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.path,
    "wallpaper.color": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.color,
    "wallpaper.fit": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.fit,
    "wallpaper.interval": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.interval,
    "wallpaper.shuffle": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.shuffle,
    "wallpaper.videoOnBattery": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.videoOnBattery,
    "wallpaper.online.provider": Tree.WallpaperConfig.WALLPAPER_DEFAULTS.online.provider,
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
    "accessibility.increaseContrast": {type: "boolean"},
    "accessibility.textSize": {type: "number", min: 1, max: 1.3},
    "dock.size": {type: "integer", min: 32, max: 96},
    "dock.position": {type: "enum", values: ["left", "bottom", "right"]},
    "dock.magnification": {type: "number", min: 1, max: 2.5},
    "dock.magnificationEnabled": {type: "boolean"},
    "dock.autohide": {type: "boolean"},
    "dock.showRecents": {type: "boolean"},
    "dock.minimizeIntoApp": {type: "boolean"},
    "dock.animateOpening": {type: "boolean"},
    "dock.showIndicators": {type: "boolean"},
    "dock.minimizeEffect": {type: "enum", values: ["funnel", "shrink"]},
    "desktop.showIcons": {type: "boolean"},
    "menubar.showBackground": {type: "boolean"},
    "menubar.autoHide": {type: "enum", values: ["always", "desktop", "fullscreen", "never"]},
    "menubar.showNowPlaying": {type: "boolean"},
    "menubar.showSearch": {type: "boolean"},
    "windows.titlebarDoubleClick": {type: "enum", values: ["zoom", "minimize", "none"]},
    "windows.tilingEdges": {type: "boolean"},
    "windows.tilingMenuBar": {type: "boolean"},
    "windows.tilingMargins": {type: "boolean"},
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
    // ADR-0016: lists, defaults, path and outputs rules come from ui/Grassfield/Ui/WallpaperConfig.js (one copy).
    "wallpaper.source": {type: "enum", values: Tree.WallpaperConfig.SOURCES},
    "wallpaper.path": {type: "wallpaperPath"},
    "wallpaper.color": {type: "pointerColor"},
    "wallpaper.fit": {type: "enum", values: Tree.WallpaperConfig.FITS},
    "wallpaper.interval": {type: "enum", values: Tree.WallpaperConfig.INTERVAL_NAMES},
    "wallpaper.shuffle": {type: "boolean"},
    "wallpaper.videoOnBattery": {type: "boolean"},
    "wallpaper.online.provider": {type: "enum", values: Tree.WallpaperConfig.ONLINE_PROVIDERS},
    "wallpaper.outputs": {type: "wallpaperOutputs"}
};

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
        return value === "" || Tree.WallpaperConfig.pathProblem(value) === "" ? "" : path + ": expected an absolute path without control characters (at most 4096 bytes)";
    case "wallpaperOutputs": {
        const why = Tree.WallpaperConfig.outputsProblem(value);
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
