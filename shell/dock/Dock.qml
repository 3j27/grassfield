pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Grassfield.Ui
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

    function rebuild(): void {
        const running = [];
        const tops = Compositor.toplevels ? Compositor.toplevels.values : [];
        for (let i = 0; i < tops.length; i++)
            running.push({appId: tops[i].appId, ref: tops[i]});
        items = DockModel.withTail(DockModel.merge(Settings.dockPinned, running, Apps.lookup), DockModel.minimizedItems(Compositor.minimized, Apps.lookup));
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
            if (item.entry)
                Apps.launch(item.entry);
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
            readonly property real shelfWidth: Magnify.totalWidth(widths.map((w, i) => w * scaleList[i]), Tokens.dockSpacing) + 2 * Tokens.dockPadding

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
                Popups.open("dock", win.screen.name, cx, win.screen.height - Tokens.dockBottomMargin - shelfHeight - Tokens.spacingSm, "above", {
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
            implicitHeight: shelfHeight + Tokens.dockBottomMargin + overhang + tooltipArea
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
            function tileRect(index: int, adding: bool): var {
                const sep = root.items.findIndex(it => it.kind === "separator");
                const mon = Compositor.monitorByName(win.screen.name);
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
                    height: win.revealed ? (win.pointerActive ? win.height : win.shelfHeight + Tokens.dockBottomMargin) : Tokens.dockRevealZone
                    y: win.height - height
                }

                Material {
                    id: shelf
                    width: win.shelfWidth
                    height: win.shelfHeight
                    x: (win.width - width) / 2
                    y: win.height - Tokens.dockBottomMargin - height + (win.revealed ? 0 : height + Tokens.dockBottomMargin + shadowMargin)
                    radius: Tokens.radiusDock

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
                            model: root.items

                            delegate: Item {
                                id: tile

                                required property var modelData
                                required property int index

                                readonly property real tileScale: win.scaleList[index] !== undefined ? win.scaleList[index] : 1
                                readonly property bool isApp: modelData.kind === "app"
                                readonly property bool isTrash: modelData.kind === "trash"
                                readonly property bool isSeparator: modelData.kind === "separator"
                                readonly property bool isMinimized: modelData.kind === "minimized"
                                readonly property bool running: isApp && modelData.windows.length > 0
                                readonly property string label: isTrash ? qsTr("Trash") : (isApp || isMinimized ? modelData.name : "")
                                readonly property real iconPx: win.iconSize * tileScale

                                width: isSeparator ? win.separatorWidth : iconPx
                                height: win.iconSize + win.indicatorArea
                                activeFocusOnTab: !isSeparator
                                Accessible.role: isSeparator ? Accessible.Separator : Accessible.Button
                                Accessible.name: isTrash ? (Trash.empty ? qsTr("Trash, empty") : qsTr("Trash, contains items")) : (isMinimized ? qsTr("%1, minimized").arg(label) : (running ? qsTr("%1, running").arg(label) : label))
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
                                    anchors.bottomMargin: win.indicatorArea
                                    width: Tokens.dockSeparatorWidth
                                    height: win.iconSize
                                    color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
                                }

                                // Application icon, growing upward from the shelf.
                                IconImage {
                                    id: appIcon
                                    visible: tile.isApp
                                    width: tile.iconPx
                                    height: tile.iconPx
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: win.indicatorArea
                                    source: tile.isApp ? Quickshell.iconPath(tile.modelData.icon, "application-x-executable") : ""
                                    smooth: true
                                    mipmap: true
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

                                    IconImage {
                                        width: minimizedTile.live ? Math.round(parent.width * Tokens.dockMinimizedBadgeScale) : parent.width
                                        height: width
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        source: minimizedTile.iconSource
                                        smooth: true
                                        mipmap: true
                                    }
                                }

                                // Trash: own symbolic icon on a rounded tile.
                                Rectangle {
                                    id: trashIcon
                                    visible: tile.isTrash
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
                                    visible: tile.activeFocus && !tile.isSeparator
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
                                    text: tile.label
                                    delay: 0
                                    shown: tile.label !== "" && (tileHover.hovered || tile.activeFocus) && !Popups.active
                                    x: (tile.width - width) / 2
                                    y: tile.height - win.indicatorArea - tile.iconPx - Tokens.dockTooltipGap - height
                                }

                                HoverHandler {
                                    id: tileHover
                                    enabled: !tile.isSeparator
                                    cursorShape: Qt.PointingHandCursor
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

                                TapHandler {
                                    enabled: !tile.isSeparator
                                    acceptedButtons: Qt.LeftButton
                                    onTapped: {
                                        tile.forceActiveFocus();
                                        root.activateItem(tile.modelData);
                                    }
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
