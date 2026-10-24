.pragma library

// The gfc/1 `stages` state (docs/specs/stages.md "Shell contract" 4), validated: pure, no compositor access, unit tested in
// tests/unit/tst_stages.qml. The event is a change notice ({gen, on, reason}: Hyprland cuts socket2 events at 1024 bytes);
// the state with its monitors is the reply of `hyprctl grassfield-stages` (ADR-0007 amendment 2026-10-24). An older plugin
// sent the whole state in the event: `complete` tells which one was parsed.

const reasons = ["invalid", "disabled", "no-strip", "unknown", "unavailable", "interrupted"];
const maxStages = 64;
const maxWindows = 64;

function cleanAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

function finite(n) {
    return typeof n === "number" && Number.isFinite(n);
}

function cleanWindow(w) {
    if (!w || typeof w !== "object")
        return null;
    const address = cleanAddress(w.address);
    if (address === "")
        return null;
    const out = {address: address};
    if (finite(w.x) && finite(w.y) && finite(w.w) && finite(w.h)) {
        out.x = w.x;
        out.y = w.y;
        out.w = w.w;
        out.h = w.h;
    }
    return out;
}

function cleanStage(s) {
    if (!s || typeof s !== "object" || !Number.isInteger(s.id) || s.id < 0 || !Number.isInteger(s.slot) || s.slot < -1)
        return null;
    const windows = [];
    const list = Array.isArray(s.windows) ? s.windows.slice(0, maxWindows) : [];
    for (let i = 0; i < list.length; i++) {
        const w = cleanWindow(list[i]);
        if (w)
            windows.push(w);
    }
    return {id: s.id, slot: s.slot, windows: windows};
}

function cleanMonitor(m) {
    if (!m || typeof m !== "object" || typeof m.monitor !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(m.monitor))
        return null;
    const stages = [];
    const list = Array.isArray(m.stages) ? m.stages.slice(0, maxStages) : [];
    for (let i = 0; i < list.length; i++) {
        const s = cleanStage(list[i]);
        if (s)
            stages.push(s);
    }
    return {
        monitor: m.monitor,
        workspace: Number.isInteger(m.workspace) ? m.workspace : -1,
        active: Number.isInteger(m.active) ? m.active : -1,
        hidden: m.hidden === true,
        overlap: m.overlap === true,
        stages: stages
    };
}

// {on, reason, gen, complete, monitors: {<name>: monitor}} for a stages notice or state, null for anything else (other
// types, foreign protocol versions, malformed text). `reason` is "" or one of the contract's reasons (anything else is
// dropped); `gen` the plugin's generation (-1 when absent: an older plugin); `complete` whether the text carried the
// monitors (a state), false for a notice.
function parse(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "stages" || typeof msg.on !== "boolean")
        return null;
    const monitors = {};
    const list = Array.isArray(msg.monitors) ? msg.monitors.slice(0, 8) : [];
    for (let i = 0; i < list.length; i++) {
        const m = cleanMonitor(list[i]);
        if (m)
            monitors[m.monitor] = m;
    }
    return {
        on: msg.on,
        reason: typeof msg.reason === "string" && reasons.indexOf(msg.reason) >= 0 ? msg.reason : "",
        gen: Number.isSafeInteger(msg.gen) && msg.gen >= 0 ? msg.gen : -1,
        complete: Array.isArray(msg.monitors),
        monitors: monitors
    };
}

// The stages of a monitor other than the active one, most recent first (the order of the strip, slot 0 at the top).
function stripStages(monitor) {
    if (!monitor)
        return [];
    return monitor.stages.filter(s => s.id !== monitor.active);
}

// The stage shown in tile `slot` (the event gives `slot`; -1 for the active stage and for stages beyond the tiles), or null.
function stageAtSlot(monitor, slot) {
    if (!monitor || slot < 0)
        return null;
    return monitor.stages.find(s => s.slot === slot) || null;
}

// The stage holding a window address (lower-case hex, no 0x), or null.
function stageOfWindow(monitor, address) {
    if (!monitor)
        return null;
    const a = cleanAddress(address);
    return monitor.stages.find(s => s.windows.some(w => w.address === a)) || null;
}
