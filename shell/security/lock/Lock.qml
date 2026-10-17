pragma ComponentBehavior: Bound
pragma Singleton
// Portions adapted from Omarchy shell/plugins/lock/Service.qml (omacom/omarchy, branch quattro),
// MIT License, Copyright (c) the Omarchy authors: the PamContext prompt/response wiring and the
// WlSessionLock secure-state handling.
import QtQuick
import Quickshell
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
// Crash recovery: Hyprland keeps the session locked when this process dies; a marker in
// $XDG_RUNTIME_DIR (one per compositor instance) tells the restarted shell to take the lock
// again (misc.allow_session_lock_restore = true lets it).
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

    // Called by the controller after a PAM success only.
    function release(): void {
        retryTimer.stop();
        fingerprintRetry.stop();
        if (fingerprintPam.active)
            fingerprintPam.abort();
        sessionLock.locked = false;
        writeMarker("unlocked");
        console.info("grassfield-lock: unlocked");
    }

    function writeMarker(value: string): void {
        if (markerPath === "") {
            console.warn("grassfield-lock: XDG_RUNTIME_DIR unset, crash recovery marker disabled");
            return;
        }
        marker.setText(value + "\n");
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
            if (lockState === Machine.LOCKED)
                root.startFingerprint();
        }
    }

    WlSessionLock {
        id: sessionLock

        locked: false

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
        path: root.markerPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onSaveFailed: console.warn("grassfield-lock: could not write the crash recovery marker", root.markerPath)
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

    Component.onCompleted: {
        controller.pamAvailable = pamServiceInstalled();
        // A lock taken by a previous instance of this shell (crash, restart, reload) is restored.
        if (sessionLock.locked || (markerPath !== "" && Machine.markerSaysLocked(marker.text())))
            lock("restore");
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
    }
}
