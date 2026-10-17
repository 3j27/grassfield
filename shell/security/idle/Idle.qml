pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/services/idle/Service.qml (omacom/omarchy, branch
// quattro), MIT License, Copyright (c) the Omarchy authors: IdleMonitor with respectInhibitors.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.security.lock
import "IdleModel.js" as IdleModel

// Idle handling (SEC7, ADR-0010): after T-10 s without input the screens dim, at T the session
// locks (T = lock.idleMinutes, default 5, 0 = never). Any input undims and cancels. Wayland idle
// inhibitors (video players, presentations) are respected by the compositor's idle-notify
// protocol. Display power-off after the lock is out of scope for M2. Also hosts the
// lock-before-sleep inhibitor.
Scope {
    id: root

    readonly property var timing: IdleModel.timings(Settings.lockIdleMinutes)
    property bool dimmed: false

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

        // Test hook: idle state as JSON.
        function status(): string {
            return JSON.stringify({
                enabled: monitor.enabled,
                idle: monitor.isIdle,
                dimmed: root.dimmed,
                dimSeconds: root.timing.dimSeconds,
                lockSeconds: root.timing.lockSeconds,
                sleepInhibitor: sleepInhibitor.inhibiting
            });
        }
    }
}
