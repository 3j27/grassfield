pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.notifications
import qs.platform
import qs.services
import "DockModel.js" as DockModel
import "../desktop/IconsLogic.js" as Icons
import "Magnify.js" as Magnify

// Bottom dock, one per screen: pinned apps (Settings) and running apps (foreign-toplevel app ids
// mapped to desktop entries), a separator and the Trash. Click launches, focuses the most recent
// window or cycles windows; right click opens the item menu. Magnification and autohide follow
// Settings (dock.magnification, dock.autohide) and Reduce Motion.
Scope {
    id: root

    // [{kind, key, name, icon, entry, windows, pinned}], rebuilt when apps/toplevels/pins change.
    property var items: []
    // Tiles are a keyed list model updated by diffing (DockModel.diffKeys) so a delegate survives a rebuild and its animations
    // (glide, launch bounce and landing) keep running. A delegate reads its item from itemByKey by its key.
    property var itemByKey: ({})
    property var tileKeys: []
    ListModel {
        id: tileModel
    }

    function applyOps(ops: var): void {
        for (const o of ops) {
            if (o.op === "remove") {
                tileModel.remove(o.at);
                tileKeys.splice(o.at, 1);
            } else if (o.op === "insert") {
                tileModel.insert(o.at, {tileId: o.key});
                tileKeys.splice(o.at, 0, o.key);
            } else {
                tileModel.move(o.from, o.to, 1);
                tileKeys.splice(o.to, 0, tileKeys.splice(o.from, 1)[0]);
            }
        }
    }

    // Replaces the items: rows that went away are removed first (no delegate looks up a missing key), then the items are
    // published, then rows are inserted and moved.
    function setItems(next: var): void {
        const ops = DockModel.diffKeys(tileKeys, next.map(DockModel.tileKey));
        applyOps(ops.filter(o => o.op === "remove"));
        const map = {};
        next.forEach(it => {
            map[DockModel.tileKey(it)] = it;
        });
        itemByKey = map;
        items = next;
        applyOps(ops.filter(o => o.op !== "remove"));
    }
    // Test hooks (IPC): a pointer x forcing magnification, and a forced reveal.
    property real testPointerX: -1
    property bool testReveal: false
    // Keyboard navigation mode: the dock takes exclusive keyboard focus until Esc, an
    // activation, or pointer use; then the layer releases focus and the compositor restores the app.
    property bool keyboardMode: false
    // Output whose Dock has the keyboard (the focused one when the mode was entered).
    property string keyboardScreen: ""

    // Enter keyboard mode and focus the first tile.
    function enterKeyboardMode(): void {
        keyboardScreen = Compositor.focusedScreenName !== "" ? Compositor.focusedScreenName : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        keyboardMode = true;
        Qt.callLater(() => {
            const all = windows.instances;
            let bar = null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === root.keyboardScreen)
                    bar = all[i];
            }
            if (bar)
                bar.focusFirstTile();
        });
    }

    // Tiles launched from the Dock that have no window yet (they bounce): key -> start time (ms).
    property var launching: ({})

    // Keys of the listed apps that had a window at the previous rebuild (null: no rebuild yet).
    property var previousRunning: null

    // Persists the recent apps list only when it differs from the stored one.
    function writeRecents(list: var): void {
        const current = Settings.dockRecent;
        if (list.length !== current.length || list.some((k, i) => k !== current[i]))
            Settings.setDockRecent(list);
    }

    // A tile is being dragged on some screen: the tiles are not rebuilt until the release (a rebuild destroys the dragged
    // delegate and its drag handler, and the drop would never be finished). The latest state is applied right after.
    property bool rebuildPending: false

    function dragInProgress(): bool {
        return windows.instances.some(w => w.dragFrom >= 0);
    }

    function rebuild(): void {
        if (dragInProgress()) {
            rebuildPending = true;
            return;
        }
        rebuildPending = false;
        const running = [];
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let i = 0; i < tops.length; i++)
            running.push({appId: tops[i].appId, ref: tops[i]});
        const apps = DockModel.merge(Settings.dockPinned, running, Apps.lookup);
        // Apps that were running and quit while not kept in the Dock become "recent" (DockModel.recentsAfter: a pure
        // function of the previous and current running sets, written only when the list really changes).
        const runningKeys = apps.filter(a => a.windows.length > 0 && a.entry && Apps.isListed(a.entry)).map(a => a.key);
        // Not before the desktop entries and the hidden-entry list are loaded (DockModel.recentsStep).
        const ready = Apps.hiddenReady && DesktopEntries.applications.values.length > 0;
        const pinnedKeys = apps.filter(a => a.pinned).map(a => a.key);
        const step = DockModel.recentsStep(ready, Settings.dockRecent, previousRunning, runningKeys, pinnedKeys, Tokens.dockRecentMax);
        previousRunning = step.previous;
        if (ready && Settings.dockShowRecents)
            writeRecents(step.recent);
        const shown = ready && Settings.dockShowRecents ? DockModel.withRecents(apps, Settings.dockRecent, Apps.lookup, Tokens.dockRecentMax, Apps.isListed) : apps;
        const tail = Settings.dockMinimizeIntoApp ? [] : DockModel.minimizedItems(Compositor.minimized, Apps.lookup);
        const all = windows.instances;
        all.forEach(w => w.captureLayout());
        setItems(DockModel.withTail(shown, tail));
        all.forEach(w => w.playLayout());
        pruneLaunching();
    }

    function pruneLaunching(): void {
        const keys = Object.keys(launching);
        if (keys.length === 0)
            return;
        const kept = DockModel.bounceKeys(launching, items, Date.now(), Tokens.dockLaunchTimeout);
        if (Object.keys(kept).length !== keys.length)
            launching = kept;
    }

    // Starts an app tile: the launch bounce runs until a window appears (or the timeout), and an app that is not kept
    // in the Dock is remembered as a recent application.
    function launchItem(item: var): void {
        if (!item.entry)
            return;
        Apps.launch(item.entry);
        const next = Object.assign({}, launching);
        next[item.key] = Date.now();
        launching = next;
        launchTimer.restart();
        if (!item.pinned && Settings.dockShowRecents && Apps.isListed(item.entry))
            writeRecents(DockModel.pushRecent(Settings.dockRecent, item.key, Tokens.dockRecentMax));
    }

    // Removes a tile from the Dock (drag out): unpins it and forgets it as a recent app. Running apps keep their
    // tile. True when the tile goes away.
    function removeItem(item: var): bool {
        if (item.kind !== "app")
            return false;
        if (item.pinned)
            Settings.setDockPinned(DockModel.unpinKey(Settings.dockPinned, item.key, Apps.lookup));
        if (item.recent)
            Settings.setDockRecent(Settings.dockRecent.filter(r => r !== item.key));
        return item.windows.length === 0;
    }

    Timer {
        id: launchTimer
        interval: Tokens.dockLaunchTimeout
        onTriggered: root.pruneLaunching()
    }

    function activateItem(item: var): void {
        keyboardMode = false;
        if (item.kind === "trash") {
            Trash.open();
            Trash.refresh();
            return;
        }
        if (item.kind === "minimized") {
            Compositor.unminimize(item.toplevel);
            return;
        }
        if (item.windows.length === 0) {
            root.launchItem(item);
            return;
        }
        // Minimized windows take part only when the app has nothing else (then the click restores one).
        const visible = item.windows.filter(t => !Compositor.isMinimized(t));
        const pool = visible.length > 0 ? visible : item.windows;
        const focused = Compositor.focusedToplevel;
        const focusedHere = focused !== null && pool.indexOf(focused) >= 0;
        // Already focused: cycle through this app's windows; otherwise raise the most recent one.
        Compositor.activate(focusedHere ? Compositor.nextAfter(pool, focused) : Compositor.mostRecent(pool));
    }

    Component.onCompleted: rebuild()

    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Compositor

        function onMinimizedChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Apps

        // The hidden-entry list has (re)loaded.
        function onListChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.rebuild();
        }
    }

    Connections {
        target: Settings

        function onDockPinnedChanged(): void {
            root.rebuild();
        }

        function onDockRecentChanged(): void {
            root.rebuild();
        }

        function onDockShowRecentsChanged(): void {
            root.rebuild();
        }

        function onDockMinimizeIntoAppChanged(): void {
            root.rebuild();
        }
    }

    // Test hooks: qs ipc call dock <hover|unhover|reveal|autohide|magnify|click|keyboard|menu>.
    IpcHandler {
        target: "dock"

        function hover(x: real): void {
            root.testPointerX = x;
        }

        function unhover(): void {
            root.testPointerX = -1;
        }

        function reveal(on: bool): void {
            root.testReveal = on;
        }

        function autohide(on: bool): void {
            Settings.setDockAutohide(on);
        }

        function magnify(factor: real, enabled: bool): void {
            Settings.setDockMagnification(factor, enabled);
        }

        // Same code path as a click on item `index`.
        function click(index: int): void {
            if (root.items[index])
                root.activateItem(root.items[index]);
        }

        function keyboard(): void {
            root.enterKeyboardMode();
        }

        function menu(index: int, screen: string): void {
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            if (win)
                win.openMenu(index);
        }
    }

    Variants {
        id: windows

        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            readonly property int iconSize: Tokens.dockIconSize
            readonly property int separatorWidth: Tokens.dockSpacing * 2 + Tokens.dockSeparatorWidth
            readonly property real maxScale: Settings.dockMagnificationEnabled ? Settings.dockMagnification : 1
            readonly property real pitch: iconSize + Tokens.dockSpacing
            readonly property var dockMetrics: ({
                    iconSize: Tokens.dockIconSize,
                    padding: Tokens.dockPadding,
                    indicatorSize: Tokens.dockIndicatorSize,
                    spacing: Tokens.dockSpacing,
                    bottomMargin: Tokens.dockBottomMargin
                })
            readonly property int indicatorArea: Tokens.dockIndicatorSize + Tokens.dockSpacing
            readonly property int shelfHeight: DockModel.shelfHeight(dockMetrics)
            readonly property real overhang: Math.ceil((maxScale - 1) * iconSize)
            readonly property int tooltipArea: Tokens.dockTooltipArea
            // Drag to reorder or remove: the dragged tile (index in items, -1 none), its offset from the press, the slot
            // it would take, and whether releasing it now removes it from the Dock.
            property int dragFrom: -1
            property real dragDx: 0
            property real dragDy: 0
            onDragFromChanged: if (dragFrom < 0 && root.rebuildPending)
                root.rebuild()
            // Item indices of the app tiles; the drag slots and the reorder work on positions in this list (the recent
            // applications divider sits between app tiles).
            readonly property var appItems: DockModel.appIndices(root.items)
            readonly property int dragFromApp: dragFrom < 0 ? -1 : appItems.indexOf(dragFrom)
            readonly property int dragSlot: dragFrom < 0 ? -1 : DockModel.dropSlot(baseCenters, appItems, baseCenters[dragFrom] + dragDx)
            readonly property bool dragOut: dragFrom >= 0 && dragDy < -(Tokens.dockPadding + iconSize / 2 + Tokens.dockDragOutDistance)
            readonly property bool dragRemovable: dragFrom >= 0 && !!root.items[dragFrom] && (root.items[dragFrom].pinned || root.items[dragFrom].recent === true) && root.items[dragFrom].windows.length === 0
            property real poofX: 0
            property real poofY: 0
            property real poofProgress: 1

            function finishDrag(tileItem: Item): void {
                const from = dragFrom;
                const all = root.items;
                const item = all[from];
                const out = dragOut && dragRemovable;
                const slot = dragSlot;
                const fromApp = dragFromApp;
                // mapToItem already includes the tile's drag translation (its Translate transform): adding dragDx/dragDy put the puff off the window.
                const cx = tileItem.mapToItem(area, tileItem.width / 2, win.iconSize / 2).x;
                const cy = tileItem.mapToItem(area, 0, win.iconSize / 2).y;
                const dx = dragDx;
                const dy = dragDy;
                // The tiles keep their dragged / displaced places until the rebuild: it animates from there.
                layoutBefore = tileXs();
                dragSnap = true;
                collapseAnim.stop();
                dragCollapse = 0;
                dragFrom = -1;
                dragDx = 0;
                dragDy = 0;
                if (!item)
                    return;
                if (out) {
                    if (root.removeItem(item)) {
                        holdLayout = true;
                        holdTimer.restart();
                        win.poof(cx, cy);
                    } else {
                        tileItem.glideFrom(dx, dy);
                    }
                    return;
                }
                const r = DockModel.reorder(all, fromApp, slot);
                if (r.changed) {
                    holdLayout = true;
                    holdTimer.restart();
                    Settings.setDockPinned(r.pinned);
                } else {
                    tileItem.glideFrom(dx, dy);
                }
            }

            Timer {
                id: holdTimer
                interval: Tokens.motionNormal
                onTriggered: win.holdLayout = false
            }

            // A tile dragged out of the Dock (it would be removed) closes its gap in the shelf, and reopens when dragged back.
            property real dragCollapse: 0
            property bool dragSnap: false
            readonly property bool dragCollapsing: dragFrom >= 0 && dragOut && dragRemovable
            onDragCollapsingChanged: {
                if (dragFrom < 0)
                    return;
                collapseAnim.stop();
                collapseAnim.to = dragCollapsing ? 1 : 0;
                collapseAnim.start();
            }

            NumberAnimation {
                id: collapseAnim
                target: win
                property: "dragCollapse"
                duration: Appearance.duration(Tokens.motionFast)
                easing.type: Easing.OutQuad
            }

            // Layout transition (DockModel.layoutTransition): x of every tile (window coordinates) before a rebuild.
            property var layoutBefore: ({})

            function tileXs(): var {
                const out = {};
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (t)
                        out[t.tileId] = t.mapToItem(area, 0, 0).x;
                }
                return out;
            }

            // Set by finishDrag: the positions captured when the tile was released (with the drag and make-room offsets still
            // applied) are the ones the next rebuild animates from.
            property bool holdLayout: false

            function captureLayout(): void {
                if (!holdLayout)
                    layoutBefore = tileXs();
            }

            // After the tiles were rebuilt: tiles that moved glide from their old place (an app that quit moves into the
            // recents section instead of jumping), new tiles fade in. Skipped with Reduce Motion and while a tile is dragged.
            function playLayout(): void {
                holdLayout = false;
                if (Appearance.reduceMotion || dragFrom >= 0)
                    return;
                tiles.forceLayout();
                const after = tileXs();
                const plan = DockModel.layoutTransition(layoutBefore, after, 1);
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (!t)
                        continue;
                    const key = t.tileId;
                    if (plan.slide[key] !== undefined)
                        t.glideFrom(plan.slide[key], 0);
                    else if (plan.enter.indexOf(key) >= 0)
                        t.fadeIn();
                }
            }

            // Removal puff (own drawing, no artwork): a ring of fading circles around (x, y).
            function poof(x: real, y: real): void {
                poofX = x;
                poofY = y;
                poofAnim.restart();
            }

            NumberAnimation {
                id: poofAnim
                target: win
                property: "poofProgress"
                from: 0
                to: 1
                duration: Appearance.duration(Tokens.dockPoofDuration)
                easing.type: Easing.OutQuad
            }
            readonly property bool autohide: Settings.dockAutohide
            // Layout from the unmagnified geometry (stable under the pointer), then scaled.
            readonly property var widths: root.items.map(it => it.kind === "separator" ? separatorWidth : iconSize)
            readonly property real baseTotal: Magnify.totalWidth(widths, Tokens.dockSpacing)
            readonly property var baseCenters: Magnify.centersFor(widths, Tokens.dockSpacing, (width - baseTotal) / 2)

            readonly property bool pointerActive: areaHover.hovered || root.testPointerX >= 0
            readonly property real pointerX: root.testPointerX >= 0 ? root.testPointerX : areaHover.point.position.x
            // 0..1, eases magnification in and out.
            property real influence: pointerActive ? 1 : 0

            readonly property var scaleList: {
                const raw = Magnify.scales(baseCenters, pointerX, pitch, maxScale, Tokens.dockMagnificationRadius);
                return raw.map((s, i) => root.items[i].kind === "separator" ? 1 : 1 + (s - 1) * influence);
            }
            readonly property real shelfWidth: Magnify.totalWidth(widths.map((w, i) => w * scaleList[i]), Tokens.dockSpacing) + 2 * Tokens.dockPadding - dragCollapse * pitch

            // Autohide: revealed while the pointer is on the dock (or the bottom edge strip).
            property bool revealedState: false
            readonly property bool revealed: !autohide || revealedState || root.testReveal || root.keyboardMode || Popups.kind === "dock"

            function focusFirstTile(): void {
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (t && t.activeFocusOnTab) {
                        t.forceActiveFocus();
                        return;
                    }
                }
            }

            function openMenu(index: int): void {
                root.keyboardMode = false;
                const item = root.items[index];
                if (!item || item.kind !== "app")
                    return;
                const t = tileRepeater.itemAt(index);
                const cx = t.mapToItem(null, t.width / 2, 0).x;
                Popups.open("dock", win.screen.name, cx, win.screen.height - Tokens.dockBottomMargin - shelfHeight - Tokens.dockMenuTailGap - Tokens.dockMenuTailHeight, "above", {
                    key: item.key,
                    entry: item.entry,
                    pinned: item.pinned,
                    running: item.windows.length > 0,
                    windows: item.windows
                });
            }

            screen: modelData
            anchors {
                bottom: true
                left: true
                right: true
            }
            implicitHeight: shelfHeight + Tokens.dockBottomMargin + overhang + Math.max(tooltipArea, Tokens.dockDragArea)
            exclusiveZone: DockModel.reservedHeight(dockMetrics, autohide)
            color: "transparent"
            focusable: true
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: root.keyboardMode && win.screen.name === root.keyboardScreen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-dock"
            // Only the dock itself (or the reveal strip while hidden) takes input.
            // qmllint disable missing-type
            mask: Region {
                item: hitItem
            }
            BackgroundEffect.blurRegion: shelf.blurActive ? blurRegion : null
            // qmllint enable missing-type

            Region {
                id: blurRegion
                item: shelf
                radius: shelf.radius
            }

            // Rectangle (global layout coordinates) of the minimized tile `index` (0 = first right of the
            // separator): where that window lands (minimize, `adding`: the tile does not exist yet and is
            // appended before the Trash) or leaves from (restore). Called by Compositor for this screen.
            function tileRect(index: int, adding: bool, toplevel: var): var {
                const sep = root.items.findIndex(it => it.kind === "separator" && !it.divider);
                const mon = Compositor.monitorByName(win.screen.name);
                if (Settings.dockMinimizeIntoApp && toplevel && mon) {
                    // Minimize into the application icon: the window goes to (and comes from) its app's tile.
                    const at = root.items.findIndex(it => it.kind === "app" && it.windows.indexOf(toplevel) >= 0);
                    if (at >= 0) {
                        return {
                            x: mon.x + baseCenters[at] - iconSize / 2,
                            y: mon.y + win.screen.height - Tokens.dockBottomMargin - shelfHeight + Tokens.dockPadding,
                            w: iconSize,
                            h: iconSize
                        };
                    }
                }
                if (sep < 0 || !mon || index < 0)
                    return null;
                const w = widths.slice();
                if (adding)
                    w.splice(sep + 1 + index, 0, iconSize);
                const slot = Magnify.centersFor(w, Tokens.dockSpacing, (width - Magnify.totalWidth(w, Tokens.dockSpacing)) / 2)[sep + 1 + index];
                if (slot === undefined)
                    return null;
                return {
                    x: mon.x + slot - iconSize / 2,
                    y: mon.y + win.screen.height - Tokens.dockBottomMargin - shelfHeight + Tokens.dockPadding,
                    w: iconSize,
                    h: iconSize
                };
            }

            // modelData is already null when a removed screen destroys this window: keep the name.
            property string screenName: ""
            Component.onCompleted: {
                screenName = win.modelData.name;
                Compositor.registerDock(screenName, win);
            }
            Component.onDestruction: Compositor.unregisterDock(screenName, win)

            Behavior on influence {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                    easing.type: Easing.OutQuad
                }
            }

            onPointerActiveChanged: {
                if (pointerActive) {
                    hideTimer.stop();
                    revealedState = true;
                    Trash.refresh();
                } else {
                    hideTimer.restart();
                }
            }

            Timer {
                id: hideTimer
                interval: Tokens.dockHideDelay
                onTriggered: win.revealedState = false
            }

            Item {
                id: area
                anchors.fill: parent

                HoverHandler {
                    id: areaHover
                    // Using the pointer leaves keyboard mode (focus returns to the app).
                    onPointChanged: {
                        if (hovered)
                            PointerTracker.report(win.screen.name, point.position.x, win.screen.height - win.height + point.position.y);
                        if (hovered && root.keyboardMode)
                            root.keyboardMode = false;
                    }
                }

                // Input area: the shelf (plus magnified icons and tooltips while hovered), or the
                // bottom strip while the dock is hidden.
                Item {
                    id: hitItem
                    x: win.revealed ? shelf.x : 0
                    width: win.revealed ? shelf.width : win.width
                    height: win.revealed ? (win.dragFrom >= 0 ? win.height : (win.pointerActive ? win.shelfHeight + Tokens.dockBottomMargin + win.overhang + win.tooltipArea : win.shelfHeight + Tokens.dockBottomMargin)) : Tokens.dockRevealZone
                    y: win.height - height
                }

                // Removal puff.
                Item {
                    id: poofLayer
                    visible: win.poofProgress < 1
                    z: 50

                    Repeater {
                        model: 7

                        delegate: Rectangle {
                            id: puff

                            required property int index
                            readonly property real angle: index === 6 ? 0 : index * Math.PI / 3
                            readonly property real reach: index === 6 ? 0 : win.poofProgress * Tokens.dockPoofSize / 2
                            width: Tokens.dockPoofSize * (index === 6 ? Tokens.dockPoofCoreScale : Tokens.dockPoofPuffScale) * (Tokens.dockPoofGrowFrom + win.poofProgress)
                            height: width
                            radius: width / 2
                            x: win.poofX + Math.cos(angle) * reach - width / 2
                            y: win.poofY + Math.sin(angle) * reach - height / 2
                            color: Appearance.withAlpha(Appearance.colors.materialHighlight, Tokens.dockPoofOpacity * (1 - win.poofProgress))
                        }
                    }
                }

                Material {
                    id: shelf
                    width: win.shelfWidth
                    height: win.shelfHeight
                    x: (win.width - width) / 2
                    y: win.height - Tokens.dockBottomMargin - height + (win.revealed ? 0 : height + Tokens.dockBottomMargin + shadowMargin)
                    radius: Tokens.radiusDock
                    tintAlphaOverride: Appearance.dark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight
                    highlightOpacity: Tokens.dockHighlightOpacity
                    borderOpacity: Tokens.dockRimOpacity
                    borderColor: Appearance.colors.materialHighlight

                    Behavior on y {
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }

                    Row {
                        id: tiles
                        x: Tokens.dockPadding
                        y: Tokens.dockPadding
                        spacing: Tokens.dockSpacing

                        Repeater {
                            id: tileRepeater
                            model: tileModel

                            delegate: Item {
                                id: tile

                                required property string tileId
                                required property int index
                                readonly property var modelData: root.itemByKey[tileId] !== undefined ? root.itemByKey[tileId] : ({kind: "", windows: []})

                                readonly property real tileScale: win.scaleList[index] !== undefined ? win.scaleList[index] : 1
                                readonly property bool isApp: modelData.kind === "app"
                                readonly property bool isTrash: modelData.kind === "trash"
                                readonly property bool isSeparator: modelData.kind === "separator"
                                readonly property bool isMinimized: modelData.kind === "minimized"
                                readonly property bool running: isApp && modelData.windows.length > 0
                                readonly property string label: isTrash ? qsTr("Trash") : (isApp || isMinimized ? modelData.name : "")
                                readonly property real iconPx: win.iconSize * tileScale
                                readonly property bool dragging: win.dragFrom === index
                                readonly property bool bouncing: isApp && !running && root.launching[modelData.key] !== undefined && !Appearance.reduceMotion
                                readonly property int badge: isApp ? DockModel.badgeCount(Notifications.history, modelData) : 0
                                // Neighbours of a dragged tile make room (or close the gap while it is dragged out).
                                readonly property real shiftX: {
                                    if (win.dragFrom < 0 || index === win.dragFrom)
                                        return 0;
                                    if (win.dragCollapsing)
                                        return index > win.dragFrom ? -win.pitch : 0;
                                    const from = win.dragFromApp;
                                    const at = win.appItems.indexOf(index);
                                    if (from < 0 || at === from || !isApp)
                                        return 0;
                                    const slot = win.dragSlot;
                                    if (from < slot && at > from && at <= slot)
                                        return -win.pitch;
                                    if (slot < from && at >= slot && at < from)
                                        return win.pitch;
                                    return 0;
                                }

                                // Layout transition: horizontal offset gliding to 0, and the fade-in of a new tile.
                                property real glide: 0
                                property real glideY: 0
                                // The make-room offset animates while a tile is dragged; it snaps at the release, together
                                // with the layout change.
                                property real shiftAnim: shiftX
                                Behavior on shiftAnim {
                                    enabled: !tile.dragging && !win.dragSnap
                                    NumberAnimation {
                                        duration: Appearance.duration(Tokens.motionFast)
                                        easing.type: Easing.OutQuad
                                    }
                                }
                                function glideFrom(dx: real, dy: real): void {
                                    glide = dx;
                                    glideY = dy;
                                    glideAnim.restart();
                                    glideYAnim.restart();
                                }
                                function fadeIn(): void {
                                    opacity = 0;
                                    fadeAnim.restart();
                                }

                                NumberAnimation {
                                    id: glideAnim
                                    target: tile
                                    property: "glide"
                                    to: 0
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Appearance.curve
                                }

                                NumberAnimation {
                                    id: glideYAnim
                                    target: tile
                                    property: "glideY"
                                    to: 0
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.BezierSpline
                                    easing.bezierCurve: Appearance.curve
                                }

                                NumberAnimation {
                                    id: fadeAnim
                                    target: tile
                                    property: "opacity"
                                    to: 1
                                    duration: Appearance.duration(Tokens.motionNormal)
                                    easing.type: Easing.OutQuad
                                }

                                width: isSeparator ? win.separatorWidth : iconPx
                                height: win.iconSize + win.indicatorArea
                                z: dragging ? 100 : 0
                                // The shelf closes a gap around its centre: the dragged tile compensates to stay under the pointer.
                                transform: Translate {
                                    x: tile.dragging ? win.dragDx - win.dragCollapse * win.pitch / 2 : tile.shiftAnim + tile.glide
                                    y: tile.dragging ? win.dragDy : tile.glideY
                                }
                                activeFocusOnTab: !isSeparator
                                Accessible.role: isSeparator ? Accessible.Separator : Accessible.Button
                                Accessible.name: isTrash ? (Trash.empty ? qsTr("Trash, empty") : qsTr("Trash, contains items")) : (isMinimized ? qsTr("%1, minimized").arg(label) : ((running ? qsTr("%1, running").arg(label) : label) + (badge > 0 ? (badge === 1 ? qsTr(", 1 notification") : qsTr(", %1 notifications").arg(badge)) : "")))
                                Accessible.focusable: !isSeparator
                                Accessible.ignored: isSeparator
                                Accessible.onPressAction: root.activateItem(modelData)
                                Keys.onReturnPressed: root.activateItem(modelData)
                                Keys.onEnterPressed: root.activateItem(modelData)
                                Keys.onSpacePressed: root.activateItem(modelData)
                                Keys.onEscapePressed: root.keyboardMode = false
                                Keys.onLeftPressed: (tile.nextItemInFocusChain(false) as Item).forceActiveFocus()
                                Keys.onRightPressed: (tile.nextItemInFocusChain(true) as Item).forceActiveFocus()
                                Keys.onMenuPressed: win.openMenu(index)

                                // Separator hairline.
                                Rectangle {
                                    visible: tile.isSeparator
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea - (height - win.iconSize) / 2
                                    width: Tokens.dockSeparatorWidth
                                    height: Tokens.dockSeparatorHeight
                                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                                }

                                // Application icon, growing upward from the shelf.
                                TintedIcon {
                                    id: appIcon
                                    visible: tile.isApp
                                    size: win.iconSize
                                    // Default mode is decoded as before; an effect mode decodes at the largest magnification so the
                                    // fixed-size texture is never upscaled.
                                    oversample: appIcon.modeActive ? Tokens.dockIconOversample : appIcon.defaultOversample
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    source: tile.isApp ? Quickshell.iconPath(tile.modelData.icon, "application-x-executable") : ""

                                    // Launch bounce: hops until the app has a window (or the launch timeout).
                                    property real lift: 0
                                    transform: Translate {
                                        y: -appIcon.lift
                                    }

                                    SequentialAnimation {
                                        running: tile.bouncing
                                        loops: Animation.Infinite
                                        // The hop ends by landing (a few small rebounds), not by snapping back.
                                        onRunningChanged: {
                                            if (running)
                                                landAnim.stop();
                                            else if (appIcon.lift > 0)
                                                landAnim.restart();
                                        }

                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: Tokens.dockBounceHeight
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.OutQuad
                                        }
                                        NumberAnimation {
                                            target: appIcon
                                            property: "lift"
                                            to: 0
                                            duration: Tokens.dockBounceDuration / 2
                                            easing.type: Easing.InQuad
                                        }
                                    }

                                    NumberAnimation {
                                        id: landAnim
                                        target: appIcon
                                        property: "lift"
                                        to: 0
                                        duration: Appearance.duration(Tokens.motionNormal)
                                        easing.type: Easing.OutBounce
                                    }

                                    // Notification badge (counts from the notification history).
                                    Rectangle {
                                        visible: tile.badge > 0
                                        height: Tokens.dockBadgeSize
                                        width: Math.max(height, badgeLabel.implicitWidth + Tokens.spacingSm)
                                        radius: height / 2
                                        color: Appearance.colors.destructive
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.rightMargin: -Tokens.dockBadgeOverhang
                                        anchors.topMargin: -Tokens.dockBadgeOverhang

                                        Text {
                                            id: badgeLabel
                                            textFormat: Text.PlainText
                                            anchors.centerIn: parent
                                            text: DockModel.badgeText(tile.badge)
                                            color: Appearance.colors.destructiveText
                                            font.family: Appearance.fontFamily
                                            font.pixelSize: Tokens.typographyCaptionSize
                                            font.weight: Tokens.typographyMenuBoldWeight
                                        }
                                    }
                                }

                                // Minimized window: live thumbnail with the app icon badge in the
                                // `full` material profile, the app icon alone otherwise.
                                Item {
                                    id: minimizedTile
                                    visible: tile.isMinimized
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea

                                    readonly property bool live: Settings.materialProfile === "full"
                                    readonly property string iconSource: tile.isMinimized ? Quickshell.iconPath(tile.modelData.icon, "application-x-executable") : ""

                                    Rectangle {
                                        visible: minimizedTile.live
                                        anchors.fill: parent
                                        radius: Tokens.radiusDockIcon * tile.tileScale
                                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                                        clip: true

                                        ScreencopyView {
                                            id: thumb
                                            // Fit inside the tile keeping the aspect ratio.
                                            readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : 1
                                            width: ratio >= 1 ? parent.width : parent.height * ratio
                                            height: ratio >= 1 ? parent.width / ratio : parent.height
                                            anchors.centerIn: parent
                                            captureSource: minimizedTile.live && tile.isMinimized ? tile.modelData.toplevel : null
                                            live: true
                                            paintCursor: false
                                        }
                                    }

                                    TintedIcon {
                                        size: win.iconSize
                                        width: minimizedTile.live ? Math.round(parent.width * Tokens.dockMinimizedBadgeScale) : parent.width
                                        height: width
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        source: minimizedTile.iconSource
                                    }
                                }

                                // Trash: the icon theme's user-trash / user-trash-full (never hand-drawn), in the user's icon
                                // mode; a symbolic glyph on a rounded tile when the theme has neither.
                                TintedIcon {
                                    id: trashThemed
                                    readonly property string themed: Quickshell.iconPath(Trash.empty ? "user-trash" : "user-trash-full", true)
                                    visible: tile.isTrash && themed !== ""
                                    size: win.iconSize
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    source: tile.isTrash ? themed : ""
                                }

                                Rectangle {
                                    id: trashIcon
                                    visible: tile.isTrash && trashThemed.themed === ""
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    radius: Tokens.radiusDockIcon * tile.tileScale
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                                    Icon {
                                        anchors.centerIn: parent
                                        size: Math.round(tile.iconPx * Tokens.dockTrashIconScale)
                                        name: Trash.empty ? "trash" : "trash-full"
                                    }
                                }

                                // Keyboard focus ring.
                                Rectangle {
                                    visible: tile.activeFocus && root.keyboardMode && !tile.isSeparator
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    radius: Tokens.radiusDockIcon * tile.tileScale
                                    color: "transparent"
                                    border.width: Tokens.controlFocusRing
                                    border.color: Appearance.colors.accent
                                }

                                // Running indicator.
                                Rectangle {
                                    visible: tile.running
                                    width: Tokens.dockIndicatorSize
                                    height: Tokens.dockIndicatorSize
                                    radius: width / 2
                                    color: Appearance.colors.indicator
                                    x: (tile.width - width) / 2
                                    y: win.iconSize + Tokens.dockSpacing
                                }

                                Tooltip {
                                    id: tooltip
                                    z: 10
                                    tail: true
                                    text: tile.dragging ? qsTr("Remove") : tile.label
                                    delay: 0
                                    shown: tile.dragging ? (win.dragOut && win.dragRemovable) : (tile.label !== "" && (tileHover.hovered || (tile.activeFocus && root.keyboardMode)) && !Popups.active && win.dragFrom < 0)
                                    x: (tile.width - width) / 2
                                    y: tile.height - win.indicatorArea - tile.iconPx - Tokens.dockTooltipGap - height
                                }

                                HoverHandler {
                                    id: tileHover
                                    enabled: !tile.isSeparator
                                    cursorShape: Qt.ArrowCursor
                                }

                                // Files dropped on the Trash tile (from the desktop icons or any
                                // application offering text/uri-list) are moved to the trash.
                                DropArea {
                                    id: trashDrop
                                    anchors.fill: parent
                                    enabled: tile.isTrash
                                    keys: ["text/uri-list"]
                                    onDropped: drop => {
                                        drop.accept(Qt.MoveAction);
                                        const paths = Icons.parseUriList(drop.getDataAsString("text/uri-list"));
                                        if (paths.length > 0)
                                            Apps.openDetached(["gio", "trash", "--"].concat(paths)); // isolated trash in dev (ADR-0011)
                                    }
                                }

                                // Drop highlight on the Trash tile.
                                Rectangle {
                                    visible: tile.isTrash && trashDrop.containsDrag
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    radius: Tokens.radiusDockIcon * tile.tileScale
                                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconSelectionOpacity)
                                }

                                // Files dropped on an app tile are opened with that app.
                                DropArea {
                                    id: appDrop
                                    anchors.fill: parent
                                    enabled: tile.isApp && !!tile.modelData.entry
                                    keys: ["text/uri-list"]
                                    // The tile highlights and accepts only a document its app can open (file field code
                                    // in Exec and a matching MimeType). The real type of every path (a folder may carry an extension)
                                    // is looked up while hovering (Apps.hoverEnter, cached for the drag): until it is known the tile
                                    // accepts without highlighting, once known a refused file is refused at the DnD level too (the source
                                    // gets a cancel). A source that hands its URI list over only at the drop leaves the verdict unknown.
                                    property var paths: []
                                    readonly property string verdict: paths.length === 0 ? "unknown" : Apps.hoverVerdict(tile.modelData.entry, paths)
                                    readonly property bool acceptable: verdict === "yes" || verdict === "unknown"
                                    function read(drag: var): void {
                                        if (paths.length > 0)
                                            return;
                                        const found = Icons.parseUriList(drag.getDataAsString("text/uri-list"));
                                        if (found.length === 0)
                                            return;
                                        paths = found;
                                        Apps.hoverEnter(tile.modelData.entry, found);
                                    }
                                    onEntered: drag => {
                                        paths = [];
                                        read(drag);
                                        drag.accepted = verdict !== "no";
                                    }
                                    onPositionChanged: drag => {
                                        read(drag);
                                        drag.accepted = verdict !== "no";
                                    }
                                    onExited: {
                                        paths = [];
                                        Apps.hoverLeave();
                                    }
                                    onDropped: drop => {
                                        const found = Icons.parseUriList(drop.getDataAsString("text/uri-list"));
                                        paths = [];
                                        if (found.length > 0 && Apps.dropOnApp(tile.modelData.entry, found))
                                            drop.accept(Qt.CopyAction);
                                        else
                                            drop.accepted = false;
                                    }
                                }

                                Rectangle {
                                    visible: tile.isApp && appDrop.containsDrag && appDrop.acceptable && appDrop.verdict !== "pending"
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    radius: Tokens.radiusDockIcon * tile.tileScale
                                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.dockDropHighlightOpacity)
                                }

                                // Drag to reorder; dragged far above the shelf it leaves the Dock (poof).
                                DragHandler {
                                    id: dragHandler
                                    enabled: tile.isApp
                                    target: null
                                    cursorShape: Qt.ClosedHandCursor
                                    onActiveChanged: {
                                        if (active) {
                                            win.dragSnap = false;
                                            win.dragFrom = tile.index;
                                            win.dragDx = 0;
                                            win.dragDy = 0;
                                        } else if (win.dragFrom === tile.index) {
                                            win.finishDrag(tile);
                                        }
                                    }
                                    onTranslationChanged: {
                                        if (active) {
                                            win.dragDx = translation.x;
                                            // Never above the point where the "Remove" label would leave the window.
                                            const iconTop = win.height - Tokens.dockBottomMargin - Tokens.dockPadding - win.indicatorArea - tile.iconPx;
                                            win.dragDy = Math.max(translation.y, -(iconTop - Tokens.dockTooltipGap - tooltip.height));
                                        }
                                    }
                                }

                                TapHandler {
                                    enabled: !tile.isSeparator
                                    acceptedButtons: Qt.LeftButton
                                    onTapped: root.activateItem(tile.modelData)
                                }

                                TapHandler {
                                    enabled: tile.isApp
                                    acceptedButtons: Qt.RightButton
                                    onTapped: win.openMenu(tile.index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
