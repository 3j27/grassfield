pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform

// The activity monitor's menus in the global menu bar (spec AM6; T1: master-prompt 5.7, ADR-0008), exported by Qt through
// DBusMenu. Main.qml creates it only while the registrar is there. macOS structure: File, Edit, View, Help; the app menu and
// Window are the shell's T0 menus. There is no settings window: the View menu holds the options (macOS). Every item runs
// the same action as the window's shortcuts; a key both register is handled once.
Platform.MenuBar {
    id: bar

    // Main.qml.
    required property var win
    readonly property var backend: bar.win.backend
    // Not while one of the window's Inspect windows has the keyboard: Qt matches these keys there too
    // (Main.qml childIsKey), and Ctrl+W typed in an Inspect window closed the main window.
    readonly property bool keysHere: bar.win.childIsKey !== true

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("Close Window")
            shortcut: "Ctrl+W"
            enabled: bar.keysHere
            onTriggered: bar.win.close()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Copy")
            shortcut: StandardKey.Copy
            enabled: bar.keysHere && bar.backend.table.selectedCount > 0
            onTriggered: bar.win.copy()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: StandardKey.SelectAll
            enabled: bar.keysHere
            onTriggered: bar.win.selectAll()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find…")
            shortcut: "Ctrl+F"
            enabled: bar.keysHere
            onTriggered: bar.win.focusSearch()
        }
    }

    Platform.Menu {
        id: viewMenu
        title: qsTr("View")

        // AM15: the current tab's optional columns, checked when shown.
        Platform.Menu {
            id: columnsMenu
            title: qsTr("Columns")

            Instantiator {
                model: bar.backend.columns.filter(c => c.hideable)
                delegate: Platform.MenuItem {
                    required property var modelData
                    text: modelData.title
                    checkable: true
                    checked: modelData.shown
                    onTriggered: bar.backend.setColumnShown(modelData.key, !modelData.shown)
                }
                onObjectAdded: (index, object) => columnsMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => columnsMenu.removeItem(object)
            }
        }

        Platform.MenuSeparator {}

        // AM12: one view checked.
        Instantiator {
            id: views
            model: bar.backend.views
            delegate: Platform.MenuItem {
                required property var modelData
                text: modelData.title
                checkable: true
                checked: bar.backend.view === modelData.key
                onTriggered: bar.backend.view = modelData.key
            }
            // After the Columns submenu and its separator.
            onObjectAdded: (index, object) => viewMenu.insertItem(index + 2, object)
            onObjectRemoved: (index, object) => viewMenu.removeItem(object)
        }

        Platform.MenuSeparator {}

        // AM9.
        Platform.Menu {
            title: qsTr("Update Frequency")

            Platform.MenuItem {
                text: qsTr("Very Often (1 sec)")
                checkable: true
                checked: bar.backend.interval === 1
                onTriggered: bar.backend.interval = 1
            }
            Platform.MenuItem {
                text: qsTr("Often (2 sec)")
                checkable: true
                checked: bar.backend.interval === 2
                onTriggered: bar.backend.interval = 2
            }
            Platform.MenuItem {
                text: qsTr("Normally (5 sec)")
                checkable: true
                checked: bar.backend.interval === 5
                onTriggered: bar.backend.interval = 5
            }
        }

        Platform.MenuSeparator {}

        // AM50, AM55 (step 2c): the sheets of the window; AM57 (step 2d): the selected process's Inspect window.
        Platform.MenuItem {
            text: qsTr("Quit Process")
            shortcut: "Ctrl+Alt+Q"
            enabled: bar.keysHere && bar.backend.actions.canQuit
            onTriggered: bar.win.sheets.openQuit()
        }
        Platform.MenuItem {
            text: qsTr("Inspect Process")
            shortcut: "Ctrl+I"
            enabled: bar.keysHere && bar.backend.canInspect
            onTriggered: bar.backend.inspectSelection()
        }
        Platform.MenuItem {
            text: qsTr("Send Signal to Process…")
            enabled: bar.backend.actions.canSignal
            onTriggered: bar.win.sheets.openSignal()
        }
    }
}
