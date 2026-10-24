.pragma library

// Show Desktop bookkeeping (pure, unit-tested; GF-106). macOS model: Show Desktop moves the windows of the current
// display aside; switching Space, activating a window, opening an app or pressing it again ends it and brings every window
// back exactly where it was (same Space, same tiling order, same focus). The record below is what makes "exactly" possible:
// it is kept in memory and in the state dir, so a restarted shell puts the windows back at start (nothing stays parked).
//
// Record: {screen, workspace, focus, windows: [{address, x, y}]}; addresses are Hyprland's, lower-case hex without 0x.

const VERSION = 1;
const MAX_WINDOWS = 256;
// Where the windows wait: a special workspace nobody toggles (never special:hidden: "Hide app" lists that one).
const PARKING = "special:desktop";

function address(value) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(value));
    return m ? m[1].toLowerCase() : "";
}

function workspaceId(value) {
    const s = String(value);
    return /^[1-9][0-9]{0,8}$/.test(s) ? parseInt(s, 10) : 0;
}

function num(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
}

// The windows Show Desktop moves: those on workspace `workspace` that are neither minimized nor hidden. `windows`:
// [{address, workspace, x, y, minimized, hidden}]. Null when nothing qualifies, when the workspace is not a regular one,
// or when Stages is on (a stage cannot be restored window by window: docs/specs/stages.md ST8/ST9, the call does nothing).
function capture(windows, screen, workspace, focus, stagesOn) {
    if (stagesOn === true || workspaceId(workspace) === 0 || !Array.isArray(windows))
        return null;
    const mine = [];
    for (const w of windows) {
        if (!w || workspaceId(w.workspace) !== workspaceId(workspace) || w.minimized === true || w.hidden === true)
            continue;
        const a = address(w.address);
        if (a === "" || mine.some(x => x.address === a))
            continue;
        mine.push({address: a, x: num(w.x), y: num(w.y)});
        if (mine.length >= MAX_WINDOWS)
            break;
    }
    if (mine.length === 0)
        return null;
    const f = address(focus);
    return {screen: typeof screen === "string" ? screen : "", workspace: workspaceId(workspace), focus: mine.some(x => x.address === f) ? f : "", windows: mine};
}

// Order in which the windows go back: top to bottom, then left to right, so a tiled layout rebuilds as it was.
function restoreOrder(record) {
    if (!record || !Array.isArray(record.windows))
        return [];
    return record.windows.slice().sort((a, b) => a.y - b.y || a.x - b.x).map(w => w.address);
}

// The windows of `record` to send back: those that still exist (`windows`: the toplevel data, [{address, workspace, ...}])
// and are not on the recorded Space already, in restoreOrder. A window that closed is skipped. (The check is on where the
// window is, not on whether the model says "parked": a model that has not caught up with the park must not leave a window hidden.)
function toRestore(record, windows) {
    const where = {};
    for (const w of Array.isArray(windows) ? windows : [])
        where[address(w.address)] = workspaceId(w.workspace);
    return restoreOrder(record).filter(a => a in where && where[a] !== record.workspace);
}

function sameAddress(a, b) {
    return address(a) !== "" && address(a) === address(b);
}

// The addresses of the record that are still parked (`parked`: addresses now on the parking workspace): a window that
// closed or was moved by hand is left alone.
function survivors(record, parked) {
    const set = {};
    for (const p of Array.isArray(parked) ? parked : [])
        set[address(p)] = true;
    return restoreOrder(record).filter(a => set[a] === true);
}

// One record per display, all displays at once (macOS Show Desktop clears every display). `monitors`: [{name, workspace}]
// with the Space each display shows; the focused window belongs to the record of the display that shows it. [] when nothing
// qualifies anywhere or when Stages is on.
function captureAll(windows, monitors, focus, stagesOn) {
    if (!Array.isArray(monitors))
        return [];
    const out = [];
    for (const m of monitors) {
        const r = m ? capture(windows, m.name, m.workspace, focus, stagesOn) : null;
        if (r)
            out.push(r);
    }
    return out;
}

// What a compositor event means for Show Desktop: true when it ends it. Switching Space and opening a window do, except the
// events our own moves raise, which are told apart by what they name and not by when they came: a Space event for the
// parking workspace, a window event for a window the records parked (or one that opens on the parking workspace).
// `data` is the event's text (Hyprland: "addr,workspace,class,title" for openwindow, "id,name" for workspacev2, "name" for
// workspace); `records` the records now on.
function endsOn(eventName, data, records) {
    const text = typeof data === "string" ? data : "";
    if (eventName === "workspace")
        return text !== PARKING;
    if (eventName === "workspacev2")
        return text.split(",").slice(1).join(",") !== PARKING;
    if (eventName === "openwindow") {
        const parts = text.split(",");
        const a = address(parts[0]);
        if (parts[1] === PARKING)
            return false;
        for (const r of Array.isArray(records) ? records : []) {
            if (r.windows.some(w => w.address === a))
                return false;
        }
        return true;
    }
    return false;
}

// The record whose focused window should get the focus back when Show Desktop is pressed again: the one shown on the same
// Space now (`shown`: [{name, workspace}]); an ending for any other reason never asks for focus (the window that ended it,
// or the Space the user went to, already has it).
function focusTarget(records, shown) {
    for (const r of Array.isArray(records) ? records : []) {
        const m = (Array.isArray(shown) ? shown : []).find(x => x && x.name === r.screen);
        if (r.focus !== "" && m && workspaceId(m.workspace) === r.workspace)
            return r.focus;
    }
    return "";
}

function serialize(records) {
    if (!Array.isArray(records) || records.length === 0)
        return "";
    return JSON.stringify({version: VERSION, records: records}) + "\n";
}

function parseRecord(r) {
    if (!r || !Array.isArray(r.windows))
        return null;
    const windows = [];
    for (const w of r.windows.slice(0, MAX_WINDOWS)) {
        const a = w ? address(w.address) : "";
        if (a !== "")
            windows.push({address: a, x: num(w.x), y: num(w.y)});
    }
    if (windows.length === 0 || workspaceId(r.workspace) === 0)
        return null;
    return {screen: typeof r.screen === "string" ? r.screen : "", workspace: workspaceId(r.workspace), focus: address(r.focus), windows: windows};
}

// "" or damaged text gives []; anything that does not validate is dropped, never trusted. A file of the first format (one
// `record`) reads as one record.
function parse(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!data || data.version !== VERSION)
        return [];
    const list = Array.isArray(data.records) ? data.records.slice(0, 16) : (data.record ? [data.record] : []);
    return list.map(parseRecord).filter(r => r !== null);
}
