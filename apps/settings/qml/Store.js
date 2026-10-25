.pragma library
.import Grassfield.Ui 1.0 as Ui
// The wallpaper rules live in ui/Grassfield/Ui/WallpaperConfig.js, once. They are imported WITHOUT a version: a versioned
// .import resolves the installed (older) Grassfield.Ui and does not find a module added since, the unversioned one resolves
// the tree's own (QML_IMPORT_PATH, -import).
.import Grassfield.Ui as Tree

// grassfield.json (contract version 1) merge and validation logic. Pure functions, no I/O:
// the caller reads the file, passes its text in and writes the returned text back.
// Rules: preserve every other key of the file, never write a key outside the schema, refuse a malformed file.

// DEFAULTS, RULES and validate come from the generated ui/Grassfield/Ui/SettingsContract.js (scripts/dev/gen-settings.py,
// from the schema): one definition for every reader. The Dock owns dock.pinned, dock.recent and dock.stackOptions: they
// are only preserved, never settable.
const DEFAULTS = Tree.SettingsContract.DEFAULTS;
const RULES = Tree.SettingsContract.RULES;

// Error message for an invalid value, or "" when the value is acceptable for the key (writes are strict).
function validate(path, value) {
    return Tree.SettingsContract.validate(path, value);
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

// Value of a dotted path in parsed data, as every reader sees it: a number out of range is clamped (an integer is rounded
// first), any other invalid value reads as the schema default (SettingsContract.read).
function read(data, path) {
    return Tree.SettingsContract.read(data, path);
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
