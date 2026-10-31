import QtQuick
import Grassfield.Ui
import qs.services

// Informational dialog (for example, a power action suppressed in the dev session).
Dialog {
    icon: "grassfield-logo"
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
