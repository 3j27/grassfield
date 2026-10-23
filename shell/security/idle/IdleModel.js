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

// Display power-off on the lock screen (D-4, macOS turns the display off soon after locking): seconds without input
// while locked before the displays go off (Hyprland DPMS); any input switches them on again.
var DISPLAY_OFF_SECONDS = 30;

// Sleep inhibitor and PrepareForSleep watcher restarts (GF-030: never given up silently). A child that exits within
// FAST_EXIT_MS of its start is a failure; MAX_FAST_FAILURES in a row make the module "degraded" (a notice tells the user)
// and the child is then retried every SLOW_RETRY_MS instead of every FAST_RETRY_MS, for as long as the shell runs.
var FAST_EXIT_MS = 2000;
var MAX_FAST_FAILURES = 5;
var FAST_RETRY_MS = 5000;
var SLOW_RETRY_MS = 60000;

// Consecutive fast failures after a child exited having run `ranMs` (not a number: counted as a failure).
function failuresAfterExit(failures, ranMs) {
    var n = Number(failures);
    if (!isFinite(n) || n < 0)
        n = 0;
    var ran = Number(ranMs);
    return isFinite(ran) && ran >= FAST_EXIT_MS ? 0 : n + 1;
}

// Delay before the next restart of a child after `failures` consecutive fast failures.
function retryDelayMs(failures) {
    return Number(failures) >= MAX_FAST_FAILURES ? SLOW_RETRY_MS : FAST_RETRY_MS;
}

function degraded(failures) {
    return Number(failures) >= MAX_FAST_FAILURES;
}

// How long the sleep delay may wait for a confirmed lock, from logind's InhibitDelayMaxUSec as printed by
// `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager InhibitDelayMaxUSec`
// ("t 15000000"). logind suspends when its window expires, locked or not: keep a fifth of the window (at least 1 s) for
// logind to act on the release, and cap at 12 s so that a raised window cannot strand a closed laptop in a bag (port
// of Omarchy's omarchy-system-sleep-lock derive_budget_ms, MIT). Unreadable: logind's default window, 5 s -> 4 s.
// Omarchy ships InhibitDelayMaxSec=15 because a lid close that reconfigures displays can take longer than 4 s to lock.
var BUDGET_CAP_MS = 12000;

function sleepBudgetMs(busctlOutput) {
    var m = String(busctlOutput || "").match(/^\s*t\s+([0-9]+)\s*$/);
    var windowMs = m ? Math.floor(Number(m[1]) / 1000) : 0;
    if (!isFinite(windowMs) || windowMs <= 0)
        windowMs = 5000;
    var budget = windowMs - Math.max(Math.floor(windowMs / 5), 1000);
    return Math.max(0, Math.min(budget, BUDGET_CAP_MS));
}

// One line of `gdbus monitor --system --dest org.freedesktop.login1 --object-path
// /org/freedesktop/login1`. Returns true (about to sleep), false (resumed) or null.
function prepareForSleep(line) {
    var m = String(line || "").match(/org\.freedesktop\.login1\.Manager\.PrepareForSleep \((true|false),?\)/);
    return m ? m[1] === "true" : null;
}
