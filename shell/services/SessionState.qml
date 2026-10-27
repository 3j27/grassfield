pragma Singleton
import QtQuick

// What the rest of the shell may know about the session lock without importing the security module: `locked` mirrors
// shell/security/lock (set by a Binding in shell.qml), and `requestLock()` asks that module to lock (shell.qml calls
// `Lock.lock(reason)`, the same function as the `lock` IPC target and the System menu). Notifications read `locked` (previews
// "When Unlocked"); Search calls `requestLock` (Lock Screen command). `saverShown` mirrors the screen saver (shell/saver, a
// Binding in shell.qml) for the polkit agent, which holds a request while it shows (ADR-0032); true when it is not would only
// hold a request. Without the shell's wiring (a test harness) the session counts as unlocked, no saver shows and a lock
// request does nothing.
QtObject {
    id: root

    property bool locked: false
    property bool saverShown: false
    // An authorization (polkit) request is open (shell/security/polkit AuthAgent.requestActive, set by a Binding in shell.qml).
    // The clipboard history records nothing while it is true and for 2 s after (ADR-0034 Q11): an echo-on answer is copyable.
    property bool authorizing: false
    signal lockRequested(string reason)

    function requestLock(reason: string): void {
        lockRequested(reason);
    }

    // GF-AUDIT-001 GF-116 (DT-08), macOS model: while the session is locked (or locking) nothing but the lock screen
    // opens. Every shell surface asks this before it opens (Search, Apps, Overview, Notification Center, every Popups
    // kind: Control Center, menus, panels; Dock keyboard mode; window commands), whatever asked: a binding, IPC, a screen
    // corner, a gesture. True (and one log line naming the surface) while locked: the caller then stays closed. Each
    // surface also closes itself when `locked` becomes true. Hyprland keeps input and rendering on the lock surfaces
    // anyway (ext-session-lock); this is the shell's own defence, so nothing waits behind the lock either.
    function refuses(surface: string): bool {
        if (!locked)
            return false;
        console.info("grassfield: " + surface + " refused: the session is locked");
        return true;
    }
}
