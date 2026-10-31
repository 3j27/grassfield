pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/services/idle/Service.qml (omacom/omarchy, branch
// quattro): IdleMonitor with respectInhibitors. Copyright (c) David Heinemeier Hansson, MIT License (upstream
// LICENSE, basecamp/omarchy v4.0.4; notice shipped as packaging/licenses/omarchy-MIT.txt).
import QtQuick
import Quickshell
import Quickshell.Hyprland // layering-exception: ADR-0021 security
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.security.lock
import "IdleModel.js" as IdleModel
import "../../lib/RunMode.js" as RunMode

// Idle handling (SEC7, ADR-0010): after T-10 s without input the screens dim, at T the session
// locks (T = lock.idleMinutes, default 5, 0 = never). Any input undims and cancels. Wayland idle
// inhibitors (video players, presentations) are respected by the compositor's idle-notify
// protocol. Display power-off on the lock screen (D-4, macOS): IdleModel.DISPLAY_OFF_SECONDS without input while
// locked switch the displays off (Hyprland DPMS); input or the unlock switch them on (the compositor also wakes them on
// a key press or pointer motion: misc.key_press_enables_dpms / mouse_move_enables_dpms, looknfeel.lua, so a shell that
// died meanwhile cannot leave the screen dark). While unlocked, lock.displayOffBattery / lock.displayOffPower minutes without
// input (the power source in use; 0 = never) also switch them off, without locking (macOS 27 Lock Screen: Turn display off when
// inactive); a lock that follows keeps them off until input. Also hosts the lock-before-sleep inhibitor.
Scope {
    id: root

    readonly property var timing: IdleModel.timings(Settings.lockIdleMinutes)
    property bool dimmed: false
    // Dev session only (RunMode.dev through the relative import, which no QML import path can replace): the dev hooks
    // answer. Never in a real session (GRASSFIELD_SESSION=1), SEC-03.
    readonly property bool devHooks: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // Seconds without input on the lock screen before the displays go off; 0 = never. Off in the nested dev session
    // unless a test sets it (`idle devDisplayOff <seconds>`): a dark nested output would spoil the lock tests' captures.
    property int displayOffSeconds: devHooks ? 0 : IdleModel.DISPLAY_OFF_SECONDS
    // This module switched the displays off (and must switch them on again).
    property bool displayOff: false
    // Seconds without input before the displays go off while unlocked, for the power source in use; 0 = never. Always off in
    // the nested dev session (a dark nested output would spoil every capture; no test needs it there).
    readonly property int inactiveOffSeconds: devHooks ? 0 : IdleModel.inactiveDisplayOffSeconds(Settings.lockDisplayOffBattery, Settings.lockDisplayOffPower, Battery.onBattery)
    // The unlocked monitor turned the displays off and no input came since.
    property bool offForInactivity: false
    property bool rearmingInactive: false

    // The compositor also switches the displays on at a key press or pointer motion, so "off" is sent whenever the state is
    // recomputed, never skipped as already done (a stale "off" would keep the next "off" from being sent); "on" only when this
    // module had them off (a repeated enable can flicker on some hardware), and always while a lock is being acquired: an
    // instance restarted with the displays dark starts with displayOff false, and the compositor confirms a lock only once it
    // has drawn it.
    function setDisplays(on: bool): void {
        if (on && !displayOff && !(Lock.locked && !Lock.holding))
            return;
        if (on === displayOff)
            console.info("grassfield-idle: displays " + (on ? "on" : (Lock.locked ? "off (locked, no input)" : "off (inactive)")));
        displayOff = !on;
        const action = on ? "enable" : "disable";
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.dpms({ action = \"" + action + "\" })" : "dpms " + (on ? "on" : "off"));
    }

    function updateDisplays(): void {
        setDisplays(!IdleModel.displaysOff(lockedMonitor.enabled && lockedMonitor.isIdle, root.offForInactivity && inactiveMonitor.enabled && inactiveMonitor.isIdle, Lock.locked, Lock.holding));
    }

    // A lock that starts lights the displays until it holds (IdleModel.displaysOff); an unlock without Wayland input (a
    // fingerprint) lights a session that went dark for inactivity. Later in the turn (Qt.callLater runs one call for all the
    // requests of a turn): once locked and holding have both settled, and after the lock request has been queued.
    Connections {
        target: Lock

        function onLockedChanged(): void {
            if (!Lock.locked) {
                root.offForInactivity = false;
                root.endDimUntilLock();
            }
            root.acquireOnTries = 0;
            Qt.callLater(root.updateDisplays);
        }

        function onHoldingChanged(): void {
            root.acquireOnTries = 0;
            // The lock holds: the dim that led to it goes (under the lock surfaces, unseen).
            if (Lock.holding) {
                root.endDimUntilLock();
                root.dimmed = false;
            }
            Qt.callLater(root.updateDisplays);
        }
    }

    // A lock restored at start (a restarted shell) may not change Lock.locked: light the displays it has to draw on.
    Component.onCompleted: updateDisplays()

    // While a lock is being acquired, "on" again until it holds (a lost request would leave it undrawn until input), a few
    // times only.
    property int acquireOnTries: 0
    Timer {
        interval: IdleModel.ACQUIRE_DISPLAYS_ON_MS
        repeat: true
        running: Lock.locked && !Lock.holding && root.acquireOnTries < IdleModel.ACQUIRE_DISPLAYS_ON_TRIES
        onTriggered: {
            root.acquireOnTries++;
            root.updateDisplays();
        }
    }

    // ---- ADR-0040 step 5 (ID-8): the dim stays until the lock it led to holds; the lock's content starts at the dim's level
    // (Lock.fromDim). The lock request is not delayed; when it fails, the dim lifts at once (as before). Display only. ----
    property bool dimUntilLock: false
    function endDimUntilLock(): void {
        if (!root.dimUntilLock)
            return;
        root.dimUntilLock = false;
        dimUntilLockBound.stop();
        Lock.fromDim = false;
        root.update();
    }
    Timer {
        id: dimUntilLockBound
        interval: IdleModel.DIM_UNTIL_LOCK_MAX_MS
        onTriggered: root.endDimUntilLock()
    }

    // ---- ADR-0040 step 5 (IQ-T4 A): a display that turns off for inactivity locks the session, at once (the displays stay
    // on until the lock holds, IdleModel.displaysOff, so the lock is drawn just before they go off) or after
    // lock.requirePasswordAfterDisplayOff without input, or never; lock.idleMinutes stays the ceiling. ----
    readonly property int requireAfterMs: IdleModel.requireAfterDisplayOffMs(Settings.lockRequirePasswordAfterDisplayOff)
    function displayOffLock(): void {
        const result = Lock.lock("display-off");
        if (result !== "ok" && result !== "already-locked")
            console.warn("grassfield-idle: display-off lock not engaged:", result);
    }
    Timer {
        id: displayOffLockTimer
        interval: Math.max(1, root.requireAfterMs)
        onTriggered: {
            if (root.offForInactivity && !Lock.locked)
                root.displayOffLock();
        }
    }

    function update(): void {
        // A lock that the dim led to is being acquired: the dim stays until it holds (ID-8).
        if (root.dimUntilLock)
            return;
        if (monitor.enabled && monitor.isIdle) {
            if (!dimmed)
                console.info("grassfield-idle: idle, dimming; lock in " + root.timing.lockDelayMs / 1000 + " s");
            dimmed = true;
            lockTimer.restart();
        } else {
            // Only real input counts as activity; a disabled monitor (locked, rearming) is not.
            if (dimmed && monitor.enabled)
                console.info("grassfield-idle: activity, idle lock cancelled");
            dimmed = false;
            lockTimer.stop();
        }
    }

    // Quickshell 0.3.1 IdleMonitor keeps the timeout it was enabled with (verified in nested:
    // a runtime change is ignored), and grassfield.json loads after startup. Re-enable it on
    // every timeout change so the new value applies.
    property bool rearming: false

    // Applications hold org.freedesktop.ScreenSaver idle inhibitors (GF-016; set from shell.qml, the menu bridge's
    // screensaver lines; false without a bridge). While true the screen neither dims nor locks on idle, as on macOS
    // while a video plays; a manual lock, the lid and the lock before sleep are unaffected.
    property bool busInhibited: false
    onBusInhibitedChanged: console.info("grassfield-idle: " + (busInhibited ? "idle inhibited by an application (org.freedesktop.ScreenSaver)" : "no application inhibits idle (org.freedesktop.ScreenSaver)"))

    IdleMonitor {
        id: monitor
        enabled: IdleModel.idleArmed(root.timing.enabled, Lock.locked, root.rearming, root.busInhibited)
        timeout: root.timing.dimSeconds
        respectInhibitors: true
        onIsIdleChanged: root.update()
        onEnabledChanged: root.update()
        onTimeoutChanged: {
            root.rearming = true;
            Qt.callLater(() => root.rearming = false);
        }
    }

    Timer {
        id: lockTimer
        interval: root.timing.lockDelayMs
        onTriggered: {
            // The lock's content starts at the dim's level (ADR-0040 ID-8), and the dim stays until the lock holds. Set before
            // the request: Lock.lock() flips `locked` synchronously, which disables the monitor and runs update() at once
            // (opus review of 9a417967, MINOR 1).
            Lock.fromDim = true;
            root.dimUntilLock = true;
            dimUntilLockBound.restart();
            const result = Lock.lock("idle");
            if (result !== "ok") {
                // As before this step: the dim lifts at once, and no new attempt is scheduled (not through update()).
                root.dimUntilLock = false;
                dimUntilLockBound.stop();
                Lock.fromDim = false;
                root.dimmed = false;
                console.warn("grassfield-idle: idle lock not engaged:", result);
            }
        }
    }

    // No input while unlocked for inactiveOffSeconds: the displays go off; the session stays unlocked until the idle lock.
    IdleMonitor {
        id: inactiveMonitor
        // Armed only once its timeout is the one wanted, so that turning the setting on never arms it with the placeholder 1 s.
        enabled: timeout === root.inactiveOffSeconds && IdleModel.inactiveOffArmed(root.inactiveOffSeconds, Lock.locked, root.offForInactivity, root.rearmingInactive, root.busInhibited)
        timeout: Math.max(1, root.inactiveOffSeconds)
        respectInhibitors: true
        onIsIdleChanged: {
            root.offForInactivity = isIdle && enabled;
            // IQ-T4 A: the lock first (at once), or after the delay without input, or never.
            if (root.offForInactivity && !Lock.locked) {
                if (root.requireAfterMs === 0)
                    root.displayOffLock();
                else if (root.requireAfterMs > 0)
                    displayOffLockTimer.restart();
            } else {
                displayOffLockTimer.stop();
            }
            root.updateDisplays();
        }
        onEnabledChanged: {
            if (!enabled) {
                root.offForInactivity = false;
                displayOffLockTimer.stop();
            }
            Qt.callLater(root.updateDisplays);
        }
        // The power source changed (or the setting): re-enable so that the new timeout applies (see `rearming`).
        onTimeoutChanged: {
            root.rearmingInactive = true;
            Qt.callLater(() => root.rearmingInactive = false);
        }
    }

    // Input on the lock screen (respectInhibitors false: a video behind the lock is not being watched). Only while the lock
    // is secured (Lock.holding: the compositor confirmed it and the lock surfaces are up), never while it is still being
    // acquired: the displays never go dark over a session that is not locked yet.
    IdleMonitor {
        id: lockedMonitor
        enabled: Lock.holding && root.displayOffSeconds > 0
        timeout: Math.max(1, root.displayOffSeconds)
        respectInhibitors: false
        onIsIdleChanged: root.updateDisplays()
        onEnabledChanged: root.updateDisplays()
    }

    SleepInhibitor {
        id: sleepInhibitor
    }

    // Dim layer: no input region, so pointer motion reaches the compositor and counts as activity.
    Variants {
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            screen: modelData
            visible: root.dimmed || shade.opacity > 0
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "grassfield-idle-dim"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // qmllint disable missing-type
            mask: Region {}
            // qmllint enable missing-type

            Rectangle {
                id: shade
                anchors.fill: parent
                color: Tokens.colorDark.shadow
                opacity: root.dimmed ? Tokens.idleDimOpacity : 0

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(root.dimmed ? Tokens.idleDimFade : Tokens.motionFast)
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "idle"

        // Test hook (dev only, else "refused"): idle state as JSON.
        function status(): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            return JSON.stringify({
                enabled: monitor.enabled,
                idle: monitor.isIdle,
                dimmed: root.dimmed,
                dimSeconds: root.timing.dimSeconds,
                lockSeconds: root.timing.lockSeconds,
                sleepInhibitor: sleepInhibitor.inhibiting,
                sleepDegraded: sleepInhibitor.degraded,
                sleepBudgetMs: sleepInhibitor.budgetMs,
                displayOffSeconds: root.displayOffSeconds,
                displayOff: root.displayOff,
                inactiveOffSeconds: root.inactiveOffSeconds,
                inactiveOffArmed: inactiveMonitor.enabled,
                offForInactivity: root.offForInactivity,
                busInhibited: root.busInhibited
            });
        }

        // Dev hook (dev only, else "refused"): run the before-sleep ("before") or after-resume ("after") path without
        // logind (tests/security/reload_locked.sh). The dev shell never holds a real inhibitor, so nothing is delayed.
        function devSleep(phase: string): string {
            if (!root.devHooks)
                return RunMode.REFUSED;
            if (phase === "before")
                sleepInhibitor.beforeSleep();
            else if (phase === "after")
                sleepInhibitor.afterResume();
            else
                return "unknown phase";
            return "ok";
        }

        // Dev hook (dev only, else "refused"): display power-off delay on the lock screen, 0..600 s (0 = never), for
        // tests/security/lock_privacy.sh `display-off`. Takes effect at the next lock.
        function devDisplayOff(seconds: int): string {
            if (!root.devHooks || seconds < 0 || seconds > 600)
                return RunMode.REFUSED;
            root.displayOffSeconds = seconds;
            return "ok";
        }
    }
}
