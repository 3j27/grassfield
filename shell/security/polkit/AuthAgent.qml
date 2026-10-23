pragma ComponentBehavior: Bound
// Portions adapted from Omarchy shell/plugins/polkit/PolkitAgent.qml (omacom/omarchy, branch
// quattro): PolkitAgent/AuthFlow wiring. Copyright (c) David Heinemeier Hansson, MIT License (upstream LICENSE,
// basecamp/omarchy v4.0.4; notice shipped as packaging/licenses/omarchy-MIT.txt).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "../../services/DevGate.js" as DevGate

// The session's polkit authentication agent (SEC6, ADR-0010): Quickshell.Services.Polkit,
// one instance per shell. polkit allows one agent per session; when another one already owns
// the session (expected in the nested dev session, where the owner's shell has it), registration
// fails: that is logged once, no dialog is ever shown and nothing is approved — requests keep
// going to the other agent.
Scope {
    id: root

    readonly property bool registered: agent.isRegistered

    PolkitAgent {
        id: agent
        path: "/org/grassfield/PolkitAgent"

        onIsRegisteredChanged: {
            if (isRegistered)
                console.info("grassfield-polkit: authentication agent registered");
            else
                console.warn("grassfield-polkit: authentication agent unregistered");
        }
        onAuthenticationRequestStarted: Popups.close()
    }

    AuthDialogModel {
        id: dialogModel
        // Quickshell qmltypes name the AuthFlow property type without exporting it (metadata quirk).
        // qmllint disable unresolved-type
        flow: agent.isActive ? agent.flow : null
        // qmllint enable unresolved-type
    }

    // Registration is asynchronous; report a refusal once, after it had time to complete.
    Timer {
        running: true
        interval: 3000
        onTriggered: {
            if (!agent.isRegistered)
                console.warn("grassfield-polkit: not registered (another authentication agent owns this session); no dialog will be shown, nothing is approved");
        }
    }

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        // A request that arrives while the session is locked waits behind the lock (macOS: the authorization sheet shows
        // once the user is back): the sheet is mapped, and takes the keyboard, only after the unlock (GF-116). The request
        // itself stays pending; nothing is answered or approved meanwhile.
        readonly property bool shown: dialogModel.active && !SessionState.locked

        visible: shown
        // Hidden by the lock: whatever was typed is dropped (as after every attempt). Shown again: the field takes the keys.
        onShownChanged: {
            const dialog = holder.item as AuthDialog;
            if (!dialog)
                return;
            if (shown)
                dialog.focusField();
            else if (dialogModel.active)
                dialogModel.clearRequested();
        }
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.shadowOpacity)
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: win.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-polkit"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: holder
            radius: Tokens.radiusDialog
        }

        // Clicks outside the sheet do nothing (no click-outside cancel for authentication).
        MouseArea {
            anchors.fill: parent
            onPressed: {
                const dialog = holder.item as AuthDialog;
                if (dialog)
                    dialog.focusField();
            }
        }

        Loader {
            id: holder
            active: dialogModel.active
            anchors.centerIn: parent
            sourceComponent: AuthDialog {
                model: dialogModel
                // The action's theme icon (sanitized by the model), only when the theme has it (no broken image).
                appIconSource: dialogModel.iconName !== "" && Quickshell.hasThemeIcon(dialogModel.iconName) ? Quickshell.iconPath(dialogModel.iconName) : ""
            }
        }
    }

    IpcHandler {
        target: "polkit"

        // Test hook (dev session only, else "refused"): "registered" | "unregistered". The real session's journal
        // has the same fact ("authentication agent registered").
        function status(): string {
            if (!DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")))
                return DevGate.REFUSED;
            return agent.isRegistered ? "registered" : "unregistered";
        }
    }
}
