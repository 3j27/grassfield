pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../search/Ranking.js" as Ranking
import "Model.js" as Model

// Apps controller (spec docs/specs/apps.md): owns the open state, the saved layout (folders and
// order), the search query, paging and the keyboard selection, and the IPC target `apps`.
// AppsWindow renders it, one overlay window per screen, shown on the focused screen only.
//
// Items shown: with an empty query the saved layout (apps and folders, saved order, new apps
// appended by name); with a query the apps ranked by shell/search/Ranking.js (folders flattened).
Scope {
    id: root

    property bool open: false
    property string screenName: ""
    property string query: ""
    property int page: 0
    // Selected item (index into `items`) and whether the keyboard owns the focus ring.
    property int selected: -1
    property bool keyNav: false
    // Key of the open folder ("" none) and the selected app inside it.
    property string folderKey: ""
    property int folderSelected: -1
    // Set after a folder was just created by a drop: its name field starts in edit mode.
    property bool renameFolder: false

    // Latency log (P3): timestamp of the IPC call.
    property real openStartMs: 0
    // Latency log: timestamp of the last query change (AppsWindow logs it at the next frame).
    property real searchStartMs: 0
    // GRASSFIELD_APPS_TRACE=1 logs every keystroke latency (dev measurements); otherwise only slow ones.
    readonly property bool trace: Quickshell.env("GRASSFIELD_APPS_TRACE") === "1"

    property var records: []
    property var byId: ({})
    property var saved: []
    property var layout: []
    property var items: []
    property var usage: Ranking.newUsage()
    // Stable display items: every app item and folder item, keyed by item key. The grid keeps one
    // cell per entry of `allItems` ({key, state}) and only moves it: `state.slot` is the index of
    // the item in `items`, or -1 when it is not shown or is outside the window of the current
    // page and its neighbours (see windowed()). A cell outside the window never re-evaluates its
    // bindings, so a search keystroke only touches the cells that are or become visible.
    property var appItems: ({})
    property var itemByKey: ({})
    property var folderItems: ({})
    property var allItems: []
    property var states: ({})
    // Item key -> index in `items` (-1 not shown): the source of every state's windowed slot.
    property var slotOf: ({})
    // Key of the item being dragged: its cell stays shown (it owns the pointer grab).
    property string pinnedKey: ""

    Component {
        id: stateComponent

        QtObject {
            property int slot: -1
            property bool selected: false
        }
    }

    readonly property bool searching: query.trim() !== ""
    readonly property var grid: Model.grid(screenSize.width, screenSize.height, ({
            iconSize: Tokens.appsIconSize,
            widthFraction: Tokens.appsWidthFraction,
            heightFraction: Tokens.appsHeightFraction,
            cellWidthScale: Tokens.appsCellWidthScale,
            cellHeightScale: Tokens.appsCellHeightScale,
            minCols: Tokens.appsMinCols,
            maxCols: Tokens.appsMaxCols,
            minRows: Tokens.appsMinRows,
            maxRows: Tokens.appsMaxRows
        }))
    readonly property int pageCount: Model.pageCount(items.length, grid.perPage)
    readonly property size screenSize: {
        for (const s of Quickshell.screens) {
            if (s.name === screenName)
                return Qt.size(s.width, s.height);
        }
        return Qt.size(1920, 1080);
    }
    readonly property var folder: {
        for (const it of items) {
            if (it.kind === "folder" && it.key === folderKey)
                return it;
        }
        return null;
    }

    readonly property string home: Quickshell.env("HOME")
    // GRASSFIELD_STATE_HOME (dev) wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: {
        const dev = Quickshell.env("GRASSFIELD_STATE_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_STATE_HOME");
        return (xdg ? xdg : home + "/.local/state") + "/grassfield";
    }
    readonly property string layoutPath: stateDir + "/apps-layout.json"
    readonly property string usagePath: stateDir + "/search-usage.json"

    // ---- state changes -------------------------------------------------------------------

    function show(): void {
        if (open)
            return;
        openStartMs = Date.now();
        if (Popups.active)
            Popups.close();
        const name = Compositor.focusedScreenName;
        let found = "";
        for (const s of Quickshell.screens) {
            if (s.name === name)
                found = name;
        }
        screenName = found !== "" ? found : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        query = "";
        page = 0;
        keyNav = false;
        selected = -1;
        folderKey = "";
        usageFile.reload();
        rebuildItems(false);
        open = true;
    }

    function hide(): void {
        open = false;
        folderKey = "";
        renameFolder = false;
    }

    function toggle(): void {
        if (open)
            hide();
        else
            show();
    }

    function setQuery(text: string): void {
        if (text === query)
            return;
        const t0 = Date.now();
        searchStartMs = t0;
        query = text;
        folderKey = "";
        page = 0;
        rebuildItems(false);
        selected = searching && items.length > 0 ? 0 : -1;
        if (trace || Date.now() - t0 > 16)
            console.info("grassfield-shell: apps search", Date.now() - t0, "ms,", items.length, "items");
    }

    function setPage(p: int): void {
        page = Model.clampPage(p, items.length, grid.perPage);
    }

    // The focus ring is a flag on the selected item's cell state, so moving the selection touches
    // two cells instead of re-evaluating a binding in every cell.
    property string selectedKey: ""

    function syncSelected(): void {
        const key = selected >= 0 && selected < items.length ? items[selected].key : "";
        if (key === selectedKey)
            return;
        if (selectedKey !== "" && states[selectedKey])
            states[selectedKey].selected = false;
        selectedKey = key;
        if (key !== "" && states[key])
            states[key].selected = true;
    }

    onSelectedChanged: syncSelected()

    // Slot of a cell inside the window (current page and its neighbours, plus the dragged item).
    function windowed(slot: int, key: string): int {
        const per = grid.perPage;
        const lo = (page - 1) * per;
        const hi = (page + 2) * per;
        return (slot >= lo && slot < hi) || key === pinnedKey ? slot : -1;
    }

    function refreshWindow(): void {
        for (const key of Object.keys(slotOf)) {
            const st = states[key];
            if (st)
                st.slot = windowed(slotOf[key], key);
        }
    }

    onPageChanged: refreshWindow()
    onPinnedKeyChanged: refreshWindow()
    onGridChanged: refreshWindow()

    // ---- items ---------------------------------------------------------------------------

    function rebuildApps(): void {
        const out = [];
        const map = {};
        const cache = {};
        for (const e of DesktopEntries.applications.values) {
            // NoDisplay, OnlyShowIn and NotShowIn: the shared list in the Apps service.
            if (!Apps.isListed(e))
                continue;
            const rec = {id: e.id, name: e.name, genericName: e.genericName, comment: e.comment,
                keywords: Array.from(e.keywords), icon: e.icon, entry: e};
            out.push(rec);
            map[e.id] = rec;
            cache["app:" + e.id] = {kind: "app", key: "app:" + e.id, id: e.id, name: e.name, rec: rec};
        }
        appItems = cache;
        records = out;
        byId = map;
        rebuildItems(true);
    }

    // Display items are created once per record, so a keystroke only picks from the cache.
    function appItem(rec: var): var {
        return appItems["app:" + rec.id];
    }

    function rebuildItems(relayout: bool): void {
        if (relayout)
            layout = Model.reconcile(saved, records.map(r => ({id: r.id, name: r.name})));
        if (relayout && selectedKey !== "") {
            if (states[selectedKey])
                states[selectedKey].selected = false;
            selectedKey = "";
        }
        let list = [];
        // Folder items and the cell states are rebuilt with the layout only (a keystroke skips this).
        if (relayout) {
            const folders = {};
            for (const it of layout) {
                if (it.t === "folder")
                    folders[it.key] = {kind: "folder", key: it.key, id: it.key, name: it.name, apps: it.apps.map(id => appItem(byId[id]))};
            }
            folderItems = folders;
            itemByKey = Object.assign({}, appItems, folders);
            const keep = {};
            allItems = Object.keys(itemByKey).map(k => {
                let st = states[k];
                if (!st) {
                    st = stateComponent.createObject(root);
                    states[k] = st;
                }
                keep[k] = true;
                return {key: k, state: st};
            });
            for (const k of Object.keys(states)) {
                if (!keep[k]) {
                    states[k].destroy();
                    delete states[k];
                }
            }
        }
        if (searching) {
            for (const r of Ranking.rank(records, query, usage, 0))
                list.push(appItem(r.app));
        } else {
            for (const it of layout) {
                if (it.t === "app") {
                    list.push(appItem(byId[it.id]));
                } else {
                    list.push(folderItems[it.key]);
                }
            }
        }
        const next = {};
        for (let i = 0; i < list.length; i++) {
            next[list[i].key] = i;
            states[list[i].key].slot = windowed(i, list[i].key);
        }
        for (const it of items) {
            if (next[it.key] === undefined && states[it.key])
                states[it.key].slot = -1;
        }
        slotOf = next;
        items = list;
        syncSelected();
        if (page >= pageCount)
            page = pageCount - 1;
        if (selected >= items.length)
            selected = items.length - 1;
        if (folderKey !== "" && !folder)
            folderKey = "";
    }

    // ---- editing (layout persisted on every change) --------------------------------------

    function commit(next: var): void {
        saved = next;
        rebuildItems(true);
        if (layoutFile.path !== "")
            layoutFile.setText(Model.serialize(next));
    }

    // Layout index of the top-level item with `key`.
    function indexOfKey(key: string): int {
        return items.findIndex(it => it.key === key);
    }

    function moveItem(key: string, to: int): void {
        const from = indexOfKey(key);
        if (from >= 0 && to >= 0)
            commit(Model.moveTo(layout, from, to));
    }

    // Drop of item `key` onto item index `dst`: creates or fills a folder (returns its key) or "".
    function mergeItem(key: string, dst: int): string {
        const from = indexOfKey(key);
        if (from < 0 || dst < 0 || dst >= items.length || from === dst)
            return "";
        if (items[from].kind !== "app")
            return "";
        if (items[dst].kind === "folder") {
            const k = items[dst].key;
            commit(Model.addToFolder(layout, from, dst));
            return k;
        }
        const dstId = items[dst].id;
        commit(Model.createFolder(layout, from, dst, qsTr("Untitled")));
        for (const it of layout) {
            if (it.t === "folder" && it.apps.indexOf(dstId) >= 0)
                return it.key;
        }
        return "";
    }

    function removeFromFolder(key: string, id: string): void {
        commit(Model.removeFromFolder(layout, key, id));
    }

    function renameFolderTo(key: string, name: string): void {
        commit(Model.renameFolder(layout, key, name));
    }

    function openFolder(key: string, rename: bool): void {
        renameFolder = rename;
        folderSelected = rename ? -1 : 0;
        folderKey = key;
    }

    function closeFolder(): void {
        folderKey = "";
        renameFolder = false;
    }

    // ---- activation and keyboard ---------------------------------------------------------

    function launch(rec: var): void {
        if (!rec)
            return;
        hide();
        Apps.launch(rec.entry);
    }

    function activate(item: var): void {
        if (!item)
            return;
        if (item.kind === "folder")
            openFolder(item.key, false);
        else
            launch(item.rec);
    }

    function activateSelected(): void {
        if (folder) {
            if (folderSelected >= 0 && folderSelected < folder.apps.length)
                launch(folder.apps[folderSelected].rec);
            return;
        }
        if (selected >= 0 && selected < items.length)
            activate(items[selected]);
    }

    // Arrow navigation; the page follows the selection.
    function move(key: string): void {
        keyNav = true;
        if (folder) {
            const cols = Math.min(Tokens.appsFolderPanelCols, folder.apps.length);
            // Up from the first row moves to the folder title (Return there renames the folder).
            folderSelected = Model.stepFolder(folderSelected, key, cols, folder.apps.length);
            return;
        }
        selected = Model.step(selected, key, grid.cols, grid.perPage, items.length);
        if (selected >= 0)
            page = Model.pageOf(selected, grid.perPage);
    }

    function flip(delta: int): void {
        const before = page;
        setPage(page + delta);
        if (page !== before && keyNav) {
            const row = selected >= 0 ? Math.floor((selected % grid.perPage) / grid.cols) : 0;
            const col = selected >= 0 ? selected % grid.cols : 0;
            selected = Math.min(items.length - 1, page * grid.perPage + row * grid.cols + col);
        }
    }

    // ---- persistence (0600, like the search usage file) ----------------------------------

    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.layoutPath]
        onRunningChanged: {
            if (!running) {
                layoutFile.path = root.layoutPath;
                usageFile.path = root.usagePath;
            }
        }
    }

    FileView {
        id: layoutFile
        printErrors: false
        atomicWrites: true
        onLoaded: {
            root.saved = Model.parse(layoutFile.text());
            root.rebuildItems(true);
        }
    }

    // Search usage (read only) feeds the ranking boost.
    FileView {
        id: usageFile
        printErrors: false
        onLoaded: root.usage = Ranking.parseUsage(usageFile.text())
    }

    Connections {
        target: Apps

        function onListChanged(): void {
            root.rebuildApps();
        }
    }

    // IPC: qs ipc call apps <toggle|open|close|status>. The hot-corner action `apps` calls toggle().
    IpcHandler {
        target: "apps"

        function toggle(): void {
            root.toggle();
        }

        function open(): void {
            root.show();
        }

        function close(): void {
            root.hide();
        }

        // Test hook: JSON {open, page, pageCount, query, selected, folder, cols, rows, visible: [id]}.
        function status(): string {
            const per = root.grid.perPage;
            const vis = root.items.slice(root.page * per, (root.page + 1) * per).map(i => i.kind === "folder" ? "folder:" + i.name + ":" + i.apps.map(a => a.id).join("+") : i.id);
            return JSON.stringify({
                open: root.open,
                page: root.page,
                pageCount: root.pageCount,
                query: root.query,
                selected: root.selected,
                keyNav: root.keyNav,
                folder: root.folder ? root.folder.name : "",
                total: root.items.length,
                cols: root.grid.cols,
                rows: root.grid.rows,
                visible: vis
            });
        }
    }

    Component.onCompleted: {
        // Before the first hidden-list run the Apps service emits listChanged by itself.
        if (Apps.hiddenReady)
            rebuildApps();
        prepare.running = true;
    }

    AppsWindow {
        controller: root
    }
}
