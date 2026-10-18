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
//
// Lock ownership (docs/specs/security.md "Lock ownership and foreign lockers"): Hyprland 0.56 with
// misc.allow_session_lock_restore hands a LIVE session lock to the next client that asks and tells
// the previous holder nothing; when either client releases its lock, the session is unlocked
// although the other one's WlSessionLock still reports locked and secure. While this shell holds a
// confirmed lock, ownershipProbe therefore asks Hyprland for the real session lock state (no
// Hyprland event exists for it) and takes a fresh lock as soon as the session is found unlocked.
// A foreign locker that takes the lock over is left alone (the session stays locked); its release
// is followed by a fresh Grassfield lock.
Singleton {
    id: root

    // "unlocked" | "locking" | "locked" | "authenticating"
    readonly property string lockState: controller.lockState
    readonly property bool locked: controller.locked
    // This shell holds a lock the compositor confirmed (its `locked` event: every output shows a
    // lock surface). On Hyprland the lock may since have been taken over: see `secure`.
    readonly property bool holding: (controller.lockState === Machine.LOCKED || controller.lockState === Machine.AUTHENTICATING) && sessionLock.secure
    // Holding, and Hyprland reported the session locked since the last verify() (or the lock was
    // just acquired). SleepInhibitor releases the sleep delay only on this.
    readonly property bool secure: holding && verified
    property bool verified: false
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

    // Hyprland IPC is available for the lock ownership checks (Quickshell.Hyprland, no hyprctl).
    readonly property bool hyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== ""
    // Date.now() when the compositor last confirmed a lock of this shell (its `locked` event).
    property double securedAt: 0
    // Consecutive Hyprland answers reporting the session unlocked while holding (see checkOwnership).
    property int unlockedAnswers: 0
    // The lock surface (one per screen) whose window has the keyboard, else null: none of this shell's lock
    // surfaces has it (another client's lock surface took it, or a window did after the session was unlocked
    // under this lock). Only ever speeds the ownership check up.
    property var focusedSurface: null
    // The lock this shell holds was requested by restore() or checkStranded() (reason "restore"): it may be a lock
    // taken over from a live foreign locker, whose release unlocks the session without any event. Cleared by
    // relock() (the session was found unlocked: that release happened) and release().
    property bool inheritedLock: false
    // Another client may hold or have held the session lock (Machine.takeoverSuspected): the ownership check then
    // runs every Machine.PROBE_SUSPECTED_MS instead of every second (R12 review #3: the session stayed unlocked up
    // to ~1.1 s after a foreign locker released a lock it had taken over).
    readonly property bool takeoverSuspected: holding && hyprland && Machine.takeoverSuspected(focusedSurface !== null, inheritedLock)

    onTakeoverSuspectedChanged: {
        if (takeoverSuspected)
            console.info("grassfield-lock: takeover suspected (" + (focusedSurface === null ? "no lock surface has the keyboard" : "lock inherited at start") + "); ownership check every " + Machine.PROBE_SUSPECTED_MS + " ms");
        else if (holding)
            console.info("grassfield-lock: no takeover suspected; ownership check every " + Machine.PROBE_INTERVAL_MS + " ms");
    }

    // Engage the lock. reason: "ipc" | "menu" | "idle" | "sleep" | "restore". Returns "ok",
    // "already-locked" or "refused: missing-pam". When this shell already holds a lock, the
    // compositor is asked again (verify()): a session found unlocked under it gets a fresh lock once
    // a fresh answer confirms it (checkOwnership), never here on an earlier answer alone: relock()
    // releases the lock object first, and releasing the lock the compositor still uses unlocks the
    // session until the new lock arrives (R12 review #3: keys reached a window in forced runs).
    function lock(reason: string): string {
        if (controller.locked) {
            console.info("grassfield-lock: lock requested (" + reason + ") while " + controller.lockState + "; verifying the session lock");
            engage();
            verify();
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
        inheritedLock = reason === "restore";
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

    // Ask Hyprland again whether the session is locked (repeated lock request, before sleep, lock
    // surface lost keyboard focus). `secure` is false until the answer; checkOwnership() takes a
    // fresh lock if the session is found unlocked. A lock confirmed less than verifyGraceMs ago
    // needs no answer: the compositor's own `locked` event is the proof.
    function verify(): void {
        if (!holding || !hyprland || Date.now() - securedAt < ownershipProbe.verifyGraceMs)
            return;
        verified = false;
        Hyprland.refreshMonitors();
    }

    // The session is unlocked under a lock object that still reports secure (another client took
    // the lock over and released it): drop that stale object and request a new lock in the same
    // event-loop turn. Never unlocks anything that is not already unlocked; the carried intent and
    // the marker stay "locked". Not atomic (the release can reach Hyprland before the new request):
    // called ONLY from checkOwnership() on a confirmed "unlocked" answer (Machine.ownershipAction),
    // never on a single answer, which may be stale (tests/security/reload_order checks the callers).
    function relock(why: string): void {
        console.warn("grassfield-lock: the session is unlocked although this shell holds a lock (taken over and released by another client; " + why + "); taking a fresh lock");
        unlockedAnswers = 0;
        verified = false;
        inheritedLock = false;
        controller.lockLost();
        sessionLock.locked = false;
        engage();
    }

    // Runs after every Hyprland monitor answer (whoever asked). While holding, a session reported
    // unlocked twice in a row (Machine.ownershipAction) is re-locked. Answers in the first
    // verifyGraceMs after the lock was confirmed are skipped: they may answer a request sent before.
    function checkOwnership(): void {
        if (!holding || Date.now() - securedAt < ownershipProbe.verifyGraceMs) {
            unlockedAnswers = 0;
            return;
        }
        const state = Machine.compositorLockState(Hyprland.monitors.values.map(m => m.lastIpcObject));
        const action = Machine.ownershipAction(state, unlockedAnswers);
        unlockedAnswers = state === "unlocked" ? unlockedAnswers + 1 : 0;
        if (action === "confirm")
            Hyprland.refreshMonitors();
        else if (action === "relock")
            relock("confirmed by Hyprland");
        else
            verified = true; // "ok": the session is locked; "unknown": WlSessionLock's word is all there is
    }

    // Called by the controller after a PAM success only: the only path that clears the carried
    // intent and writes "unlocked".
    function release(): void {
        retryTimer.stop();
        fingerprintRetry.stop();
        if (fingerprintPam.active)
            fingerprintPam.abort();
        verified = false;
        unlockedAnswers = 0;
        inheritedLock = false;
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
    // crashed instance whose marker was missing or wrong, or a live foreign locker (Hyprland cannot
    // tell them apart). Take it over (fail closed: a dead client's lock could never be unlocked
    // otherwise). If it was a live locker, its later release unlocks the session under this lock
    // and ownershipProbe takes a fresh one.
    function checkStranded(): void {
        if (controller.locked) {
            strandedProbe.stop();
            return;
        }
        const monitors = Hyprland.monitors.values.map(m => m.lastIpcObject);
        const state = Machine.compositorLockState(monitors);
        if (state === "locked") {
            strandedProbe.stop();
            console.warn("grassfield-lock: the compositor holds a session lock this shell did not take (a crash with a missing or wrong marker, or a foreign locker); taking it over");
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
                // A fresh `locked` event: the compositor uses this lock now.
                root.securedAt = Date.now();
                root.unlockedAnswers = 0;
                root.verified = true;
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

            // Keyboard focus left this lock surface: on Hyprland that also happens when another
            // client takes the session lock over or the session is unlocked under it. Ask now
            // rather than at the next ownershipProbe tick (moving between outputs only costs a query),
            // and track whether any lock surface has the keyboard (takeoverSuspected).
            Item {
                id: keyboardProbe

                Window.onActiveChanged: {
                    if (Window.active) {
                        // Keyboard focus says nothing about a lock inherited at start: a live foreign locker that held the
                        // session lock sits UNDER this lock, and its release unlocks the session while this surface keeps
                        // the keyboard (R12 counter-review of 620f08c). inheritedLock is cleared only by relock() (that
                        // release happened) and release().
                        root.focusedSurface = keyboardProbe;
                    } else {
                        if (root.focusedSurface === keyboardProbe)
                            root.focusedSurface = null;
                        root.verify();
                    }
                }
                Component.onDestruction: {
                    if (root.focusedSurface === keyboardProbe)
                        root.focusedSurface = null;
                }
            }

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

    // Lock ownership check, only while holding a lock on Hyprland: one monitor query
    // (Quickshell.Hyprland IPC request, no hyprctl process) per second, every 100 ms while a takeover
    // is suspected (takeoverSuspected). Hyprland 0.56.2 emits no event when a session lock is taken
    // over or released (verified on its event socket), so a query is the only way to notice that the
    // session was unlocked under this lock. The answer is handled by checkOwnership() (monitorAnswers),
    // as are answers to anyone's query. A changed interval restarts the timer.
    Timer {
        id: ownershipProbe

        // Answers this soon after the compositor confirmed the lock are not trusted (see checkOwnership).
        readonly property int verifyGraceMs: 500

        interval: Machine.probeInterval(root.takeoverSuspected)
        repeat: true
        running: root.holding && root.hyprland && !devPause.running
        onTriggered: Hyprland.refreshMonitors()
    }

    // Dev-only (GRASSFIELD_DEV=1): `lock devPauseOwnershipCheck` stops the periodic check for 10 s so
    // that tests/security/reload_locked.sh can hold a desync and check the lock()/before-sleep paths.
    Timer {
        id: devPause
        interval: 10000
        onTriggered: console.warn("grassfield-lock: dev pause of the lock ownership check ended")
    }

    Instantiator {
        id: monitorAnswers

        active: root.hyprland
        model: Hyprland.monitors

        delegate: Connections {
            required property HyprlandMonitor modelData

            target: modelData

            // One call per answer, after every monitor of it was updated.
            function onLastIpcObjectChanged(): void {
                Qt.callLater(root.checkOwnership);
            }
        }
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
        // Defence in depth: in a dev/test session, never hand a password to PAM unless the L2 test opts in.
        // A stray key reaching the lock field in nested then cannot count a faillock failure on the real account.
        controller.pamSuppressed = Quickshell.env("GRASSFIELD_DEV") === "1" && Quickshell.env("GRASSFIELD_DEV_ALLOW_PAM") !== "1";
        if (controller.pamSuppressed)
            console.warn("grassfield-lock: dev: PAM is suppressed on the lock (no real authentication; set GRASSFIELD_DEV_ALLOW_PAM=1 for the L2 failure-path test)");
        restore(false, "start");
        if (!controller.locked && root.hyprland)
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

        // Dev-only test hook (GRASSFIELD_DEV=1, nested): pause the periodic lock ownership check for
        // 10 s (answers to other queries, lock() and verify() still check). Refused otherwise.
        function devPauseOwnershipCheck(): string {
            if (Quickshell.env("GRASSFIELD_DEV") !== "1")
                return "refused";
            console.warn("grassfield-lock: dev pause of the lock ownership check (10 s)");
            devPause.restart();
            return "paused";
        }

        // Dev-only test hook (GRASSFIELD_DEV=1, nested): count one "unlocked" answer Hyprland never gave, as a stale
        // answer would, while the session is really locked (tests/security/reload_locked.sh `relock-confirm`). Only a
        // relock can follow (never an unlock), and only once a fresh answer confirms it. Refused otherwise.
        function devForgeUnlockedAnswer(): string {
            if (Quickshell.env("GRASSFIELD_DEV") !== "1")
                return "refused";
            if (!root.holding)
                return "not-holding";
            console.warn("grassfield-lock: dev forged one unlocked answer");
            root.unlockedAnswers = 1;
            return "forged";
        }
    }
}
