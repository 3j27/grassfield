.pragma library
.import "ShowDesktop.js" as SD
.import "Minimized.js" as Minimized

// The Show Desktop event flow as a pure reducer (GF-106, reviews 4 and 5 of the shell UX batch). Compositor.qml only builds the
// context, forwards the events, the timers and the presses to the functions below and runs what they return; every decision
// (what ends Show Desktop, what is dispatched in which order, how the activated window is told, what a retry or the bound
// does) is here, so tests/unit/tst_showdesktopflow.qml replays event sequences, recorded from Hyprland in both orders an
// activation can come in, and kills a mutation of any rule.
//
// State: {records, parking, hideAt, ended, verify, activation, focusSeen, recoverTries, pending}.
// Context (what the shell reads when it calls): {now (ms), windows (toplevel data: {address, workspace, parked, x, y,
// minimized, hidden}), shown ([{name, workspace}]), focused (address), stages, loaded (the window list has arrived),
// lookbackMs, echoMs, maxVerify, maxRecover}.
// Result: {state, dispatches: [Lua strings, in order], timers: {activation|check|verify|recover: "restart"|"stop"}, persist
// (write state.records), focusDesktop (hand the keyboard to the desktop icons), refresh (read the window list, then call
// capture), ended (an ending ran), logs: [{level, text}]}.

function initial() {
    return {
        records: [],
        parking: {},
        hideAt: -1e12,
        ended: [],
        verify: {records: [], tries: 0},
        activation: {open: false, sealed: false, before: "", after: ""},
        focusSeen: {address: "", at: -1e12},
        recoverTries: 0,
        pending: false
    };
}

function clone(state) {
    return JSON.parse(JSON.stringify(state));
}

function begin(state) {
    const s = clone(state || initial());
    return {state: s, dispatches: [], timers: {}, persist: false, focusDesktop: false, refresh: false, ended: false, logs: []};
}

function send(r, request) {
    if (request !== "")
        r.dispatches.push(request);
}

function log(r, level, text) {
    r.logs.push({level: level, text: "grassfield: " + text});
}

function inRecords(records, a) {
    return a !== "" && records.some(rec => rec.windows.some(w => w.address === a));
}

// Hides the parking workspace if it is shown, by STATE (never by toggling a workspace that may be hidden: the toggle would open
// it). It is always the first dispatch of an ending, before any window moves.
function hideByState(s, ctx, r) {
    if (!SD.parkingVisible(s.parking))
        return;
    send(r, SD.hideParkingRequest());
    s.parking = {};
    s.hideAt = ctx.now;
}

// Ends Show Desktop (if on): the records are gone before anything is dispatched, so nothing can end it twice. The workspace is
// hidden first, then every window goes back to its Space in its tiling order; `refocus` (the second press, on the Space it was
// pressed on) gives the focus back to the window that had it, every other ending issues no focus request. The verify watches
// that nothing stays parked.
function ending(s, ctx, r, refocus) {
    const records = s.records;
    if (records.length === 0)
        return false;
    s.records = [];
    r.persist = true;
    r.ended = true;
    hideByState(s, ctx, r);
    const focus = refocus ? SD.focusTarget(records, ctx.shown) : "";
    let back = [];
    for (const record of records) {
        const mine = SD.toRestore(record, ctx.windows);
        back = back.concat(mine);
        mine.forEach(a => send(r, Minimized.moveRequest(a, String(record.workspace))));
    }
    s.ended = back;
    if (focus !== "" && back.indexOf(focus) >= 0)
        send(r, Minimized.focusWindowRequest(focus));
    s.verify = {records: records, tries: 0};
    r.timers.verify = "restart";
    return true;
}

// Does this event show the parking workspace (an app activated a parked window, Hyprland shows the special workspace)?
function showsParking(name, data) {
    return SD.parkingVisible(SD.parkingShownAfter({}, name, data));
}

