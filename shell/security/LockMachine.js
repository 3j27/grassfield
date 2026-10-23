.pragma library

// Lock state machine (ADR-0010) and pure helpers of the lock screen. No Qt or Quickshell types:
// unit-tested offscreen by tests/security/tst_lockmachine.qml.
//
//   unlocked -request-> locking -acquired-> locked -submit-> authenticating
//   authenticating -success-> unlocked
//   authenticating -failure|error|timeout|abort-> locked
//   locking|locked|authenticating -lost-> locking        (lock dropped, or the session found unlocked
//                                                         under a lock still reported secure: re-acquire)
//   locked|authenticating -fingerprint-> unlocked        (PAM success of omarchy-lock-fingerprint)
//
// Only a PAM success ("success", "fingerprint") ever leads to "unlocked". Unknown events and
// events that do not apply to the current state leave the state unchanged (fail closed).

var UNLOCKED = "unlocked";
var LOCKING = "locking";
var LOCKED = "locked";
var AUTHENTICATING = "authenticating";

var STATES = [UNLOCKED, LOCKING, LOCKED, AUTHENTICATING];
var EVENTS = ["request", "acquired", "lost", "submit", "success", "fingerprint", "failure", "error", "timeout", "abort"];

function next(state, event) {
    if (STATES.indexOf(state) === -1)
        return LOCKING; // corrupted state: never treat it as unlocked
    switch (event) {
    case "request":
        return state === UNLOCKED ? LOCKING : state;
    case "acquired":
        return state === LOCKING ? LOCKED : state;
    case "lost":
        return state === UNLOCKED ? UNLOCKED : LOCKING;
    case "submit":
        return state === LOCKED ? AUTHENTICATING : state;
    case "success":
        return state === AUTHENTICATING ? UNLOCKED : state;
    case "fingerprint":
        return state === LOCKED || state === AUTHENTICATING ? UNLOCKED : state;
    case "failure":
    case "error":
    case "timeout":
    case "abort":
        return state === AUTHENTICATING ? LOCKED : state;
    }
    return state;
}

function isLocked(state) {
    return state !== UNLOCKED;
}

// A lock of this shell that the compositor confirmed is held in these states (Lock.holding also needs
// WlSessionLock.secure). Anything else, unknown states included, is not holding: a decision that waits for a held lock
// (the sleep delay) then keeps waiting (fail closed).
function isHolding(state) {
    return state === LOCKED || state === AUTHENTICATING;
}

// Lid closed (Hyprland switch binding `switch:on:Lid Switch`, config/hypr/grassfield/bindings.lua): lock unless a
// physical external display is active, which is clamshell mode, still in use on that display (macOS does not lock or
// sleep then; Omarchy's omarchy-system-lid-close makes the same choice). `names` are the shell's output names
// (Quickshell.screens). External connectors are the DRM names Hyprland gives physical outputs (DP-1, HDMI-A-1,
// DVI-D-1, VGA-1, ...); the built-in panel (eDP, LVDS, DSI), headless and nested outputs (HEADLESS-1, WAYLAND-1, any
// custom name) are not. Anything unreadable locks (fail closed).
var EXTERNAL_OUTPUT = /^(DP|HDMI-[A-Z]|DVI-[A-Z]|VGA|TV|USB)-[0-9]+$/;

function lidShouldLock(names) {
    if (!names || typeof names.length !== "number")
        return true;
    for (var i = 0; i < names.length; i++) {
        if (EXTERNAL_OUTPUT.test(String(names[i])))
            return false;
    }
    return true;
}

// Crash-recovery marker ($XDG_RUNTIME_DIR, one per compositor instance), as returned by markerRead:
// null when the file does not exist, else its content. Anything but an exact "unlocked" means the
// session was (or may have been) locked: re-lock. That includes an empty or unreadable marker.
function markerSaysLocked(text) {
    if (text === null || text === undefined)
        return false; // missing: the first start of this compositor instance
    return String(text).trim() !== "unlocked";
}

// Meaning of a marker read, from FileView's result: null when the file does not exist (FileNotFound);
// "" when it exists but could not be read (permission denied, not a file, I/O error), which locks like
// any other content that is not exactly "unlocked"; else the file's text. `failed` must be exactly
// false for the text to be used (fail closed).
function markerRead(missing, failed, text) {
    if (missing === true)
        return null;
    if (failed !== false)
        return "";
    return String(text === undefined || text === null ? "" : text);
}

// Lock to restore when a shell instance starts (crash restart, reload or session start), from
// what it can read synchronously. Fail closed:
//   - intent: the previous instance's lock intent carried over a soft reload (PersistentProperties);
//   - markerAvailable false (XDG_RUNTIME_DIR unset): no marker can prove the session unlocked;
//   - otherwise the marker decides (markerSaysLocked on a markerRead result). A missing marker (null)
//     is the first start of this compositor instance; if it was removed while locked, the compositor
//     still holds the dead client's lock (ext-session-lock) and compositorLockState() finds it.
function restoreAtStart(intent, markerAvailable, markerText) {
    return intent === true || markerAvailable !== true || markerSaysLocked(markerText);
}

// Session lock state as reported by Hyprland, from `hyprctl -j monitors` objects
// (Quickshell HyprlandMonitor.lastIpcObject). Hyprland has no lock query, but an active
// ext-session-lock, including one whose client died, puts "LOCK" in solitaryBlockedBy. Hyprland
// stops listing at "WORKSPACE" (monitor without a workspace yet), so such a list proves nothing.
// Returns "locked", "unlocked" or "unknown" (no complete list; e.g. not Hyprland).
function compositorLockState(monitors) {
    var list = monitors || [];
    return compositorLockStateLazy(list.length, function (i) {
        return list[i];
    });
}

