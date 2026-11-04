.pragma library

// Fingerprint & Security Key > Fingerprint (ADR-0045 OC-6, OC-0.7): fprintd's state as the pane shows it, and the enrolment
// as the sheet shows it (macOS 27's: place the finger, a ring that fills with each accepted touch, one message per status).
// Pure logic: the sheet (FingerprintEnrollSheet.qml) words the message keys, the Backend talks to fprintd (systembus.h
// fingerprintState, enrollFinger: each EnrollStatus arrives as Backend.progress, the end as finished).

// fprintd's finger names, in the order a new finger is proposed (Omarchy's setup enrols the right index finger first).
var FINGERS = ["right-index-finger", "left-index-finger", "right-thumb", "left-thumb", "right-middle-finger", "left-middle-finger",
    "right-ring-finger", "left-ring-finger", "right-little-finger", "left-little-finger"];

// The names the pane shows (qsTranslate("Fingerprint", name)).
var NAMES = {
    "right-index-finger": QT_TRANSLATE_NOOP("Fingerprint", "Right index finger"),
    "left-index-finger": QT_TRANSLATE_NOOP("Fingerprint", "Left index finger"),
    "right-thumb": QT_TRANSLATE_NOOP("Fingerprint", "Right thumb"),
    "left-thumb": QT_TRANSLATE_NOOP("Fingerprint", "Left thumb"),
    "right-middle-finger": QT_TRANSLATE_NOOP("Fingerprint", "Right middle finger"),
    "left-middle-finger": QT_TRANSLATE_NOOP("Fingerprint", "Left middle finger"),
    "right-ring-finger": QT_TRANSLATE_NOOP("Fingerprint", "Right ring finger"),
    "left-ring-finger": QT_TRANSLATE_NOOP("Fingerprint", "Left ring finger"),
    "right-little-finger": QT_TRANSLATE_NOOP("Fingerprint", "Right little finger"),
    "left-little-finger": QT_TRANSLATE_NOOP("Fingerprint", "Left little finger")
};

function isFinger(s) {
    return FINGERS.indexOf(s) >= 0;
}

// `fprint.state`: {present, name, stages, scanType, fingers (known names, in FINGERS' order)}; null when not that.
function parseState(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.present !== "boolean")
        return null;
    const listed = Array.isArray(j.fingers) ? j.fingers : [];
    return {
        present: j.present,
        name: typeof j.name === "string" ? j.name : "",
        stages: Number.isInteger(j.stages) && j.stages > 0 && j.stages <= 100 ? j.stages : 0,
        scanType: j.scanType === "swipe" ? "swipe" : "press",
        fingers: FINGERS.filter(f => listed.indexOf(f) >= 0)
    };
}

// The finger a new enrolment asks for: the first of FINGERS not enrolled yet, "" when all ten are.
function nextFinger(enrolled) {
    const have = Array.isArray(enrolled) ? enrolled : [];
    for (const f of FINGERS) {
        if (have.indexOf(f) < 0)
            return f;
    }
    return "";
}

// ---- The enrolment's state machine ---------------------------------------------------------------------------------
// {phase, finger, stages, passed, message}:
//   phase    "starting" (asked fprintd: the polkit dialog may be up), "scanning" (fprintd waits for touches), "done",
//            "failed", "stopped"
//   stages   touches fprintd needs (num-enroll-stages; 5 when it gave none); passed: those it accepted
//   message  the key of the line under the ring (the sheet words it): "place" (the first touch), "again" (lift and touch
//            again), "edges" (macOS's second half: adjust the grip), "retry", "short", "center", "remove", "completed",
//            "failed", "full", "disconnected", "duplicate", "unknown", or "error" (a failed call: `reason` holds its text)

// fprintd's EnrollStatus values that end an enrolment, with their message keys.
var FAILURES = {
    "enroll-failed": "failed",
    "enroll-data-full": "full",
    "enroll-disconnected": "disconnected",
    "enroll-unknown-error": "unknown",
    "enroll-duplicate": "duplicate"
};
// Those that ask for the touch again.
var RETRIES = {
    "enroll-retry-scan": "retry",
    "enroll-swipe-too-short": "short",
    "enroll-finger-not-centered": "center",
    "enroll-remove-and-retry": "remove"
};

function start(finger, stages) {
    return {phase: "starting", finger: String(finger || ""), stages: stages > 0 ? stages : 5, passed: 0, message: "place", reason: ""};
}

// One EnrollStatus applied. A status after the end changes nothing; an unknown one neither.
function step(state, status) {
    if (state === null || state === undefined || state.phase === "done" || state.phase === "failed" || state.phase === "stopped")
        return state;
    const s = Object.assign({}, state, {phase: "scanning"});
    if (status === "enroll-stage-passed") {
        // The ring never reads full before fprintd says completed.
        s.passed = Math.min(s.passed + 1, s.stages - 1);
        s.message = s.passed * 2 >= s.stages ? "edges" : "again";
    } else if (status === "enroll-completed") {
        s.phase = "done";
        s.passed = s.stages;
        s.message = "completed";
    } else if (RETRIES[status] !== undefined) {
        s.message = RETRIES[status];
    } else if (FAILURES[status] !== undefined) {
        s.phase = "failed";
        s.message = FAILURES[status];
    } else {
        return state;
    }
    return s;
}

// The Backend's answer (finished): "" ok; otherwise fprintd's final status, "enroll-stopped", or a failed call's reason.
function finish(state, ok, reason) {
    if (state === null || state === undefined)
        return state;
    if (ok)
        return Object.assign({}, state, {phase: "done", passed: state.stages, message: "completed"});
    if (state.phase === "failed")
        return state;
    const r = String(reason || "");
    if (r === "enroll-stopped")
        return Object.assign({}, state, {phase: "stopped"});
    if (FAILURES[r] !== undefined)
        return Object.assign({}, state, {phase: "failed", message: FAILURES[r]});
    return Object.assign({}, state, {phase: "failed", message: "error", reason: r});
}

// The ring: 0 to 1.
function progress(state) {
    if (!state || state.stages <= 0)
        return 0;
    return Math.max(0, Math.min(1, state.passed / state.stages));
}

function running(state) {
    return state !== null && state !== undefined && (state.phase === "starting" || state.phase === "scanning");
}