// A Hyprland event (name, data as in socket2).
function onEvent(state, ctx, name, data) {
    const r = begin(state);
    const s = r.state;
    if (name === "activewindowv2") {
        const a = SD.address(data);
        if (a !== "") {
            // The window an app activates is named by an activewindowv2 either right BEFORE the workspace event (a real
            // activation, xdg-activation or focus_on_activate: Hyprland focuses the window, which shows its special workspace)
            // or right AFTER it (the focus dispatcher: the workspace first). Never a window outside the records. What follows
            // the hide of the workspace (sealed) is a consequence of the ending itself (Hyprland gives the focus to the first
            // window that comes back), not an activation.
            if (inRecords(s.records, a))
                s.focusSeen = {address: a, at: ctx.now};
            if (s.activation.open && !s.activation.sealed && s.activation.after === "" && s.ended.some(x => x === a))
                s.activation.after = a;
        }
        return r;
    }
    if (name === "closewindow") {
        const a = SD.address(data);
        if (a !== "") {
            const drop = rec => ({screen: rec.screen, workspace: rec.workspace, focus: rec.focus === a ? "" : rec.focus, windows: rec.windows.filter(w => w.address !== a)});
            const before = s.records.length > 0 ? JSON.stringify(s.records) : "";
            s.records = s.records.map(drop).filter(rec => rec.windows.length > 0);
            s.verify.records = s.verify.records.map(drop).filter(rec => rec.windows.length > 0);
            if (before !== "" && JSON.stringify(s.records) !== before)
                r.persist = true;
        }
        return r;
    }
    if (name === "activespecial" || name === "activespecialv2") {
        const shows = showsParking(name, data);
        if (shows && ctx.now - s.hideAt < ctx.echoMs)
            return r;   // the echo of our own hide (both event forms are posted for one change)
        s.parking = SD.parkingShownAfter(s.parking, name, data);
        if (!shows && s.activation.open)
            s.activation.sealed = true;   // the workspace is hidden again: the events that follow are not the activation's
        if (shows) {
            const seen = s.focusSeen;
            s.activation = {open: true, sealed: false, before: ctx.now - seen.at <= ctx.lookbackMs ? seen.address : "", after: ""};
            r.timers.activation = "restart";
            if (s.records.length > 0) {
                log(r, "info", "Show Desktop ends: " + name);
                ending(s, ctx, r, false);
            } else {
                hideByState(s, ctx, r);   // an earlier ending ran first: the workspace is still hidden by state
            }
        }
        return r;
    }
    if (s.records.length === 0)
        return r;
    if (SD.endsOn(name, data, s.records)) {
        log(r, "info", "Show Desktop ends: " + name);
        ending(s, ctx, r, false);
    } else if (SD.checksSpaces(name)) {
        r.timers.check = "restart";
    }
    return r;
}

// A display plugged or unplugged (Quickshell.screens changed).
function onScreensChanged(state, ctx) {
    const r = begin(state);
    if (r.state.records.length > 0)
        r.timers.check = "restart";
    return r;
}

// A timer of the controller fired: "activation", "check", "verify" or "recover".
function onTimer(state, ctx, id) {
    const r = begin(state);
    const s = r.state;
    if (id === "activation") {
        const act = s.activation;
        s.activation = {open: false, sealed: false, before: "", after: ""};
        const a = act.after !== "" ? act.after : act.before;
        if (a !== "" && s.ended.some(x => SD.sameAddress(x, a)))
            send(r, Minimized.focusWindowRequest(a));
    } else if (id === "check") {
        if (s.records.length > 0 && SD.spaceChanged(s.records, ctx.shown)) {
            log(r, "info", "Show Desktop ends: a display shows another Space or went away");
            ending(s, ctx, r, false);
        }
    } else if (id === "verify") {
        verify(s, ctx, r);
    } else if (id === "recover") {
        recover(s, ctx, r);
    }
    return r;
}

