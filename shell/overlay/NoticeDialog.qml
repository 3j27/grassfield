import QtQuick
import Grassfield.Ui
import qs.services

// Informational dialog (for example, a power action suppressed in the dev session). Its glyph is its subject's symbol
// (Popups.notice's third argument), the information symbol when none is given; never the Grassfield mark (ADR-0040 IQ-B1 B).
Dialog {
    icon: Popups.data.symbol ? Popups.data.symbol : "info"
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
