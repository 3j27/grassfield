.pragma library

// Activity Monitor's graph on its Dock tile (ADR-0038 f; docs/specs/activity.md AM62): the file the app writes in the
// display's runtime folder, checked before anything is drawn, and the gauge's lit segments. Pure functions
// (tests/unit/tst_docktilegraph.qml).

const APP_ID = "org.grassfield.Activity";
const KINDS = ["network", "disk", "cpu-usage", "cpu-history"];
const MAX_TEXT = 2048;
const MAX_SAMPLES = 32;

function unit(x) {
    return typeof x === "number" && isFinite(x) && x >= 0 && x <= 1;
}

// The graph to draw, {kind, samples}, or null. The file's text: at most 2 KiB, version 1, a known kind, 1 to 32 samples
// each in [0, 1] (a number for CPU usage, a pair for the others), from a live writer: a process that owns one of the app's
// windows now (`windowPids`). The app removes the file when the icon is chosen and when it quits; a crashed app owns no
// window, so its file is never drawn.
function parse(text, windowPids) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_TEXT)
        return null;
    let o = null;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!o || typeof o !== "object" || Array.isArray(o) || o.v !== 1)
        return null;
    const w = o.writer;
    if (!w || typeof w !== "object" || !Number.isInteger(w.pid) || w.pid <= 1 || typeof w.start !== "number" || w.start < 0)
        return null;
    if (!(windowPids || []).includes(w.pid))
        return null;
    if (KINDS.indexOf(o.kind) < 0 || !Array.isArray(o.samples) || o.samples.length === 0 || o.samples.length > MAX_SAMPLES)
        return null;
    const pairs = o.kind !== "cpu-usage";
    for (const s of o.samples) {
        if (pairs ? !(Array.isArray(s) && s.length === 2 && unit(s[0]) && unit(s[1])) : !unit(s))
            return null;
    }
    return {kind: o.kind, samples: o.samples};
}

// The CPU usage gauge's lit segments for a share of the processor.
function litSegments(value, segments) {
    return Math.max(0, Math.min(segments, Math.round(value * segments)));
}
