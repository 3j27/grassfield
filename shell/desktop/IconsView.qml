pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.widgets
import "../widgets/Placements.js" as Placements
import qs.services
import "IconsLogic.js" as Logic

// Desktop icons (docs/specs/desktop.md): the files of the desktop folder as a grid of icons on the
// wallpaper surface, so a click between icons simply lands on the wallpaper and the widgets (a
// layer above) keep their own input. Selection, rubber band, keyboard navigation, inline rename,
// context menus, drops from applications and drags out. Files are only touched by the explicit
// actions of this item, through files.
FocusScope {
    id: root

    // Screen of the hosting window (the context menu window opens there).
    required property ShellScreen screen
    // KEYBOARD SAFE MODE (docs/specs/desktop.md, "Keyboard safe mode (2026-10-17)"): the desktop surface
    // never holds the keyboard on its own, so none of the desktop keyboard actions below (arrows, Return,
    // Space, F2, Ctrl+A, Ctrl+Backspace, Esc) can run. Off until the macOS-model redesign; the pointer
    // (selection, double click, drag and drop, context menu) is unaffected. Setting it true alone
    // does nothing: the host would also have to give the surface the keyboard.
    readonly property bool desktopKeyboardNav: false
    // The host's keyboard state machine (KeyboardFocus.js): the menu window stays mapped / Exclusive
    // beyond the menu itself during the hand-off to the rename field.
    property bool kbMenuMapped: false
    property bool kbMenuHoldsKeys: false
    // The click catchers of the other outputs are up (DesktopIcons.qml): the menu window may take the keyboard.
    property bool kbGate: true
    // A click catcher of another output has the keyboard (the pointer is on that output): a rename
    // does not end for that, it only stops receiving keys until the pointer is back.
    property bool kbCatcherHasKeys: false
    // New Folder was chosen and its rename field is not open yet: the menu window keeps the keyboard.
    property bool awaitingFolder: false
    // An icon drag (real drag-and-drop) is in progress.
    property bool dragging: false

    // Selected names ({name: true}) and the keyboard cursor.
    property var selected: ({})
    property string current: ""
    property string renaming: ""
    property string renameError: ""
    // Rubber band in item coordinates, or null.
    property var band: null
    property var bandBase: ({})
    // Context menu: kind "icon" | "desktop", position in window coordinates.
    property string menuKind: ""
    property point menuAt: Qt.point(0, 0)

    readonly property real margin: Tokens.desktopIconMargin
    readonly property real topInset: Tokens.menubarHeight + margin
    // The Dock sits at the bottom edge: keep the grid above it.
    readonly property real bottomInset: margin + Tokens.dockIconSize + 2 * Tokens.dockPadding + Tokens.dockBottomMargin
    readonly property real areaW: Math.max(0, width - 2 * margin)
    readonly property real areaH: Math.max(0, height - topInset - bottomInset)
    readonly property var grid: Logic.gridSize(areaW, areaH, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight)
    readonly property bool ready: width > 0 && height > 0 && files.positionsLoaded && files.dir !== ""
    // Widgets of this screen are never overlapped: slots under a widget tile are not available to
    // icons (widgets win; the icons move to the next free slot).
    readonly property var widgetRects: {
        const g = Widgets.gridFor(screen);
        const out = [];
        for (const e of Widgets.desktop) {
            if (e.screen !== screen.name)
                continue;
            const s = Placements.px(e.size, g.cell, g.gap);
            out.push({
                x: g.x0 + e.col * (g.cell + g.gap),
                y: g.y0 + e.row * (g.cell + g.gap),
                w: s.w,
                h: s.h
            });
        }
        return out;
    }
    readonly property var blocked: Logic.blockedSlots(widgetRects, margin, topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows)
    readonly property var lay: Logic.layout(files.names, files.positions, grid.cols, grid.rows, blocked)
    readonly property var shown: files.entries.filter(e => lay[e.name] !== undefined)
    readonly property var selectedNames: Object.keys(selected).filter(n => selected[n] === true && lay[n] !== undefined)
    readonly property var selectedPaths: selectedNames.map(n => files.path(n))

    DesktopFiles {
        id: files
    }

    // Keyboard focus events for the host's state machine (KeyboardFocus.js): {type: "menuOpened"},
    // {type: "menuClosed"}, {type: "renameOpened"}, {type: "renameClosed"}.
    signal focusEvent(var event)

    // Dedicated key sink: the focus item of this scope whenever no rename field is open, so that a
    // finished rename can never hand focus back to its (hidden) field. (No keyboard reaches it in
    // safe mode.)
    Item {
        id: keySink
        focus: true
        activeFocusOnTab: false
    }

    // The key sink becomes the scope's focus item: at a user press on the desktop and at the end of a
    // rename or menu.
    function restoreFocus(): void {
        keySink.forceActiveFocus();
    }

    activeFocusOnTab: false
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Desktop")

    // Persist the slots handed out to icons that had none (new files, a smaller grid).
    onLayChanged: syncTimer.restart()

    Timer {
        id: syncTimer
        interval: 0
        onTriggered: {
            if (!root.ready)
                return;
            const pos = files.positions;
            let changed = false;
            for (const n of Object.keys(root.lay)) {
                const p = pos[n];
                if (!p || p.col !== root.lay[n].col || p.row !== root.lay[n].row)
                    changed = true;
            }
            if (changed)
                files.setPositions(Object.assign({}, pos, root.lay));
        }
    }

    // Cell of an icon; empty for a name without a slot (a delegate can be re-evaluated while a rename
    // swaps the old name for the new one in the folder model).
    function rectOf(name: string): rect {
        if (lay[name] === undefined)
            return Qt.rect(0, 0, 0, 0);
        const s = Logic.slotPos(lay[name].col, lay[name].row, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight);
        return Qt.rect(margin + s.x, topInset + s.y, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight);
    }

    function iconAt(x: real, y: real): string {
        for (const n of Object.keys(lay)) {
            const r = rectOf(n);
            if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
                return n;
        }
        return "";
    }

    function selectOnly(name: string): void {
        const next = {};
        if (name !== "")
            next[name] = true;
        selected = next;
        current = name;
    }

    function clearSelection(): void {
        selected = ({});
        current = "";
    }

    function endRename(): void {
        renaming = "";
        renameError = "";
        restoreFocus();
        focusEvent({
            type: "renameClosed"
        });
    }

    // The rename field lost the keyboard. Hyprland gives the keyboard to a click catcher while the pointer is on
    // another output: that is not the end of the rename. The check is deferred so that the catcher's
    // activation, delivered right after the desktop's deactivation, is seen.
    function renameFocusLost(name: string): void {
        Qt.callLater(() => {
            if (root.renaming === name && !root.kbCatcherHasKeys)
                root.endRename();
        });
    }

    // Opens the rename field: the rename surface takes the keyboard (the host's state machine; from the
    // menu, before the menu window lets go of it).
    function beginRename(name: string): void {
        if (name === "" || lay[name] === undefined)
            return;
        awaitingFolder = false;
        selectOnly(name);
        renameError = "";
        renaming = name;
        focusEvent({
            type: "renameOpened"
        });
    }

    function openNames(names: var): void {
        for (const n of names)
            files.open(n);
    }

    readonly property bool menuOpen: menuKind !== ""

    onMenuOpenChanged: {
        if (menuOpen)
            focusEvent({
                type: "menuOpened"
            });
    }

    // Closes the menu: the menu window lets go of the keyboard and nobody re-takes it (a no-op for the
    // state machine when the menu already handed it to the rename field).
    function endMenu(): void {
        if (menuOpen || awaitingFolder)
            focusEvent({
                type: "menuClosed"
            });
        awaitingFolder = false;
        menuKind = "";
    }

    // Layer state reaches the compositor with the next surface commit: render the menu window now.
    function commitMenu(): void {
        const w = menuLoader.Window.window;
        if (w)
            w.update();
    }

    function closeMenu(): void {
        endMenu();
        restoreFocus();
    }

    function applyMenu(action: string): void {
        const names = selectedNames;
        const paths = selectedPaths;
        const kind = menuKind;
        restoreFocus();
        if (kind === "desktop") {
            if (action === "newFolder") {
                // The menu window keeps the keyboard until the new folder's rename field takes it.
                awaitingFolder = true;
                menuKind = "";
                files.newFolder();
            } else {
                endMenu();
            }
            return;
        }
        if (action === "rename" && names.length === 1) {
            // The rename surface takes the keyboard before the menu window releases it.
            beginRename(names[0]);
            menuKind = "";
            return;
        }
        endMenu();
        if (action === "open")
            openNames(names);
        else if (action === "copy")
            files.copy(paths);
        else if (action === "trash")
            files.trash(paths);
    }

    // While a menu or a rename is active, a press on the desktop surface only cancels it: it never
    // selects, opens or drags an icon, nor starts a rubber band. The press may come through a window
    // that covers an icon (an Exclusive surface takes the pointer), so it says nothing about the desktop.
    // `swallow` keeps the rest of that gesture (drag, release) inert until the pointer is up.
    property bool swallow: false

    // Returns whether the press was swallowed (a menu or rename was active, now cancelled).
    function swallowPress(): bool {
        if (!cancelInteraction())
            return false;
        swallow = true;
        return true;
    }

    // Ends the open menu or the active rename (never commits, never renames, never trashes). Called by a
    // press on the desktop surface and by the click catchers of the other outputs (DesktopIcons.qml).
    // Returns whether there was anything to cancel.
    function cancelInteraction(): bool {
        const active = menuOpen || awaitingFolder || renaming !== "";
        if (menuOpen || awaitingFolder)
            closeMenu();
        if (renaming !== "")
            endRename();
        return active;
    }

    // The pointer is up again: the next press counts.
    PointHandler {
        acceptedButtons: Qt.AllButtons
        onActiveChanged: if (!active)
            root.swallow = false
    }

    // Select by press: Ctrl toggles, Shift adds, otherwise the icon alone (kept as is when it is
    // already part of the selection, so that a drag carries the whole selection).
    function press(name: string, modifiers: int, right: bool): void {
        root.restoreFocus();
        if (swallowPress())
            return;
        if (modifiers & Qt.ControlModifier) {
            const next = Object.assign({}, selected);
            if (next[name])
                delete next[name];
            else
                next[name] = true;
            selected = next;
            current = name;
        } else if (modifiers & Qt.ShiftModifier) {
            selected = Object.assign({}, selected, {
                [name]: true
            });
            current = name;
        } else if (!selected[name]) {
            selectOnly(name);
        } else {
            current = name;
        }
    }

    // A click (release without drag) on an icon: without Ctrl or Shift it leaves that icon alone
    // selected, also when it was part of a larger selection (kept on press for a group drag).
    function tap(name: string, modifiers: int): void {
        if (!(modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) && lay[name] !== undefined)
            selectOnly(name);
    }

    function rects(): var {
        const out = {};
        for (const n of Object.keys(lay)) {
            const r = rectOf(n);
            out[n] = {
                x: r.x,
                y: r.y,
                w: r.width,
                h: r.height
            };
        }
        return out;
    }

    function updateBand(x: real, y: real, x0: real, y0: real): void {
        const b = {
            x: Math.min(x, x0),
            y: Math.min(y, y0),
            w: Math.abs(x - x0),
            h: Math.abs(y - y0)
        };
        band = b;
        const next = Object.assign({}, bandBase);
        for (const n of Logic.inRect(rects(), b))
            next[n] = true;
        selected = next;
    }

    // A drop on the desktop. Internal drags (marker format) rearrange; everything else is copied in.
    function dropped(drop: var): void {
        const dir = files.dir;
        if (drop.formats.indexOf("application/x-grassfield-desktop-icons") >= 0) {
            let m = null;
            try {
                m = JSON.parse(drop.getDataAsString("application/x-grassfield-desktop-icons"));
            } catch (e) {
                m = null;
            }
            if (m && Array.isArray(m.names) && typeof m.anchor === "string" && lay[m.anchor] !== undefined) {
                const want = Logic.slotAt(drop.x - m.hx - margin, drop.y - m.hy - topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows);
                const names = m.names.filter(n => typeof n === "string" && lay[n] !== undefined);
                files.setPositions(Object.assign({}, files.positions, Logic.moveGroup(lay, names, m.anchor, want, grid.cols, grid.rows)));
                drop.accept(Qt.MoveAction);
                return;
            }
        }
        if (!drop.hasUrls) {
            drop.accept(Qt.IgnoreAction);
            return;
        }
        const paths = Logic.parseUriList(drop.getDataAsString("text/uri-list"));
        drop.accept(Qt.CopyAction);
        if (paths.length === 0 || dir === "")
            return;
        const want = Logic.slotAt(drop.x - Tokens.desktopIconCellWidth / 2 - margin, drop.y - Tokens.desktopIconCellHeight / 2 - topInset, areaW, Tokens.desktopIconCellWidth, Tokens.desktopIconCellHeight, grid.cols, grid.rows);
        const added = files.importPaths(paths, false);
        // Reserve slots for the new names next to the drop point.
        const taken = {};
        for (const n of Object.keys(lay))
            taken[Logic.key(lay[n].col, lay[n].row)] = true;
        const pos = Object.assign({}, files.positions);
        for (const n of added) {
            const spot = Logic.nearestFree(taken, want, grid.cols, grid.rows);
            if (!spot)
                break;
            pos[n] = spot;
            taken[Logic.key(spot.col, spot.row)] = true;
        }
        files.setPositions(pos);
    }

    // ---- keyboard --------------------------------------------------------------------------------

    // Safe mode: off (Keys.enabled), see desktopKeyboardNav. The surface has no keyboard anyway.
    // Gated off, kept for the macOS-model redesign: do not delete (Space / Glance, F2, Ctrl+Backspace ...).
    Keys.enabled: root.desktopKeyboardNav
    Keys.onPressed: event => {
        if (root.menuOpen) {
            event.accepted = true;
            return;
        }
        if (root.renaming !== "")
            return;
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        let dir = "";
        switch (event.key) {
        case Qt.Key_Left:
            dir = "left";
            break;
        case Qt.Key_Right:
            dir = "right";
            break;
        case Qt.Key_Up:
            dir = "up";
            break;
        case Qt.Key_Down:
            dir = "down";
            break;
        }
        if (dir !== "") {
            root.selectOnly(Logic.navigate(root.lay, root.current, dir));
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openNames(root.selectedNames);
            event.accepted = true;
        } else if (event.key === Qt.Key_Space && !ctrl) {
            // Glance at the selected files (Space again closes it; folders are skipped by Glance itself).
            if (root.selectedPaths.length > 0) {
                GlanceApp.toggle(root.selectedPaths);
            }
            event.accepted = true;
        } else if (event.key === Qt.Key_F2) {
            if (root.selectedNames.length === 1)
                root.beginRename(root.selectedNames[0]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_Backspace) {
            if (root.selectedPaths.length > 0)
                files.trash(root.selectedPaths);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_A) {
            const all = {};
            for (const n of Object.keys(root.lay))
                all[n] = true;
            root.selected = all;
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            root.clearSelection();
            event.accepted = true;
        }
    }

    Connections {
        target: files

        // New Folder (a user action) opens the rename field of the folder it created.
        function onRenameWanted(name: string): void {
            Qt.callLater(() => {
                root.beginRename(name);
                if (root.renaming === "" && root.awaitingFolder)
                    root.endMenu();
            });
        }

        // The folder could not be created: the menu window lets go of the keyboard.
        function onNewFolderFailed(): void {
            if (root.awaitingFolder)
                root.endMenu();
        }

        // The file system refused an accepted rename: reopen the field with the reason inline.
        function onRenameFailed(name: string, reason: string): void {
            root.restoreFocus();
            root.beginRename(name);
            root.renameError = "failed";
        }
    }

    // ---- empty space: rubber band, focus, context menu ---------------------------------------------

    MouseArea {
        id: background
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property real x0: 0
        property real y0: 0
        property bool banding: false

        onPressed: mouse => {
            if (root.iconAt(mouse.x, mouse.y) !== "") {
                mouse.accepted = false;
                return;
            }
            root.restoreFocus();
            if (root.swallowPress())
                return;
            if (mouse.button === Qt.RightButton) {
                root.clearSelection();
                root.menuAt = root.mapToItem(null, mouse.x, mouse.y);
                root.menuKind = "desktop";
                return;
            }
            x0 = mouse.x;
            y0 = mouse.y;
            banding = false;
            root.bandBase = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.selected : ({});
            if (!(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
                root.clearSelection();
        }
        onPositionChanged: mouse => {
            if (!pressed || mouse.buttons !== Qt.LeftButton || root.swallow)
                return;
            if (!banding && Math.abs(mouse.x - x0) + Math.abs(mouse.y - y0) < Tokens.desktopIconDragThreshold)
                return;
            banding = true;
            root.updateBand(Math.max(0, Math.min(root.width, mouse.x)), Math.max(0, Math.min(root.height, mouse.y)), x0, y0);
        }
        onReleased: {
            banding = false;
            root.band = null;
            root.swallow = false;
        }
        onCanceled: {
            banding = false;
            root.band = null;
            root.swallow = false;
        }
    }

    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list", "application/x-grassfield-desktop-icons"]
        onDropped: drop => root.dropped(drop)
    }

    // ---- icons -------------------------------------------------------------------------------------

    Repeater {
        model: ScriptModel {
            values: root.shown
            objectProp: "name"
        }

        delegate: DesktopIcon {
            id: icon

            required property var modelData

            name: modelData.name
            isDir: modelData.isDir
            filePath: modelData.path
            x: root.rectOf(modelData.name).x
            y: root.rectOf(modelData.name).y
            selected: root.selected[modelData.name] === true
            renaming: root.renaming === modelData.name
            renameError: root.renameError
            dragPaths: root.selectedPaths
            dragNames: root.selectedNames
            blocked: root.swallow
            onPressedIcon: (modifiers, right) => root.press(modelData.name, modifiers, right)
            onTappedIcon: modifiers => root.tap(modelData.name, modifiers)
            onDragActiveChanged: {
                root.dragging = icon.dragActive;
                if (!icon.dragActive)
                    root.swallow = false;
            }
            onActivated: root.openNames([modelData.name])
            onMenuRequested: (px, py) => {
                root.menuAt = Qt.point(px, py);
                root.menuKind = "icon";
            }
            onRenameAccepted: text => {
                if (root.renaming !== modelData.name)
                    return;
                const why = files.rename(modelData.name, text);
                if (why === "" || why === "same") {
                    root.endRename();
                    root.selectOnly(why === "" ? text : modelData.name);
                }
                else
                    root.renameError = why;
            }
            onRenameCancelled: root.endRename()
            onRenameFocusLost: root.renameFocusLost(modelData.name)
        }
    }

    // Rubber band.
    Rectangle {
        visible: root.band !== null
        x: root.band ? root.band.x : 0
        y: root.band ? root.band.y : 0
        width: root.band ? root.band.w : 0
        height: root.band ? root.band.h : 0
        radius: Tokens.desktopIconSelectionRadius / 2
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconRubberBandOpacity)
        border.width: 1
        border.color: Appearance.withAlpha(Appearance.colors.accent, Tokens.desktopIconSelectionOpacity)
    }

    // Context menu window: an Overlay window (the desktop surface cannot show a menu above windows);
    // clicking anywhere else dismisses it. While the menu is open this window holds the keyboard
    // (Exclusive) and the desktop is None. On close it goes back to None and unmaps, and the desktop does
    // not take the keyboard: Hyprland decides (the last window). Handing over to a rename field, the
    // rename surface is Exclusive first, then this window lets go and unmaps (KeyboardFocus.js, hand-off).
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: menuWin

        screen: root.screen
        visible: (root.menuKind !== "" || root.kbMenuMapped) && root.kbGate
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: (root.menuKind !== "" || root.kbMenuHoldsKeys) && root.kbGate ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.onKeyboardFocusChanged: root.commitMenu()
        WlrLayershell.namespace: "grassfield-icons-menu"

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.closeMenu()
        }

        Loader {
            id: menuLoader
            active: root.menuKind !== ""
            x: Math.max(Tokens.spacingSm, Math.min(root.menuAt.x, menuWin.width - width - Tokens.spacingSm))
            y: Math.max(Tokens.spacingSm, Math.min(root.menuAt.y, menuWin.height - height - Tokens.spacingSm))
            sourceComponent: IconMenu {
                kind: root.menuKind
                count: root.selectedNames.length
                shortcutsShown: root.desktopKeyboardNav
                onChoose: action => root.applyMenu(action)
                onCloseRequested: root.closeMenu()
            }
        }
    }
}
