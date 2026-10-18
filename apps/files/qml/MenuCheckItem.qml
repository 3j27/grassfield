import QtQuick
import Qt.labs.platform as Platform

// A global menu item with a check mark that follows the app's state (`on`). Qt toggles a checkable item itself when
// it is triggered; the binding to `on` is restored right after `chosen` so the mark always shows the real state.
Platform.MenuItem {
    id: item

    property bool on: false

    signal chosen

    checkable: true
    checked: item.on
    onTriggered: {
        item.chosen();
        item.checked = Qt.binding(() => item.on);
    }
}
