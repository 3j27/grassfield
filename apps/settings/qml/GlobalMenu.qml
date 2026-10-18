pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The window's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu.
// Main.qml creates it only when the registrar is there (src/main.cpp, apps/globalmenu.h); the window keeps its own
// controls either way. macOS structure: File, Edit, View; the app menu and Window are the shell's T0 menus. Every item
// runs the same action as the window's controls. A shortcut also registered by an in-window Shortcut is handled once:
// Qt hands an ambiguous key to one of them per press and the window's Shortcut also acts on activatedAmbiguously.
Platform.MenuBar {
    id: bar

    // Main.qml.
    required property var win
    readonly property var field: bar.win.searchField

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+W"
            onTriggered: bar.win.close()
        }
    }

    // Edit acts on the search field, the only text field of the window.
    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: StandardKey.Undo
            enabled: bar.field.focus && bar.field.canUndo
            onTriggered: bar.field.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: "Ctrl+Shift+Z"
            enabled: bar.field.focus && bar.field.canRedo
            onTriggered: bar.field.redo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Cut")
            shortcut: StandardKey.Cut
            enabled: bar.field.focus && bar.field.selectedText !== ""
            onTriggered: bar.field.cut()
        }
        Platform.MenuItem {
            text: qsTr("Copy")
            shortcut: StandardKey.Copy
            enabled: bar.field.focus && bar.field.selectedText !== ""
            onTriggered: bar.field.copy()
        }
        Platform.MenuItem {
            text: qsTr("Paste")
            shortcut: StandardKey.Paste
            enabled: bar.field.focus && bar.field.canPaste
            onTriggered: bar.field.paste()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: StandardKey.SelectAll
            enabled: bar.field.focus && bar.field.text !== ""
            onTriggered: bar.field.selectAll()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find")
            shortcut: "Ctrl+F"
            onTriggered: bar.win.focusSearch()
        }
    }

    // View lists the sections, like the sidebar.
    Platform.Menu {
        id: viewMenu
        title: qsTr("View")

        Instantiator {
            model: bar.win.sections

            delegate: Platform.MenuItem {
                required property var modelData

                // A single & marks a mnemonic in Qt menus: a literal one is doubled.
                text: modelData.title.replace(/&/g, "&&")
                onTriggered: bar.win.select(modelData.id)
            }

            onObjectAdded: (index, object) => viewMenu.insertItem(index, object as Platform.MenuItem)
            onObjectRemoved: (index, object) => viewMenu.removeItem(object as Platform.MenuItem)
        }
    }
}
