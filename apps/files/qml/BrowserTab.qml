pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Nav.js" as Nav

// One tab of a browser window: location, history, view mode, search and every action on the selection.
// The views (IconView, FileList, ColumnView) only draw and forward input here.
FocusScope {
    id: root

    required property var app
    // The BrowserWindow (menus, sheets, Get Info windows, tabs).
    required property var win
    required property url startUrl

    property url url
    property var history: []
    property int historyIndex: -1
    property string viewMode: root.app.viewMode
    // FolderModel listing `url` (icon and list views; the column view keeps one per column).
    property var folder: null
    property string searchText: ""
    // Inline rename target: an item of `renameModel` (a url survives re-sorting). Kept in a url-typed
    // property so it stringifies like the delegates' url roles (percent-encoded).
    property url renameTarget
    property var renameModel: null
    property string typeBuffer: ""
    property real typeTime: 0

    readonly property var view: viewLoader.item
    // The listing the selection actions apply to: the focused column in the column view.
    readonly property var activeFolder: root.viewMode === "columns" && root.view && root.view.activeModel ? root.view.activeModel : root.folder
    readonly property bool canBack: root.historyIndex > 0
    readonly property bool canForward: root.historyIndex >= 0 && root.historyIndex < root.history.length - 1
    readonly property var segments: root.app.pathSegments(root.url)
    readonly property string title: root.segments.length > 0 ? root.segments[root.segments.length - 1].label : ""
    readonly property bool isTrash: String(root.url).startsWith("trash:")

    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    function createModel(owner: QtObject): var {
        const m = root.app.createFolderModel(owner);
        root.applyPrefs(m);
        return m;
    }

    function applyPrefs(m: var): void {
        m.sortKey = root.app.sortKey;
        m.sortDescending = root.app.sortDescending;
        m.foldersFirst = root.app.foldersFirst;
        m.showHidden = root.app.showHidden;
        m.previewSize = Tokens.filesIconSize * Tokens.filesThumbnailOversample;
    }

    Connections {
        target: root.app
        function onPrefsChanged(): void {
            root.applyPrefs(root.folder);
            if (root.view && root.view.applyPrefs)
                root.view.applyPrefs();
            root.viewMode = root.app.viewMode;
        }
    }

    Connections {
        target: root.folder
        ignoreUnknownSignals: true
        function onRedirected(url: url): void {
            root.navigate(url, false);
        }
    }

    Component.onCompleted: {
        root.folder = root.createModel(root);
        root.navigate(root.startUrl, true);
    }

    function focusView(): void {
        if (root.view)
            root.view.focusView();
    }

    // Navigation -------------------------------------------------------------------------------

    function navigate(target: url, record: bool): void {
        if (String(target) === "")
            return;
        root.renameModel = null;
        if (root.searchText !== "")
            root.setSearch("");
        root.url = target;
        root.folder.url = target;
        if (record && !(root.historyIndex >= 0 && root.app.sameUrl(root.history[root.historyIndex], target))) {
            const h = Nav.pushHistory(root.history, root.historyIndex, target);
            root.history = h.entries;
            root.historyIndex = h.index;
        }
    }

    // After going up or back, select the folder we came from (macOS behavior).
    function selectChild(previous: url): void {
        if (root.app.isDirectChild(root.url, previous))
            root.folder.expect(previous, false);
    }

    function back(): void {
        if (!root.canBack)
            return;
        const previous = root.url;
        root.historyIndex -= 1;
        root.navigate(root.history[root.historyIndex], false);
        root.selectChild(previous);
    }

    function forward(): void {
        if (!root.canForward)
            return;
        root.historyIndex += 1;
        root.navigate(root.history[root.historyIndex], false);
    }

    function up(): void {
        if (root.segments.length < 2)
            return;
        const previous = root.url;
        root.navigate(root.segments[root.segments.length - 2].url, true);
        root.selectChild(previous);
    }

    function setViewMode(mode: string): void {
        root.app.viewMode = mode;
        root.viewMode = mode;
        Qt.callLater(root.focusView);
    }

    function setSearch(text: string): void {
        root.searchText = text;
        root.folder.filterText = text;
    }

    // Header click in the list view, or a Sort By menu choice.
    function sortBy(key: int, toggle: bool): void {
        const next = toggle ? Nav.sortClick(root.app.sortKey, root.app.sortDescending, key, root.app.defaultDescending(key))
                            : {key: key, descending: root.app.defaultDescending(key)};
        root.app.sortKey = next.key;
        root.app.sortDescending = next.descending;
    }

    // Opening ------------------------------------------------------------------------------------

    function activate(row: int, model: var): void {
        if (row < 0)
            return;
        if (model.isDirAt(row))
            root.navigate(model.urlAt(row), true);
        else
            root.app.open([model.urlAt(row)]);
    }

    function openSelection(): void {
        const m = root.activeFolder;
        const rows = m.selectedRows();
        if (rows.length === 0)
            return;
        const files = [];
        let firstDir = null;
        for (let i = 0; i < rows.length; i++) {
            if (m.isDirAt(rows[i])) {
                if (firstDir === null)
                    firstDir = m.urlAt(rows[i]);
                else
                    root.win.newTab(m.urlAt(rows[i]));
            } else {
                files.push(m.urlAt(rows[i]));
            }
        }
        if (files.length > 0)
            root.app.open(files);
        if (firstDir !== null)
            root.navigate(firstDir, true);
    }

    // Selection actions --------------------------------------------------------------------------

    function selection(): var {
        return root.activeFolder ? root.activeFolder.selectedUrls() : [];
    }

    function trashSelection(): void {
        const urls = root.selection();
        if (urls.length === 0)
            return;
        if (root.activeFolder.isTrash)
            root.app.restore(urls);
        else
            root.app.trash(urls);
    }

    function putBack(): void {
        root.app.restore(root.selection());
    }

    function deleteImmediately(): void {
        const urls = root.selection();
        if (urls.length === 0)
            return;
        const message = urls.length === 1 ? qsTr("“%1” will be deleted immediately. You can’t undo this action.").arg(root.activeFolder.nameAt(root.activeFolder.selectedRows()[0]))
                                          : qsTr("%1 items will be deleted immediately. You can’t undo this action.").arg(urls.length);
        root.win.confirm(qsTr("Delete immediately?"), message, qsTr("Delete"), () => root.app.deletePermanently(urls));
    }

    function emptyTrash(): void {
        root.win.confirm(qsTr("Are you sure you want to permanently erase the items in the Trash?"), qsTr("You can’t undo this action."), qsTr("Empty Trash"), () => root.app.emptyTrash());
    }

    function copySelection(cut: bool): void {
        const urls = root.selection();
        if (urls.length > 0 && !(cut && root.activeFolder.isTrash))
            root.app.copyToClipboard(urls, cut);
    }

    function paste(): void {
        if (root.activeFolder.writable && root.app.canPaste)
            root.app.paste(root.activeFolder.url, root.activeFolder);
    }

    function newFolder(): void {
        if (root.activeFolder.writable)
            root.app.newFolder(root.activeFolder.url, root.activeFolder);
    }

    function duplicateSelection(): void {
        const urls = root.selection();
        if (urls.length > 0 && root.activeFolder.writable)
            root.app.duplicate(urls, root.activeFolder);
    }

    function canRename(): bool {
        const m = root.activeFolder;
        return m !== null && m.selectedCount === 1 && m.writable && !m.isTrash;
    }

    function renameSelection(): void {
        if (!root.canRename())
            return;
        root.startRename(root.activeFolder, root.activeFolder.selectedRows()[0]);
    }

    function startRename(model: var, row: int): void {
        root.renameModel = model;
        root.renameTarget = model.urlAt(row);
    }

    function isRenaming(model: var, url: url): bool {
        return root.renameModel !== null && root.renameModel === model && root.app.sameUrl(url, root.renameTarget);
    }

    function commitRename(name: string): void {
        const m = root.renameModel;
        const target = root.renameTarget;
        root.renameModel = null;
        // FilesApp.rename ignores an unchanged name.
        if (m)
            root.app.rename(target, name, m);
        Qt.callLater(root.focusView);
    }

    function cancelRename(): void {
        root.renameModel = null;
        Qt.callLater(root.focusView);
    }

    function getInfo(): void {
        const m = root.activeFolder;
        const rows = m.selectedRows();
        if (rows.length === 0) {
            root.win.showInfo(m.info(-1));
            return;
        }
        // One window per item, like the macOS file manager (bounded).
        for (let i = 0; i < Math.min(rows.length, 10); i++)
            root.win.showInfo(m.info(rows[i]));
    }

    function quickLook(): void {
        const urls = root.selection();
        if (urls.length > 0)
            root.app.quickLook(urls);
    }

    function showInEnclosingFolder(): void {
        const urls = root.selection();
        if (urls.length === 0)
            return;
        const target = urls[0];
        root.setSearch("");
        root.folder.expect(target, false);
    }

    function dropUrls(urls: var, destination: url, model: var): void {
        root.app.drop(urls, destination, model);
    }

    // Keyboard -----------------------------------------------------------------------------------

    function keyName(key: int): string {
        switch (key) {
        case Qt.Key_Left:
            return "left";
        case Qt.Key_Right:
            return "right";
        case Qt.Key_Up:
            return "up";
        case Qt.Key_Down:
            return "down";
        case Qt.Key_Home:
            return "home";
        case Qt.Key_End:
            return "end";
        case Qt.Key_PageUp:
            return "pageup";
        case Qt.Key_PageDown:
            return "pagedown";
        }
        return "";
    }

    // Shared key handling of the views. `mover(keyName)` returns the next row for a navigation key.
    function handleViewKey(event: var, model: var, mover: var): void {
        const ctrl = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) !== 0;
        const name = root.keyName(event.key);
        if (name !== "" && !ctrl) {
            const next = mover(name);
            if (next >= 0)
                model.select(next, (event.modifiers & Qt.ShiftModifier) ? Qt.ShiftModifier : 0);
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (!ctrl) {
                root.openSelection();
                event.accepted = true;
            }
            return;
        case Qt.Key_Space:
            if (!ctrl) {
                root.quickLook();
                event.accepted = true;
            }
            return;
        case Qt.Key_Escape:
            if (root.searchText !== "")
                root.setSearch("");
            else
                model.clearSelection();
            event.accepted = true;
            return;
        case Qt.Key_Menu:
            root.contextMenuForKeyboard(model);
            event.accepted = true;
            return;
        case Qt.Key_F10:
            if (event.modifiers & Qt.ShiftModifier) {
                root.contextMenuForKeyboard(model);
                event.accepted = true;
            }
            return;
        }
        if (!ctrl && event.text.length === 1 && event.text >= " " && event.key !== Qt.Key_Delete) {
            root.typeahead(model, event.text);
            event.accepted = true;
        }
    }

    function typeahead(model: var, text: string): void {
        const now = Date.now();
        const fresh = now - root.typeTime > Tokens.filesTypeaheadResetMs;
        root.typeBuffer = Nav.typeahead(root.typeBuffer, text, now - root.typeTime, Tokens.filesTypeaheadResetMs);
        root.typeTime = now;
        // A new search starts after the current item so repeating a letter cycles through matches.
        const current = model.currentRow;
        const from = fresh && current >= 0 ? current + 1 : Math.max(0, current);
        const row = model.findPrefix(root.typeBuffer, from);
        if (row >= 0)
            model.select(row, 0);
    }

    // Context menus ------------------------------------------------------------------------------

    function contextMenuForKeyboard(model: var): void {
        const row = model.currentRow;
        const p = root.view && root.view.rowPosition ? root.view.rowPosition(model, row) : Qt.point(root.width / 2, root.height / 3);
        root.contextMenu(model, row, p.x, p.y, true);
    }

    // Context menu for `row` of `model` (-1: the folder background) at window coordinates.
    function contextMenu(model: var, row: int, x: real, y: real, keyboard: bool): void {
        if (row >= 0 && !model.isSelected(row))
            model.select(row, 0);
        if (row < 0)
            model.clearSelection();
        const items = row >= 0 ? root.itemMenu(model) : root.backgroundMenu(model);
        root.win.menuLayer.open(items, x, y, id => root.runAction(id, model), root.view, keyboard);
    }

    function itemMenu(model: var): var {
        const rows = model.selectedRows();
        const count = rows.length;
        const first = count > 0 ? rows[0] : -1;
        const name = first >= 0 ? model.nameAt(first) : "";
        if (model.isTrash) {
            return [
                {id: "putback", text: qsTr("Put Back"), shortcut: qsTr("Ctrl+Backspace")},
                {id: "deleteNow", text: qsTr("Delete Immediately…"), destructive: true},
                {separator: true},
                {id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")},
                {id: "copy", text: count === 1 ? qsTr("Copy “%1”").arg(name) : qsTr("Copy %1 Items").arg(count), shortcut: qsTr("Ctrl+C")}
            ];
        }
        const items = [];
        items.push({id: "open", text: qsTr("Open")});
        const allFiles = rows.every(r => !model.isDirAt(r));
        const apps = allFiles ? root.app.applicationsFor(model.selectedUrls()) : [];
        if (apps.length > 0) {
            const sub = [];
            for (let i = 0; i < apps.length; i++)
                sub.push({id: "app:" + apps[i].id, text: apps[i].name});
            items.push({id: "openWith", text: qsTr("Open With"), submenu: sub});
        } else {
            items.push({id: "openWith", text: qsTr("Open With"), enabled: false});
        }
        if (count === 1 && model.isDirAt(first))
            items.push({id: "newTab", text: qsTr("Open in New Tab")});
        items.push({separator: true});
        items.push({id: "trash", text: qsTr("Move to Trash"), shortcut: qsTr("Ctrl+Backspace"), enabled: model.writable});
        items.push({separator: true});
        items.push({id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")});
        items.push({id: "rename", text: qsTr("Rename"), shortcut: qsTr("F2"), enabled: count === 1 && model.writable});
        items.push({id: "duplicate", text: qsTr("Duplicate"), shortcut: qsTr("Ctrl+D"), enabled: model.writable});
        // Placeholder (R11): Quick Look needs grassfield-preview, which is not built yet.
        items.push({id: "quicklook", text: count === 1 ? qsTr("Quick Look “%1” (coming with Preview)").arg(name) : qsTr("Quick Look (coming with Preview)"), shortcut: qsTr("Space"), enabled: false});
        items.push({separator: true});
        items.push({id: "copy", text: count === 1 ? qsTr("Copy “%1”").arg(name) : qsTr("Copy %1 Items").arg(count), shortcut: qsTr("Ctrl+C")});
        items.push({id: "cut", text: qsTr("Cut"), shortcut: qsTr("Ctrl+X"), enabled: model.writable});
        if (root.searchText !== "") {
            items.push({separator: true});
            items.push({id: "enclosing", text: qsTr("Show in Enclosing Folder")});
        }
        return items;
    }

    function backgroundMenu(model: var): var {
        const items = [];
        if (model.isTrash) {
            items.push({id: "emptyTrash", text: qsTr("Empty Trash…"), destructive: true, enabled: !root.app.places.trashEmpty});
            items.push({separator: true});
        } else {
            items.push({id: "newFolder", text: qsTr("New Folder"), shortcut: qsTr("Ctrl+Shift+N"), enabled: model.writable});
            items.push({separator: true});
        }
        items.push({id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")});
        items.push({separator: true});
        const n = root.app.clipboardCount;
        items.push({id: "paste", text: n > 1 ? qsTr("Paste %1 Items").arg(n) : qsTr("Paste"), shortcut: qsTr("Ctrl+V"), enabled: root.app.canPaste && model.writable});
        items.push({separator: true});
        items.push(root.viewSubmenu());
        items.push(root.sortSubmenu());
        items.push({id: "hidden", text: qsTr("Show Hidden Files"), shortcut: qsTr("Ctrl+H"), checked: root.app.showHidden});
        return items;
    }

    function viewSubmenu(): var {
        return {id: "viewAs", text: qsTr("View As"), submenu: [
            {id: "view:icons", text: qsTr("Icons"), shortcut: qsTr("Ctrl+1"), checked: root.viewMode === "icons"},
            {id: "view:list", text: qsTr("List"), shortcut: qsTr("Ctrl+2"), checked: root.viewMode === "list"},
            {id: "view:columns", text: qsTr("Columns"), shortcut: qsTr("Ctrl+3"), checked: root.viewMode === "columns"}
        ]};
    }

    function sortSubmenu(): var {
        const k = root.app.sortKey;
        return {id: "sortBy", text: qsTr("Sort By"), submenu: [
            {id: "sort:0", text: qsTr("Name"), checked: k === 0},
            {id: "sort:1", text: qsTr("Kind"), checked: k === 1},
            {id: "sort:2", text: qsTr("Date Modified"), checked: k === 2},
            {id: "sort:3", text: qsTr("Size"), checked: k === 3},
            {separator: true},
            {id: "sortDescending", text: qsTr("Descending"), checked: root.app.sortDescending},
            {id: "foldersFirst", text: qsTr("Keep Folders on Top"), checked: root.app.foldersFirst}
        ]};
    }

    // The toolbar Action menu: item actions for a selection, folder actions otherwise.
    function actionMenu(): var {
        const m = root.activeFolder;
        return m.selectedCount > 0 ? root.itemMenu(m) : root.backgroundMenu(m);
    }

    function runAction(id: string, model: var): void {
        if (id.startsWith("app:")) {
            root.app.openWith(id.substring(4), model.selectedUrls());
            return;
        }
        if (id.startsWith("view:")) {
            root.setViewMode(id.substring(5));
            return;
        }
        if (id.startsWith("sort:")) {
            root.sortBy(parseInt(id.substring(5)), false);
            return;
        }
        switch (id) {
        case "open":
            root.openSelection();
            break;
        case "newTab":
            root.win.newTab(model.selectedUrls()[0]);
            break;
        case "trash":
            root.trashSelection();
            break;
        case "putback":
            root.putBack();
            break;
        case "deleteNow":
            root.deleteImmediately();
            break;
        case "emptyTrash":
            root.emptyTrash();
            break;
        case "info":
            root.getInfo();
            break;
        case "rename":
            root.renameSelection();
            break;
        case "duplicate":
            root.duplicateSelection();
            break;
        case "copy":
            root.copySelection(false);
            break;
        case "cut":
            root.copySelection(true);
            break;
        case "paste":
            root.paste();
            break;
        case "newFolder":
            root.newFolder();
            break;
        case "enclosing":
            root.showInEnclosingFolder();
            break;
        case "hidden":
            root.app.showHidden = !root.app.showHidden;
            break;
        case "sortDescending":
            root.app.sortDescending = !root.app.sortDescending;
            break;
        case "foldersFirst":
            root.app.foldersFirst = !root.app.foldersFirst;
            break;
        }
    }

    // Views --------------------------------------------------------------------------------------

    Loader {
        id: viewLoader
        anchors.fill: parent
        focus: true
        sourceComponent: root.viewMode === "list" ? listComponent : root.viewMode === "columns" ? columnComponent : iconComponent
        onLoaded: Qt.callLater(root.focusView)
    }

    Component {
        id: iconComponent
        IconView {
            tab: root
            model: root.folder
        }
    }

    Component {
        id: listComponent
        FileList {
            tab: root
            model: root.folder
        }
    }

    Component {
        id: columnComponent
        ColumnView {
            tab: root
        }
    }
}
