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

// The windows of `record` to send back: those that are on the parking workspace now (`windows`: the toplevel data,
// [{address, parked, ...}]), in restoreOrder. One rule for the ending, the verify and the crash recovery: a window that closed
// is skipped, and a window the user moved by hand out of the parking workspace stays where the user put it.
function toRestore(record, windows) {
    const parked = {};
    for (const w of Array.isArray(windows) ? windows : []) {
        if (w && w.parked === true)
            parked[address(w.address)] = true;
    }
    return restoreOrder(record).filter(a => parked[a] === true);
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

// A window opening ends Show Desktop (a window the records parked, or one opening on the parking workspace, is our own move
// and does not). `data` is the openwindow text "addr,workspace,class,title"; `records` the records now on.
function endsOn(eventName, data, records) {
    const text = typeof data === "string" ? data : "";
    const list = Array.isArray(records) ? records : [];
    const parkedWindow = a => list.some(r => r.windows.some(w => w.address === a));
    if (eventName === "openwindow") {
        const parts = text.split(",");
        return parts[1] !== PARKING && !parkedWindow(address(parts[0]));
    }
    return false;
}

// An app activating a parked window (focus_on_activate): Hyprland focuses it and shows the special workspace over the screen,
// the parked windows as an overlay. Show Desktop is over then (macOS: an app activating a window ends it). These events are
// not decisive on their own (parking the focused window moves the focus to a window that is about to be parked too), so they
// only schedule a look at who has the focus (parkedHasFocus).
function checksActivation(eventName) {
    return ["activewindowv2", "activewindow", "urgent", "activespecial", "activespecialv2"].indexOf(eventName) >= 0;
}

// True when the window that has the focus is one of the parked ones: an activation reached a hidden window.
// `windows`: the toplevel data ({address, parked}); `focus`: the focused window's address, "" for none.
function parkedHasFocus(windows, focus) {
    const f = address(focus);
    if (f === "")
        return false;
    return (Array.isArray(windows) ? windows : []).some(w => w && w.parked === true && address(w.address) === f);
}

// Events after which the Spaces the displays show may have changed. They cannot be read as "the user switched Space": when
// only the focus moves to another display Hyprland reports a workspace event too (the Space that display already shows), so
// the events only trigger a look at what each display shows now (spaceChanged).
function checksSpaces(eventName) {
    return ["workspace", "workspacev2", "focusedmon", "focusedmonv2", "moveworkspace", "moveworkspacev2", "monitoradded",
        "monitoraddedv2", "monitorremoved", "monitorremovedv2"].indexOf(eventName) >= 0;
}

// True when a display now shows another Space than the one Show Desktop was pressed on, on either display, or when a display
// of the records is gone. `shown`: [{name, workspace}] from the monitor list. A record without a display name is not compared.
// The focus or the pointer moving to the other display changes nothing here: its Space is the one it showed.
function spaceChanged(records, shown) {
    const list = Array.isArray(shown) ? shown : [];
    for (const r of Array.isArray(records) ? records : []) {
        if (r.screen === "")
            continue;
        const m = list.find(x => x && x.name === r.screen);
        if (!m || workspaceId(m.workspace) !== r.workspace)
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
        if (a !== "" && !windows.some(x => x.address === a))
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
