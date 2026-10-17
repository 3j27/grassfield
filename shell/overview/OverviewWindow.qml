pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Grassfield.Ui
import qs.platform
import qs.services
import "Layout.js" as Layout

// Overview surface, one per screen: a full-screen layer-shell overlay below the menu bar with a
// dimmed, blurred backdrop, a Spaces bar on top and the windows of the output's current
// workspace laid out as live thumbnails (ScreencopyView of the toplevel).
//
// Spaces tiles (v1): window count and app icons, no capture of the workspace.
// Zoom: thumbnails interpolate from the real window rectangle to the layout rectangle.
// Reduce Motion: geometry does not move, everything crossfades in at most motionReducedMax.
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property string screenName: modelData.name
        readonly property bool shown: root.controller.open
        readonly property bool holdsKeyboard: shown && !root.controller.releasing && (root.controller.keyScreen === "" || root.controller.keyScreen === screenName)

        // 0 = windows at their real place, 1 = fully laid out.
        property real progress: shown ? 1 : 0
        readonly property real zoom: Appearance.reduceMotion ? 1 : progress

        // Windows of the current workspace and the Spaces of this output, kept while the
        // closing animation runs. Reactive on Hyprland data and on window/workspace events.
        readonly property var liveWins: shown ? Compositor.windowsOn(screenName, Compositor.topologyRevision) : null
        readonly property var liveSpaces: shown ? Compositor.spacesOn(screenName, Compositor.topologyRevision) : null
        property var wins: []
        property var spaces: []
        property var winKeys: []
        property var byKey: ({})

        // Selection: window address ("" none) or, in Spaces mode, the tile index (windows mode = -1).
        property string selected: ""
        property int spaceFocus: -1
        // Drag state.
        property string dragKey: ""
        property point dragPoint: Qt.point(0, 0)
        property int dropIndex: -1

        readonly property real barBottom: Tokens.overviewBarTopMargin + Tokens.overviewTileHeight
        // Free region in this window's coordinates (the overlay starts below the menu bar). Taken
        // from the screen, never from the window size, which is 0 until the compositor configures
        // the layer surface.
        readonly property var area: ({
                x: Tokens.overviewAreaMargin,
                y: barBottom + Tokens.overviewAreaMargin,
                w: modelData.width - 2 * Tokens.overviewAreaMargin,
                h: modelData.height - Tokens.menubarHeight - barBottom - 2 * Tokens.overviewAreaMargin - Tokens.overviewLabelHeight
            })
        // Layout of `wins`, recomputed only when the inputs change (see relayout()).
        property var placement: ({
                scale: Tokens.overviewMaxScale,
                rects: []
            })
        property string layoutSignature: ""

        // Window rectangles in this window's coordinates, laid out when the window ids, rects or
        // the area actually changed (toplevel refreshes re-deliver identical data).
        function relayout(): void {
            const a = area;
            if (!(a.w > 1 && a.h > 1))
                return;
            const input = wins.map(w => ({
                        id: w.address,
                        x: w.x,
                        y: w.y - Tokens.menubarHeight,
                        w: w.w,
                        h: w.h
                    }));
            const sig = Layout.signature(input, a);
            if (sig === layoutSignature)
                return;
            layoutSignature = sig;
            placement = Layout.layout(input, a, {
                maxScale: Tokens.overviewMaxScale,
                gap: Tokens.overviewMinGap
            });
        }
        onAreaChanged: relayout()
        readonly property var placedMap: {
            const m = {};
            for (const r of placement.rects)
                m[r.id] = r;
            return m;
        }
        readonly property var tiles: spaces.concat([
            {
                plus: true,
                id: 0
            }
        ])

        screen: modelData
        // Persistent: created once per screen and kept mapped (transparent, no input) between
        // opens, so opening does not pay for a new surface and its first frame.
        readonly property bool active: shown || progress > 0.001
        visible: true
        mask: active ? null : emptyMask
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        // qmllint disable unqualified unresolved-type
        margins.top: Tokens.menubarHeight
        // qmllint enable unqualified unresolved-type
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: holdsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overview"
        // qmllint disable missing-type
        // The full-screen blur is re-computed by the compositor every frame while the surface
        // animates (swap up to 1 s); it is applied only once the zoom-in has finished and dropped
        // when the zoom-out starts. The dim animates on its own meanwhile.
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && shown && progress >= 1 ? blur : null
        // qmllint enable missing-type

        Region {
            id: emptyMask
        }

        Region {
            id: blur
            item: backdrop
        }

        Behavior on progress {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionSlow)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        onLiveWinsChanged: {
            if (!liveWins)
                return;
            wins = liveWins;
            relayout();
            const keys = liveWins.map(w => w.address);
            if (keys.join(",") !== winKeys.join(","))
                winKeys = keys;
            const map = {};
            for (const w of liveWins)
                map[w.address] = w;
            byKey = map;
            if (selected !== "" && !map[selected])
                selected = "";
        }

        onLiveSpacesChanged: {
            if (liveSpaces)
                spaces = liveSpaces;
        }

        onShownChanged: {
            if (shown) {
                selected = "";
                spaceFocus = -1;
                dragKey = "";
                keys.forceActiveFocus();
            }
        }

        onHoldsKeyboardChanged: {
            if (holdsKeyboard)
                keys.forceActiveFocus();
        }

        // ---- Actions ----

        function activateWindow(key: string): void {
            const info = byKey[key];
            if (info)
                root.controller.closeAnd(() => Compositor.activate(info.toplevel));
            else
                root.controller.hide();
        }

        // Esc / backdrop: closes and re-focuses the Space shown on this output now. Releasing
        // the exclusive keyboard grab lets Hyprland refocus its last window, which can live on
        // the previous Space (e.g. right after "+"), so the current Space is focused again once
        // the grab is gone.
        function closeKeepingSpace(): void {
            const mon = Compositor.monitorByName(screenName);
            const id = mon && mon.activeWorkspace ? mon.activeWorkspace.id : 0;
            root.controller.closeAnd(id > 0 ? () => Compositor.focusSpace(id) : null);
        }

        function switchSpace(id: int): void {
            root.controller.closeAnd(() => Compositor.focusSpace(id));
        }

        function addSpace(): void {
            Compositor.focusSpace(Compositor.nextSpaceId());
        }

        function activateTile(index: int): void {
            const tile = tiles[index];
            if (!tile)
                return;
            if (tile.plus)
                addSpace();
            else
                switchSpace(tile.id);
        }

        // Tile index under a point in window coordinates, -1 for none.
        function tileIndexAt(point: point): int {
            for (let i = 0; i < tileRepeater.count; i++) {
                const item = tileRepeater.itemAt(i);
                if (!item)
                    continue;
                const p = item.mapFromItem(contentRoot, point.x, point.y);
                if (p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= item.height)
                    return i;
            }
            return -1;
        }

        function dropWindow(key: string, index: int): void {
            const info = byKey[key];
            const tile = tiles[index];
            if (info && tile && !tile.plus && !tile.active)
                Compositor.moveToSpace(info.address, tile.id);
        }

        function selectDirection(dir: string): void {
            const rects = placement.rects;
            let at = -1;
            for (let i = 0; i < rects.length; i++) {
                if (rects[i].id === selected)
                    at = i;
            }
            if (at < 0) {
                // First arrow key: the focused window, else the first.
                const active = wins.findIndex(w => w.toplevel && w.toplevel === Compositor.focusedToplevel);
                const pick = rects.length > 0 ? rects[active >= 0 ? active : 0] : null;
                selected = pick ? pick.id : "";
                return;
            }
            const next = Layout.neighbor(rects, at, dir);
            if (next >= 0)
                selected = rects[next].id;
            else if (dir === "up" && tiles.length > 0)
                enterSpaces(spaces.findIndex(s => s.active));
        }

        function enterSpaces(index: int): void {
            spaceFocus = Math.max(0, Math.min(index, tiles.length - 1));
        }

        // Tab order: windows (-1), then each tile, then back to the windows.
        function cycle(step: int): void {
            let next = spaceFocus + step;
            if (next >= tiles.length || next < -1)
                next = step > 0 ? -1 : tiles.length - 1;
            spaceFocus = next;
        }

        function statusData(): var {
            return {
                name: screenName,
                width: width,
                height: height,
                progress: progress,
                scale: placement.scale,
                selected: selected,
                spaceFocus: spaceFocus,
                windows: wins.map(w => ({
                            address: w.address,
                            appId: w.appId,
                            title: w.title,
                            real: {
                                x: w.x,
                                y: w.y - Tokens.menubarHeight,
                                w: w.w,
                                h: w.h
                            },
                            rect: placedMap[w.address] ? {
                                x: placedMap[w.address].x,
                                y: placedMap[w.address].y,
                                w: placedMap[w.address].w,
                                h: placedMap[w.address].h
                            } : null
                        })),
                spaces: spaces.map(s => ({
                            id: s.id,
                            name: s.name,
                            active: s.active,
                            windowCount: s.windowCount
                        }))
            };
        }

        Item {
            id: contentRoot
            anchors.fill: parent
            visible: win.active
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Overview")

            // Dimmed, blurred backdrop. A click on it closes Overview.
            Rectangle {
                id: backdrop
                anchors.fill: parent
                color: Appearance.withAlpha(Appearance.colors.shadow, Appearance.effectiveTransparency > 0 ? Tokens.overviewBackdropOpacity : Tokens.overviewBackdropOpacityOpaque)
                opacity: win.progress

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: {
                        root.controller.keyScreen = win.screenName;
                        win.closeKeepingSpace();
                    }
                }
            }

            // Keyboard: arrows move the selection, Return focuses, Tab cycles the Spaces bar, Esc closes.
            Item {
                id: keys
                focus: true
                Accessible.ignored: true

                Keys.onPressed: event => {
                    const inSpaces = win.spaceFocus >= 0;
                    event.accepted = true;
                    switch (event.key) {
                    case Qt.Key_Escape:
                        // Release-then-act as for the other actions: staying on a Space just
                        // created with "+" instead of returning to the previous one.
                        win.closeKeepingSpace();
                        break;
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        if (inSpaces)
                            win.activateTile(win.spaceFocus);
                        else if (win.selected !== "")
                            win.activateWindow(win.selected);
                        break;
                    case Qt.Key_Tab:
                        win.cycle((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                        break;
                    case Qt.Key_Backtab:
                        win.cycle(-1);
                        break;
                    case Qt.Key_Left:
                    case Qt.Key_Right:
                        if (inSpaces)
                            win.enterSpaces(win.spaceFocus + (event.key === Qt.Key_Left ? -1 : 1));
                        else
                            win.selectDirection(event.key === Qt.Key_Left ? "left" : "right");
                        break;
                    case Qt.Key_Down:
                        if (inSpaces)
                            win.spaceFocus = -1;
                        else
                            win.selectDirection("down");
                        break;
                    case Qt.Key_Up:
                        if (!inSpaces)
                            win.selectDirection("up");
                        break;
                    default:
                        event.accepted = false;
                    }
                }
            }

            // Spaces bar.
            Row {
                id: bar
                spacing: Tokens.overviewTileGap
                x: (win.width - width) / 2
                y: Tokens.overviewBarTopMargin - (Appearance.reduceMotion ? 0 : (1 - win.progress) * (Tokens.overviewTileHeight + Tokens.overviewBarTopMargin))
                opacity: win.progress
                Accessible.role: Accessible.List
                Accessible.name: qsTr("Spaces")

                Repeater {
                    id: tileRepeater
                    model: win.tiles

                    delegate: Rectangle {
                        id: tile

                        required property var modelData
                        required property int index

                        readonly property bool isPlus: modelData.plus === true
                        readonly property bool dropTarget: win.dragKey !== "" && win.dropIndex === index && !isPlus && !modelData.active
                        readonly property bool focused: win.spaceFocus === index
                        readonly property int shownIcons: isPlus ? 0 : Math.min(modelData.appIds.length, Tokens.overviewTileMaxIcons)

                        width: Tokens.overviewTileWidth
                        height: Tokens.overviewTileHeight
                        radius: Tokens.radiusDialog
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * (dropTarget ? 3 : (tileMouse.containsMouse ? 2 : 1)))
                        border.width: modelData.active || focused || dropTarget ? Tokens.overviewSelectionWidth : 1
                        border.color: modelData.active || focused || dropTarget ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
                        Accessible.role: Accessible.Button
                        Accessible.name: isPlus ? qsTr("Add Desktop") : qsTr("Desktop %1").arg(modelData.id)
                        Accessible.onPressAction: win.activateTile(index)

                        Text {
                            visible: !tile.isPlus
                            anchors.top: parent.top
                            anchors.topMargin: Tokens.spacingSm
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: qsTr("Desktop %1").arg(tile.modelData.id)
                            textFormat: Text.PlainText
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.weight: Tokens.typographyMenuWeight
                        }

                        Row {
                            visible: !tile.isPlus
                            anchors.centerIn: parent
                            spacing: Tokens.spacingXs

                            Repeater {
                                model: tile.shownIcons

                                delegate: IconImage {
                                    id: tileIcon
                                    required property int index
                                    implicitSize: Tokens.overviewTileIconSize
                                    source: Quickshell.iconPath(Apps.lookup(tile.modelData.appIds[index]) ? Apps.lookup(tile.modelData.appIds[index]).icon : "", "application-x-executable")
                                    smooth: true
                                    mipmap: true
                                }
                            }
                        }

                        Text {
                            visible: !tile.isPlus
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: Tokens.spacingSm
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: tile.modelData.windowCount === 1 ? qsTr("1 window") : qsTr("%1 windows").arg(tile.isPlus ? 0 : tile.modelData.windowCount)
                            textFormat: Text.PlainText
                            color: Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyCaptionSize
                        }

                        Text {
                            visible: tile.isPlus
                            anchors.centerIn: parent
                            text: "+"
                            textFormat: Text.PlainText
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyTitleSize * 2
                            font.weight: Tokens.typographySmallWeight
                        }

                        MouseArea {
                            id: tileMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.controller.keyScreen = win.screenName;
                                win.activateTile(tile.index);
                            }
                        }
                    }
                }
            }

            // Window thumbnails.
            Repeater {
                model: root.controller.thumbnailMode ? win.winKeys : []

                delegate: Item {
                    id: thumb

                    required property string modelData

                    readonly property var info: win.byKey[modelData]
                    readonly property var target: win.placedMap[modelData]
                    readonly property bool valid: info !== undefined && target !== undefined
                    readonly property bool isSelected: win.selected === modelData && win.spaceFocus < 0
                    readonly property bool dragging: win.dragKey === modelData

                    // Layout rectangle, animated when the layout changes while open.
                    property real tx: target ? target.x : 0
                    property real ty: target ? target.y : 0
                    property real tw: target ? target.w : 1
                    property real th: target ? target.h : 1
                    property real ox: 0
                    property real oy: 0

                    readonly property real realX: info ? info.x : 0
                    readonly property real realY: info ? info.y - Tokens.menubarHeight : 0
                    readonly property real realW: info ? info.w : 1
                    readonly property real realH: info ? info.h : 1

                    visible: valid
                    x: realX + (tx - realX) * win.zoom + ox
                    y: realY + (ty - realY) * win.zoom + oy
                    width: Math.max(1, realW + (tw - realW) * win.zoom)
                    height: Math.max(1, realH + (th - realH) * win.zoom)
                    z: dragging ? 100 : (isSelected ? 2 : 1)
                    opacity: (dragging ? Tokens.overviewDragOpacity : 1) * (Appearance.reduceMotion ? win.progress : 1)
                    Accessible.role: Accessible.Button
                    Accessible.name: info ? (info.title !== "" ? info.title : Apps.nameFor(info.appId)) : ""
                    Accessible.onPressAction: win.activateWindow(modelData)

                    Behavior on tx {
                        enabled: win.progress >= 1
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on ty {
                        enabled: win.progress >= 1
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on tw {
                        enabled: win.progress >= 1
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on th {
                        enabled: win.progress >= 1
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on ox {
                        enabled: !thumb.dragging
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }
                    Behavior on oy {
                        enabled: !thumb.dragging
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }

                    // Rounded mask for the live content.
                    Rectangle {
                        id: maskShape
                        anchors.fill: parent
                        radius: Tokens.overviewThumbRadius
                        visible: false
                        layer.enabled: true
                    }

                    Item {
                        id: clipper
                        anchors.fill: parent
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: maskShape
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: Appearance.withAlpha(Appearance.colors.materialTint, 1)
                        }

                        ScreencopyView {
                            id: view
                            anchors.fill: parent
                            captureSource: thumb.info ? thumb.info.toplevel : null
                            live: root.controller.profile === "full"
                            paintCursor: false
                            // A single frame can only be requested once the capture context knows
                            // the buffer size (sourceSize); earlier calls warn "Cannot capture frame".
                            readonly property bool ready: captureSource !== null && sourceSize.width > 0 && sourceSize.height > 0
                            property bool snapshotTaken: false
                            function snapshot(): void {
                                if (!live && ready && !snapshotTaken) {
                                    snapshotTaken = true;
                                    captureFrame();
                                }
                            }
                            onReadyChanged: snapshot()
                            onLiveChanged: snapshot()
                            onCaptureSourceChanged: snapshotTaken = false
                        }
                    }

                    // Balanced profile: one captured frame every balancedIntervalMs.
                    Timer {
                        interval: Tokens.overviewBalancedIntervalMs
                        repeat: true
                        running: root.controller.profile === "balanced" && win.shown && thumb.visible && view.ready
                        onTriggered: {
                            view.captureFrame();
                        }
                    }

                    // Selection / hover outline.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -Tokens.overviewSelectionWidth
                        radius: Tokens.overviewThumbRadius + Tokens.overviewSelectionWidth
                        color: "transparent"
                        border.width: Tokens.overviewSelectionWidth
                        border.color: Appearance.colors.accent
                        visible: thumb.isSelected
                    }

                    MouseArea {
                        id: thumbMouse
                        property point pressAt: Qt.point(0, 0)
                        property bool moved: false

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        onEntered: {
                            if (win.dragKey === "") {
                                win.spaceFocus = -1;
                                win.selected = thumb.modelData;
                            }
                        }
                        onPressed: mouse => {
                            root.controller.keyScreen = win.screenName;
                            pressAt = mapToItem(contentRoot, mouse.x, mouse.y);
                            moved = false;
                        }
                        onPositionChanged: mouse => {
                            if (!pressed)
                                return;
                            const p = mapToItem(contentRoot, mouse.x, mouse.y);
                            const dx = p.x - pressAt.x;
                            const dy = p.y - pressAt.y;
                            if (!moved && Math.hypot(dx, dy) > Tokens.overviewDragThreshold) {
                                moved = true;
                                win.dragKey = thumb.modelData;
                            }
                            if (moved) {
                                thumb.ox = dx;
                                thumb.oy = dy;
                                win.dragPoint = p;
                                win.dropIndex = win.tileIndexAt(p);
                            }
                        }
                        onReleased: mouse => {
                            if (!moved) {
                                win.activateWindow(thumb.modelData);
                                return;
                            }
                            const index = win.tileIndexAt(mapToItem(contentRoot, mouse.x, mouse.y));
                            const key = thumb.modelData;
                            win.dragKey = "";
                            win.dropIndex = -1;
                            thumb.ox = 0;
                            thumb.oy = 0;
                            if (index >= 0)
                                win.dropWindow(key, index);
                        }
                        onCanceled: {
                            win.dragKey = "";
                            win.dropIndex = -1;
                            thumb.ox = 0;
                            thumb.oy = 0;
                        }
                    }
                }
            }

            // App icon and name under the selected (hovered) window.
            Material {
                id: label

                readonly property var info: win.selected !== "" && win.spaceFocus < 0 ? win.byKey[win.selected] : undefined
                readonly property var rect: win.selected !== "" ? win.placedMap[win.selected] : undefined
                readonly property var entry: info ? Apps.lookup(info.appId) : null
                readonly property string appName: info ? Apps.nameFor(info.appId) : ""

                visible: info !== undefined && rect !== undefined && win.dragKey === ""
                opacity: win.progress >= 1 ? 1 : 0
                radius: Tokens.overviewLabelHeight / 2
                shadowEnabled: false
                width: Math.min(Tokens.overviewLabelMaxWidth, labelRow.implicitWidth + 2 * Tokens.spacingMd)
                height: Tokens.overviewLabelHeight
                x: rect ? Math.max(Tokens.spacingSm, Math.min(win.width - width - Tokens.spacingSm, rect.x + (rect.w - width) / 2)) : 0
                y: rect ? Math.min(win.height - height - Tokens.spacingSm, rect.y + rect.h + Tokens.spacingSm) : 0
                z: 50
                Accessible.role: Accessible.StaticText
                Accessible.name: appName

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                    }
                }

                Row {
                    id: labelRow
                    anchors.centerIn: parent
                    spacing: Tokens.spacingSm

                    IconImage {
                        implicitSize: Tokens.overviewLabelIconSize
                        anchors.verticalCenter: parent.verticalCenter
                        source: Quickshell.iconPath(label.entry ? label.entry.icon : "", "application-x-executable")
                        smooth: true
                        mipmap: true
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, Tokens.overviewLabelMaxWidth - 2 * Tokens.spacingMd - Tokens.overviewLabelIconSize - Tokens.spacingSm)
                        text: label.appName
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        font.weight: Tokens.typographyMenuWeight
                    }
                }
            }
        }
    }
}