// Nothing may stay parked a moment after an ending: what is still parked is sent back again, a bounded number of times; at the
// bound it gets a record again (Show Desktop is on for it), never none (and never replacing a record that is on).
function verify(s, ctx, r) {
    const records = s.verify.records;
    if (records.length === 0)
        return;
    const parked = ctx.windows.filter(w => w.parked === true).map(w => w.address);
    let again = 0;
    for (const record of records) {
        const stuck = SD.survivors(record, parked);
        again += stuck.length;
        stuck.forEach(a => send(r, Minimized.moveRequest(a, String(record.workspace))));
    }
    s.verify.tries++;
    if (again > 0 && s.verify.tries < ctx.maxVerify) {
        r.timers.verify = "restart";
        return;
    }
    if (again > 0) {
        log(r, "warn", "Show Desktop: " + again + " window(s) did not come back; kept for the next press");
        s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));
        r.persist = true;
    }
    s.verify = {records: [], tries: 0};
}

// The stragglers of `records` that no record in `live` lists already.
function strandedOnly(records, parked, live) {
    return SD.stragglerRecords(records, parked).map(rec => ({
        screen: rec.screen, workspace: rec.workspace, focus: "",
        windows: rec.windows.filter(w => !inRecords(live, w.address))
    })).filter(rec => rec.windows.length > 0);
}

// The crash recovery (a shell that starts with a record on disk): see SD.recoverStep; the record stays at the bound while a
// window is still parked.
function recover(s, ctx, r) {
    if (s.records.length === 0)
        return;
    const step = SD.recoverStep(s.records, ctx.windows, ctx.loaded, s.recoverTries, ctx.maxRecover);
    step.moves.forEach(m => send(r, Minimized.moveRequest(m.address, String(m.workspace))));
    s.recoverTries++;
    if (step.retry) {
        r.timers.recover = "restart";
    } else if (step.clear) {
        s.records = [];
        r.persist = true;
    } else {
        log(r, "warn", "Show Desktop: windows left over from an earlier run did not come back; the record stays");
    }
}

// The shell started and read the records of an earlier run from disk.
function onLoaded(state, ctx, records) {
    const r = begin(state);
    const s = r.state;
    if (Array.isArray(records) && records.length > 0 && s.records.length === 0) {
        s.records = records;
        s.recoverTries = 0;
        r.timers.recover = "restart";
    }
    return r;
}

// Super+F3 (Compositor.showDesktop): the second press ends it (also with Stages on), otherwise the window positions are read
// again first (`refresh`) and `capture` follows.
function onPress(state, ctx) {
    const r = begin(state);
    const s = r.state;
    if (ending(s, ctx, r, true))
        return r;
    if (ctx.stages || s.pending)
        return r;
    s.pending = true;
    r.refresh = true;
    return r;
}

// The window list was read: Show Desktop parks the windows of every display. A previous ending that is still being verified is
// finished into this record: what it left parked stays parked and joins the new record (no move back that would show it).
function onCapture(state, ctx) {
    const r = begin(state);
    const s = r.state;
    s.pending = false;
    let stragglers = [];
    if (s.verify.records.length > 0) {
        const parkedNow = ctx.windows.filter(w => w.parked === true).map(w => w.address);
        stragglers = SD.stragglerRecords(s.verify.records, parkedNow);
    }
    s.verify = {records: [], tries: 0};
    r.timers.verify = "stop";
    const records = SD.captureAll(ctx.windows, ctx.shown, ctx.focused, ctx.stages);
    if (records.length === 0 && stragglers.length === 0) {
        r.focusDesktop = true;
        return r;
    }
    s.records = records.concat(stragglers);
    r.persist = true;
    records.forEach(rec => rec.windows.forEach(w => send(r, Minimized.moveRequest(w.address, SD.PARKING))));
    r.focusDesktop = true;
    return r;
}

// activate() and unminimize(): an activation by the shell itself ends Show Desktop first (result.ended tells).
function onActivate(state, ctx) {
    const r = begin(state);
    ending(r.state, ctx, r, false);
    return r;
}
