import QtQuick
import Grassfield.Ui

// Printers > a printer (macOS 27 opens its sheet): its state (and CUPS's message while it is stopped), its location, its kind,
// and Remove Printer…, which Main.qml confirms first (RemovePrinterSheet). `printer` is PrintersPage.details().
Sheet {
    id: root

    property var printer: null

    signal removeRequested(var printer)

    title: root.printer ? root.printer.title : ""
    confirmText: qsTr("Done")
    showCancel: false

    function openFor(printer: var): void {
        root.printer = printer;
        root.open();
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Status")
            valueText: root.printer ? (root.printer.message !== "" ? root.printer.status + " — " + root.printer.message : root.printer.status) : ""
        }
        SettingsRow {
            visible: root.printer !== null && root.printer.location !== ""
            title: qsTr("Location")
            valueText: root.printer ? root.printer.location : ""
        }
        SettingsRow {
            title: qsTr("Kind")
            valueText: root.printer ? root.printer.kind : ""
        }
        SettingsRow {
            title: qsTr("Queue")
            valueText: root.printer ? root.printer.name : ""
        }
    }

    Button {
        push: true
        text: qsTr("Remove Printer…")
        onClicked: {
            root.close();
            root.removeRequested(root.printer);
        }
    }
}
