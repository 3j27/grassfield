.pragma library

// Pure helpers of the idle module (tests/security/tst_idlemodel.qml).

var DEFAULT_MINUTES = 5;
var MAX_MINUTES = 240;
// The screen dims this many seconds before the idle lock (ADR-0010: dim at T-10 s).
var DIM_LEAD_SECONDS = 10;

// lock.idleMinutes (grassfield.json, 0..240, 0 = never) → idle timings. Invalid values fall
// back to the default rather than disabling the lock.
function timings(minutes) {
    var m = Number(minutes);
    if (!isFinite(m) || m < 0 || m > MAX_MINUTES || Math.floor(m) !== m)
        m = DEFAULT_MINUTES;
    var lockSeconds = m * 60;
    var dimSeconds = Math.max(1, lockSeconds - DIM_LEAD_SECONDS);
    return {
        enabled: m > 0,
        lockSeconds: lockSeconds,
        dimSeconds: dimSeconds,
        lockDelayMs: (lockSeconds - dimSeconds) * 1000
    };
}

// One line of `gdbus monitor --system --dest org.freedesktop.login1 --object-path
// /org/freedesktop/login1`. Returns true (about to sleep), false (resumed) or null.
function prepareForSleep(line) {
    var m = String(line || "").match(/org\.freedesktop\.login1\.Manager\.PrepareForSleep \((true|false),?\)/);
    return m ? m[1] === "true" : null;
}
