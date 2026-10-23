pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/services/idle/Service.qml (omacom/omarchy, branch
// quattro), MIT License, Copyright (c) the Omarchy authors: IdleMonitor with respectInhibitors.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.security.lock
import "IdleModel.js" as IdleModel
import "../../services/DevGate.js" as DevGate

// Idle handling (SEC7, ADR-0010): after T-10 s without input the screens dim, at T the session
// locks (T = lock.idleMinutes, default 5, 0 = never). Any input undims and cancels. Wayland idle
// inhibitors (video players, presentations) are respected by the compositor's idle-notify
// protocol. Display power-off on the lock screen (D-4, macOS): IdleModel.DISPLAY_OFF_SECONDS without input while
// locked switch the displays off (Hyprland DPMS); input or the unlock switch them on (the compositor also wakes them on
// a key press or pointer motion: misc.key_press_enables_dpms / mouse_move_enables_dpms, looknfeel.lua, so a shell that
// died meanwhile cannot leave the screen dark). Also hosts the lock-before-sleep inhibitor.
Scope {
    id: root

    readonly property var timing: IdleModel.timings(Settings.lockIdleMinutes)
    property bool dimmed: false
    // Dev session only (DevGate): the dev hooks answer. Never in a real session (GRASSFIELD_SESSION=1), SEC-03.
    readonly property bool devHooks: DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    // Seconds without input on the lock screen before the displays go off; 0 = never. Off in the nested dev session
    // unless a test sets it (`idle devDisplayOff <seconds>`): a dark nested output would spoil the lock tests' captures.
    property int displayOffSeconds: devHooks ? 0 : IdleModel.DISPLAY_OFF_SECONDS
    // This module switched the displays off (and must switch them on again).
    property bool displayOff: false

    function setDisplays(on: bool): void {
        if (on === !displayOff)
            return;
        displayOff = !on;
        console.info("grassfield-idle: displays " + (on ? "on" : "off (locked, no input)"));
        const action = on ? "enable" : "disable";
        Hyprland.dispatch(Hyprland.usingLua ? "hl.dsp.dpms({ action = \"" + action + "\" })" : "dpms " + (on ? "on" : "off"));
    }

    function updateDisplays(): void {
        setDisplays(!(lockedMonitor.enabled && lockedMonitor.isIdle));
    }

    function update(): void {
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

    IdleMonitor {
        id: monitor
        enabled: root.timing.enabled && !Lock.locked && !root.rearming
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
            const result = Lock.lock("idle");
            root.dimmed = false;
            if (result !== "ok")
                console.warn("grassfield-idle: idle lock not engaged:", result);
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
                return DevGate.REFUSED;
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
                displayOff: root.displayOff
            });
        }

        // Dev hook (dev only, else "refused"): run the before-sleep ("before") or after-resume ("after") path without
        // logind (tests/security/reload_locked.sh). The dev shell never holds a real inhibitor, so nothing is delayed.
        function devSleep(phase: string): string {
            if (!root.devHooks)
                return DevGate.REFUSED;
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
                return DevGate.REFUSED;
            root.displayOffSeconds = seconds;
            return "ok";
        }
    }
}
