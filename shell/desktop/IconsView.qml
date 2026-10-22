pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.widgets
import "../widgets/Placements.js" as Placements
import qs.services
import qs.notifications
import "IconsLogic.js" as Logic

// Desktop icons (docs/specs/desktop.md): the files of the desktop folder as a grid of icons on the
// wallpaper surface, so a click between icons simply lands on the wallpaper and the widgets (a
// layer above) keep their own input. Selection, rubber band, keyboard navigation, inline rename,
// context menus, drops from applications and drags out. Files are only touched by the explicit
// actions of this item, through files.
FocusScope {
    id: root

    // Screen and window of the hosting surface (the context menu is a PopupWindow anchored to it).
    required property ShellScreen screen
    required property var hostWindow
    // The desktop surface holds the keyboard (KeyboardFocus.js "held"): the desktop keyboard actions below
    // (arrows, Return, Ctrl+O, Ctrl+Backspace, Ctrl+A, Space, Esc) run only then.
    property bool keysActive: false
    // An icon drag (real drag-and-drop) is in progress.
    property bool dragging: false

    // Selected names ({name: true}) and the keyboard cursor.
    property var selected: ({})
    property string current: ""
    property string renaming: ""
    // The text typed in the rename field so far.
    property string renameDraft: ""
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
    // {type: "menuClosed", how: "esc" | "item"}.
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
        renameDraft = "";
        restoreFocus();
    }

    // Commits the rename field. A refused name keeps the field open with the reason, unless `endOnError`
    // (the field lost the keyboard and cannot stay open): then the rename is cancelled.
    function commitRename(name: string, text: string, endOnError: bool): void {
        if (root.renaming !== name)
            return;
        const why = files.rename(name, text);
        if (why === "" || why === "same") {
            root.endRename();
            root.selectOnly(why === "" ? text : name);
        } else if (endOnError) {
            root.endRename();
        } else {
            root.renameError = why;
        }
    }

    // The rename field lost the keyboard (a click elsewhere, the pointer left for a window): commit what was typed,
    // as macOS does. Deferred one turn so that a rename ended by the same event is not committed twice.
    function renameFocusLost(name: string): void {
        Qt.callLater(() => {
            if (root.renaming === name)
                root.commitRename(name, root.renameDraft, true);
        });
    }

    // Opens the rename field of one icon.
    function beginRename(name: string): void {
        if (name === "" || lay[name] === undefined)
            return;
        selectOnly(name);
        renameError = "";
        renameDraft = name;
        renaming = name;
    }

    function openNames(names: var): void {
        for (const n of names)
            files.open(n);
    }

    // Context menu: a PopupWindow anchored to the desktop surface with a grab (ADR-0012). The compositor
    // dismisses it on a click elsewhere and swallows that click.
    readonly property bool menuOpen: menuKind !== ""

    function openMenu(kind: string, x: real, y: real): void {
        menuAt = Qt.point(x, y);
        // What the menu offers beyond the fixed items is read now: the clipboard's files (Paste) or the apps that open
        // the selection (Open With ▸); the rows appear as soon as the answer is in.
        if (kind === "desktop")
            files.refreshClipboard();
        else
            files.resolveOpenWith(selectedPaths);
        menuKind = kind;
        menuPopup.visible = true;
        focusEvent({
            type: "menuOpened"
        });
    }

    // Closes the menu on the user's action ("esc" or "item"): the keyboard is back on the desktop.
    function closeMenu(how: string): void {
        if (!menuOpen)
            return;
        menuKind = "";
        menuPopup.visible = false;
        focusEvent({
            type: "menuClosed",
            how: how
        });
    }

    function applyMenu(action: string): void {
        const names = selectedNames;
        const paths = selectedPaths;
        const kind = menuKind;
        closeMenu("item");
        if (kind === "desktop") {
            if (action === "newFolder")
                files.newFolder();
            else if (action === "paste")
                files.paste();
            else if (action === "getInfo")
                files.showInfo([files.dir]);
            else if (action === "wallpaper")
                SettingsApp.openSection("wallpaper");
            else if (action === "editWidgets")
                Notifications.openWidgetGallery(root.screen ? root.screen.name : "");
            else if (action === "cleanUp")
                files.setPositions(Logic.arrange(Logic.visualOrder(lay), grid.cols, grid.rows, blocked));
            else if (action.startsWith("cleanUpBy:"))
                cleanUpBy(action.substring(10));
            return;
        }
        if (action === "rename" && names.length === 1)
            beginRename(names[0]);
        else if (action === "open")
            openNames(names);
        else if (action.startsWith("openWith:"))
            files.openWith(action.substring(9));
        else if (action === "getInfo")
            files.showInfo(paths);
        else if (action === "compress")
            files.compress(names);
        else if (action === "duplicate")
            files.duplicate(names);
        else if (action === "alias")
            files.makeAlias(names);
        else if (action === "quickLook")
            GlanceApp.toggle(paths);
        else if (action === "copy")
            files.copy(paths);
        else if (action === "trash")
            files.trash(paths);
    }

    // Clean Up By: every icon in the chosen order (name, kind, size, dates), packed from the top-right corner.
    function cleanUpBy(key: string): void {
        files.readMeta(meta => files.setPositions(Logic.arrange(Logic.orderBy(files.names, key, meta), grid.cols, grid.rows, blocked)));
    }

    // A press elsewhere ends the rename: it commits (macOS). The press goes on with its own action.
    function commitRenameOnPress(): void {
        if (renaming !== "")
            commitRename(renaming, renameDraft, true);
    }

    // Select by press: Ctrl toggles, Shift adds, otherwise the icon alone (kept as is when it is
    // already part of the selection, so that a drag carries the whole selection).
    function press(name: string, modifiers: int, right: bool): void {
        root.restoreFocus();
        commitRenameOnPress();
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

    // Active only while the desktop surface holds the keyboard (keysActive).
    // Keyboard actions that change or open files (Return/F2 rename, Ctrl+O, Ctrl+Backspace) are on only while the
    // compositor enforces the desktop focus policy (ADR-0012, "desktop-focus-v2" capability), set by the host: without
    // it the desktop can keep the keyboard after a click on Hyprland's active window, which the shell cannot observe.
    // Arrows, Ctrl+A, Space (Glance) and Esc only change the selection or a preview.
    property bool fileKeyActions: false
    Keys.enabled: root.keysActive
    Keys.onPressed: event => {
        if (root.renaming !== "")
            return;
        const ctrl = (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0;
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
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !ctrl && root.fileKeyActions) {
            // Return renames the selected file (macOS); opening is Ctrl+O or a double click.
            if (root.selectedNames.length === 1)
                root.beginRename(root.selectedNames[0]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_O && root.fileKeyActions) {
            root.openNames(root.selectedNames);
            event.accepted = true;
        } else if (event.key === Qt.Key_Space && !ctrl) {
            // Glance at the selected files (Space again closes it; folders are skipped by Glance itself).
            if (root.selectedPaths.length > 0)
                GlanceApp.toggle(root.selectedPaths);
            event.accepted = true;
        } else if (event.key === Qt.Key_F2 && root.fileKeyActions) {
            if (root.selectedNames.length === 1)
                root.beginRename(root.selectedNames[0]);
            event.accepted = true;
        } else if (ctrl && event.key === Qt.Key_Backspace && root.fileKeyActions) {
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
            // Esc closes Glance first (as Quick Look); the next one clears the selection.
            if (GlanceApp.open)
                GlanceApp.close();
            else
                root.clearSelection();
            event.accepted = true;
        }
    }

    Connections {
        target: files

        // New Folder (a user action) opens the rename field of the folder it created.
        function onRenameWanted(name: string): void {
            Qt.callLater(() => root.beginRename(name));
        }

        // The file system refused an accepted rename: reopen the field with the reason inline.
        function onRenameFailed(name: string, reason: string): void {
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
            root.commitRenameOnPress();
            if (mouse.button === Qt.RightButton) {
                root.clearSelection();
                root.openMenu("desktop", mouse.x, mouse.y);
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
            if (!pressed || mouse.buttons !== Qt.LeftButton)
                return;
            if (!banding && Math.abs(mouse.x - x0) + Math.abs(mouse.y - y0) < Tokens.desktopIconDragThreshold)
                return;
            banding = true;
            root.updateBand(Math.max(0, Math.min(root.width, mouse.x)), Math.max(0, Math.min(root.height, mouse.y)), x0, y0);
        }
        onReleased: {
            banding = false;
            root.band = null;
        }
        onCanceled: {
            banding = false;
            root.band = null;
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
            folderColor: files.folderStyle(modelData.name).color
            folderGlyph: files.folderStyle(modelData.name).glyph
            x: root.rectOf(modelData.name).x
            y: root.rectOf(modelData.name).y
            selected: root.selected[modelData.name] === true
            renaming: root.renaming === modelData.name
            renameError: root.renameError
            dragPaths: root.selectedPaths
            dragNames: root.selectedNames
            onPressedIcon: (modifiers, right) => root.press(modelData.name, modifiers, right)
            onTappedIcon: modifiers => root.tap(modelData.name, modifiers)
            onDragActiveChanged: root.dragging = icon.dragActive
            onActivated: root.openNames([modelData.name])
            onMenuRequested: (px, py) => root.openMenu("icon", px, py)
            onRenameEdited: text => root.renameDraft = text
            onRenameAccepted: text => root.commitRename(modelData.name, text, false)
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

    // Context menu: a PopupWindow with a grab, anchored to the desktop surface. It draws above windows and gets
    // the keyboard; Esc and an item hand it back to the desktop, a click elsewhere dismisses it (swallowed).
    // qmllint disable uncreatable-type
    PopupWindow {
        // qmllint enable uncreatable-type
        id: menuPopup

        // qmllint disable missing-type
        anchor.window: root.hostWindow
        anchor.rect: Qt.rect(root.menuAt.x, root.menuAt.y, 1, 1)
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.All
        // qmllint enable missing-type
        // The menu and its open submenu (Open With ▸, Clean Up By ▸), which opens to the right of the menu.
        implicitWidth: Math.max(1, (menuLoader.item as Item)?.childrenRect.width ?? 1)
        implicitHeight: Math.max(1, (menuLoader.item as Item)?.childrenRect.height ?? 1)
        color: "transparent"
        grabFocus: true
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && visible ? menuBlur : null
        // qmllint enable missing-type

        // Dismissed by the compositor (a click elsewhere): the grab ended, the click was swallowed.
        onVisibleChanged: {
            if (visible) {
                (menuLoader.item as Item)?.forceActiveFocus();
                return;
            }
            if (root.menuOpen) {
                root.menuKind = "";
                root.focusEvent({
                    type: "menuClosed",
                    how: "outside"
                });
            }
        }

        Region {
            id: menuBlur
            item: menuLoader
            radius: Tokens.radiusMenu

            Region {
                item: (menuLoader.item as PopupMenu)?.submenuItem ?? null
                radius: Tokens.radiusMenu
            }
        }

        Loader {
            id: menuLoader
            active: root.menuKind !== ""
            sourceComponent: IconMenu {
                kind: root.menuKind
                showKeyHints: root.fileKeyActions
                count: root.selectedNames.length
                singleName: root.selectedNames.length === 1 ? root.selectedNames[0] : ""
                pasteCount: files.clipboardPaths.length
                openWithApps: files.openWithApps
                onChoose: action => root.applyMenu(action)
                onCloseRequested: root.closeMenu("esc")
            }
            onLoaded: (item as Item).forceActiveFocus()
        }
    }

}