// Same result as compositorLockState, reading monitor i's IPC object only when needed (get(i), called at most once per
// monitor, in order). Each read of Quickshell's HyprlandMonitor.lastIpcObject converts a whole monitor map to JS, which
// the 100 ms ownership check did twice per answer (the garbage made the shell's RSS climb ~5 MB/min between
// collections). A monitor listing LOCK settles the answer (the session lock is global), so in the steady locked state
// only the first monitor is read. Any other answer still reads every monitor, exactly as before.
function compositorLockStateLazy(count, get) {
    var readable = false;
    var n = typeof count === "number" ? count : 0;
    for (var i = 0; i < n; i++) {
        var object = get(i);
        var blockers = object ? object.solitaryBlockedBy : undefined;
        if (!blockers || typeof blockers === "string" || typeof blockers.length !== "number")
            continue;
        var lock = false;
        var workspace = false;
        for (var j = 0; j < blockers.length; j++) {
            var name = String(blockers[j]);
            if (name === "LOCK")
                lock = true;
            else if (name === "WORKSPACE")
                workspace = true;
        }
        if (lock)
            return "locked";
        if (!workspace)
            readable = true;
    }
    return readable ? "unlocked" : "unknown";
}

// Lock watchdog decision while this shell holds a lock the compositor confirmed (locked or
// authenticating, WlSessionLock secure), from a fresh compositorLockState() answer and the number of
// consecutive "unlocked" answers just before it. Hyprland 0.56 with misc.allow_session_lock_restore
// hands a live session lock to the next client that asks and tells the previous holder nothing; when
// either client then releases it, the session is unlocked although the other one's lock object still
// reports secure. Returns:
//   "ok"      the compositor reports the session locked (by this shell, or by a foreign locker that
//             took it over: coexist, the session is locked);
//   "unknown" no complete monitor list (not Hyprland, outputs coming up): rely on WlSessionLock;
//   "confirm" first "unlocked" answer: ask once more, so that an answer to a request sent before this
//             lock existed can never trigger a re-lock;
//   "relock"  confirmed unlocked: drop the stale lock object and take a fresh lock (fail closed).
function ownershipAction(compositorState, unlockedBefore) {
    if (compositorState === "locked")
        return "ok";
    if (compositorState !== "unlocked")
        return "unknown";
    return unlockedBefore >= 1 ? "relock" : "confirm";
}

// Lock ownership probe intervals (ms) while this shell holds a lock on Hyprland (Lock.qml ownershipProbe): one
// monitor query per tick. The interval bounds how long the session can stay unlocked after another client releases
// a lock it took over, so it is short while such a release is possible.
var PROBE_INTERVAL_MS = 1000;
var PROBE_SUSPECTED_MS = 100;

// A takeover is suspected, i.e. another client may hold or have held the session lock, so that its release can unlock
// the session under this shell's lock, while
//   - no lock surface of this shell has the keyboard (another client's lock surface took it, or the session was
//     unlocked under this lock and a window took it), or
//   - the lock this shell holds was requested at start or after a reload ("restore"): it may be a lock this shell
//     took over from a live foreign locker, whose release unlocks the session without any event.
// Anything but exact booleans counts as suspected: probing faster never unlocks anything (fail closed).
function takeoverSuspected(surfaceFocused, inheritedLock) {
    return !(surfaceFocused === true && inheritedLock === false);
}

function probeInterval(suspected) {
    return suspected === false ? PROBE_INTERVAL_MS : PROBE_SUSPECTED_MS;
}

// File name of the marker; the instance id is reduced to safe file-name characters.
function markerName(instance, display) {
    var id = String(instance || display || "default").replace(/[^A-Za-z0-9_.-]/g, "_");
    return "grassfield-lock-" + id;
}

// Display name of `user` from /etc/passwd text (GECOS full name), else the login name.
function displayName(passwd, user) {
    var lines = String(passwd || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var f = lines[i].split(":");
        if (f.length >= 5 && f[0] === user) {
            var full = f[4].split(",")[0].trim();
            return full !== "" ? full : user;
        }
    }
    return String(user || "");
}

// Up to two initials for the avatar placeholder.
function initials(name) {
    var parts = String(name || "").trim().split(/\s+/).filter(function (p) {
        return p.length > 0;
    });
    if (parts.length === 0)
        return "";
    var first = parts[0].charAt(0);
    var last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : "";
    return (first + last).toUpperCase();
}

// Caps Lock inferred from a typed character (Quickshell 0.3.1 exposes no lock-key state):
// a cased letter that disagrees with Shift means Caps Lock is on. Returns true, false, or null
// when the character tells nothing (digits, symbols, uncased scripts).
function capsLockFromKey(text, shift) {
    var c = String(text || "");
    if (c.length !== 1 || c.toUpperCase() === c.toLowerCase())
        return null;
    var upper = c === c.toUpperCase();
    return upper !== !!shift;
}

// Lock-screen clock pattern: hours and minutes without AM/PM, in the locale's 12/24 h style.
function clockFormat(localeTimeFormat) {
    return /a/i.test(String(localeTimeFormat || "")) ? "h:mm" : "H:mm";
}
