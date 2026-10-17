import QtQuick
import Grassfield.Ui

// Context menu of the desktop icons. kind "icon": Open, Rename, Copy, Move to Trash for the
// selection; kind "desktop": New Folder. `choose` carries the action id.
// Get Info and Change Wallpaper are left out: there is no Info panel or wallpaper picker yet.
PopupMenu {
    id: root

    property string kind: "desktop"
    property int count: 1
    // Shortcut hints are shown only for actions that work: the desktop keyboard actions (F2,
    // Ctrl+Backspace) are off in keyboard safe mode.
    property bool shortcutsShown: false

    signal choose(string action)

    accessibleName: qsTr("Desktop menu")
    currentIndex: 0

    // The menu window holds the keyboard while it is open: the menu takes the active focus.
    Component.onCompleted: forceActiveFocus()

    model: kind === "icon" ? [
        {
            id: "open",
            text: qsTr("Open")
        },
        {
            id: "rename",
            text: qsTr("Rename"),
            shortcut: shortcutsShown ? "F2" : "",
            enabled: count === 1
        },
        {
            id: "copy",
            text: qsTr("Copy")
        },
        {
            separator: true
        },
        {
            id: "trash",
            text: qsTr("Move to Trash"),
            shortcut: shortcutsShown ? "Ctrl+Backspace" : "",
            destructive: true
        }
    ] : [
        {
            id: "newFolder",
            text: qsTr("New Folder")
        }
    ]

    onActivated: item => root.choose(String(item.id))
}
