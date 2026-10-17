pragma ComponentBehavior: Bound
pragma Singleton
// Portions adapted from Omarchy shell/plugins/lock/Service.qml (omacom/omarchy, branch quattro),
// MIT License, Copyright (c) the Omarchy authors: the PamContext prompt/response wiring and the
// WlSessionLock secure-state handling; the stranded-lock signal (LOCK in solitaryBlockedBy) comes
// from Omarchy's omarchy-hyprland-session-locked.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import Grassfield.Ui
import qs.security
import qs.services
import "../LockMachine.js" as Machine

// Session lock (ADR-0010, master-prompt R12): ext-session-lock through WlSessionLock, password
// checked by PAM service "omarchy-lock-password" (no PAM file of ours). Only a PAM success
// unlocks; every error, timeout or lost lock keeps the session locked.
//
// Lock survival, fail closed (docs/specs/security.md "Lock survival"):
// - Crash: Hyprland keeps the session locked when this process dies (ext-session-lock; its
//   "lockscreen app died" screen, no input reaches clients). The restarted shell re-takes the lock
//   (misc.allow_session_lock_restore = true) when the marker in $XDG_RUNTIME_DIR (one per
//   compositor instance) says anything but exactly "unlocked", when XDG_RUNTIME_DIR is unset
//   (nothing can prove the session unlocked), or when Hyprland reports a lock this instance did
//   not take (forged or missing marker): see strandedProbe.
// - Soft reload (Quickshell.reload(false)): the new WlSessionLock inherits the old instance's lock
//   in WlSessionLock::onReload and RELEASES it if its `locked` is false at that moment. The lock
//   intent is therefore carried over in `persist` (PersistentProperties), which Quickshell restores
//   before sessionLock reloads, and the marker is also checked in Component.onCompleted, which runs
//   before the reload pass. File watching is off (shell.qml), so only an explicit reload can happen.
// A fresh session (no marker, no carried intent) starts unlocked: if a marker was removed while
// locked, the compositor still holds the dead client's lock and strandedProbe re-acquires it.
Singleton {
    id: root

    // "unlocked" | "locking" | "locked" | "authenticating"
    readonly property string lockState: controller.lockState
    readonly property bool locked: controller.locked
    // The compositor confirmed that every output shows a lock surface.
    readonly property bool secure: sessionLock.secure
    readonly property bool pamAvailable: controller.pamAvailable
    readonly property bool fingerprintAvailable: fingerprintFile.available

    readonly property string loginName: Quickshell.env("USER")
    property string userName: loginName
    // Account picture: ~/.face if readable, else the AccountsService icon, else "" (initials).
    property string avatarSource: ""

    readonly property string markerPath: {
        const dir = Quickshell.env("XDG_RUNTIME_DIR");
        return dir ? dir + "/" + Machine.markerName(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"), Quickshell.env("WAYLAND_DISPLAY")) : "";
    }
    // The last marker write failed (or could not be read back).
    property bool markerFailed: false
    // Crash recovery cannot record the lock state; shown on the lock surface (the lock itself is
    // unaffected: a crash still leaves the compositor locked).
    readonly property bool recoveryDegraded: markerPath === "" || markerFailed

    // Engage the lock. reason: "ipc" | "menu" | "idle" | "sleep" | "restore". Returns "ok",
    // "already-locked" or "refused: missing-pam".
    function lock(reason: string): string {
        if (controller.locked) {
            engage();
            return "already-locked";
        }
        controller.pamAvailable = pamServiceInstalled();
        // A lock nobody could open is refused, except when restoring one (never fail open).
        if (!controller.pamAvailable && reason !== "restore") {
            console.warn("grassfield-lock: refused (" + reason + "): /etc/pam.d/omarchy-lock-password is missing");
            return "refused: missing-pam";
        }
        strandedProbe.stop();
        console.info("grassfield-lock: lock requested (" + reason + ")");
        Popups.close();
        writeMarker("locked");
        controller.requestLock();
        engage();
        return "ok";
    }

    // Ask the compositor for the lock; retried by retryTimer until it is confirmed.
    function engage(): void {
        if (controller.lockState !== Machine.LOCKING)
            return;
        if (Quickshell.screens.length > 0 && !sessionLock.locked)
            sessionLock.locked = true;
        if (sessionLock.locked && sessionLock.secure)
            controller.lockAcquired();
        else
            retryTimer.start();
    }

    // Called by the controller after a PAM success only: the only path that clears the carried
    // intent and writes "unlocked".
    function release(): void {
        retryTimer.stop();
        fingerprintRetry.stop();
        if (fingerprintPam.active)
            fingerprintPam.abort();
        persist.intent = false;
        sessionLock.locked = false;
        writeMarker("unlocked");
        console.info("grassfield-lock: unlocked");
    }

    // Atomic, blocking write, then read back. Returns false (and sets markerFailed, logged and
    // shown on the lock surface) when the marker cannot hold the value.
    function writeMarker(value: string): bool {
        if (markerPath === "") {
            console.warn("grassfield-lock: XDG_RUNTIME_DIR unset: no crash recovery marker (" + value + "); a restart will lock");
            return false;
        }
        // FileView skips a write equal to its cached text, which is stale if the file was changed
        // or removed behind its back: re-read first.
        marker.reload();
        marker.waitForJob();
        marker.setText(value + "\n");
        marker.reload();
        marker.waitForJob();
        const ok = String(marker.text()).trim() === value;
        if (!ok)
            console.warn("grassfield-lock: crash recovery marker could not be written:", root.markerPath, "(wanted " + value + ")");
        markerFailed = !ok;
        return ok;
    }

    // null when the marker does not exist; "" when it exists but cannot be read (locks); else its
    // text (Machine.markerRead).
    function readMarker(): var {
        if (markerPath === "")
            return null;
        marker.reload();
        marker.waitForJob();
        return Machine.markerRead(marker.loadError === FileViewError.FileNotFound, marker.loadError !== FileViewError.Success, marker.text());
    }

    // Restore the lock if the previous instance held or wanted it (see the header). Only ever
    // locks; never unlocks.
    function restore(intent: bool, when: string): void {
        if (controller.locked || !Machine.restoreAtStart(intent, markerPath !== "", readMarker()))
            return;
        console.info("grassfield-lock: restoring the lock (" + when + (intent ? ", carried intent" : "") + (markerPath === "" ? ", no XDG_RUNTIME_DIR" : "") + ")");
        lock("restore");
    }

    // Stranded lock: Hyprland holds a session lock although this instance never locked, i.e. a
    // crashed instance whose marker was missing or wrong. Re-acquire it so it can be unlocked.
    function checkStranded(): void {
        if (controller.locked) {
            strandedProbe.stop();
            return;
        }
        const monitors = Hyprland.monitors.values.map(m => m.lastIpcObject);
        const state = Machine.compositorLockState(monitors);
        if (state === "locked") {
            strandedProbe.stop();
            console.warn("grassfield-lock: the compositor holds a session lock this shell did not take (crash with a missing or wrong marker); re-acquiring it");
            lock("restore");
        } else if (state === "unlocked") {
            strandedProbe.stop();
        } else if (--strandedProbe.remaining <= 0) {
            strandedProbe.stop();
            console.info("grassfield-lock: compositor lock state unknown; relying on the crash recovery marker");
        } else {
            Hyprland.refreshMonitors();
        }
    }

    function pamServiceInstalled(): bool {
        passwordFile.reload();
        return passwordFile.text().length > 0;
    }

    function pamResultName(result: int): string {
        switch (result) {
        case PamResult.Success:
            return "success";
        case PamResult.Failed:
            return "failed";
        case PamResult.MaxTries:
            return "maxtries";
        }
        return "error";
    }

    function startFingerprint(): void {
        if (!fingerprintFile.available || controller.lockState !== Machine.LOCKED || !sessionLock.secure || fingerprintPam.active)
            return;
        if (!fingerprintPam.start())
            fingerprintRetry.restart();
    }

    LockController {
        id: controller
        pam: passwordPam
        onUnlockRequested: root.release()
        onLockStateChanged: {
            // Carried over a soft reload; cleared only by release() (PAM success).
            if (controller.locked)
                persist.intent = true;
            if (lockState === Machine.LOCKED)
                root.startFingerprint();
        }
    }

    // Lock intent carried over a Quickshell soft reload. MUST stay declared before sessionLock:
    // Quickshell 0.3.1 reloads a Singleton's children in declaration order (ReloadPropagator),
    // so the old values are restored here, and sessionLock's `locked` binding re-evaluated, before
    // WlSessionLock::onReload decides whether to keep the handed-over lock. Checked offscreen by
    // tests/security/reload_order and in nested by tests/security/reload_locked.sh.
    PersistentProperties {
        id: persist
        reloadableId: "grassfield-lock-intent"

        // The previous instance was locking, locked or authenticating.
        property bool intent: false

        // Runs inside the reload pass of every instance (no old instance: intent stays false). The
        // old value just restored must not downgrade a lock taken in Component.onCompleted: only
        // release() (PAM success) ever clears the intent.
        onLoaded: {
            intent = intent || controller.locked;
            root.restore(intent, "reload");
        }
    }

    WlSessionLock {
        id: sessionLock

        // Declarative initial value (no false-to-true window): already true at WlSessionLock::onReload
        // when the previous instance held or wanted the lock (persist) or the marker restored it
        // (controller). False only when both are unlocked, i.e. after release(). engage() and
        // release() take over imperatively afterwards.
        locked: persist.intent || controller.locked

        onSecureStateChanged: {
            if (secure) {
                retryTimer.stop();
                controller.lockAcquired();
            }
        }

        onLockStateChanged: {
            if (!locked && controller.locked) {
                if (controller.lockState !== Machine.LOCKING)
                    console.warn("grassfield-lock: compositor dropped the lock; re-acquiring");
                controller.lockLost();
                retryTimer.start();
            }
        }

        WlSessionLockSurface {
            id: surface

            color: Tokens.colorDark.shadow

            LockView {
                id: view
                anchors.fill: parent
                userName: root.userName
                avatarSource: root.avatarSource
                authenticating: controller.authenticating
                inputEnabled: controller.pamAvailable
                message: controller.pamAvailable ? controller.message : qsTr("Authentication service unavailable. The session stays locked.")
                notice: root.recoveryDegraded ? qsTr("Crash recovery unavailable: the lock state could not be saved.") : ""
                onSubmitted: password => controller.submit(password)
                onEdited: controller.clearMessage()
            }

            Connections {
                target: controller

                function onFailed(): void {
                    view.shake();
                }

                function onClearRequested(): void {
                    view.clear();
                }
            }
        }
    }

    PamContext {
        id: passwordPam
        config: "omarchy-lock-password"
        // user unset: PAM authenticates the uid running the shell, not $USER.

        onPamMessage: controller.pamMessage(message, messageIsError, responseRequired)
        onCompleted: result => controller.pamCompleted(root.pamResultName(result))
        onError: controller.pamError()
    }

    // Started only when /etc/pam.d/omarchy-lock-fingerprint exists (SEC8).
    PamContext {
        id: fingerprintPam
        config: "omarchy-lock-fingerprint"

        onCompleted: result => {
            if (result === PamResult.Success)
                controller.fingerprintSucceeded();
            else if (result !== PamResult.MaxTries)
                fingerprintRetry.restart();
        }
        onError: fingerprintRetry.restart()
    }

    Timer {
        id: fingerprintRetry
        interval: 1000
        onTriggered: root.startFingerprint()
    }

    Timer {
        id: retryTimer
        interval: 500
        repeat: true
        onTriggered: {
            if (controller.lockState !== Machine.LOCKING)
                stop();
            else
                root.engage();
        }
    }

    // Bounded startup check (at most 20 Hyprland monitor queries in 10 s, only until this instance
    // first locks); outputs may still be coming up, so an unknown answer is asked again.
    Timer {
        id: strandedProbe

        property int remaining: 20

        interval: 500
        repeat: true
        onTriggered: root.checkStranded()
    }

    FileView {
        id: passwordFile
        path: "/etc/pam.d/omarchy-lock-password"
        blockLoading: true
        printErrors: false
    }

    FileView {
        id: fingerprintFile

        property bool available: false

        path: "/etc/pam.d/omarchy-lock-fingerprint"
        printErrors: false
        onLoaded: available = true
        onLoadFailed: available = false
    }

    FileView {
        id: marker

        // Result of the last read (FileViewError): tells a missing marker from an unreadable one.
        property int loadError: FileViewError.Success

        path: root.markerPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onLoaded: loadError = FileViewError.Success
        onLoadFailed: error => loadError = error
        onSaveFailed: error => console.warn("grassfield-lock: crash recovery marker write failed:", FileViewError.toString(error))
    }

    // Existence probes for the account picture (no QML image warnings for missing files).
    FileView {
        path: Quickshell.env("HOME") + "/.face"
        printErrors: false
        onLoaded: root.avatarSource = "file://" + path
        onLoadFailed: accountsIcon.path = "/var/lib/AccountsService/icons/" + root.loginName
    }

    FileView {
        id: accountsIcon
        printErrors: false
        onLoaded: {
            if (root.avatarSource === "")
                root.avatarSource = "file://" + path;
        }
    }

    FileView {
        path: "/etc/passwd"
        printErrors: false
        onLoaded: root.userName = Machine.displayName(text(), root.loginName)
    }

    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.engage();
        }
    }

    // Runs before the reload pass (persist.onLoaded): a marker that says locked, or no
    // XDG_RUNTIME_DIR, restores the lock even if the carried intent were lost.
    Component.onCompleted: {
        controller.pamAvailable = pamServiceInstalled();
        restore(false, "start");
        if (!controller.locked && Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== "")
            strandedProbe.start();
    }

    IpcHandler {
        target: "lock"

        // Used by the Hyprland binding (SUPER+CTRL+Q) and the Grassfield menu.
        function lock(): string {
            return root.lock("ipc");
        }

        // Test hook: the state machine state.
        function status(): string {
            return root.lockState;
        }

        // Dev-only test hook (GRASSFIELD_DEV=1, nested): soft-reload the configuration the way
        // Quickshell's file watcher would (tests/security/reload_locked.sh). Refused otherwise.
        function devReload(): string {
            if (Quickshell.env("GRASSFIELD_DEV") !== "1")
                return "refused";
            console.warn("grassfield-lock: dev soft reload requested");
            Qt.callLater(() => Quickshell.reload(false));
            return "reloading";
        }
    }
}
