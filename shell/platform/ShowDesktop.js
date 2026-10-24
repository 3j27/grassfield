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

// The addresses of the record that are still parked (`parked`: addresses now on the parking workspace): a window that
// closed or was moved by hand is left alone.
function survivors(record, parked) {
    const set = {};
    for (const p of Array.isArray(parked) ? parked : [])
        set[address(p)] = true;
    return restoreOrder(record).filter(a => set[a] === true);
}

// Compositor events that end Show Desktop (switching Space, opening a window); everything else, our own moves included,
// does not.
function endsOn(eventName) {
    return eventName === "workspace" || eventName === "workspacev2" || eventName === "openwindow";
}

function serialize(record) {
    if (!record)
        return "";
    return JSON.stringify({version: VERSION, record: record}) + "\n";
}

// "" or damaged text gives null; anything that does not validate is dropped, never trusted.
function parse(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!data || data.version !== VERSION || !data.record || !Array.isArray(data.record.windows))
        return null;
    const r = data.record;
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
