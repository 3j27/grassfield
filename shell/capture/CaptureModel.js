.pragma library

// The capture toolbar's decisions (spec docs/specs/system-dialogs.md "Capture toolbar", ADR-0045 OC-1): its modes in macOS 27's
// order, the mode it opens in, the arrows, the helper's argv for a mode and the options, and the Options menu. Pure functions
// (tests/unit/tst_capturemodel.qml); Capture.qml and CaptureToolbar.qml hold the state and draw it.

// The modes, left to right: the three captures, then the two recordings. `glyph`: the button's symbol (branding/icons).
var MODES = [
    {id: "screen", record: false, glyph: "capture-screen"},
    {id: "window", record: false, glyph: "capture-window"},
    {id: "selection", record: false, glyph: "capture-selection"},
    {id: "recordScreen", record: true, glyph: "record-screen"},
    {id: "recordSelection", record: true, glyph: "record-selection"}
];
var SAVE_TO = ["desktop", "documents", "clipboard", "preview"];
// A recording is not copied: its Save to lists these, and a stored "clipboard" means the Desktop for it.
var RECORD_SAVE_TO = ["desktop", "documents", "preview"];
var TIMERS = ["none", "5", "10"];
var OUTPUT_NAME = /^[A-Za-z0-9._-]{1,64}$/;

function known(mode) {
    return MODES.some(m => m.id === mode);
}

function isRecord(mode) {
    return mode === "recordScreen" || mode === "recordSelection";
}

// A mode the toolbar offers now: the recordings only while one can start (the recorder is installed, none is running).
function available(mode, canRecord) {
    return known(mode) && (canRecord || !isRecord(mode));
}

// The modes shown, in order (the recordings' group is not shown without the recorder: OC-0 graceful degradation).
function shown(recorder) {
    return MODES.filter(m => recorder || !m.record);
}

// The mode the toolbar opens in: the one chosen last, else Capture Selected Portion (macOS's first use); a recording that
// cannot start now gives way to Capture Selected Portion.
function startMode(stored, canRecord) {
    return available(stored, canRecord) ? stored : "selection";
}

// Left (-1) and Right (+1): the previous or next mode the toolbar offers, stopping at the ends (macOS's segmented toolbar).
function step(mode, delta, canRecord) {
    const ids = MODES.filter(m => available(m.id, canRecord)).map(m => m.id);
    const at = ids.indexOf(mode);
    if (at < 0)
        return ids.length > 0 ? ids[0] : mode;
    return ids[Math.max(0, Math.min(ids.length - 1, at + (delta < 0 ? -1 : 1)))];
}

// The destination a mode uses for the stored Save to.
function saveTo(mode, stored) {
    const value = SAVE_TO.indexOf(stored) >= 0 ? stored : "desktop";
    return isRecord(mode) && value === "clipboard" ? "desktop" : value;
}

function timerSeconds(timer) {
    return timer === "5" ? 5 : timer === "10" ? 10 : 0;
}

// The helper's arguments (packaging/bin/grassfield-capture) for a mode, the options ({saveTo, timer, microphone,
// showPointer}, as the settings store them) and the toolbar's display (Record Entire Screen records it).
function helperArgs(mode, options, output) {
    const o = options || {};
    const args = isRecord(mode) ? ["record", mode === "recordScreen" ? "screen" : "selection"]
                                : [known(mode) ? mode : "selection"];
    args.push("--save", saveTo(mode, o.saveTo));
    const seconds = timerSeconds(o.timer);
    if (seconds > 0)
        args.push("--timer", String(seconds));
    if (o.showPointer === true)
        args.push("--pointer");
    if (isRecord(mode) && o.microphone === "default")
        args.push("--mic");
    if (mode === "recordScreen" && typeof output === "string" && OUTPUT_NAME.test(output))
        args.push("--output", output);
    return args;
}

// The Options menu (PopupMenu rows): Save to, Timer, Microphone for a recording, then Options (Show Mouse Pointer), each a
// section with its header and a check on the current choice. `labels` holds the translated texts (the QML's qsTr), by key:
// saveTo desktop documents clipboard preview timer none five ten microphone micNone micDefault options showPointer.
function menuModel(mode, options, labels) {
    const o = options || {};
    const l = labels || {};
    const record = isRecord(mode);
    const destination = saveTo(mode, o.saveTo);
    const timer = TIMERS.indexOf(o.timer) >= 0 ? o.timer : "none";
    const rows = [{header: true, text: l.saveTo}];
    for (const id of record ? RECORD_SAVE_TO : SAVE_TO)
        rows.push({id: "saveTo:" + id, text: l[id], checked: destination === id});
    rows.push({separator: true}, {header: true, text: l.timer});
    const timerLabels = {"none": l.none, "5": l.five, "10": l.ten};
    for (const id of TIMERS)
        rows.push({id: "timer:" + id, text: timerLabels[id], checked: timer === id});
    if (record) {
        rows.push({separator: true}, {header: true, text: l.microphone});
        rows.push({id: "microphone:none", text: l.micNone, checked: o.microphone !== "default"});
        rows.push({id: "microphone:default", text: l.micDefault, checked: o.microphone === "default"});
    }
    rows.push({separator: true}, {header: true, text: l.options});
    rows.push({id: "showPointer:toggle", text: l.showPointer, checked: o.showPointer === true});
    return rows;
}

// A chosen row as the setting it changes ({key, value} of capture.<key>), or null for a row that changes nothing.
function choice(id, options) {
    const o = options || {};
    const parts = String(id || "").split(":");
    if (parts.length !== 2)
        return null;
    const key = parts[0];
    const value = parts[1];
    if (key === "saveTo" && SAVE_TO.indexOf(value) >= 0)
        return {key: key, value: value};
    if (key === "timer" && TIMERS.indexOf(value) >= 0)
        return {key: key, value: value};
    if (key === "microphone" && (value === "none" || value === "default"))
        return {key: key, value: value};
    if (key === "showPointer" && value === "toggle")
        return {key: key, value: o.showPointer !== true};
    return null;
}
