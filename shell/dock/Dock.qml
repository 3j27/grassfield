pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.notifications
import qs.platform
import qs.services
import "DockModel.js" as DockModel
import "Launch.js" as Launch
import "../desktop/IconsLogic.js" as Icons
import "AutoHide.js" as AutoHide
import "Magnify.js" as Magnify

// Bottom dock, one per screen: pinned apps (Settings) and running apps (foreign-toplevel app ids
// mapped to desktop entries), a separator and the Trash. Click launches, focuses the most recent
// window or cycles windows; right click opens the item menu. Magnification and autohide follow
// Settings (dock.magnification, dock.autohide) and Reduce Motion.
Scope {
    id: root

    // [{kind, key, name, icon, entry, windows, pinned}], rebuilt when apps/toplevels/pins change.
    property var items: []

    // The first tile is "Apps" (macOS 26: Launchpad became Apps and keeps its Dock tile). The shell root opens the panel.
    signal appsRequested
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

    // Time of the last launch click (ms); with the visual fixtures the bounce curve is logged against it (tests/visual/dock-launch.sh).
    property real launchClickedAt: 0

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
        // Files is the fixed first tile: out of the pinned list and the recents, its windows ride on the fixed tile.
        const split = DockModel.splitFiles(DockModel.merge(DockModel.withoutFiles(Settings.dockPinned), running, Apps.lookup), Apps.lookup);
        const apps = split.rest;
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
        const shown = ready && Settings.dockShowRecents ? DockModel.withRecents(apps, Settings.dockRecent, Apps.lookup, Tokens.dockRecentMax, e => Apps.isListed(e) && !DockModel.isFilesId(e.id)) : apps;
        const tail = Settings.dockMinimizeIntoApp ? [] : DockModel.minimizedItems(Compositor.minimized, Apps.lookup);
        const all = windows.instances;
        all.forEach(w => w.captureLayout());
        setItems(DockModel.withFixed(split.files, DockModel.withTail(shown, tail)));
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
        if (!item.entry) {
            // Files without its desktop entry (not installed): its home folder through the open policy.
            if (item.kind === "files")
                Apps.openDetached(["gio", "open", Quickshell.env("HOME")]);
            return;
        }
        // A second click while the tile bounces does nothing (no double launch).
        const click = Launch.click(launching, item.key, Date.now(), Tokens.dockLaunchTimeout);
        if (!click.start)
            return;
        launchClickedAt = Date.now();
        Apps.launch(item.entry);
        launching = click.launching;
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
        if (item.kind === "apps") {
            root.appsRequested();
            return;
        }
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
        // macOS: every window of the app comes forward, the most recent one ends focused; with everything minimized, the most
        // recent one is restored (Launch.activationPlan). A click on the focused app does not cycle its windows.
        const plan = Launch.activationPlan(item.windows.map(t => Compositor.windowInfo(t)));
        for (const top of plan)
            Compositor.activate(top);
    }

    Component.onCompleted: rebuild()

    // Drag-out removal follows "cancel on interruption": anything that can take the pointer or the focus during a tile drag marks the
    // drag interrupted (win.dragInterrupted), and an interrupted drag never removes its tile (it glides back). Events only. The
    // Dock's own drag feedback (Remove label, puff, tooltip) is inside its window and reports none of these.
    // Counts every interruption event, drag or not: a press records it when the button goes down, and a drag that starts later in the same
    // press keeps any interruption seen since (starting a drag never clears one).
    property int dragInterruptions: 0

    function interruptDrag(): void {
        dragInterruptions++;
        const all = windows.instances;
        for (let i = 0; i < all.length; i++) {
            if (all[i].dragFrom >= 0)
                all[i].dragInterrupted = true;
        }
    }

    // CLICK CANCELLATION, its own short list (not the drag-out list above: that one over-cancels on purpose, owner batch 7, and a window
    // retitling every few milliseconds must not eat Dock clicks). A press on a tile is taken away from the Dock, and its release never
    // clicks, only when:
    //   1. a shell surface opens over the Dock (Search, Overview, Apps, the switcher, a Dock or menu-bar menu, Notification Center,
    //      Control Center): FocusReturn.surfaceOpened, and Popups.kind switching to a popup;
    //   2. the session locks (FocusReturn.lockedChanged);
    //   3. Qt cancels the grab or the pointer leaves the tile's handler (TapHandler.canceled / a cancelled grab, in the delegate).
    // Window titles, focus changes and windows closing are NOT in the list (a window OPENING ends a held press in Qt, see lastWindowEvent).
    // A tile records clickCancels when its button goes down and refuses its tap when the value changed.
    property int clickCancels: 0

    // Time (ms) of the last window OPENING (an insertion into the window list; a closing never ends a press). Qt ends a held press with a synthesized release, and a
    // tap, when a window opens (nested probe: pressed, toplevels-changed, 35 ms later tap + release with grab state 8, no hover or cancel
    // event, nothing that tells it from a real release). A press that began before such an event and whose tap comes within
    // Tokens.dockClickWindowGuard of it is refused: it was not finished by the user. A real click that coincides with a window opening
    // within that time is lost and costs one repeated click.
    property real lastWindowEvent: 0

    // Fixtures only (IPC dock forcehold): every press on an app tile counts as having opened the hold menu at once (no popup), so a test
    // gets "menu first, then the drag of the same press" deterministically instead of racing a hook against the 550 ms timer.
    property bool forceHoldMenu: false

    // Fixtures only (IPC dock forceinterrupt): every press on an app tile is interrupted (one interruption event, no popup, no menu) the
    // moment it goes down, so a test reaches "interrupted before the drag starts" without racing a real surface against the drag.
    property bool forceInterrupt: false

    function cancelClicks(): void {
        clickCancels++;
        if (VisualFixtures.active)
            console.info("dock-launch: click-cancel", Date.now());
    }

    onKeyboardModeChanged: interruptDrag()

    // A shell full-attention surface opened (Search, Apps, switcher, popup host, Notification Center, widget menu, Overview).
    Connections {
        target: FocusReturn

        function onSurfaceOpened(name: string): void {
            root.interruptDrag();
            root.cancelClicks();
        }

        function onSurfaceClosed(name: string): void {
            root.interruptDrag();
        }

        // The session lock.
        function onLockedChanged(): void {
            root.interruptDrag();
            root.cancelClicks();
        }
    }

    // Any shell popup (Dock menu, menu-bar menus, Control Center, ...) opening, switching or closing.
    Connections {
        target: Popups

        function onKindChanged(): void {
            root.interruptDrag();
            if (Popups.kind !== "")
                root.cancelClicks();
        }
    }

    // Windows, workspaces, monitors and layers of the session (Hyprland events, relayed by the platform layer).
    Connections {
        target: Compositor

        function onInterrupted(event: string): void {
            root.interruptDrag();
        }

        function onFocusedToplevelChanged(): void {
            root.interruptDrag();
        }

        function onFocusedScreenNameChanged(): void {
            root.interruptDrag();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.interruptDrag();
        }
    }

    Connections {
        target: Compositor.toplevels

        function onValuesChanged(): void {
            root.interruptDrag();
            root.rebuild();
        }

        // Only a window OPENING makes Qt end a held press (nested probe); a window closing never did (3 of 3 clicks tapped).
        function onObjectInsertedPost(object: var, index: int): void {
            root.lastWindowEvent = Date.now();
            if (VisualFixtures.active)
                console.info("dock-launch: toplevel-inserted", Date.now());
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

    // Test hooks: qs ipc call dock <hover|unhover|reveal|autohide|magnify|click|keyboard|menu|pinned|tiles|centre|popup|holdmenu|forcehold|forceinterrupt>. autohide, magnify, click
    // and pinned (read-only) act only with the visual fixtures (dev, --visual-fixtures); elsewhere they are inert.
    IpcHandler {
        target: "dock"

        // The kept apps (JSON list) from the live settings: the drag stress test asserts it never changes.
        function pinned(): string {
            if (!VisualFixtures.active)
                return "[]";
            return JSON.stringify(Settings.dockPinned);
        }

        function forceinterrupt(on: bool): void {
            if (VisualFixtures.active)
                root.forceInterrupt = on;
        }

        // Fixtures only: while on, every press on an app tile is marked as having opened the hold menu at the moment it goes down.
        function forcehold(on: bool): void {
            if (VisualFixtures.active)
                root.forceHoldMenu = on;
        }

        // The press held on tile `index` becomes a hold menu without a popup (fixtures only): the press is marked as having opened the menu
        // and the interruption a popup opening causes is recorded, in this order, before any drag of the press starts. A real hold menu
        // takes the pointer and usually ends the press; only a stalled GUI thread lets the drag of the same press follow (reviewer: menu
        // +6569 ms, drag +27 ms later), and that order cannot be forced from outside, so the hook forces the state it leaves behind.
        function holdmenu(index: int, screen: string): void {
            if (!VisualFixtures.active)
                return;
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            if (win)
                win.markHoldMenu(index);
        }

        // Kind of the open shell popup ("" when none; fixtures only): tests close menus before a part.
        function popup(): string {
            return VisualFixtures.active ? Popups.kind : "";
        }

        // Keys of the tiles in order (JSON list), the index `click` takes (fixtures only).
        function tiles(): string {
            if (!VisualFixtures.active)
                return "[]";
            return JSON.stringify(root.items.map(i => i.key !== undefined ? i.key : i.kind));
        }

        function hover(x: real): void {
            root.testPointerX = x;
        }

        function unhover(): void {
            root.testPointerX = -1;
        }

        // Auto-hide machine state and visible fraction "state visible" (fixtures only).
        function hidestate(screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    return all[i].hideMachine.state + " " + all[i].hideMachine.visible.toFixed(3);
            }
            return "";
        }

        function reveal(on: bool): void {
            root.testReveal = on;
        }

        function autohide(on: bool): void {
            if (!VisualFixtures.active)
                return;
            Settings.setDockAutohide(on);
        }

        function magnify(factor: real, enabled: bool): void {
            if (!VisualFixtures.active)
                return;
            Settings.setDockMagnification(factor, enabled);
        }

        // Same code path as a click on item `index`.
        function click(index: int): void {
            if (VisualFixtures.active && root.items[index])
                root.activateItem(root.items[index]);
        }

        // Centre "x y" of tile `index` on `screen` in output coordinates (fixtures only; the magnification must be off).
        function centre(index: int, screen: string): string {
            if (!VisualFixtures.active)
                return "";
            const all = windows.instances;
            let win = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    win = all[i];
            }
            return win ? win.tileCentre(index) : "";
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
            // How far above its press point a tile must be to leave the Dock (outside the drop zone: the shelf and the room around it).
            readonly property real dragOutReach: Tokens.dockPadding + iconSize / 2 + Tokens.dockDragOutDistance
            readonly property bool dragOut: dragFrom >= 0 && dragDy < -dragOutReach
            // Set ONLY by the drag handler when the pointer button is really released (exclusive grab ended by a release event)
            // away from the drop zone. Every other end of a drag (cancelled or stolen grab) leaves it false.
            property bool releasedOutside: false
            // Set by root.interruptDrag() and by a cancelled or stolen grab, cleared when a drag ends: something took the pointer or the
            // focus during the drag (a shell surface, a popup, the lock, a window, workspace or monitor event, Esc in keyboard mode). Qt
            // then ends the drag with a synthesized release that looks real, so an interrupted drag changes no pins (no removal, no
            // reorder): the tile glides back. A press that was already interrupted when the drag would start does not start it at all.
            property bool dragInterrupted: false
            readonly property bool dragRemovable: dragFrom >= 0 && !!root.items[dragFrom] && (root.items[dragFrom].pinned || root.items[dragFrom].recent === true) && root.items[dragFrom].windows.length === 0
            property real poofX: 0
            property real poofY: 0
            property real poofProgress: 1

            // A tile is removed only when ALL hold: releasedOutside was set by a positive release event outside the Dock's drop zone,
            // the live drag offset agrees, the item can be removed and the drag was not interrupted. A release inside the shelf never
            // removes (macOS).
            function finishDrag(tileItem: Item): void {
                const from = dragFrom;
                const all = root.items;
                const item = all[from];
                const out = releasedOutside && !dragInterrupted && dragOut && dragRemovable;
                const dragOutNotReleased = !out && dragOut && dragRemovable;
                const interrupted = dragInterrupted;
                const slot = dragSlot;
                const fromApp = dragFromApp;
                releasedOutside = false;
                dragInterrupted = false;
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
                if (dragOutNotReleased || interrupted) {
                    // Dragged out but not released out there, or interrupted by anything: no pin changes (no removal, no reorder), the
                    // tile glides back to its slot.
                    tileItem.glideFrom(dx, dy);
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
            // Magnification: the target scales of the pointer (all 1 without it) and the displayed ones, which follow them
            // with a frame-rate independent exponential smoothing (Magnify.step; Reduce Motion snaps).
            readonly property var separatorFlags: root.items.map(it => it.kind === "separator")
            readonly property var targetScales: pointerActive ? Magnify.slotScales(baseCenters, widths, Tokens.dockSpacing, separatorFlags, pointerX, pitch, maxScale, Tokens.dockMagnificationRadius) : widths.map(() => 1)
            property var smoothScales: []
            readonly property var scaleList: widths.map((w, i) => smoothScales[i] !== undefined ? smoothScales[i] : 1)
            readonly property real shelfWidth: Magnify.totalWidth(widths.map((w, i) => w * scaleList[i]), Tokens.dockSpacing) + 2 * Tokens.dockPadding - dragCollapse * pitch

            // Autohide state machine (AutoHide.js, table in docs/specs/dock.md): inhibitors keep the shelf shown.
            property int pressedTile: -1
            property var hideMachine: AutoHide.create()
            readonly property var hideInhibitors: ({
                    pointer: pointerActive,
                    drag: dragFrom >= 0,
                    popup: Popups.kind === "dock",
                    hold: pressedTile >= 0,
                    keyboard: root.keyboardMode,
                    forced: root.testReveal
                })
            readonly property var hideTiming: ({
                    hideGrace: Tokens.dockHideGrace,
                    hideDuration: Appearance.duration(Tokens.dockHideDuration),
                    revealDwell: Tokens.dockRevealDwell,
                    revealDuration: Appearance.duration(Tokens.dockRevealDuration)
                })
            // The input area is the shelf unless the machine is fully hidden (then only the edge strip takes input).
            readonly property bool revealed: !autohide || hideMachine.state !== "hidden" || AutoHide.forcing(hideInhibitors)
            // Tooltips: after one was shown, the next icon labels at once for a while.
            property bool tipsWarm: false

            function focusFirstTile(): void {
                for (let i = 0; i < tileRepeater.count; i++) {
                    const t = tileRepeater.itemAt(i) as Item;
                    if (t && t.activeFocusOnTab) {
                        t.forceActiveFocus();
                        return;
                    }
                }
            }

            // Test hook (IPC dock holdmenu): the pressed tile `index` counts as having opened the hold menu.
            function markHoldMenu(index: int): void {
                const t = tileRepeater.itemAt(index);
                if (!t)
                    return;
                t.menuByHold = true;
                root.interruptDrag();
                console.info("dock-launch: menu-by-hold (forced)", Date.now());
            }

            // "x y" of the icon centre of tile `index`, in output coordinates (test hook).
            function tileCentre(index: int): string {
                const t = tileRepeater.itemAt(index);
                if (!t)
                    return "";
                const p = t.mapToItem(null, t.width / 2, t.height - indicatorArea - t.iconPx / 2);
                return Math.round(p.x) + " " + Math.round(screen.height - height + p.y);
            }

            function openMenu(index: int): void {
                root.keyboardMode = false;
                const item = root.items[index];
                if (!item || (item.kind !== "app" && item.kind !== "files"))
                    return;
                const t = tileRepeater.itemAt(index);
                const cx = t.mapToItem(null, t.width / 2, 0).x;
                Popups.open("dock", win.screen.name, cx, win.screen.height - Tokens.dockBottomMargin - shelfHeight - Tokens.dockMenuTailGap - Tokens.dockMenuTailHeight, "above", {
                    key: item.key,
                    entry: item.entry,
                    pinned: item.pinned,
                    running: item.windows.length > 0,
                    fixed: item.fixed === true,
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
                    const at = root.items.findIndex(it => (it.kind === "app" || it.kind === "files") && it.windows.indexOf(toplevel) >= 0);
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

            onPointerActiveChanged: {
                if (pointerActive)
                    Trash.refresh();
            }

            // Frame clock of the magnification: runs only until the displayed scales reach their targets.
            FrameAnimation {
                running: !Magnify.settled(win.smoothScales, win.targetScales, 0.0005)
                onTriggered: {
                    let next = Magnify.step(win.smoothScales, win.targetScales, frameTime * 1000, Appearance.reduceMotion ? 0 : Tokens.dockMagnificationTau, Tokens.dockMagnificationMaxDt);
                    if (Magnify.settled(next, win.targetScales, 0.0005))
                        next = win.targetScales.slice();
                    win.smoothScales = next;
                }
            }

            // Frame clock of the auto-hide machine: stops while nothing can change (hidden and idle, or shown and held).
            FrameAnimation {
                running: AutoHide.active(win.hideMachine, win.hideInhibitors, win.autohide)
                onTriggered: win.hideMachine = AutoHide.step(win.hideMachine, win.hideInhibitors, win.autohide, win.hideTiming, Math.min(frameTime * 1000, 100))
            }

            Timer {
                id: tipsWarmTimer
                interval: Tokens.dockTooltipWarm
                onTriggered: win.tipsWarm = false
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
                    y: win.height - Tokens.dockBottomMargin - height + (1 - AutoHide.ease(win.hideMachine.visible)) * (height + Tokens.dockBottomMargin + shadowMargin)
                    radius: Tokens.radiusDock
                    tintAlphaOverride: Appearance.dark ? Tokens.dockTintAlphaDark : Tokens.dockTintAlphaLight
                    highlightOpacity: Tokens.dockHighlightOpacity
                    borderOpacity: Tokens.dockRimOpacity
                    borderColor: Appearance.colors.materialHighlight

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
                                readonly property bool isFiles: modelData.kind === "files"
                                readonly property bool isApp: modelData.kind === "app" || isFiles
                                readonly property bool isTrash: modelData.kind === "trash"
                                readonly property bool isAppsTile: modelData.kind === "apps"
                                readonly property bool isSeparator: modelData.kind === "separator"
                                readonly property bool isMinimized: modelData.kind === "minimized"
                                readonly property bool running: isApp && modelData.windows.length > 0
                                readonly property string label: isTrash ? qsTr("Trash") : isAppsTile ? qsTr("Apps") : (isApp || isMinimized ? modelData.name : "")
                                readonly property real iconPx: win.iconSize * tileScale
                                readonly property bool dragging: win.dragFrom === index
                                // The button is held on an app tile: the icon darkens slightly (macOS).
                                readonly property bool pressedDown: isApp && leftTap.pressed && !dragging
                                property bool tipSuppressed: false
                                // The hovered state outlives the pointer by Tokens.dockHoverHold, so the label does not flicker
                                // when the pointer crosses the gap between two icons.
                                property bool hoverHeld: false
                                // A magnified icon rises by a small part of its growth (the running dot stays on the shelf).
                                readonly property real hoverLift: win.iconSize * (tileScale - 1) * Tokens.dockMagnificationLift
                                // The Dock menu was opened by holding the button: the release is not a click.
                                property bool menuByHold: false
                                // root.clickCancels when the button went down, and whether Qt cancelled the press (the tap is refused then).
                                property int pressMark: 0
                                property bool pressCancelled: false
                                property real pressTime: 0
                                // root.dragInterruptions when the button went down (a drag of this press starts interrupted when it changed).
                                property int dragMark: 0
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
                                    if (from < 0 || at === from || !isApp || isFiles)
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
                                    y: tile.dragging ? win.dragDy : tile.glideY - tile.hoverLift
                                }
                                activeFocusOnTab: !isSeparator
                                Accessible.role: isSeparator ? Accessible.Separator : Accessible.Button
                                Accessible.name: isAppsTile ? qsTr("Apps") : isTrash ? (Trash.empty ? qsTr("Trash, empty") : qsTr("Trash, contains items")) : (isMinimized ? qsTr("%1, minimized").arg(label) : ((running ? qsTr("%1, running").arg(label) : label) + (badge > 0 ? (badge === 1 ? qsTr(", 1 notification") : qsTr(", %1 notifications").arg(badge)) : "")))
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

                                    // Held button: darker by Tokens.dockPressDim (an offscreen layer only while pressed).
                                    layer.enabled: tile.pressedDown
                                    layer.effect: MultiEffect {
                                        brightness: -Tokens.dockPressDim
                                    }

                                    // Launch bounce: hops until the app has a window (or the launch timeout).
                                    property real lift: 0
                                    onLiftChanged: if (VisualFixtures.active && root.launchClickedAt > 0 && tile.bouncing)
                                        console.info("dock-launch: lift", Date.now() - root.launchClickedAt, Math.round(lift * 10) / 10)
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
                                            to: tile.iconPx * Tokens.dockBounceHeightScale
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
                                }

                                // Notification badge (counts from the notification history). Not a child of the icon: the press-dim layer
                                // would clip the part that overhangs the icon. It hops with the icon.
                                Rectangle {
                                    visible: tile.badge > 0
                                    transform: Translate {
                                        y: -appIcon.lift
                                    }
                                    height: Tokens.dockBadgeSize
                                    width: Math.max(height, badgeLabel.implicitWidth + Tokens.spacingSm)
                                    radius: height / 2
                                    color: Appearance.colors.destructive
                                    anchors.right: appIcon.right
                                    anchors.top: appIcon.top
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
                                        id: minimizedIcon
                                        // The drawn nominal size (the badge is a fraction of the tile when the thumbnail shows), so that
                                        // the minimum size of the icon modes applies to what is on screen.
                                        size: minimizedTile.live ? Math.round(win.iconSize * Tokens.dockMinimizedBadgeScale) : win.iconSize
                                        // The same decode as the tile's icon: an effect mode decodes at the largest magnification.
                                        oversample: minimizedIcon.modeActive ? Tokens.dockIconOversample : minimizedIcon.defaultOversample
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
                                    oversample: trashThemed.modeActive ? Tokens.dockIconOversample : trashThemed.defaultOversample
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

                                // Apps: a rounded tile with the grid glyph (our own symbolic icon, no borrowed artwork).
                                Rectangle {
                                    id: appsTileIcon
                                    visible: tile.isAppsTile
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    radius: Tokens.radiusDockIcon * tile.tileScale
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    color: Appearance.colors.accent

                                    Icon {
                                        anchors.centerIn: parent
                                        size: Math.round(tile.iconPx * Tokens.dockTrashIconScale)
                                        name: "apps"
                                        color: Appearance.colors.accentText
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
                                    y: win.iconSize + Tokens.dockSpacing + tile.hoverLift
                                }

                                Tooltip {
                                    id: tooltip
                                    z: 10
                                    tail: true
                                    text: tile.dragging ? qsTr("Remove") : tile.label
                                    delay: (tile.dragging || (tile.activeFocus && root.keyboardMode) || win.tipsWarm) ? 0 : Tokens.dockTooltipDelay
                                    onVisibleNowChanged: {
                                        if (visibleNow) {
                                            win.tipsWarm = true;
                                            tipsWarmTimer.stop();
                                        } else {
                                            tipsWarmTimer.restart();
                                        }
                                    }
                                    shown: tile.dragging ? (win.dragOut && win.dragRemovable) : (tile.label !== "" && (tile.hoverHeld || (tile.activeFocus && root.keyboardMode)) && !tile.tipSuppressed && !Popups.active && win.dragFrom < 0)
                                    x: (tile.width - width) / 2
                                    y: tile.height - win.indicatorArea - tile.iconPx - Tokens.dockTooltipGap - height
                                }

                                HoverHandler {
                                    id: tileHover
                                    onHoveredChanged: {
                                        if (VisualFixtures.active && leftTap.pressed)
                                            console.info("dock-launch: hover-while-pressed", hovered, Date.now());
                                        if (hovered) {
                                            hoverHoldTimer.stop();
                                            tile.hoverHeld = true;
                                        } else {
                                            hoverHoldTimer.restart();
                                            tile.tipSuppressed = false;
                                        }
                                    }
                                    enabled: !tile.isSeparator
                                    cursorShape: Qt.ArrowCursor
                                }

                                Timer {
                                    id: hoverHoldTimer
                                    interval: Tokens.dockHoverHold
                                    onTriggered: tile.hoverHeld = false
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
                                            Apps.runHelper(["gio", "trash", "--"].concat(paths)); // isolated trash in dev (ADR-0011)
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
                                    enabled: tile.isApp && !tile.isFiles
                                    target: null
                                    cursorShape: Qt.ClosedHandCursor
                                    // The one positive release signal: the exclusive grab ends with a Released event point (state 8,
                                    // QEventPoint::Released). A cancelled or stolen grab, or an `active` change alone, is not a release
                                    // and marks the drag interrupted. When something takes the pointer during the drag Qt ends it with
                                    // a synthesized release that looks real: only win.dragInterrupted (events) tells it apart.
                                    onGrabChanged: (transition, point) => {
                                        if (win.dragFrom !== tile.index)
                                            return;
                                        if (transition === PointerDevice.UngrabExclusive && point.state === 8)
                                            win.releasedOutside = point.scenePosition.y - point.scenePressPosition.y < -win.dragOutReach;
                                        else if (transition === PointerDevice.CancelGrabExclusive || transition === PointerDevice.UngrabExclusive)
                                            win.dragInterrupted = true;
                                    }
                                    onActiveChanged: {
                                        if (active) {
                                            // A press that is already interrupted (it opened the hold menu, or a surface, popup, window or focus
                                            // event came since the button went down) does not become a drag: nothing moves, no gap opens, the
                                            // tooltip stays, the release changes no pin. The decision is taken here, from per-press state
                                            // (tile.menuByHold, root.dragInterruptions against the mark taken at the press), not from an enabled
                                            // flag or from leftTap.pressed: the tap handler cancels at the drag threshold, which would
                                            // re-enable a handler guarded by it within the same event. win.dragFrom stays -1.
                                            if (tile.menuByHold || root.dragInterruptions !== tile.dragMark) {
                                                if (VisualFixtures.active)
                                                    console.info("dock-launch: drag-refused", tile.menuByHold ? "hold-menu" : "interrupted", Date.now());
                                                return;
                                            }
                                            win.releasedOutside = false;
                                            win.dragInterrupted = false;
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: drag-start", Date.now());
                                            win.dragSnap = false;
                                            win.dragFrom = tile.index;
                                            win.dragDx = 0;
                                            win.dragDy = 0;
                                        } else if (win.dragFrom === tile.index) {
                                            // One turn of the event loop later: the grab transition can be reported after the deactivation.
                                            const idx = tile.index;
                                            Qt.callLater(() => {
                                                if (win.dragFrom === idx)
                                                    win.finishDrag(tile);
                                            });
                                        }
                                    }
                                    onTranslationChanged: {
                                        if (active && win.dragFrom === tile.index) {
                                            win.dragDx = translation.x;
                                            // Never above the point where the "Remove" label would leave the window.
                                            const iconTop = win.height - Tokens.dockBottomMargin - Tokens.dockPadding - win.indicatorArea - tile.iconPx;
                                            win.dragDy = Math.max(translation.y, -(iconTop - Tokens.dockTooltipGap - tooltip.height));
                                        }
                                    }
                                }

                                TapHandler {
                                    id: leftTap
                                    enabled: !tile.isSeparator
                                    acceptedButtons: Qt.LeftButton
                                    // macOS: a press held past Tokens.dockMenuHold opens the Dock menu and its release launches nothing; a
                                    // shorter press is a click; a press that turns into a drag is a drag (the drag cancels this handler).
                                    // Only a tile with a Dock menu (apps and Files, the same as a right click) takes the hold; the others
                                    // (Apps, Trash, minimized windows) keep the click on release however long the button is held, as before.
                                    longPressThreshold: tile.isApp ? Tokens.dockMenuHold / 1000 : Tokens.dockClickHoldLimit
                                    // The label goes away on the press and stays away until the pointer leaves the tile.
                                    onPressedChanged: {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: pressed", pressed, Date.now());
                                        // Auto-hide inhibitor: a press (and hold) in progress on this tile.
                                        win.pressedTile = pressed ? tile.index : (win.pressedTile === tile.index ? -1 : win.pressedTile);
                                        if (pressed) {
                                            tile.tipSuppressed = true;
                                            tile.menuByHold = false;
                                            tile.pressMark = root.clickCancels;
                                            tile.pressCancelled = false;
                                            tile.pressTime = Date.now();
                                            tile.dragMark = root.dragInterruptions;
                                            if (root.forceHoldMenu && tile.isApp)
                                                win.markHoldMenu(tile.index);
                                            if (root.forceInterrupt && tile.isApp)
                                                root.interruptDrag();
                                        }
                                    }
                                    onCanceled: {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: canceled", Date.now());
                                        tile.pressCancelled = true;
                                    }
                                    onGrabChanged: (transition, point) => {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: grab", transition, point.state, Date.now());
                                        if (transition === PointerDevice.CancelGrabExclusive || transition === PointerDevice.CancelGrabPassive)
                                            tile.pressCancelled = true;
                                    }
                                    onLongPressed: if (tile.isApp) {
                                        tile.menuByHold = true;
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: menu-by-hold", Date.now());
                                        win.openMenu(tile.index);
                                    }
                                    onTapped: {
                                        if (tile.menuByHold)
                                            return;
                                        // Press taken away from the Dock (a shell surface or popup opened, the lock, or Qt cancelled it; see root.clickCancels): nothing happens.
                                        if (root.clickCancels !== tile.pressMark || tile.pressCancelled) {
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: tap-refused-interrupted", Date.now());
                                            return;
                                        }
                                        // A window OPENED during the press and the release follows it at once: Qt ended the press.
                                        if (root.lastWindowEvent >= tile.pressTime && Date.now() - root.lastWindowEvent < Tokens.dockClickWindowGuard) {
                                            if (VisualFixtures.active)
                                                console.info("dock-launch: tap-refused-window-event", Date.now());
                                            return;
                                        }
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: tap", Date.now());
                                        root.activateItem(tile.modelData);
                                    }
                                }

                                TapHandler {
                                    enabled: tile.isApp
                                    acceptedButtons: Qt.RightButton
                                    // macOS: a secondary click opens the Dock menu on the press, however long the button is held.
                                    onPressedChanged: if (pressed) {
                                        if (VisualFixtures.active)
                                            console.info("dock-launch: menu-by-right-press", Date.now());
                                        win.openMenu(tile.index);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
