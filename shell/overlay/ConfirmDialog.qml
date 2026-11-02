import QtQuick
import Grassfield.Ui
import qs.services
import "../services/PopupKinds.js" as PopupKinds

// Confirmation for destructive session actions. Payload (Popups.data): title, message,
// confirmLabel, action, args, destructive. Destructive actions focus Cancel first.
// Log Out, Restart and Shut Down count down instead of showing a message (ADR-0040 ID-21, macOS): left alone, the dialog
// confirms itself after session.exitCountdownSeconds. Closing it stops the count: Cancel, Esc, another popup in its place, and
// the lock (Lock.qml closes every popup as it locks, so a countdown never ends the session from behind the lock screen).
Dialog {
    id: root

    readonly property var info: Popups.data

    // The glyph follows the action: power for restart and shut down, the person for log out, the cross for Force Quit, the bin for
    // Empty Trash; an action without a symbol here shows the information symbol (its subject is unknown: power would claim
    // one). Never the Grassfield mark (ADR-0040 IQ-B1 B: a dialog shows its subject's symbol).
    readonly property var glyphs: ({"restart": "power", "shutdown": "power", "logout": "person", "forcequit": "close-glyph", "emptytrash": "trash"})
    icon: glyphs[info.action] ?? "info"
    title: info.title ? info.title : ""
    message: countsDown ? PopupKinds.countdownMessage(info.action, secondsLeft) : (info.message ? info.message : "")

    readonly property bool countsDown: PopupKinds.countsDown(info.action)
    property int secondsLeft: Tokens.sessionExitCountdownSeconds

    // Each confirmation starts its own count (Restart, then Shut Down from Search, reuses this dialog).
    onInfoChanged: secondsLeft = Tokens.sessionExitCountdownSeconds

    Timer {
        interval: 1000 // one second of the countdown
        repeat: true
        running: root.countsDown && root.secondsLeft > 0
        onTriggered: {
            root.secondsLeft--;
            if (root.secondsLeft <= 0)
                root.confirm();
        }
    }

    function confirm(): void {
        const action = info.action;
        const args = info.args;
        Popups.close();
        Power.run(action, args);
    }

    onRejected: Popups.close()

    buttons: [
        Button {
            id: cancel
            text: qsTr("Cancel")
            focus: root.info.destructive === true
            onClicked: Popups.close()
        },
        Button {
            text: root.info.confirmLabel ? root.info.confirmLabel : qsTr("OK")
            primary: true
            destructive: root.info.destructive === true
            focus: root.info.destructive !== true
            onClicked: root.confirm()
        }
    ]
}
