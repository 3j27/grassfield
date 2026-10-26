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
import "../../lib/RunMode.js" as RunMode

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

        // A request arrived, or none is left.
        onActiveChanged: root.arrive(false)
        // Another request replaces the one in the sheet: Quickshell 0.3.1 activates a new request at once, abandoning the open
        // one (agentimpl.cpp initiateAuthentication; re-check of b5d7657), so `active` does not change. It is a new arrival,
        // held (review of f513b3b, MEDIUM-2): keys typed for the first must not land in its field. One that arrives after the
        // first ended passes through no request and is held by AuthDialogModel.afterRequest.
        onFlowChanged: {
            const follows = root.shownFlow !== null && flow !== null && flow !== root.shownFlow;
            root.shownFlow = flow;
            if (follows)
                root.arrive(true);
        }
    }

    // The request now in the sheet (the last flow seen), to tell the next queued one from it.
    property var shownFlow: null

    // A request arrives (`follows`: it replaced the one in the sheet) or none is left: whether it is held and why, the
    // keyboard not given yet, the time its notice prints. One that follows starts empty and its click guard starts over; if
    // the sheet had the keyboard (the user was typing the first one's password), it keeps it on the key sink, so the rest of
    // what is typed reaches neither its field nor the window underneath (re-check of b5d7657, MEDIUM-2). No request left:
    // the next one within heldAfterUnlockMs is held (noteEnded).
    function arrive(follows: bool): void {
        const typing = follows && win.takesKeys;
        const queued = follows || (dialogModel.active && dialogModel.followsAnother());
        root.heldWhy = SessionState.locked ? "locked" : SessionState.saverShown ? "saver" : queued ? "queued" : "unlock";
        root.heldByLock = dialogModel.active && (follows || dialogModel.arrivesHeld(SessionState.locked || SessionState.saverShown));
        root.userFocused = false;
        root.sinkingKeys = typing;
        root.requestStartedAt = dialogModel.active ? new Date() : null;
        if (!dialogModel.active)
            dialogModel.noteEnded();
        if (follows) {
            dialogModel.clearRequested();
            dialogModel.noteShown();
        }
    }

    // The request arrived, or was open, while the session was locked (review of 1d2c856) or the screen saver showed (ADR-0032,
    // owner decision 2026-10-26: over the opaque saver the sheet looked like the lock's prompt and took the keys at once),
    // arrived within AuthDialogModel.heldAfterUnlockMs after an unlock (review of d8e654c), or followed another request in the
    // same sheet: the sheet is shown without the keyboard until the user clicks it (AuthDialogModel.heldGuardMs after it
    // appeared, after the saver ended or after the request before it), so keys typed right after the unlock, the wake or the
    // previous answer never reach its field; it says when the request arrived and why it waited (`heldWhy`). Both delays are timed by the model's Timers (monotonic, review of 6e24d36); requestStartedAt is only the
    // wall-clock time the notice prints (display, never compared).
    property bool heldByLock: false
    property string heldWhy: "unlock"
    // A held request whose sheet keeps the keyboard on the key sink (it replaced the one being typed into).
    property bool sinkingKeys: false
    onSinkingKeysChanged: if (sinkingKeys)
        keySink.forceActiveFocus()
    property bool userFocused: false
    property var requestStartedAt: null

    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (!SessionState.locked) {
                dialogModel.noteUnlock();
            } else if (dialogModel.active) {
                root.heldByLock = true;
                root.heldWhy = "locked";
                root.userFocused = false;
                root.sinkingKeys = false;
            }
        }

        // The screen saver came up over an open request: held as by the lock, its field emptied; the saver holds the keyboard
        // meanwhile. It ended over a held one: the click guard starts over, so no click in the next heldGuardMs gives the sheet
        // the keyboard (such a click still reaches the control it hits, as after an unlock: Cancel at worst).
        function onSaverShownChanged(): void {
            if (!dialogModel.active || SessionState.locked)
                return;
            if (SessionState.saverShown) {
                if (!root.heldByLock || root.userFocused)
                    root.heldWhy = "saver";
                root.heldByLock = true;
                root.userFocused = false;
                root.sinkingKeys = false;
                dialogModel.clearRequested();
            } else if (root.heldByLock) {
                dialogModel.noteUncovered();
            }
        }
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
        // The sheet holds the keyboard: shown, and not a held request the user has not clicked yet (unless it keeps the keys on
        // the sink).
        readonly property bool takesKeys: shown && (!root.heldByLock || root.userFocused || root.sinkingKeys)

        visible: shown
        // Hidden by the lock: whatever was typed is dropped (as after every attempt). Shown again: a request that was not
        // held takes the keys at once; a held one waits for a click (takesKeys) with an empty field.
        onShownChanged: {
            if (shown)
                dialogModel.noteShown();
            const dialog = holder.item as AuthDialog;
            if (!dialog)
                return;
            if (shown && !root.heldByLock)
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
        WlrLayershell.keyboardFocus: win.takesKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-polkit"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: holder
            radius: Tokens.radiusDialog
        }

        // The keys of a held request that kept the keyboard (sinkingKeys) stop here: no field, no Esc, nothing underneath,
        // until a click past the guard gives the sheet its field.
        Item {
            id: keySink
            Keys.onPressed: event => event.accepted = true
            Keys.onReleased: event => event.accepted = true
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
                // The action's theme icon (sanitized by the model), only when the theme has it (no broken image) and every
                // file Qt could read for it is a regular file of bounded size (ThemeIcons, review of 2dfd992).
                appIconSource: ThemeIcons.source(dialogModel.iconName)
                heldNotice: root.heldByLock ? dialogModel.heldNotice(root.requestStartedAt, root.heldWhy) : ""
            }
        }

        // A held request: the first click on the sheet (anywhere, the field included) gives it the keyboard, once
        // AuthDialogModel.heldGuardMs passed since it appeared; the press goes on to what is under it.
        MouseArea {
            anchors.fill: parent
            enabled: root.heldByLock && !root.userFocused
            onPressed: mouse => {
                mouse.accepted = false;
                if (!dialogModel.heldClickAccepted())
                    return;
                root.userFocused = true;
                root.sinkingKeys = false;
                const dialog = holder.item as AuthDialog;
                if (dialog)
                    dialog.focusField();
            }
        }

        // While the screen saver shows, a press (any button) or the wheel on the sheet goes nowhere: it is the input that wakes
        // the screen (the saver ends on it), never an answer, the field's focus or a middle-click paste into it.
        MouseArea {
            anchors.fill: parent
            enabled: SessionState.saverShown
            acceptedButtons: Qt.AllButtons
            onPressed: mouse => mouse.accepted = true
            onWheel: wheel => wheel.accepted = true
        }
    }

    IpcHandler {
        target: "polkit"

        // Test hook (dev session only, else "refused"): "registered" | "unregistered". The real session's journal
        // has the same fact ("authentication agent registered").
        function status(): string {
            if (!RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")))
                return RunMode.REFUSED;
            return agent.isRegistered ? "registered" : "unregistered";
        }
    }
}
