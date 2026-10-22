import QtQuick
import Grassfield.Ui

// Context menu of the desktop icons. kind "icon": Open, Rename, Copy, Move to Trash for the
// selection; kind "desktop": New Folder, and "About This Wallpaper" while an online daily picture is shown (ADR-0016 step 2).
// `choose` carries the action id. Get Info and Change Wallpaper are left out: there is no Info panel or wallpaper picker yet.
PopupMenu {
    id: root

    property string kind: "desktop"
    property int count: 1
    // The wallpaper on this screen is the online daily picture: the menu offers its attribution.
    property bool aboutWallpaper: false
    // Shortcut hints only when the matching desktop keyboard actions are enabled (IconsView.fileKeyActions).
    property bool showKeyHints: false
    signal choose(string action)

    accessibleName: qsTr("Desktop menu")
    currentIndex: 0

    model: kind === "icon" ? [
        {
            id: "open",
            text: qsTr("Open"),
            shortcut: showKeyHints ? "Ctrl+O" : ""
        },
        {
            id: "rename",
            text: qsTr("Rename"),
            shortcut: showKeyHints ? "Return" : "",
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
            shortcut: showKeyHints ? "Ctrl+Backspace" : "",
            destructive: true
        }
    ] : root.aboutWallpaper ? [
        {
            id: "newFolder",
            text: qsTr("New Folder")
        },
        {
            separator: true
        },
        {
            id: "aboutWallpaper",
            text: qsTr("About This Wallpaper")
        }
    ] : [
        {
            id: "newFolder",
            text: qsTr("New Folder")
        }
    ]

    onActivated: item => root.choose(String(item.id))
}
