pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The window's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu. Main.qml
// creates it only while the registrar is there, and a fresh one when the registrar restarts (src/main.cpp,
// apps/globalmenu.h). The app menu and Window are the shell's T0 menus (ADR-0008), so Settings… is in File. Every item runs
// the same action as the window's shortcuts; a shortcut the window also registers is handled once (Qt hands an ambiguous
// key to one of them per press and the window's Shortcut also acts on activatedAmbiguously).
Platform.MenuBar {
    id: bar

    // Main.qml.
    required property var win
    readonly property var field: bar.win.searchField
    // The items with a key are live only while the settings window is not the key window: Qt matches their keys there too
    // (Main.qml childIsKey).
    readonly property bool keysHere: bar.win.childIsKey !== true

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("Settings…")
            shortcut: "Ctrl+,"
            enabled: bar.keysHere
            onTriggered: bar.win.openSettings()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+W"
            enabled: bar.keysHere
            onTriggered: bar.win.close()
        }
    }

    // Edit acts on the search field, the only text field of the window.
    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: StandardKey.Undo
            enabled: bar.keysHere && bar.field.focus && bar.field.canUndo
            onTriggered: bar.field.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: "Ctrl+Shift+Z"
            enabled: bar.keysHere && bar.field.focus && bar.field.canRedo
            onTriggered: bar.field.redo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Cut")
            shortcut: StandardKey.Cut
            enabled: bar.keysHere && bar.field.focus && bar.field.selectedText !== ""
            onTriggered: bar.field.cut()
        }
        Platform.MenuItem {
            text: qsTr("Copy")
            shortcut: StandardKey.Copy
            enabled: bar.keysHere && bar.field.focus && bar.field.selectedText !== ""
            onTriggered: bar.field.copy()
        }
        Platform.MenuItem {
            text: qsTr("Paste")
            shortcut: StandardKey.Paste
            enabled: bar.keysHere && bar.field.focus && bar.field.canPaste
            onTriggered: bar.field.paste()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: StandardKey.SelectAll
            enabled: bar.keysHere && bar.field.focus && bar.field.text !== ""
            onTriggered: bar.field.selectAll()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find")
            shortcut: "Ctrl+F"
            enabled: bar.keysHere
            onTriggered: bar.win.focusSearch()
        }
    }

    // View lists the sidebar's items with their shortcuts, then Back, Forward and Refresh.
    Platform.Menu {
        id: viewMenu
        title: qsTr("View")

        Instantiator {
            model: bar.win.sidebarItems

            delegate: Platform.MenuItem {
                required property var modelData
                required property int index

                // A single & marks a mnemonic in Qt menus: a literal one is doubled.
                text: modelData.title.replace(/&/g, "&&")
                shortcut: index < 9 ? "Ctrl+" + (index + 1) : ""
                enabled: bar.keysHere
                onTriggered: bar.win.pick(modelData.key)
            }

            onObjectAdded: (index, object) => viewMenu.insertItem(index, object as Platform.MenuItem)
            onObjectRemoved: (index, object) => viewMenu.removeItem(object as Platform.MenuItem)
        }

        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Back")
            shortcut: "Ctrl+["
            enabled: bar.keysHere && bar.win.canBack
            onTriggered: bar.win.goBack()
        }
        Platform.MenuItem {
            text: qsTr("Forward")
            shortcut: "Ctrl+]"
            enabled: bar.keysHere && bar.win.canForward
            onTriggered: bar.win.goForward()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Refresh")
            shortcut: "Ctrl+R"
            enabled: bar.keysHere
            onTriggered: bar.win.backend.refresh()
        }
    }
}
