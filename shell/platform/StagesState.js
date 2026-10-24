.pragma library

// The gfc/1 Stages notice and state (docs/specs/stages.md "Shell contract" 4), validated, and the fetch of the state: pure,
// no compositor access, unit tested in tests/unit/tst_stages.qml. The `stages` event is a change notice ({gen, on, reason}:
// Hyprland cuts socket2 events at 1024 bytes); the state with its monitors is the reply of `hyprctl grassfield-stages`
// (ADR-0007 amendment 2026-10-24). The event never carries monitors: the session runs the shell and the plugin of one
// Grassfield version only (the packages pin each other's version and the loader checks the stamp's `source` line;
// ADR-0007's exception to the gfc/N rule).

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

// {on, reason, gen} for a `stages` event (the change notice), null for anything else (other types, foreign protocol
// versions, malformed text). `reason` is "" or one of the contract's reasons; `gen` the plugin's generation (-1 absent).
function parseNotice(data) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== "gfc/1" || msg.type !== "stages" || typeof msg.on !== "boolean")
        return null;
    return {
        on: msg.on,
        reason: typeof msg.reason === "string" && reasons.indexOf(msg.reason) >= 0 ? msg.reason : "",
        gen: Number.isSafeInteger(msg.gen) && msg.gen >= 0 ? msg.gen : -1
    };
}

// The state of a notice that says Stages is off: nothing to fetch.
function offState(notice) {
    return {on: false, reason: notice.reason, gen: notice.gen, complete: true, monitors: {}};
}

// gfc1-reply: grassfield-stages
// {on, reason, gen, complete, monitors: {<name>: monitor}} for the reply of `hyprctl grassfield-stages`, null for anything
// else (other types, foreign protocol versions, malformed text, "unknown request" when the plugin is gone). `reason` is ""
// or one of the contract's reasons (anything else is dropped); `gen` the plugin's generation (-1 when absent); `complete`
// whether the text carried the monitors.
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

// ---- the fetch of the state (StagesLink drives it: one `hyprctl grassfield-stages` at a time) ----
// fetch: {running, again, tries, pendingSince, againSince}. Each step takes ctx = {active, shown, now}: Stages may run
// (available, enabled, flag on; nothing is fetched or shown otherwise), the state shown now (or null) and the time in ms.
// It returns {fetch, start, retryMs, staleMs, state}: `start` a fetch now; `retryMs` > 0: start one after that many ms;
// `staleMs` > 0: call onTick after that many ms; `state`: the state to show (undefined: unchanged; null: none, the strip
// hides, rather than a stale one shown as current).
// Staleness is bounded by time: a notice that no successful fetch has answered for more than staleAfterMs means no state,
// however many notices keep coming (each one restarts the retries, never the clock), unless a fetch is under way: its
// answer (or its 2-s deadline) decides, so slow fetches under a steady flow of notices never make the strip flicker. The
// worst case is staleAfterMs plus one fetch deadline.

const maxTries = 3;              // retries after a failed fetch before the state is given up as unknown
const retryBaseMs = 200;         // backoff: 200, 400, 800 ms
const fetchDeadlineMs = 2000;    // a fetch not answered by then failed (StagesLink stops it)
const staleAfterMs = 3000;       // a notice unanswered that long: the shown state is given up

// pendingSince: when the oldest notice not answered by a successful fetch came (-1: none); againSince: the same for the
// notices that came while the running fetch was under way (they are not answered by it).
function newFetch() {
    return {running: false, again: false, tries: 0, pendingSince: -1, againSince: -1};
}

function step(fetch, extra) {
    return {fetch: Object.assign({}, fetch, extra || {}), start: false, retryMs: 0, staleMs: 0, state: undefined};
}

// The time bound on what is shown: none once the oldest unanswered notice is staleAfterMs old and no fetch is under way
// (a running fetch ends in onReply or onTimeout, which look again), else when to look again.
function bounded(out, ctx) {
    const visible = out.state !== undefined ? out.state : ctx.shown;
    if (!ctx.active || out.fetch.pendingSince < 0 || !visible)
        return out;
    const left = out.fetch.pendingSince + staleAfterMs - ctx.now;
    if (left > 0)
        out.staleMs = left;
    else if (!out.fetch.running)
        out.state = null;
    return out;
}

// A notice (parseNotice; null is ignored).
function onNotice(fetch, notice, ctx) {
    const out = step(fetch);
    if (!notice || !ctx.active)
        return out;
    if (!notice.on) {
        // Stages is off: that is the whole state, it answers every notice before it.
        out.state = offState(notice);
        out.fetch.pendingSince = -1;
        out.fetch.againSince = -1;
        return out;
    }
    if (out.fetch.pendingSince < 0)
        out.fetch.pendingSince = ctx.now;
    if (fetch.running) {
        out.fetch.again = true;
        if (out.fetch.againSince < 0)
            out.fetch.againSince = ctx.now;
    } else {
        out.fetch.running = true;
        out.fetch.tries = 0;
        out.start = true;
    }
    return bounded(out, ctx);
}

// The fetch ended with `text` (the reply; "" or anything unparsable is a failure).
function onReply(fetch, text, ctx) {
    const out = step(fetch, {running: false});
    const parsed = parse(text);
    if (!parsed || !parsed.complete)
        return failed(out, ctx);
    if (!ctx.active) {
        out.fetch = newFetch();
        return out;
    }
    out.fetch.tries = 0;
    const shown = ctx.shown;
    if (!(shown && shown.gen >= 0 && parsed.gen >= 0 && shown.gen > parsed.gen))
        out.state = parsed;
    // The notices that came during this fetch are not answered by it: one more fetch, and their clock goes on.
    out.fetch.pendingSince = out.fetch.again ? out.fetch.againSince : -1;
    out.fetch.againSince = -1;
    if (out.fetch.again) {
        out.fetch.again = false;
        out.fetch.running = true;
        out.start = true;
    }
    return bounded(out, ctx);
}

// The fetch did not end in time (StagesLink stops it): a failure.
function onTimeout(fetch, ctx) {
    return failed(step(fetch, {running: false}), ctx);
}

function failed(out, ctx) {
    if (!ctx.active) {
        out.fetch = newFetch();
        return out;
    }
    if (out.fetch.tries < maxTries) {
        // The retry fetches the latest state anyway: the notices that came meanwhile need no fetch of their own.
        out.fetch.tries += 1;
        out.fetch.again = false;
        out.fetch.againSince = -1;
        out.retryMs = retryBaseMs * Math.pow(2, out.fetch.tries - 1);
        return bounded(out, ctx);
    }
    out.fetch = newFetch();
    out.state = null;
    return out;
}

// A retry is due: start the fetch.
function onRetry(fetch, ctx) {
    const out = step(fetch);
    if (!ctx.active || fetch.running)
        return bounded(out, ctx);
    out.fetch.running = true;
    out.start = true;
    return bounded(out, ctx);
}

// The time bound came (staleMs of an earlier step).
function onTick(fetch, ctx) {
    return bounded(step(fetch), ctx);
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
