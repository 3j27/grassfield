pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform
import Grassfield.Ui

// A browser window's menus in the global menu bar (T1: master-prompt 5.7, ADR-0008), exported by Qt through DBusMenu.
// BrowserWindow.qml creates one per window, only while the registrar is there, and a fresh one when the registrar
// restarts (src/main.cpp, apps/globalmenu.h); the toolbar, context menus and Action menu stay either way. macOS structure: File, Edit, View, Go; the app menu and
// Window are the shell's T0 menus (tab switching is under View). Every item runs the same BrowserTab action as the
// window's own menus and shortcuts. A shortcut that an in-window Shortcut also registers is handled once: Qt hands an
// ambiguous key to one of them per press and the window's Shortcut also acts on activatedAmbiguously.
Platform.MenuBar {
    id: bar

    // BrowserWindow.qml.
    required property var win
    readonly property var app: bar.win.app
    readonly property var tab: bar.win.tab
    // The listing the selection actions apply to (the focused column in the column view).
    readonly property var folder: bar.win.folder
    readonly property int count: bar.folder ? bar.folder.selectedCount : 0
    readonly property bool inTrash: bar.folder !== null && bar.folder.isTrash
    readonly property bool inApplications: bar.folder !== null && bar.folder.isApplications
    readonly property bool writable: bar.folder !== null && bar.folder.writable
    // Items can be renamed, cut and trashed (BrowserTab.itemsEditable: a writable folder or a tag search).
    readonly property bool editable: bar.folder !== null && !bar.inTrash && (bar.folder.writable || bar.folder.isSearch)
    // Colour tags of the selection, read again on every selection change and every tag write.
    readonly property string tagsReason: {
        bar.app.tagRevision;
        const f = bar.folder;
        return f && f.selectedCount > 0 ? bar.app.tagsUnavailable(f.selectedUrls()) : "";
    }
    readonly property var tagStates: {
        bar.app.tagRevision;
        const f = bar.folder;
        return f && f.selectedCount > 0 && bar.tagsReason === "" ? bar.app.colorTagStates(f.selectedUrls()) : [];
    }
    // These read folder.selectedCount themselves: its NOTIFY (selectionChanged) fires on every selection change, while a
    // binding on `count` only re-runs when the number changes (selecting another single item kept the old name and
    // Open With list, and Open With then acted on the new selection: review of 72272e4).
    readonly property string firstName: bar.folder && bar.folder.selectedCount === 1 ? bar.label(bar.folder.nameAt(bar.folder.selectedRows()[0])) : ""
    // Open With: the applications for a selection of files (re-read when the selection changes).
    readonly property var openWithApps: {
        const f = bar.folder;
        // Not in Applications: an item there is an application (the desktop entry is not a file to open with another one:
        // Kdenlive offered itself for "*.kdenlive" and was started with a grassfield-app: URL).
        if (!f || f.selectedCount === 0 || f.isTrash || f.isApplications)
            return [];
        const rows = f.selectedRows();
        if (!rows.every(r => !f.isDirAt(r)))
            return [];
        return bar.app.applicationsFor(f.selectedUrls());
    }

    // Customize Folder applies to a selection of local folders. Read from folder.selectedCount (its NOTIFY fires on every
    // selection change, also from one item to another one: a binding on `count` does not, and canCustomize() reads no
    // property, so the menu item stayed stale: the bug class above) and from the folder style revision.
    readonly property bool customizeEnabled: {
        bar.app.folderStyleRevision;
        const f = bar.folder;
        if (!f || f.selectedCount === 0)
            return false;
        return f.selectedRows().every(r => f.isDirAt(r)) && bar.app.folderStyleUnavailable(f.selectedUrls()) === "";
    }

        // Menu text from data (file and application names): one line, and a literal & doubled (a single one marks a
    // mnemonic in Qt menus).
    function label(text: string): string {
        return DisplayName.text(text).replace(/&/g, "&&");
    }

    Platform.Menu {
        title: qsTr("File")

        Platform.MenuItem {
            text: qsTr("New Window")
            shortcut: "Ctrl+N"
            onTriggered: bar.win.manager.newWindow(bar.tab ? bar.tab.url : bar.win.startUrl)
        }
        Platform.MenuItem {
            text: qsTr("New Folder")
            shortcut: "Ctrl+Shift+N"
            enabled: bar.writable && !bar.inTrash
            onTriggered: bar.tab.newFolder()
        }
        Platform.MenuItem {
            text: qsTr("New Tab")
            shortcut: "Ctrl+T"
            enabled: bar.tab !== null
            onTriggered: bar.win.newTab(bar.tab.url)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Open")
            shortcut: "Super+Down"
            enabled: bar.count > 0
            onTriggered: bar.tab.openSelection()
        }
        Platform.Menu {
            id: openWithMenu
            title: qsTr("Open With")
            enabled: bar.openWithApps.length > 0

            Instantiator {
                model: bar.openWithApps

                delegate: Platform.MenuItem {
                    required property var modelData

                    text: bar.label(modelData.name)
                    onTriggered: bar.tab.runAction("app:" + modelData.id, bar.folder)
                }

                onObjectAdded: (index, object) => openWithMenu.insertItem(index, object as Platform.MenuItem)
                onObjectRemoved: (index, object) => openWithMenu.removeItem(object as Platform.MenuItem)
            }
        }
        Platform.MenuItem {
            text: bar.win.tabs.length > 1 ? qsTr("Close Tab") : qsTr("Close Window")
            shortcut: "Ctrl+W"
            onTriggered: bar.win.closeTab(bar.win.currentIndex)
        }
        Platform.MenuItem {
            text: qsTr("Eject")
            shortcut: "Ctrl+E"
            enabled: bar.win.canEject === true
            onTriggered: bar.win.ejectVolume()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Get Info")
            shortcut: "Ctrl+I"
            enabled: bar.tab !== null
            onTriggered: bar.tab.getInfo()
        }
        Platform.MenuItem {
            text: qsTr("Customize Folder…")
            enabled: bar.tab !== null && bar.customizeEnabled
            onTriggered: bar.tab.customizeSelection()
        }
        Platform.MenuItem {
            text: qsTr("Rename")
            shortcut: "F2"
            enabled: bar.count === 1 && bar.editable
            onTriggered: bar.tab.renameSelection()
        }
        Platform.MenuItem {
            text: qsTr("Duplicate")
            shortcut: "Ctrl+D"
            enabled: bar.count > 0 && bar.writable && !bar.inTrash
            onTriggered: bar.tab.duplicateSelection()
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Glance at %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Glance at “%1”").arg(bar.firstName) : qsTr("Glance")
            enabled: bar.count > 0 && !bar.inTrash && !bar.inApplications
            onTriggered: bar.tab.glance()
        }
        // The colour tags of the selection (the window's item menu shows them as a row of colour dots).
        Platform.Menu {
            id: tagsMenu
            title: qsTr("Tags")
            enabled: bar.count > 0 && bar.tagsReason === ""

            Instantiator {
                model: bar.app.colorTagNames

                delegate: MenuCheckItem {
                    required property string modelData
                    required property int index

                    text: bar.label(modelData)
                    on: bar.tagStates[index] === 2
                    onChosen: bar.tab.toggleColorTag(index)
                }

                onObjectAdded: (index, object) => tagsMenu.insertItem(index, object as Platform.MenuItem)
                onObjectRemoved: (index, object) => tagsMenu.removeItem(object as Platform.MenuItem)
            }
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: bar.inTrash ? qsTr("Put Back") : qsTr("Move to Trash")
            shortcut: "Ctrl+Backspace"
            enabled: bar.count > 0 && (bar.inTrash || bar.editable)
            onTriggered: bar.tab.trashSelection()
        }
        Platform.MenuItem {
            text: qsTr("Delete Immediately…")
            visible: bar.inTrash
            enabled: bar.count > 0
            onTriggered: bar.tab.deleteImmediately()
        }
        // A dev session never empties a trash (ADR-0011), like the folder menu.
        Platform.MenuItem {
            text: qsTr("Empty Trash…")
            visible: bar.inTrash && !bar.app.devSession
            enabled: !bar.app.places.trashEmpty
            onTriggered: bar.tab.emptyTrash()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Find")
            shortcut: "Ctrl+F"
            onTriggered: bar.win.focusSearch()
        }
    }

    Platform.Menu {
        title: qsTr("Edit")

        Platform.MenuItem {
            text: qsTr("Undo")
            shortcut: "Ctrl+Z"
            enabled: bar.app.canUndo
            onTriggered: bar.app.undo()
        }
        Platform.MenuItem {
            text: qsTr("Redo")
            shortcut: "Ctrl+Shift+Z"
            enabled: bar.app.canRedo
            onTriggered: bar.app.redo()
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Cut")
            shortcut: "Ctrl+X"
            enabled: bar.count > 0 && bar.editable
            onTriggered: bar.tab.copySelection(true)
        }
        Platform.MenuItem {
            text: bar.count > 1 ? qsTr("Copy %1 Items").arg(bar.count) : bar.count === 1 ? qsTr("Copy “%1”").arg(bar.firstName) : qsTr("Copy")
            shortcut: "Ctrl+C"
            enabled: bar.count > 0
            onTriggered: bar.tab.copySelection(false)
        }
        Platform.MenuItem {
            text: bar.app.clipboardCount > 1 ? qsTr("Paste %1 Items").arg(bar.app.clipboardCount) : qsTr("Paste")
            shortcut: "Ctrl+V"
            enabled: bar.app.canPaste && bar.writable
            onTriggered: bar.tab.paste()
        }
        Platform.MenuItem {
            text: qsTr("Select All")
            shortcut: "Ctrl+A"
            enabled: bar.folder !== null && bar.folder.count > 0
            onTriggered: bar.folder.selectAll()
        }
    }

    Platform.Menu {
        title: qsTr("View")

        MenuCheckItem {
            text: qsTr("as Icons")
            shortcut: "Super+1"
            on: bar.tab !== null && bar.tab.viewMode === "icons"
            onChosen: bar.tab.setViewMode("icons")
        }
        MenuCheckItem {
            text: qsTr("as List")
            shortcut: "Super+2"
            on: bar.tab !== null && bar.tab.viewMode === "list"
            onChosen: bar.tab.setViewMode("list")
        }
        MenuCheckItem {
            text: qsTr("as Columns")
            shortcut: "Super+3"
            on: bar.tab !== null && bar.tab.viewMode === "columns"
            onChosen: bar.tab.setViewMode("columns")
        }
        MenuCheckItem {
            text: qsTr("as Gallery")
            shortcut: "Super+4"
            on: bar.tab !== null && bar.tab.viewMode === "gallery"
            onChosen: bar.tab.setViewMode("gallery")
        }
        Platform.MenuSeparator {}
        MenuCheckItem {
            text: qsTr("Show Info Panel")
            shortcut: "Ctrl+Shift+P"
            enabled: bar.tab !== null && bar.tab.viewMode === "gallery"
            on: bar.app.galleryInfo
            onChosen: bar.tab.toggleGalleryInfo()
        }
        Platform.MenuSeparator {}
        Platform.Menu {
            title: qsTr("Sort By")

            MenuCheckItem {
                text: qsTr("Name")
                on: bar.app.sortKey === 0
                onChosen: bar.tab.sortBy(0, false)
            }
            MenuCheckItem {
                text: qsTr("Kind")
                on: bar.app.sortKey === 1
                onChosen: bar.tab.sortBy(1, false)
            }
            MenuCheckItem {
                text: qsTr("Date Modified")
                on: bar.app.sortKey === 2
                onChosen: bar.tab.sortBy(2, false)
            }
            MenuCheckItem {
                text: qsTr("Size")
                on: bar.app.sortKey === 3
                onChosen: bar.tab.sortBy(3, false)
            }
            Platform.MenuSeparator {}
            MenuCheckItem {
                text: qsTr("Descending")
                on: bar.app.sortDescending
                onChosen: bar.app.sortDescending = !bar.app.sortDescending
            }
            MenuCheckItem {
                text: qsTr("Keep Folders on Top")
                on: bar.app.foldersFirst
                onChosen: bar.app.foldersFirst = !bar.app.foldersFirst
            }
        }
        MenuCheckItem {
            text: qsTr("Show Hidden Files")
            shortcut: "Ctrl+H"
            on: bar.app.showHidden
            onChosen: bar.app.showHidden = !bar.app.showHidden
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Show Previous Tab")
            shortcut: "Ctrl+Shift+Tab"
            enabled: bar.win.tabs.length > 1
            onTriggered: bar.win.selectTab(bar.win.currentIndex - 1)
        }
        Platform.MenuItem {
            text: qsTr("Show Next Tab")
            shortcut: "Ctrl+Tab"
            enabled: bar.win.tabs.length > 1
            onTriggered: bar.win.selectTab(bar.win.currentIndex + 1)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Reload")
            shortcut: "Ctrl+R"
            enabled: bar.tab !== null
            onTriggered: bar.tab.folder.reload()
        }
    }

    Platform.Menu {
        id: goMenu
        title: qsTr("Go")

        Platform.MenuItem {
            text: qsTr("Back")
            shortcut: "Ctrl+["
            enabled: bar.tab !== null && bar.tab.canBack
            onTriggered: bar.tab.back()
        }
        Platform.MenuItem {
            text: qsTr("Forward")
            shortcut: "Ctrl+]"
            enabled: bar.tab !== null && bar.tab.canForward
            onTriggered: bar.tab.forward()
        }
        Platform.MenuItem {
            text: qsTr("Enclosing Folder")
            shortcut: "Super+Up"
            enabled: bar.tab !== null && bar.tab.segments.length > 1
            onTriggered: bar.tab.up()
        }
        Platform.MenuSeparator {}
        // The sidebar places (Favorites, then Locations), opened like a sidebar click (an unmounted volume is mounted).
        // The sidebar's tags are not places of the Go menu (as on macOS).
        Instantiator {
            model: bar.app.places

            delegate: Platform.MenuItem {
                required property int index
                required property string name
                required property url url
                required property bool mounted
                required property string kind

                visible: kind !== "tag"
                text: bar.label(name)
                shortcut: kind === "applications" ? "Ctrl+Shift+A" : bar.app.sameUrl(url, Qt.url("file://" + bar.app.homePath)) ? "Ctrl+Shift+H" : ""
                onTriggered: bar.win.openPlace(index, url, mounted)
            }

            // After the four navigation items and their separator.
            onObjectAdded: (index, object) => goMenu.insertItem(index + 4, object as Platform.MenuItem)
            onObjectRemoved: (index, object) => goMenu.removeItem(object as Platform.MenuItem)
        }
        Platform.MenuSeparator {}
        Platform.MenuItem {
            text: qsTr("Go to Folder…")
            shortcut: "Ctrl+Shift+G"
            onTriggered: bar.win.goToFolder()
        }
    }
}
