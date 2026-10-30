import QtQuick
import Grassfield.Ui
import qs.services

// Informational dialog (for example, a power action suppressed in the dev session). The glyph is the full Grassfield mark:
// the alert draws it at 48 px (grassfield-logo is the 16-24 px optical version).
Dialog {
    icon: "grassfield-logo-full"
    title: Popups.data.title ? Popups.data.title : ""
    message: Popups.data.message ? Popups.data.message : ""

    onRejected: Popups.close()

    buttons: [
        Button {
            text: qsTr("OK")
            primary: true
            focus: true
            onClicked: Popups.close()
        }
    ]
}
