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

    // Emitted after an item was opened: the host window lets go of the keyboard.
    signal released

    // Dedicated key sink: the focus item of this scope whenever no rename field is open, so that a
    // finished rename can never hand focus back to its (hidden) field.
    Item {
        id: keySink
        focus: true
        activeFocusOnTab: false
    }

    function takeFocus(): void {
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

    function rectOf(name: string): rect {
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
        keySink.forceActiveFocus();
    }

    function beginRename(name: string): void {
        if (name === "" || lay[name] === undefined)
            return;
        selectOnly(name);
        renameError = "";
        renaming = name;
    }

    // Opening hands the keyboard to whatever opens: the desktop lets go of it.
    function openNames(names: var): void {
        for (const n of names)
            files.open(n);
        released();
    }

    readonly property bool menuOpen: menuKind !== ""

    function closeMenu(): void {
        menuKind = "";
        takeFocus();
    }

    function applyMenu(action: string): void {
        const names = selectedNames;
        const paths = selectedPaths;
        const kind = menuKind;
        menuKind = "";
        keySink.forceActiveFocus();
        if (kind === "desktop") {
            if (action === "newFolder")
                files.newFolder();
            return;
        }
        if (action === "open")
            openNames(names);
        else if (action === "rename" && names.length === 1)
            Qt.callLater(() => root.beginRename(names[0]));
        else if (action === "copy")
            files.copy(paths);
        else if (action === "trash")
            files.trash(paths);
    }

    // Select by press: Ctrl toggles, Shift adds, otherwise the icon alone (kept as is when it is
    // already part of the selection, so that a drag carries the whole selection).
    function press(name: string, modifiers: int, right: bool): void {
        root.takeFocus();
        if (renaming !== "" && renaming !== name)
            endRename();
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

    Keys.onPressed: event => {
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
            if (root.selectedPaths.length > 0)
                GlanceApp.toggle(root.selectedPaths);
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

        function onRenameWanted(name: string): void {
            Qt.callLater(() => root.beginRename(name));
        }

        // The file system refused an accepted rename: reopen the field with the reason inline.
        function onRenameFailed(name: string, reason: string): void {
            root.takeFocus();
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
            root.takeFocus();
            if (root.renaming !== "")
                root.endRename();
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
            x: root.rectOf(modelData.name).x
            y: root.rectOf(modelData.name).y
            selected: root.selected[modelData.name] === true
            renaming: root.renaming === modelData.name
            renameError: root.renameError
            dragPaths: root.selectedPaths
            dragNames: root.selectedNames
            onPressedIcon: (modifiers, right) => root.press(modelData.name, modifiers, right)
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

    // Context menu window: an Overlay window that takes the keyboard while it is open (the desktop
    // surface cannot show a menu above windows); clicking anywhere else dismisses it.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: menuWin

        screen: root.screen
        visible: root.menuKind !== ""
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-icons-menu"

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.closeMenu()
        }

        Loader {
            active: root.menuKind !== ""
            x: Math.max(Tokens.spacingSm, Math.min(root.menuAt.x, menuWin.width - width - Tokens.spacingSm))
            y: Math.max(Tokens.spacingSm, Math.min(root.menuAt.y, menuWin.height - height - Tokens.spacingSm))
            sourceComponent: IconMenu {
                kind: root.menuKind
                count: root.selectedNames.length
                onChoose: action => root.applyMenu(action)
                onCloseRequested: root.closeMenu()
                Component.onCompleted: forceActiveFocus()
            }
        }
    }
}
