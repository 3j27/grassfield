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

// The idle monitor (dim, then lock) is armed: idle locking is on (lock.idleMinutes > 0), the session is not locked, the
// monitor is not being re-armed, and no application holds an org.freedesktop.ScreenSaver idle inhibitor (GF-016,
// reported by the menu bridge; Wayland idle inhibitors are honoured by the compositor's idle-notify protocol). Anything
// but an explicit `true` for the inhibitor counts as not inhibited (fail closed: the idle lock works). A lock request
// (manual, lid, before sleep) never asks this.
function idleArmed(enabled, locked, rearming, busInhibited) {
    return enabled === true && locked !== true && rearming !== true && busInhibited !== true;
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
// A child must show progress within PROGRESS_BUDGET_MS of its start (the inhibitor: the line its command prints once
// systemd-inhibit holds the lock; the watcher: gdbus' first line, printed once it is connected and subscribed). One that
// runs without it is hung: it is stopped and counted as a failure (review of eee45cc: a hung child counted as healthy,
// so the user was never told that the screen may not lock before sleep).
var PROGRESS_BUDGET_MS = 10000;

// Consecutive fast failures after a child exited: `ranLong` is true only when it ran at least FAST_EXIT_MS AND showed
// progress (SleepInhibitor times that with Timers, a monotonic clock: review of 2dfd992, a wall-clock step forward made an
// early exit look long and hid the failure; review of eee45cc, a hung child looked healthy). Anything else (false, unknown,
// a child that never started or never progressed) counts as a failure.
function failuresAfterRun(failures, ranLong) {
    var n = Number(failures);
    if (!isFinite(n) || n < 0)
        n = 0;
    return ranLong === true ? 0 : n + 1;
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
