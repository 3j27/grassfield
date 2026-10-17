.pragma library

// Lock state machine (ADR-0010) and pure helpers of the lock screen. No Qt or Quickshell types:
// unit-tested offscreen by tests/security/tst_lockmachine.qml.
//
//   unlocked -request-> locking -acquired-> locked -submit-> authenticating
//   authenticating -success-> unlocked
//   authenticating -failure|error|timeout|abort-> locked
//   locking|locked|authenticating -lost-> locking        (compositor dropped the lock: re-acquire)
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

// Crash-recovery marker ($XDG_RUNTIME_DIR, one per compositor instance). Anything but an exact
// "unlocked" in an existing, non-empty marker means the session was locked: re-lock.
function markerSaysLocked(text) {
    var t = String(text === undefined || text === null ? "" : text).trim();
    return t !== "" && t !== "unlocked";
}

// Lock to restore when a shell instance starts (crash restart, reload or session start), from
// what it can read synchronously. Fail closed:
//   - intent: the previous instance's lock intent carried over a soft reload (PersistentProperties);
//   - markerAvailable false (XDG_RUNTIME_DIR unset): no marker can prove the session unlocked;
//   - otherwise the marker decides (markerSaysLocked). A missing marker is the first start of this
//     compositor instance; if it was removed while locked, the compositor still holds the dead
//     client's lock (ext-session-lock) and compositorLockState() finds it.
function restoreAtStart(intent, markerAvailable, markerText) {
    return intent === true || markerAvailable !== true || markerSaysLocked(markerText);
}

// Session lock state as reported by Hyprland, from `hyprctl -j monitors` objects
// (Quickshell HyprlandMonitor.lastIpcObject). Hyprland has no lock query, but an active
// ext-session-lock, including one whose client died, puts "LOCK" in solitaryBlockedBy. Hyprland
// stops listing at "WORKSPACE" (monitor without a workspace yet), so such a list proves nothing.
// Returns "locked", "unlocked" or "unknown" (no complete list; e.g. not Hyprland).
function compositorLockState(monitors) {
    var readable = false;
    var list = monitors || [];
    for (var i = 0; i < list.length; i++) {
        var blockers = list[i] ? list[i].solitaryBlockedBy : undefined;
        if (!blockers || typeof blockers === "string" || typeof blockers.length !== "number")
            continue;
        var names = [];
        for (var j = 0; j < blockers.length; j++)
            names.push(String(blockers[j]));
        if (names.indexOf("LOCK") !== -1)
            return "locked";
        if (names.indexOf("WORKSPACE") === -1)
            readable = true;
    }
    return readable ? "unlocked" : "unknown";
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
