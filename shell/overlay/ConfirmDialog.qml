import QtQuick
import Grassfield.Ui
import qs.services

// Confirmation for destructive session actions. Payload (Popups.data): title, message,
// confirmLabel, action, args, destructive. Destructive actions focus Cancel first.
Dialog {
    id: root

    readonly property var info: Popups.data

    // The glyph follows the action: power for restart and shut down, the person for log out, the cross for Force Quit, the bin for
    // Empty Trash; an action without a symbol here shows the information symbol (its subject is unknown: power would claim
    // one). Never the Grassfield mark (ADR-0040 IQ-B1 B: a dialog shows its subject's symbol).
    readonly property var glyphs: ({"restart": "power", "shutdown": "power", "logout": "person", "forcequit": "close-glyph", "emptytrash": "trash"})
    icon: glyphs[info.action] ?? "info"
    title: info.title ? info.title : ""
    message: info.message ? info.message : ""

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
