.pragma library

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
    "dock.magnificationEnabled": true,
    "dock.autohide": false,
    "windows.titlebarDoubleClick": "zoom",
    "notifications.dnd": false,
    "notifications.previews": "unlocked",
    "lock.idleMinutes": 5,
    "hotCorners.topLeft": "none",
    "hotCorners.topRight": "none",
    "hotCorners.bottomLeft": "none",
    "hotCorners.bottomRight": "none"
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
    "windows.titlebarDoubleClick": {type: "enum", values: ["zoom", "minimize", "none"]},
    "notifications.dnd": {type: "boolean"},
    "notifications.previews": {type: "enum", values: ["always", "unlocked", "never"]},
    "lock.idleMinutes": {type: "integer", min: 0, max: 240},
    "hotCorners.topLeft": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.topRight": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.bottomLeft": {type: "enum", values: CORNER_ACTIONS},
    "hotCorners.bottomRight": {type: "enum", values: CORNER_ACTIONS}
};

// Error message for an invalid value, or "" when the value is acceptable for the key.
function validate(path, value) {
    const rule = RULES[path];
    if (!rule)
        return "unknown setting: " + path;
    switch (rule.type) {
    case "enum":
        return rule.values.indexOf(value) >= 0 ? "" : path + ": expected one of " + rule.values.join(", ");
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

// Parse the file text. Empty text is a fresh file ({}); anything that is not a JSON object is an error.
function parse(text) {
    if (text === null || text === undefined || String(text).trim() === "")
        return {ok: true, data: {}, fresh: true, error: ""};
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return {ok: false, data: {}, fresh: false, error: String(e.message)};
    }
    if (data === null || typeof data !== "object" || Array.isArray(data))
        return {ok: false, data: {}, fresh: false, error: "the top level is not a JSON object"};
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
        return {ok: false, text: "", error: "unsupported contract version: " + JSON.stringify(data.version)};
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
