.pragma library

// Pure helpers of the idle module (tests/security/tst_idlemodel.qml).

var DEFAULT_MINUTES = 5;
var MAX_MINUTES = 240;
// The screen dims this many seconds before the idle lock (ADR-0010: dim at T-10 s).
var DIM_LEAD_SECONDS = 10;

// lock.idleMinutes (grassfield.json, 0..240, 0 = never) → idle timings. Invalid values fall
// back to the default rather than disabling the lock: only an exact 0 means never. Only a number is a number: false, "0",
// null and [0] convert to 0 in JavaScript and would switch the lock off. The value arrives here already read by the settings
// store through the contract (SettingsContract.normalize, rule zeroIsExact): a value above 240 is 240 there (the lock still
// fires), a fraction is rounded, and a negative number or a fraction that rounds to 0 is 5. This function is a backstop for
// anything else and is stricter on purpose (above 240 or a fraction: the default 5, sooner than the contract's reading); it
// never answers "never" for anything but a number that is exactly 0.
function timings(minutes) {
    var m = minutes;
    if (typeof m !== "number" || !isFinite(m) || m < 0 || m > MAX_MINUTES || Math.floor(m) !== m)
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

// While a lock is being acquired, "on" is sent again this often, at most this many times: a lost request (a restarted shell,
// a dispatch the compositor refused) must not keep the lock undrawn, hence unconfirmed, until input; a lock that cannot hold
// (no display connected) is not woken all night.
var ACQUIRE_DISPLAYS_ON_MS = 2000;
var ACQUIRE_DISPLAYS_ON_TRIES = 5;

// Display power-off while the session is unlocked (macOS 27 Lock Screen: Turn display off on battery / on power adapter when
// inactive): the minutes of the power source in use, as seconds; 0 = never. The values arrive read through the contract
// (integers 0..240); anything else is never: turning the displays off is not what keeps the session safe (the lock is, and it
// does not depend on this).
function inactiveDisplayOffSeconds(batteryMinutes, powerMinutes, onBattery) {
    var m = onBattery === true ? batteryMinutes : powerMinutes;
    if (typeof m !== "number" || !isFinite(m) || m <= 0 || m > MAX_MINUTES || Math.floor(m) !== m)
        return 0;
    return m * 60;
}

// The unlocked display-off monitor is armed: a delay is set, it is not being re-armed, and no application holds an idle
// inhibitor (a video plays). While locked it stays armed only when it had already turned the displays off (`offForInactivity`):
// the lock that follows keeps them dark until input, instead of lighting them for its own display-off delay.
function inactiveOffArmed(seconds, locked, offForInactivity, rearming, busInhibited) {
    return seconds > 0 && (locked !== true || offForInactivity === true) && rearming !== true && busInhibited !== true;
}

// When a display that turned off for inactivity locks the session (ADR-0040 IQ-T4 A, lock.requirePasswordAfterDisplayOff):
// 0 at once, a delay in ms, or -1 never. Anything unknown reads as at once (fail closed: the stricter choice).
var REQUIRE_AFTER_DISPLAY_OFF_MS = {immediately: 0, "5s": 5000, "1m": 60000, "5m": 300000, "15m": 900000, "1h": 3600000, never: -1};

function requireAfterDisplayOffMs(choice) {
    return typeof choice === "string" && Object.prototype.hasOwnProperty.call(REQUIRE_AFTER_DISPLAY_OFF_MS, choice) ? REQUIRE_AFTER_DISPLAY_OFF_MS[choice] : 0;
}

// The idle dim stays until the lock it led to holds (ADR-0040 ID-8), at most this long: a lock that never confirms does not
// leave the screen dimmed for ever (the lock itself keeps trying; the dim is display only).
var DIM_UNTIL_LOCK_MAX_MS = 5000;

// The displays are off: the lock screen's monitor is idle, or the unlocked one turned them off (`inactiveOff`), but never
// while a lock is being acquired (locked, not holding yet): the compositor confirms a lock only once it has drawn it on every
// display, and a display that is off draws nothing (review of 6e61829: the sleep inhibitor would wait out its budget and the
// ownership check would not run). Once the lock holds, a session that went dark for inactivity is dark again.
function displaysOff(lockedIdle, inactiveOff, locked, holding) {
    if (lockedIdle === true)
        return true;
    return inactiveOff === true && (locked !== true || holding === true);
}

// ---- Automatic sleep (macOS 27 Energy and Battery > Options: the computer sleeps once the displays are off for
// inactivity, unless "Prevent automatic sleeping ... when the display is off" is on). Sleep only: nothing here is read by a
// lock decision above (timings, idleArmed, inactiveOffArmed, requireAfterDisplayOffMs, displaysOff take no part of it), and
// the computer is only put to sleep by Grassfield while its own lock holds. ----

// Seconds the displays stay off without input before the computer sleeps (macOS sleeps about a minute after the display).
var AUTO_SLEEP_SECONDS = 60;

// Automatic sleep is prevented: on battery never (macOS: a portable on battery always sleeps after the display), else
// unless energy.preventSleep is exactly false. The value arrives read through the contract (a boolean, default true);
// anything else, an unknown power source included, keeps the computer awake: Grassfield never put a computer to sleep by
// itself before this setting, so a value that cannot be read gives back that behaviour, never another.
function sleepPrevented(preventSleep, onBattery) {
    if (onBattery === true)
        return false;
    return preventSleep !== false;
}

// The automatic sleep monitor is armed: this module turned the displays off for lack of input (the unlocked display-off
// monitor or the lock screen's), sleep is not prevented, and no application holds an org.freedesktop.ScreenSaver inhibitor
// (Wayland idle inhibitors: the monitor respects them). Anything but these exact values disarms it (fail awake).
function autoSleepArmed(displaysOff, prevented, busInhibited) {
    return displaysOff === true && prevented === false && busInhibited !== true;
}

// What a due automatic sleep does: "suspend" once Grassfield's lock holds (the session is locked and the compositor
// confirmed it), "lock" when the session is not locked (the lock first; the sleep waits for the next due time, after the
// lock holds), "wait" while a lock is being acquired. Never "suspend" on an unlocked or unconfirmed session: Grassfield
// never puts an unlocked session to sleep (the lock before sleep, SleepInhibitor, would also lock it, but only while its
// logind delay inhibitor is held).
function autoSleepAction(locked, holding) {
    if (locked === true && holding === true)
        return "suspend";
    if (locked !== true)
        return "lock";
    return "wait";
}

// Sleep inhibitor and PrepareForSleep watcher restarts (GF-030: never given up silently). A child that exits within
// FAST_EXIT_MS of its start is a failure; MAX_FAST_FAILURES in a row make the module "degraded" (a notice tells the user)
// and the child is then retried every SLOW_RETRY_MS instead of every FAST_RETRY_MS, for as long as the shell runs.
var FAST_EXIT_MS = 2000;
var MAX_FAST_FAILURES = 5;
var FAST_RETRY_MS = 5000;
var SLOW_RETRY_MS = 60000;
// A child must show progress within PROGRESS_BUDGET_MS of its start (the inhibitor: the line its command prints once
// systemd-inhibit holds the lock; the watcher: watcherSubscribed). One that runs without it is hung: it is stopped and
// counted as a failure (review of eee45cc: a hung child counted as healthy, so the user was never told that the screen
// may not lock before sleep). 35 s: above sd-bus' and GDBus' default method call timeout (25 s), so a slow but healthy
// logind (systemd-inhibit's Inhibit call, gdbus' GetNameOwner) is waited for rather than killed on every retry (review of
// 100692f); a hung child still costs only the sleep delay, the lock arms anyway.
var PROGRESS_BUDGET_MS = 35000;

// The PrepareForSleep watcher is subscribed: `gdbus monitor --dest org.freedesktop.login1` prints this line from its
// name watcher, which GLib starts after it sent the signal subscription (AddMatch); the bus answers one connection's
// messages in order, so once the owner is known the match is in place. Its first line ("Monitoring signals ...") is
// printed before subscribing and proves nothing (review of 100692f). From GLib's gdbus-tool source order; not observed
// at runtime here (no system bus in the sandbox).
function watcherSubscribed(line) {
    return typeof line === "string" && line.indexOf("The name org.freedesktop.login1 is owned by ") === 0;
}

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
