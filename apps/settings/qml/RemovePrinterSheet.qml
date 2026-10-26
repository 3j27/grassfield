import QtQuick
import Grassfield.Ui

// Printers > Remove Printer…: the confirmation (macOS asks before it deletes a printer). The removal then asks for the
// administrator's password (cups-pk-helper, ADR-0026).
Sheet {
    id: root

    property var printer: null

    signal remove(string name)

    title: root.printer ? qsTr("Remove “%1”?").arg(root.printer.title) : ""
    message: qsTr("The printer is removed from this computer, with the print jobs waiting for it. To use it again, add it again.")
    confirmText: qsTr("Remove Printer")
    destructive: true

    function openFor(printer: var): void {
        root.printer = printer;
        root.open();
    }

    onAccepted: root.remove(root.printer.name)
}
