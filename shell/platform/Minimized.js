.pragma library

// Minimized-window bookkeeping (pure, unit-tested). The shell records every window it
// minimized: Hyprland has no minimized state, so the record is the source of truth for the Dock.
// Record: {toplevel, address, appId, title}.

// Validated lowercase hex of a Hyprland window address ("0x" prefix optional), "" if invalid.
// Verbs of the compositor plugin (hl.plugin.grassfield.<verb>); anything else is never put in Lua.
var pluginVerbs = ["hello", "minimize", "restore", "overview", "theme"];

function isPluginVerb(verb) {
    return typeof verb === "string" && pluginVerbs.indexOf(verb) >= 0;
}

function normalizeAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// Lua requests built from validated pieces only (untrusted data is never interpolated). ""
// means the input was rejected: callers must not dispatch it.

// Hyprland workspace specifier the shell uses: a positive integer id or "special:<name>".
// Arbitrary names (e.g. "undefined" from a missing value) are rejected.
function validWorkspace(workspace) {
    return /^(?:[1-9][0-9]{0,8}|special:[A-Za-z0-9_-]{1,64})$/.test(String(workspace));
}

function moveRequest(address, workspace) {
    const hex = normalizeAddress(address);
    const ws = String(workspace);
    if (hex === "" || !validWorkspace(ws))
        return "";
    return "hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, window = \"address:0x" + hex + "\" })";
}

// Focus of a regular workspace by id (positive integer), "" if invalid.
function focusRequest(id) {
    const ws = String(id);
    if (!/^[1-9][0-9]{0,8}$/.test(ws))
        return "";
    return "hl.dsp.focus({ workspace = \"" + ws + "\" })";
}

// Fullscreen state change of a window; mode "maximized" is Zoom, "fullscreen" is full screen.
function fullscreenRequest(address, mode) {
    const hex = normalizeAddress(address);
    if (hex === "" || (mode !== "maximized" && mode !== "fullscreen"))
        return "";
    return "hl.dsp.window.fullscreen({ mode = \"" + mode + "\", window = \"address:0x" + hex + "\" })";
}

// {x, y, w, h} as finite numbers, or null.
function finiteRect(rect) {
    if (!rect)
        return null;
    const out = [rect.x, rect.y, rect.w, rect.h].map(Number);
    return out.every(n => Number.isFinite(n)) ? {x: out[0], y: out[1], w: out[2], h: out[3]} : null;
}

// Hyprland window data `fullscreen` field: 0 none, 1 maximized (Zoom), 2 fullscreen.
function isZoomed(data) {
    return !!data && data.fullscreen === 1;
}

function has(list, toplevel) {
    return list.some(r => r.toplevel === toplevel);
}

// New list with the record appended (a window is recorded once).
function add(list, record) {
    return has(list, record.toplevel) ? list : list.concat([record]);
}

function remove(list, toplevel) {
    return list.filter(r => r.toplevel !== toplevel);
}

// Drops records whose window no longer exists. `live` is an array of toplevel handles.
function prune(list, live) {
    return list.filter(r => live.indexOf(r.toplevel) >= 0);
}

// Windows of an app (case-insensitive app id) that are minimized.
function forApp(list, appId) {
    const wanted = String(appId).toLowerCase();
    return list.filter(r => String(r.appId).toLowerCase() === wanted);
}

// Parses a `grassfield` raw event payload; returns the validated address of a minimize-request, or "".
function minimizeRequestAddress(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return "";
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "minimize-request" || typeof msg.address !== "string")
        return "";
    return normalizeAddress(msg.address);
}
