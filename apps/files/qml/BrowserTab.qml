pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Nav.js" as Nav
import "TagColors.js" as TagColors

// One tab of a browser window: location, history, view mode, search and every action on the selection.
// The views (IconView, FileList, ColumnView, GalleryView) only draw and forward input here.
FocusScope {
    id: root

    required property var app
    // The BrowserWindow (menus, sheets, Get Info windows, tabs). Changes when the tab moves to another window.
    required property var win
    required property url startUrl
    // Unique in this process; a dragged tab is named by it (TabBar, Main.qml).
    property int tabId: 0
    // A closed tab's snapshot() to reopen (File > Reopen Closed Tab): its location, history, view and arrangement.
    property var restore: null
    // The Open or Save panel this tab browses for (grassfield-portal, FilePanel.qml); null in Files. Then a double-click on
    // a file, Return and Esc are the panel's, items the panel cannot take are dimmed (FolderModel.chooser), the menus have
    // no file operation, a drop shows the item instead of moving it, and the view is the panel's own for its application.
    property var chooser: null

    property url url
    property var history: []
    property int historyIndex: -1
    // The view and the arrangement of the shown folder (its own when chosen for it, else the defaults: Nav.viewFor,
    // Nav.sortFor, FilesApp.folderView). Keep Folders on Top and Show Hidden Files stay global.
    property string viewMode: root.restore ? Nav.normalizeViewMode(root.restore.viewMode) : root.chooser ? Nav.normalizeViewMode(root.chooser.viewMode || root.app.viewMode) : Nav.viewFor("", root.app.folderView(root.startUrl).mode, root.app.viewMode)
    property int sortKey: root.app.sortKey
    property bool sortDescending: root.app.sortDescending
    // View > Group By of the shown folder (FileLogic::GroupBy, 0: no groups; its own when chosen for it). Groups show in
    // the icon and list views; Use Groups (Ctrl+Cmd+0) brings back the last grouping (Kind at first).
    property int groupBy: 0
    property int lastGroupBy: 2
    readonly property bool groupsShown: viewLoader.kind === "icons" || viewLoader.kind === "list"
    onGroupsShownChanged: root.applyGroups()
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
    // The view's content is scrolled (icons and list; columns and gallery never report it).
    readonly property bool scrolled: root.view !== null && root.view !== undefined && root.view.scrolled === true
    // The listing the selection actions apply to: the focused column in the column view.
    readonly property var activeFolder: root.viewMode === "columns" && root.view && root.view.activeModel ? root.view.activeModel : root.folder
    readonly property bool canBack: root.historyIndex > 0
    readonly property bool canForward: root.historyIndex >= 0 && root.historyIndex < root.history.length - 1
    readonly property var segments: root.app.pathSegments(root.url)
    readonly property string title: root.segments.length > 0 ? DisplayName.text(root.segments[root.segments.length - 1].label) : ""
    readonly property bool isTrash: String(root.url).startsWith("trash:")
    // The Applications location: read-only, opening starts the application.
    readonly property bool isApplications: String(root.url).startsWith("grassfield-apps:")

    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    function createModel(owner: QtObject): var {
        const m = root.app.createFolderModel(owner);
        root.applyPrefs(m);
        return m;
    }

    function applyPrefs(m: var): void {
        m.sortKey = root.sortKey;
        m.sortDescending = root.sortDescending;
        m.foldersFirst = root.app.foldersFirst;
        m.showHidden = root.app.showHidden;
        m.previewSize = Tokens.filesIconSize * Tokens.filesThumbnailOversample;
        m.largePreviewSize = Tokens.filesGalleryPreviewSize * Tokens.filesThumbnailOversample;
        if (root.chooser)
            m.chooser = root.chooser.filter;
    }

    // The panel's filter changed (its Format pop-up): every listing of the tab dims again.
    function applyChooser(): void {
        if (root.folder)
            root.applyPrefs(root.folder);
        if (root.view && root.view.applyPrefs)
            root.view.applyPrefs();
    }

    Connections {
        target: root.app
        function onPrefsChanged(): void {
            root.applyPrefs(root.folder);
            if (root.view && root.view.applyPrefs)
                root.view.applyPrefs();
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
        if (root.restore) {
            root.sortKey = root.restore.sortKey;
            root.sortDescending = root.restore.sortDescending;
            root.groupBy = root.restore.groupBy !== undefined ? root.restore.groupBy : 0;
        }
        root.folder = root.createModel(root);
        root.applyGroups();
        if (root.restore && root.restore.history.length > 0) {
            root.history = root.restore.history;
            root.historyIndex = Math.max(0, Math.min(root.restore.historyIndex, root.history.length - 1));
            root.navigate(root.history[root.historyIndex], false);
        } else {
            root.navigate(root.startUrl, true);
        }
    }

    // What File > Reopen Closed Tab needs to bring this tab back.
    function snapshot(): var {
        return {url: root.url, history: root.history.slice(), historyIndex: root.historyIndex, viewMode: root.viewMode, sortKey: root.sortKey,
                sortDescending: root.sortDescending, groupBy: root.groupBy};
    }

    function focusView(): void {
        if (root.view)
            root.view.focusView();
    }

    // Navigation -------------------------------------------------------------------------------

    function navigate(target: url, record: bool): void {
        if (String(target) === "")
            return;
        // A navigation of the user's own ends a spring-loaded excursion: a later cancelled drag does not undo it.
        if (!root.springing)
            root.springOrigin = "";
        root.renameModel = null;
        if (root.searchText !== "")
            root.setSearch("");
        root.applyFolderView(target);
        root.url = target;
        root.folder.url = target;
        if (record && !(root.historyIndex >= 0 && root.app.sameUrl(root.history[root.historyIndex], target))) {
            const h = Nav.pushHistory(root.history, root.historyIndex, target);
            root.history = h.entries;
            root.historyIndex = h.index;
        }
    }

    // The view and the arrangement of `target` (F-3). Column view sticks while browsing (the column view itself navigates
    // the tab), so a folder's own settings apply from the other views and when the tab opens.
    function applyFolderView(target: url): void {
        if (root.viewMode === "columns" && root.folder !== null && String(root.url) !== "")
            return;
        const stored = root.app.folderView(target);
        // A panel keeps its application's view in every folder (macOS); the arrangement is the folder's own, as in Files.
        if (!root.chooser)
            root.viewMode = Nav.viewFor(String(root.url) === "" && !root.restore ? "" : root.viewMode, stored.mode, root.app.viewMode);
        // Recents opens sorted by Date Last Opened, newest first, until arranged otherwise.
        const recents = root.app.isRecents(target);
        const sort = Nav.sortFor(stored, recents ? root.app.recentsSortKey : root.app.sortKey, recents ? root.app.defaultDescending(root.app.recentsSortKey) : root.app.sortDescending, key => root.app.defaultDescending(key));
        root.setArrangement(sort.key, sort.descending);
        root.groupBy = stored.groupBy !== undefined ? stored.groupBy : 0;
        root.applyGroups();
    }

    // The listing groups as the tab says, in the views that show groups (never the column view's own listings).
    function applyGroups(): void {
        if (root.folder)
            root.folder.groupBy = root.groupsShown ? root.groupBy : 0;
    }

    // View > Group By: kept for the shown folder (F-3).
    function setGroupBy(by: int): void {
        root.groupBy = by;
        if (by > 0)
            root.lastGroupBy = by;
        root.applyGroups();
        root.app.setFolderView(root.url, {groupBy: by});
    }

    function toggleGroups(): void {
        root.setGroupBy(root.groupBy > 0 ? 0 : root.lastGroupBy);
    }

    function setArrangement(key: int, descending: bool): void {
        if (key === root.sortKey && descending === root.sortDescending)
            return;
        root.sortKey = key;
        root.sortDescending = descending;
        if (root.folder)
            root.applyPrefs(root.folder);
        if (root.view && root.view.applyPrefs)
            root.view.applyPrefs();
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

    // A view chosen for the shown folder: it opens in that view from now on (F-3).
    function setViewMode(mode: string): void {
        const m = Nav.normalizeViewMode(mode);
        const leavingColumns = root.viewMode === "columns" && m !== "columns";
        root.viewMode = m;
        if (root.chooser)
            root.chooser.viewChosen(m);
        else
            root.app.setFolderView(root.url, {mode: m});
        // Column view kept one arrangement for all its columns: the folder now shown alone takes its own.
        if (leavingColumns) {
            const sort = Nav.sortFor(root.app.folderView(root.url), root.app.sortKey, root.app.sortDescending, key => root.app.defaultDescending(key));
            root.setArrangement(sort.key, sort.descending);
        }
        Qt.callLater(root.focusView);
    }

    // Ctrl+1 .. Ctrl+4.
    function setViewModeByNumber(number: int): void {
        const m = Nav.viewModeForShortcut(number);
        if (m !== "")
            root.setViewMode(m);
    }

    // View > Show Preview (Shift+Cmd+P): the gallery's pane, the column view's preview column, or the pane beside the icon
    // and list views (three settings, as each view keeps its own in the Finder).
    readonly property bool previewShown: viewLoader.kind === "gallery" ? root.app.galleryInfo : viewLoader.kind === "columns" ? root.app.columnPreview : root.app.previewPane

    function togglePreview(): void {
        if (viewLoader.kind === "gallery")
            root.app.galleryInfo = !root.app.galleryInfo;
        else if (viewLoader.kind === "columns")
            root.app.columnPreview = !root.app.columnPreview;
        else
            root.app.previewPane = !root.app.previewPane;
    }

    function setSearch(text: string): void {
        root.searchText = text;
        root.folder.filterText = text;
    }

    // Header click in the list view, or a Sort By menu choice.
    // The shown folder keeps the arrangement chosen for it (F-3).
    function sortBy(key: int, toggle: bool): void {
        const next = toggle ? Nav.sortClick(root.sortKey, root.sortDescending, key, root.app.defaultDescending(key))
                            : {key: key, descending: root.app.defaultDescending(key)};
        root.setArrangement(next.key, next.descending);
        root.app.setFolderView(root.url, {sortKey: next.key, sortDescending: next.descending});
    }

    function setSortDescending(on: bool): void {
        root.setArrangement(root.sortKey, on);
        root.app.setFolderView(root.url, {sortKey: root.sortKey, sortDescending: on});
    }

    // Opening ------------------------------------------------------------------------------------

    // A double-click. Cmd-double-click on a folder opens it in a new tab (Finder).
    function activate(row: int, model: var, modifiers: int): void {
        if (row < 0)
            return;
        // A panel: a folder opens in it, a file is chosen (when the panel can take it); an application is never started
        // from a panel: Choose Application chooses it (FilePanel.fileActivated), any other panel leaves it alone (a Save
        // panel would take its name).
        if (root.chooser) {
            if (model.isApplications) {
                if (root.chooser.choosingApp === true)
                    root.chooser.fileActivated(model, row);
                return;
            }
            if (model.isDirAt(row))
                root.navigate(model.urlAt(row), true);
            else
                root.chooser.fileActivated(model, row);
            return;
        }
        if (model.isApplications) {
            root.app.launchApplication(model.urlAt(row));
            return;
        }
        if (model.isDirAt(row) && (modifiers & Qt.ControlModifier))
            root.win.newTab(model.urlAt(row), null);
        else if (model.isDirAt(row))
            root.navigate(model.urlAt(row), true);
        else
            root.app.open([model.urlAt(row)]);
    }

    function openSelection(): void {
        const m = root.activeFolder;
        const rows = m.selectedRows();
        if (root.chooser) {
            // Cmd+Down: one folder opens in the panel; anything else is the panel's default button.
            if (rows.length === 1 && m.isDirAt(rows[0]))
                root.navigate(m.urlAt(rows[0]), true);
            else
                root.chooser.pressDefault();
            return;
        }
        if (rows.length === 0)
            return;
        if (m.isApplications) {
            // Finder opens every selected application (bounded here).
            for (let i = 0; i < Math.min(rows.length, 10); i++)
                root.app.launchApplication(m.urlAt(rows[i]));
            return;
        }
        const files = [];
        let firstDir = null;
        for (let i = 0; i < rows.length; i++) {
            if (m.isDirAt(rows[i])) {
                if (firstDir === null)
                    firstDir = m.urlAt(rows[i]);
                else
                    root.win.newTab(m.urlAt(rows[i]), null);
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
        if (root.activeFolder.isApplications) {
            root.app.trash(urls); // refused with the permission message: the location is read-only
            return;
        }
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
        if (urls.length === 0 || root.activeFolder.isApplications)
            return;
        const message = urls.length === 1 ? qsTr("“%1” will be deleted immediately. You can’t undo this action.").arg(DisplayName.text(root.activeFolder.nameAt(root.activeFolder.selectedRows()[0])))
                                          : qsTr("%1 items will be deleted immediately. You can’t undo this action.").arg(urls.length);
        root.win.confirm(qsTr("Delete immediately?"), message, qsTr("Delete"), () => root.app.deletePermanently(urls));
    }

    function emptyTrash(): void {
        root.win.confirm(qsTr("Are you sure you want to permanently erase the items in the Trash?"), qsTr("You can’t undo this action."), qsTr("Empty Trash"), () => root.app.emptyTrash());
    }

    function copySelection(cut: bool): void {
        const urls = root.selection();
        if (urls.length > 0 && root.activeFolder.isApplications) {
            // Copy puts the applications' desktop entries on the clipboard; Cut is refused with the permission message
            // (FilesApp.copyToClipboard), as Finder refuses to move an app of a folder you cannot write.
            root.app.copyToClipboard(urls, cut);
            return;
        }
        if (urls.length > 0 && !(cut && !root.itemsEditable(root.activeFolder)))
            root.app.copyToClipboard(urls, cut);
    }

    // Items can be renamed, cut and moved to the Trash in a writable folder, and in a tag search (each item stays in its
    // own folder; KIO reports a refusal). Nothing can be created in a tag search (FolderModel.writable is false).
    function itemsEditable(m: var): bool {
        return root.chooser === null && m !== null && !m.isTrash && (m.writable || m.isSearch);
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
        return m !== null && m.selectedCount === 1 && root.itemsEditable(m);
    }

    // Tags ---------------------------------------------------------------------------------------

    // Colour tag `index` on the selection: removed when every item has it, else added (FilesApp.toggleColorTag).
    function toggleColorTag(index: int): void {
        const urls = root.selection();
        if (urls.length > 0)
            root.app.toggleColorTag(urls, index);
    }

    // A sidebar tag: the items tagged `tag` in the shown folder and below (a tag search keeps its folder).
    function showTag(tag: string): void {
        root.navigate(root.app.tagSearchUrl(tag, root.url), true);
    }

    // The colour row of the item menu: the seven tags with the selection's state, or the reason it can't be tagged.
    function tagRow(model: var): var {
        const urls = model.selectedUrls();
        const reason = root.app.tagsUnavailable(urls);
        return {
            id: "tags",
            swatches: TagColors.swatches(Tokens, root.app.colorTagNames, reason === "" ? root.app.colorTagStates(urls) : []),
            enabled: reason === "",
            caption: reason !== "" ? reason : qsTr("Tags"),
            accessibleName: qsTr("Tags")
        };
    }

    function renameSelection(): void {
        if (root.activeFolder && root.activeFolder.isApplications && root.activeFolder.selectedCount === 1) {
            // F2 on an application: the refusal Finder gives for an item you cannot rename, not silence.
            root.app.rename(root.activeFolder.urlAt(root.activeFolder.selectedRows()[0]), "", root.activeFolder);
            return;
        }
        if (!root.canRename())
            return;
        root.startRename(root.activeFolder, root.activeFolder.selectedRows()[0]);
    }

    function startRename(model: var, row: int): void {
        if (root.chooser)
            return;
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

    // Whether Customize Folder applies to the selection (local folders only).
    function canCustomize(): bool {
        const m = root.activeFolder;
        const rows = m.selectedRows();
        return rows.length > 0 && rows.every(r => m.isDirAt(r)) && root.app.folderStyleUnavailable(m.selectedUrls()) === "";
    }

    function customizeSelection(): void {
        const m = root.activeFolder;
        const rows = m.selectedRows();
        if (rows.length === 0 || !rows.every(r => m.isDirAt(r)))
            return;
        const info = m.info(rows[0]);
        root.win.customizeFolders(m.selectedUrls(), rows.length === 1 ? info.name : qsTr("%1 Folders").arg(rows.length), info.iconName);
    }

    function glance(): void {
        const urls = root.selection();
        if (urls.length > 0)
            root.app.glance(urls);
    }

    function showInEnclosingFolder(): void {
        const urls = root.selection();
        if (urls.length === 0)
            return;
        const target = urls[0];
        root.setSearch("");
        // A tag search lists items of several folders: open the item's own folder, with the item selected.
        if (root.folder.isSearch) {
            const s = String(target);
            root.navigate(Qt.url(s.substring(0, s.lastIndexOf("/"))), true);
        }
        root.folder.expect(target, false);
    }

    function dropUrls(urls: var, destination: url, model: var): void {
        // FilesApp refuses a drop on the Applications location with the permission message.
        springTimer.stop();
        root.springOrigin = "";
        // A panel never moves or copies: an item dropped on it is shown and selected there (macOS).
        if (root.chooser) {
            root.chooser.reveal(urls);
            return;
        }
        root.app.drop(urls, destination, model);
    }

    // Spring-loaded folders (Finder): a drag that rests on a folder (a row of a view or a sidebar place) opens it in this
    // tab after Tokens.filesSpringDelay. When a drag that Files started ends without a drop, the tab goes back to where it
    // was before the first spring (Main.qml dragEnded); a drop, or a navigation of the user's own, keeps it.
    property url springTarget
    property url springOrigin
    property bool springing: false

    function springHover(target: url): void {
        root.springTarget = target;
        springTimer.restart();
    }

    function springLeave(target: url): void {
        if (String(root.springTarget) === String(target))
            springTimer.stop();
    }

    // The view a system drag started from, while it runs (else ""). Drag.Automatic runs QDrag::exec in a nested event loop,
    // and Qt Quick's drag uses the item that started it after exec returns: destroying that view meanwhile (a spring-loaded
    // folder whose own view is another, a search ending) would free it under the drag. So the tab keeps showing this view
    // until the drag has ended (Nav.shownView); the folder's own view follows then.
    property string dragView: ""

    // A view starts a system drag (just before its Drag.active turns true).
    function dragStarted(): void {
        root.dragView = viewLoader.kind;
    }

    function releaseDragView(): void {
        root.dragView = "";
    }

    // A drag Files started (from any view) ended; `dropAction` is what the target did with it.
    function dragFinished(dropAction: int): void {
        if (root.win)
            root.win.manager.dragEnded(dropAction !== Qt.IgnoreAction);
        // Called from the drag's own dragFinished signal: the view may only change once that call has returned.
        Qt.callLater(root.releaseDragView);
    }

    function springEnd(dropped: bool): void {
        springTimer.stop();
        const origin = root.springOrigin;
        root.springOrigin = "";
        if (!dropped && String(origin) !== "")
            root.navigate(origin, true);
    }

    Timer {
        id: springTimer
        interval: Tokens.filesSpringDelay
        onTriggered: {
            if (String(root.springTarget) === "" || root.app.sameUrl(root.springTarget, root.url))
                return;
            if (String(root.springOrigin) === "") {
                root.springOrigin = root.url;
                root.win.manager.springStarted(root);
            }
            root.springing = true;
            root.navigate(root.springTarget, true);
            root.springing = false;
            // The folder's view now lies under the pointer: it becomes the drop target without the pointer moving.
            Qt.callLater(() => root.app.refreshDrag(root.win));
        }
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
        // Return renames the selected item (macOS, decision F-4); Cmd+O and Cmd+Down open. In a panel, Return is its
        // default button.
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (!ctrl) {
                if (root.chooser)
                    root.chooser.pressDefault();
                else
                    root.renameSelection();
                event.accepted = true;
            }
            return;
        case Qt.Key_Space:
            if (!ctrl) {
                root.glance();
                event.accepted = true;
            }
            return;
        case Qt.Key_Escape:
            if (root.searchText !== "")
                root.setSearch("");
            else if (root.chooser)
                root.chooser.cancel();
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
        // A panel: "/" or "~" typed in the listing opens Go to Folder with it (macOS panels).
        if (root.chooser && !ctrl && (event.text === "/" || event.text === "~")) {
            root.chooser.goToFolder(event.text);
            event.accepted = true;
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
        const items = root.chooser ? root.chooserMenu(model, row >= 0) : row >= 0 ? root.itemMenu(model) : root.backgroundMenu(model);
        root.win.menuLayer.open(items, x, y, id => root.runAction(id, model), root.view, keyboard);
    }

    function itemMenu(model: var): var {
        const rows = model.selectedRows();
        const count = rows.length;
        const first = count > 0 ? rows[0] : -1;
        const name = first >= 0 ? DisplayName.text(model.nameAt(first)) : "";
        if (model.isTrash) {
            return [
                {id: "putback", text: qsTr("Put Back"), shortcut: qsTr("Ctrl+Backspace")},
                {id: "deleteNow", text: qsTr("Delete Immediately…"), destructive: true},
                {separator: true},
                {id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")},
                {id: "copy", text: count === 1 ? qsTr("Copy “%1”").arg(name) : qsTr("Copy %1 Items").arg(count), shortcut: qsTr("Ctrl+C")}
            ];
        }
        if (model.isApplications) {
            // Finder's menu of an application in a read-only Applications folder: the editing items are there, dimmed.
            return [
                {id: "open", text: qsTr("Open")},
                {separator: true},
                {id: "trash", text: qsTr("Move to Trash"), shortcut: qsTr("Ctrl+Backspace"), enabled: false},
                {separator: true},
                {id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")},
                {id: "copy", text: count === 1 ? qsTr("Copy “%1”").arg(name) : qsTr("Copy %1 Items").arg(count), shortcut: qsTr("Ctrl+C")},
                {id: "rename", text: qsTr("Rename"), shortcut: qsTr("F2"), enabled: false}
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
        const editable = root.itemsEditable(model);
        items.push({separator: true});
        items.push({id: "trash", text: qsTr("Move to Trash"), shortcut: qsTr("Ctrl+Backspace"), enabled: editable});
        items.push({separator: true});
        items.push({id: "info", text: qsTr("Get Info"), shortcut: qsTr("Ctrl+I")});
        if (rows.every(r => model.isDirAt(r)))
            items.push({id: "customize", text: qsTr("Customize Folder…"), enabled: root.app.folderStyleUnavailable(model.selectedUrls()) === ""});
        items.push({id: "rename", text: qsTr("Rename"), shortcut: qsTr("F2"), enabled: count === 1 && editable});
        items.push({id: "duplicate", text: qsTr("Duplicate"), shortcut: qsTr("Ctrl+D"), enabled: model.writable});
        items.push({id: "glance", text: count === 1 ? qsTr("Glance at “%1”").arg(name) : qsTr("Glance at %1 Items").arg(count), shortcut: qsTr("Space")});
        items.push({separator: true});
        items.push({id: "copy", text: count === 1 ? qsTr("Copy “%1”").arg(name) : qsTr("Copy %1 Items").arg(count), shortcut: qsTr("Ctrl+C")});
        items.push({id: "cut", text: qsTr("Cut"), shortcut: qsTr("Ctrl+X"), enabled: editable});
        // Colour tags (macOS: a row of colour dots under the edit items).
        items.push({separator: true});
        items.push(root.tagRow(model));
        if (root.searchText !== "" || model.isSearch) {
            items.push({separator: true});
            items.push({id: "enclosing", text: qsTr("Show in Enclosing Folder")});
        }
        return items;
    }

    function backgroundMenu(model: var): var {
        const items = [];
        if (model.isTrash) {
            // A dev session never empties a trash (ADR-0011): no action rather than a confirmation that does nothing.
            if (!root.app.devSession) {
                items.push({id: "emptyTrash", text: qsTr("Empty Trash…"), destructive: true, enabled: !root.app.places.trashEmpty});
                items.push({separator: true});
            }
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
        items.push({id: "useGroups", text: qsTr("Use Groups"), shortcut: qsTr("Ctrl+Super+0"), checked: root.groupBy > 0});
        items.push(root.groupSubmenu());
        items.push(root.sortSubmenu());
        items.push({id: "hidden", text: qsTr("Show Hidden Files"), shortcut: qsTr("Ctrl+H"), checked: root.app.showHidden});
        items.push({id: "preview", text: root.previewShown ? qsTr("Hide Preview") : qsTr("Show Preview"), shortcut: qsTr("Ctrl+Shift+P")});
        return items;
    }

    function viewSubmenu(): var {
        return {id: "viewAs", text: qsTr("View As"), submenu: [
            {id: "view:icons", text: qsTr("Icons"), shortcut: qsTr("Super+1"), checked: root.viewMode === "icons"},
            {id: "view:list", text: qsTr("List"), shortcut: qsTr("Super+2"), checked: root.viewMode === "list"},
            {id: "view:columns", text: qsTr("Columns"), shortcut: qsTr("Super+3"), checked: root.viewMode === "columns"},
            {id: "view:gallery", text: qsTr("Gallery"), shortcut: qsTr("Super+4"), checked: root.viewMode === "gallery"}
        ]};
    }

    // Group By and Sort By in the Finder's order (FileLogic::GroupBy, FileLogic::SortKey; Date Added has no source here).
    function groupSubmenu(): var {
        const g = root.groupBy;
        return {id: "groupBy", text: qsTr("Group By"), submenu: [
            {id: "group:0", text: qsTr("None"), checked: g === 0},
            {separator: true},
            {id: "group:1", text: qsTr("Name"), checked: g === 1},
            {id: "group:2", text: qsTr("Kind"), checked: g === 2},
            {id: "group:3", text: qsTr("Application"), checked: g === 3},
            {id: "group:4", text: qsTr("Date Last Opened"), checked: g === 4},
            {id: "group:5", text: qsTr("Date Modified"), checked: g === 5},
            {id: "group:6", text: qsTr("Date Created"), checked: g === 6},
            {id: "group:7", text: qsTr("Size"), checked: g === 7},
            {id: "group:8", text: qsTr("Tags"), checked: g === 8}
        ]};
    }

    function sortSubmenu(): var {
        const k = root.sortKey;
        return {id: "sortBy", text: qsTr("Sort By"), submenu: [
            {id: "sort:0", text: qsTr("Name"), checked: k === 0},
            {id: "sort:1", text: qsTr("Kind"), checked: k === 1},
            {id: "sort:7", text: qsTr("Application"), checked: k === 7},
            {id: "sort:5", text: qsTr("Date Last Opened"), checked: k === 5},
            {id: "sort:2", text: qsTr("Date Modified"), checked: k === 2},
            {id: "sort:4", text: qsTr("Date Created"), checked: k === 4},
            {id: "sort:3", text: qsTr("Size"), checked: k === 3},
            {id: "sort:6", text: qsTr("Tags"), checked: k === 6},
            {separator: true},
            {id: "sortDescending", text: qsTr("Descending"), checked: root.sortDescending},
            {id: "foldersFirst", text: qsTr("Keep Folders on Top"), checked: root.app.foldersFirst}
        ]};
    }

    // The toolbar Action menu: item actions for a selection, folder actions otherwise.
    function actionMenu(): var {
        const m = root.activeFolder;
        if (root.chooser)
            return root.chooserMenu(m, m.selectedCount > 0);
        return m.selectedCount > 0 ? root.itemMenu(m) : root.backgroundMenu(m);
    }

    // A panel's menus: no file operation (the application does that with what it gets), only looking and arranging; New
    // Folder where the panel makes folders (FilePanel.canMakeFolder).
    function chooserMenu(model: var, onItems: bool): var {
        const items = [];
        if (onItems) {
            const rows = model.selectedRows();
            const name = rows.length > 0 ? DisplayName.text(model.nameAt(rows[0])) : "";
            if (rows.length > 0)
                items.push({id: "glance", text: rows.length === 1 ? qsTr("Glance at “%1”").arg(name) : qsTr("Glance at %1 Items").arg(rows.length), shortcut: qsTr("Space")});
            if (root.searchText !== "" || model.isSearch)
                items.push({id: "enclosing", text: qsTr("Show in Enclosing Folder")});
            if (items.length > 0)
                items.push({separator: true});
        }
        if (root.chooser.canMakeFolder) {
            items.push({id: "newFolder", text: qsTr("New Folder"), shortcut: qsTr("Ctrl+Shift+N"), enabled: model.writable});
            items.push({separator: true});
        }
        items.push(root.viewSubmenu());
        items.push({id: "useGroups", text: qsTr("Use Groups"), shortcut: qsTr("Ctrl+Super+0"), checked: root.groupBy > 0});
        items.push(root.groupSubmenu());
        items.push(root.sortSubmenu());
        items.push({id: "hidden", text: qsTr("Show Hidden Files"), shortcut: qsTr("Ctrl+H"), checked: root.app.showHidden});
        items.push({id: "preview", text: root.previewShown ? qsTr("Hide Preview") : qsTr("Show Preview"), shortcut: qsTr("Ctrl+Shift+P")});
        return items;
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
        if (id.startsWith("tag:")) {
            const urls = model.selectedUrls();
            if (urls.length > 0)
                root.app.toggleColorTag(urls, parseInt(id.substring(4)));
            return;
        }
        if (id.startsWith("sort:")) {
            root.sortBy(parseInt(id.substring(5)), false);
            return;
        }
        if (id.startsWith("group:")) {
            root.setGroupBy(parseInt(id.substring(6)));
            return;
        }
        switch (id) {
        case "open":
            root.openSelection();
            break;
        case "newTab":
            root.win.newTab(model.selectedUrls()[0], null);
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
        case "customize":
            root.customizeSelection();
            break;
        case "glance":
            root.glance();
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
            if (root.chooser)
                root.chooser.newFolder();
            else
                root.newFolder();
            break;
        case "enclosing":
            root.showInEnclosingFolder();
            break;
        case "hidden":
            root.app.showHidden = !root.app.showHidden;
            break;
        case "preview":
            root.togglePreview();
            break;
        case "sortDescending":
            root.setSortDescending(!root.sortDescending);
            break;
        case "useGroups":
            root.toggleGroups();
            break;
        case "foldersFirst":
            root.app.foldersFirst = !root.app.foldersFirst;
            break;
        }
    }

    // Views --------------------------------------------------------------------------------------

    Loader {
        id: viewLoader
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: previewPane.active ? previewPane.left : parent.right
        focus: true
        readonly property string kind: Nav.shownView(root.dragView, root.viewMode, root.folder !== null && root.folder.isSearch)
        sourceComponent: viewLoader.kind === "list" ? listComponent : viewLoader.kind === "columns" ? columnComponent : viewLoader.kind === "gallery" ? galleryComponent : iconComponent
        onLoaded: Qt.callLater(root.focusView)
    }

    // The preview pane beside the icon and list views (the gallery and the column view have their own), made while shown.
    Loader {
        id: previewPane
        active: (viewLoader.kind === "icons" || viewLoader.kind === "list") && root.app.previewPane
        anchors.right: parent.right
        height: parent.height
        sourceComponent: PreviewPane {
            topExtension: root.win ? root.win.previewExtension : 0
            tab: root
            model: root.activeFolder
        }
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

    Component {
        id: galleryComponent
        GalleryView {
            tab: root
            model: root.folder
        }
    }
}
