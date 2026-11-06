.pragma library
.import "MenuBridge.js" as Bridge

// Ongoing activities, the shell's side (ADR-0052): what grassfield-menu-bridge forwards from org.grassfield.Ongoing1 (menu/1
// "ongoing" and "ongoing-end" lines), the state the menu bar draws, the lock-screen redaction and the compact text of a menu
// bar item. Pure functions, unit-tested by tests/unit/tst_ongoing.qml.
//
// The bridge already validated what applications sent; this side checks it again (the socket is a trust boundary too): every
// field is type-checked, text is one plain line and capped (MenuBridge.js plainText), at most limits.activities are kept.

var kinds = ["timer", "transfer", "recording", "install", "call", "progress"];

var limits = {
    activities: 16, // as the bridge's kMaxTotal
    title: 64,
    subtitle: 128,
    label: 24,
    actions: 3,
    app: 255
};

// The menu bar glyph of each kind (ui/Grassfield/Ui/icons-bar).
var symbols = {
    timer: "clock",
    transfer: "transfer",
    recording: "record",
    install: "download",
    call: "phone",
    progress: "activity"
};

function symbolOf(kind) {
    return symbols[kind] !== undefined ? symbols[kind] : symbols.progress;
}

function isKey(id) {
    return typeof id === "string" && /^[0-9a-f]{16}$/.test(id);
}

function isActionId(id) {
    return typeof id === "string" && /^[a-z][a-z0-9-]{0,31}$/.test(id);
}

function timeOrNull(value) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value && value > 0 ? value : null;
}

// A parsed "ongoing" JSON object -> {id, app, kind, title, subtitle, progress, started, ends, actions, redacted}, or null.
function parse(msg) {
    if (!msg || typeof msg !== "object" || !isKey(msg.id) || kinds.indexOf(msg.kind) < 0)
        return null;
    const redacted = msg.redacted === true;
    const app = typeof msg.app === "string" && /^[A-Za-z0-9._-]{0,255}$/.test(msg.app) ? msg.app : "";
    let progress = null;
    if (msg.progress !== null && msg.progress !== undefined) {
        if (typeof msg.progress !== "number" || !isFinite(msg.progress) || msg.progress < 0 || msg.progress > 1)
            return null;
        progress = msg.progress;
    }
    const actions = [];
    if (!redacted && Array.isArray(msg.actions)) {
        for (let i = 0; i < msg.actions.length && actions.length < limits.actions; i++) {
            const a = msg.actions[i];
            if (!a || !isActionId(a.id) || actions.some(b => b.id === a.id))
                continue;
            const label = Bridge.plainText(a.label, limits.label);
            if (label !== "")
                actions.push({id: a.id, label: label});
        }
    }
    return {
        id: msg.id,
        app: redacted ? "" : app,
        kind: msg.kind,
        title: redacted ? "" : Bridge.plainText(msg.title, limits.title),
        subtitle: redacted ? "" : Bridge.plainText(msg.subtitle, limits.subtitle),
        progress: progress,
        started: timeOrNull(msg.started),
        ends: timeOrNull(msg.ends),
        actions: actions,
        redacted: redacted
    };
}

// ---- state: {items: {id: item}, seq: n}; an item keeps its first arrival's `seq` (its place in the bar) ----

function empty() {
    return {items: {}, seq: 0};
}

// `state` is not changed. A new activity past limits.activities is dropped.
function apply(state, item) {
    const items = Object.assign({}, state.items);
    const known = items[item.id];
    if (!known && Object.keys(items).length >= limits.activities)
        return state;
    const seq = known ? known.seq : state.seq + 1;
    items[item.id] = Object.assign({}, item, {seq: seq});
    return {items: items, seq: Math.max(state.seq, seq)};
}

function end(state, id) {
    if (state.items[id] === undefined)
        return state;
    const items = Object.assign({}, state.items);
    delete items[id];
    return {items: items, seq: state.seq};
}

// Oldest first.
function ordered(state) {
    return Object.keys(state.items).map(k => state.items[k]).sort((a, b) => a.seq - b.seq);
}

// The menu bar's items: the `max` most recently started, left to right in the order they started.
function barItems(state, max) {
    const all = ordered(state);
    return all.slice(Math.max(0, all.length - max));
}

// What a locked session may show: the kind, its progress and times, nothing the application wrote, no button.
function redact(item) {
    return Object.assign({}, item, {app: "", title: "", subtitle: "", actions: [], redacted: true});
}

function view(item, locked) {
    return locked && item && !item.redacted ? redact(item) : item;
}

function find(state, id) {
    return state.items[id] !== undefined ? state.items[id] : null;
}

// ---- compact text of a menu bar item ----

// "0:05", "4:05", "1:02:03" for a number of seconds (negative counts as 0).
function duration(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const two = n => (n < 10 ? "0" : "") + n;
    return h > 0 ? h + ":" + two(m) + ":" + two(sec) : m + ":" + two(sec);
}

// {kind: "time", text} (the countdown's remaining or the elapsed time), {kind: "percent", value} (0..100, whole), or
// {kind: "none"} (indeterminate). A countdown rounds up, as a kitchen timer shows 0:01 until the end.
function compact(item, nowMs) {
    if (item.ends !== null)
        return {kind: "time", text: duration(Math.ceil((item.ends - nowMs) / 1000))};
    if (item.started !== null)
        return {kind: "time", text: duration((nowMs - item.started) / 1000)};
    if (item.progress !== null)
        return {kind: "percent", value: Math.floor(item.progress * 100)};
    return {kind: "none"};
}

// True while some item shows a time that moves (the bar then ticks once a second).
function ticking(items) {
    return items.some(it => it.ends !== null || it.started !== null);
}

// ---- shell -> bridge lines ("" when an argument is invalid) ----

function lockLine(locked) {
    return JSON.stringify({type: "lock", locked: locked === true}) + "\n";
}

function actionLine(id, action) {
    if (!isKey(id) || !isActionId(action))
        return "";
    return JSON.stringify({type: "ongoing-action", id: id, action: action}) + "\n";
}
