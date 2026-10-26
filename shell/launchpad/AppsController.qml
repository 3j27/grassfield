pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Grassfield.Ui
import qs.platform
import qs.services
import "../platform/ScreenChoice.js" as ScreenChoice
import "../search/Ranking.js" as Ranking // layering-exception: GF-087
import "Model.js" as Model

// Apps controller (spec docs/specs/apps.md): owns the open state, the search query, the category
// chip, the keyboard zone and selection, and the IPC target `apps`. AppsWindow renders it, one
// overlay window per screen, shown on the focused screen only.
//
// Items shown: with an empty query the apps of the selected chip in alphabetical order; with a query
// every app ranked by shell/search/Ranking.js (the chip is ignored while searching).
Scope {
    id: root

    property bool open: false
    // Key focus returns to the window that was active when this opened (FocusReturn), as on macOS.
    onOpenChanged: {
        if (open)
            FocusReturn.opened("apps");
        else
            FocusReturn.closed("apps", true);
    }
    property string screenName: ""
    property string query: ""
    // Selected chip id (Model.CATEGORY_IDS) and the chip that holds the keyboard focus in the "chips" zone.
    property string category: "all"
    property string chipFocus: "all"
    // Keyboard zone: "search" (the field), "chips" (the chip row) or "grid".
    property string zone: "search"
    // Selected item (index into `items`) and whether the keyboard owns the focus ring.
    property int selected: -1
    property bool keyNav: false
    // Items whose row is in the view (set by the window: first and last index, -1 when none).
    property int viewFirst: -1
    property int viewLast: -1

    // Latency log (P3): timestamp of the IPC call.
    property real openStartMs: 0
    // Latency log: timestamps of the query changes not yet followed by a rendered frame (AppsWindow logs each
    // at the next frame).
    property var pendingSearchMs: []
    // True while the list is rebuilt because the installed apps changed (the view keeps its scroll position).
    property bool listRefresh: false
    // GRASSFIELD_APPS_TRACE=1 logs every keystroke latency (dev measurements); otherwise only slow ones.
    readonly property bool trace: Mode.appsTrace

    // Records of the installed, listed apps (Apps service) and the display item of each: {key, id, name, rec}.
    property var records: []
    property var itemById: ({})
    // Chip id -> items in alphabetical order, and the chips shown.
    property var groups: ({})
    property var chips: Model.CATEGORY_IDS
    property var items: []
    property var usage: Ranking.newUsage()

    readonly property var categoryLabels: ({
            all: qsTr("All"),
            productivity: qsTr("Productivity"),
            creativity: qsTr("Creativity"),
            utilities: qsTr("Utilities"),
            games: qsTr("Games"),
            other: qsTr("Other")
        })

    readonly property bool searching: query.trim() !== ""
    readonly property size screenSize: {
        for (const s of Quickshell.screens) {
            if (s.name === screenName)
                return Qt.size(s.width, s.height);
        }
        return Qt.size(1920, 1080);
    }
    readonly property var panel: Model.panelRect(screenSize.width, screenSize.height, ({
            width: Tokens.launcherPanelWidth,
            edgeMargin: Math.max(Tokens.launcherEdgeMargin, Settings.dockFootprint.left, Settings.dockFootprint.right),
            heightFraction: Tokens.launcherHeightFraction,
            minHeight: Tokens.launcherMinHeight,
            topFraction: Tokens.launcherTopFraction,
            // The search capsule sits above the panel (macOS 27).
            topOffset: Tokens.searchCapsuleHeight + Tokens.searchCapsuleGap,
            // Never into the Dock (its size and edge are the user's): the tokens are the floor.
            bottomClearance: Math.max(Tokens.launcherBottomClearance, Settings.dockFootprint.bottom)
        }))
    readonly property var grid: Model.grid(panel.w - 2 * Tokens.launcherPadding, ({
            columns: Tokens.launcherColumns,
            minColumns: Tokens.launcherMinColumns,
            minCellWidth: Tokens.launcherMinCellWidth,
            cellHeight: Tokens.launcherCellHeight
        }))

    readonly property string home: Quickshell.env("HOME")
    // GRASSFIELD_STATE_HOME (dev) wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: Mode.stateDir
    readonly property string usagePath: stateDir + "/search-usage.json"

    // ---- state changes -------------------------------------------------------------------

    // The screen the Apps panel is on went away (a display unplugged): the panel moves to a live screen.
    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.screenName = ScreenChoice.replacement(root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));
        }
    }

    function show(): void {
        // Nothing opens over the lock screen (GF-116): XF86LaunchA, the Dock, a screen corner, the pinch and IPC alike.
        if (open || SessionState.refuses("apps"))
            return;
        openStartMs = Date.now();
        if (Popups.active)
            Popups.close();
        screenName = Compositor.activeScreenName;
        query = "";
        category = "all";
        chipFocus = "all";
        zone = "search";
        keyNav = false;
        selected = -1;
        usageFile.reload();
        rebuildItems();
        open = true;
    }

    function hide(): void {
        open = false;
        viewFirst = -1;
        viewLast = -1;
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
        pendingSearchMs = pendingSearchMs.concat([t0]);
        query = text;
        rebuildItems();
        selected = searching && items.length > 0 ? 0 : -1;
        if (trace || Date.now() - t0 > 16)
            console.info("grassfield-shell: apps search", Date.now() - t0, "ms,", items.length, "items");
    }

    // A click or Return on a chip: the query is cleared (the chip browses every app of its category).
    function selectCategory(id: string): void {
        if (chips.indexOf(id) < 0)
            return;
        category = id;
        chipFocus = id;
        if (query !== "")
            query = "";
        rebuildItems();
        selected = -1;
    }

    // Focus moves left or right along the visible chips (clamped).
    function moveChip(delta: int): void {
        const i = Math.max(0, chips.indexOf(chipFocus));
        chipFocus = chips[Math.max(0, Math.min(chips.length - 1, i + delta))];
    }

    // The selection ring is only ever visible on the selected item, so the selection always matches the ring:
    // leaving the grid drops it (the field with a query selects the first result, as Return will launch it).
    function setZone(z: string): void {
        zone = z;
        if (z === "grid") {
            keyNav = true;
            if (selected < 0 && items.length > 0)
                selected = 0;
        } else {
            keyNav = false;
            selected = Model.selectionForZone(z, searching, items.length);
            if (z === "chips")
                chipFocus = searching ? "all" : category;
        }
    }

    // ---- items ---------------------------------------------------------------------------

    function rebuildApps(): void {
        // The selection follows its app, not its index; the view keeps its scroll position.
        const keepId = selected >= 0 && selected < items.length ? items[selected].id : "";
        const raw = [];
        const cache = {};
        for (const e of DesktopEntries.applications.values) {
            // NoDisplay, OnlyShowIn and NotShowIn: the shared list in the Apps service.
            if (!Apps.isListed(e))
                continue;
            raw.push({id: e.id, name: e.name, genericName: e.genericName, comment: e.comment,
                keywords: Array.from(e.keywords), icon: e.icon, entry: e, category: Model.categoryOf(e.categories)});
        }
        // Two apps of one name are told apart (Files and Files (GNOME)); nothing is hidden.
        const recs = Model.disambiguate(raw);
        for (const rec of recs)
            cache[rec.id] = {key: "app:" + rec.id, id: rec.id, name: rec.name, rec: rec};
        records = Model.sortApps(recs);
        itemById = cache;
        const g = Model.groupByCategory(records);
        const byCat = {};
        for (const id of Object.keys(g))
            byCat[id] = g[id].map(r => cache[r.id]);
        groups = byCat;
        chips = Model.visibleCategories(g);
        if (chips.indexOf(category) < 0)
            category = "all";
        if (chips.indexOf(chipFocus) < 0)
            chipFocus = category;
        listRefresh = true;
        rebuildItems();
        listRefresh = false;
        selected = Model.indexOfId(items, keepId);
        if (selected < 0 && zone === "search")
            selected = Model.selectionForZone(zone, searching, items.length);
    }

    function rebuildItems(): void {
        let list;
        if (searching)
            list = Ranking.rank(records, query, usage, 0).map(r => itemById[r.app.id]);
        else
            list = groups[category] ?? [];
        items = list;
        selected = -1;
    }

    // ---- activation and keyboard ---------------------------------------------------------

    function launch(rec: var): void {
        if (!rec)
            return;
        hide();
        Apps.launch(rec.entry);
    }

    function activate(item: var): void {
        if (item)
            launch(item.rec);
    }

    // Return launches the item whose selection ring is visible, nothing otherwise (an invisible selection never
    // launches). In the field with a query that is the first result (setZone selects it).
    function activateSelected(): void {
        const at = Model.launchIndex(zone, keyNav, searching, selected, items.length);
        if (at >= 0)
            activate(items[at]);
    }

    // Arrow navigation. Returns false when Up leaves the first row (the window then moves the focus).
    function move(key: string, pageRows: int): bool {
        keyNav = true;
        if (key === "up" && selected >= 0 && Model.atFirstRow(selected, grid.cols))
            return false;
        selected = Model.step(selected, key, grid.cols, items.length, pageRows);
        return true;
    }

    // ---- search usage (read only, feeds the ranking boost) -------------------------------

    FileView {
        id: usageFile
        path: root.usagePath
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

        // Test hook (dev session only, VisualFixtures.dev, SEC-04: it returns the typed query): JSON {open, query,
        // category, chips, zone, selected, selectedId, keyNav, total, cols, panel: {x, y, w, h}, visible: [id]}.
        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            const vis = root.viewFirst < 0 ? [] : root.items.slice(root.viewFirst, root.viewLast + 1).map(i => i.id);
            const sel = root.selected >= 0 && root.selected < root.items.length ? root.items[root.selected].id : "";
            return JSON.stringify({
                open: root.open,
                query: root.query,
                category: root.category,
                chips: root.chips,
                zone: root.zone,
                selected: root.selected,
                selectedId: sel,
                keyNav: root.keyNav,
                total: root.items.length,
                cols: root.grid.cols,
                panel: root.panel,
                visible: vis
            });
        }
    }

    Component.onCompleted: {
        // Before the first hidden-list run the Apps service emits listChanged by itself.
        if (Apps.hiddenReady)
            rebuildApps();
    }

    // The session locks: Apps closes.
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked && root.open)
                root.hide();
        }
    }

    AppsWindow {
        controller: root
    }
}
