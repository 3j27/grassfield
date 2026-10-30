import QtQuick
import Grassfield.Ui
import qs.services

// Confirmation for destructive session actions. Payload (Popups.data): title, message,
// confirmLabel, action, args, destructive. Destructive actions focus Cancel first.
Dialog {
    id: root

    readonly property var info: Popups.data

    // The glyph follows the action: power for restart and shut down, the person for log out, the cross for Force Quit, the bin for Empty Trash.
    // Otherwise the Grassfield mark, drawn at the alert's 48 px: the full mark (grassfield-logo is its 16-24 px optical version).
    readonly property var glyphs: ({"restart": "power", "shutdown": "power", "logout": "person", "forcequit": "close-glyph", "emptytrash": "trash"})
    icon: info.destructive === true ? (glyphs[info.action] ?? "power") : "grassfield-logo-full"
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
