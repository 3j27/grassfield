pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import "Model.js" as Model

// Apps overlay, one per screen, mapped on the controller's screen only: a full-screen layer-shell
// window with a dimmed, blurred backdrop, the search field, the paged grid, page dots, the open
// folder panel and the drag ghost. Keyboard exclusive while open.
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

        readonly property bool shown: root.controller.open && root.controller.screenName === modelData.name
        // 0 = hidden, 1 = fully shown (fade and slight scale; Reduce Motion: fade only).
        property real progress: shown ? 1 : 0

        screen: modelData
        visible: shown || progress > 0.001
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-apps"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: backdrop
        }

        Behavior on progress {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionNormal)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        onShownChanged: {
            if (shown) {
                field.text = "";
                field.forceActiveFocus();
                firstFrame.done = false;
            } else {
                host.cancelDrag();
            }
        }

        // Logs IPC call -> first rendered frame once per opening (P3).
        Connections {
            id: firstFrame

            property bool done: true

            target: win.shown ? host.Window.window : null

            function onFrameSwapped(): void {
                if (done)
                    return;
                done = true;
                console.info("grassfield-shell: apps open->visible", Date.now() - root.controller.openStartMs, "ms,", root.controller.items.length, "items");
            }
        }

        // Logs query change -> next rendered frame when a keystroke takes more than three frames.
        Connections {
            target: win.shown && root.controller.searchStartMs > 0 ? host.Window.window : null

            function onFrameSwapped(): void {
                const start = root.controller.searchStartMs;
                if (start === 0)
                    return;
                root.controller.searchStartMs = 0;
                if (root.controller.trace || Date.now() - start > 50)
                    console.info("grassfield-shell: apps search->frame", Date.now() - start, "ms,", root.controller.items.length, "items");
            }
        }

        Rectangle {
            id: backdrop
            anchors.fill: parent
            opacity: win.progress
            color: Qt.rgba(0, 0, 0, Appearance.effectiveTransparency > 0 ? Tokens.appsBackdropOpacity : Tokens.appsBackdropOpacityOpaque)
        }

        Item {
            id: host

            readonly property var controller: root.controller
            readonly property var g: root.controller.grid
            readonly property real gridX: (width - g.gridW) / 2
            readonly property real gridY: Math.max(Tokens.appsSearchTop + Tokens.appsSearchHeight + Tokens.spacingLg, (height - g.gridH) / 2)

            // Drag state (grid drags and folder drags share it).
            property bool dragging: false
            property string dragKey: ""
            property var dragInfo: null
            property bool dragFromFolder: false
            property real dragX: 0
            property real dragY: 0
            property int hoverIndex: -1
            property bool hoverMerge: false
            property int flipDirection: 0

            anchors.fill: parent
            opacity: win.progress
            scale: Appearance.reduceMotion ? 1 : Tokens.appsOpenScale + (1 - Tokens.appsOpenScale) * win.progress

            function beginDrag(info: var, x: real, y: real, fromFolder: bool): void {
                dragInfo = info;
                dragKey = info.key;
                dragFromFolder = fromFolder;
                root.controller.pinnedKey = info.key;
                dragX = x;
                dragY = y;
                dragging = true;
                updateHover();
            }

            function dragMove(x: real, y: real): void {
                dragX = x;
                dragY = y;
                updateHover();
                const edge = Tokens.appsEdgeFlip;
                const dir = x < edge ? -1 : (x > width - edge ? 1 : 0);
                if (dir !== flipDirection) {
                    flipDirection = dir;
                    if (dir !== 0)
                        flipTimer.restart();
                    else
                        flipTimer.stop();
                }
            }

            function updateHover(): void {
                if (dragFromFolder) {
                    hoverIndex = -1;
                    return;
                }
                const c = root.controller;
                const hit = Model.cellAt(dragX - gridX, dragY - gridY, g, c.page, c.items.length, Tokens.appsMergeFraction);
                hoverIndex = hit.index;
                const target = hit.index >= 0 ? c.items[hit.index] : null;
                hoverMerge = hit.center && target !== null && target.key !== dragKey && dragInfo.kind === "app";
            }

            function clearDrag(): void {
                flipTimer.stop();
                flipDirection = 0;
                dragging = false;
                dragKey = "";
                dragInfo = null;
                root.controller.pinnedKey = "";
                hoverIndex = -1;
                hoverMerge = false;
            }

            function cancelDrag(): void {
                if (dragging)
                    clearDrag();
            }

            function endDrag(): void {
                if (!dragging)
                    return;
                const c = root.controller;
                const key = dragKey;
                const id = dragInfo.id;
                const idx = hoverIndex;
                const merge = hoverMerge;
                const fromFolder = dragFromFolder;
                const px = dragX;
                const py = dragY;
                clearDrag();
                if (fromFolder) {
                    // Dropped outside the folder panel: the app leaves the folder.
                    const r = panel.mapToItem(host, 0, 0);
                    const outside = px < r.x || py < r.y || px > r.x + panel.width || py > r.y + panel.height;
                    if (outside && c.folder) {
                        c.removeFromFolder(c.folder.key, id);
                        c.closeFolder();
                    }
                    return;
                }
                const hit = Model.cellAt(px - gridX, py - gridY, c.grid, c.page, c.items.length + 1000, Tokens.appsMergeFraction);
                // A drop on the empty part of the grid after the last item moves to the end.
                let to = idx;
                if (to < 0 && hit.index >= 0)
                    to = c.items.length - 1;
                if (to < 0)
                    return;
                if (merge) {
                    // Dropping onto an app creates "Untitled" and starts renaming it.
                    const created = c.items[to].kind === "app";
                    const folderKey = c.mergeItem(key, to);
                    if (folderKey !== "")
                        c.openFolder(folderKey, created);
                } else {
                    c.moveItem(key, to);
                }
            }

            Timer {
                id: flipTimer
                interval: Tokens.appsEdgeFlipDelay
                repeat: true
                onTriggered: {
                    if (host.flipDirection !== 0) {
                        root.controller.flip(host.flipDirection);
                        host.updateHover();
                    }
                }
            }

            // Focuses the open folder's name field with its text selected (typing renames it).
            function startRename(): void {
                if (!root.controller.folder)
                    return;
                nameField.forceActiveFocus();
                nameField.selectAll();
            }

            // Closes the open folder, committing a rename in progress first.
            function closeFolderCommitted(): void {
                nameField.commit();
                root.controller.closeFolder();
            }

            function handleKey(event: var, inField: bool): void {
                const c = root.controller;
                if (nameField.activeFocus)
                    return;
                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Escape:
                    if (c.folder)
                        c.closeFolder();
                    else if (field.text !== "")
                        field.text = "";
                    else
                        c.hide();
                    return;
                case Qt.Key_Tab:
                case Qt.Key_Backtab:
                    if (inField) {
                        keys.forceActiveFocus();
                        c.keyNav = true;
                        if (c.selected < 0 && c.items.length > 0)
                            c.selected = c.page * c.grid.perPage;
                    } else {
                        c.keyNav = false;
                        field.forceActiveFocus();
                    }
                    return;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    if (c.folder && c.folderSelected < 0)
                        host.startRename();
                    else if (c.folder || c.selected >= 0)
                        c.activateSelected();
                    else if (c.searching && c.items.length > 0)
                        c.activate(c.items[0]);
                    return;
                case Qt.Key_F2:
                    if (c.folder)
                        host.startRename();
                    return;
                case Qt.Key_Left:
                case Qt.Key_Right:
                case Qt.Key_Home:
                case Qt.Key_End:
                    if (inField && field.text !== "") {
                        event.accepted = false;
                        return;
                    }
                    break;
                case Qt.Key_Up:
                case Qt.Key_Down:
                case Qt.Key_PageUp:
                case Qt.Key_PageDown:
                    break;
                default:
                    if (!inField && event.text !== "" && event.text.charCodeAt(0) >= 32 && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier)) === 0) {
                        c.keyNav = false;
                        field.forceActiveFocus();
                        field.insert(field.length, event.text);
                    } else if (!inField && event.key === Qt.Key_Backspace && field.text !== "") {
                        field.forceActiveFocus();
                        field.text = field.text.slice(0, -1);
                    } else {
                        event.accepted = inField ? false : true;
                    }
                    return;
                }
                if (inField) {
                    keys.forceActiveFocus();
                    c.keyNav = true;
                }
                switch (event.key) {
                case Qt.Key_Left:
                    c.move("left");
                    break;
                case Qt.Key_Right:
                    c.move("right");
                    break;
                case Qt.Key_Up:
                    c.move("up");
                    break;
                case Qt.Key_Down:
                    c.move("down");
                    break;
                case Qt.Key_Home:
                    c.move("home");
                    break;
                case Qt.Key_End:
                    c.move("end");
                    break;
                case Qt.Key_PageUp:
                    c.flip(-1);
                    break;
                case Qt.Key_PageDown:
                    c.flip(1);
                    break;
                }
            }

            // Empty space: click closes, a horizontal swipe flips the page; the wheel flips too.
            MouseArea {
                id: background

                property real startX: 0
                property real wheelAcc: 0
                property real lastFlip: 0

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onPressed: mouse => startX = mouse.x
                onReleased: mouse => {
                    const dx = mouse.x - startX;
                    if (Math.abs(dx) >= Tokens.appsSwipeThreshold)
                        root.controller.flip(dx < 0 ? 1 : -1);
                    else if (root.controller.folder)
                        host.closeFolderCommitted();
                    else
                        root.controller.hide();
                }
                onWheel: wheel => {
                    if (root.controller.folder)
                        return;
                    const d = Math.abs(wheel.angleDelta.x) > Math.abs(wheel.angleDelta.y) ? -wheel.angleDelta.x : -wheel.angleDelta.y;
                    wheelAcc += d;
                    if (Math.abs(wheelAcc) >= Tokens.appsWheelThreshold) {
                        const now = Date.now();
                        if (now - lastFlip > Tokens.motionNormal) {
                            root.controller.flip(wheelAcc > 0 ? 1 : -1);
                            lastFlip = now;
                        }
                        wheelAcc = 0;
                    }
                }
            }

            FocusScope {
                id: keys
                anchors.fill: parent
                Keys.onPressed: event => host.handleKey(event, false)
            }

            // Search field.
            Rectangle {
                id: searchBox
                x: (host.width - width) / 2
                y: Tokens.appsSearchTop
                width: Tokens.appsSearchWidth
                height: Tokens.appsSearchHeight
                radius: height / 2
                color: Appearance.withAlpha(Appearance.darkColors.shadow, Tokens.appsSearchFillOpacity)
                border.width: field.activeFocus ? Tokens.controlFocusRing : Tokens.appsBorderWidth
                border.color: field.activeFocus ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Search")

                Icon {
                    id: glass
                    x: Tokens.spacingMd
                    y: (parent.height - height) / 2
                    size: Tokens.menuIconSize
                    name: "search"
                    color: Appearance.darkColors.textSecondary
                }

                TextInput {
                    id: field
                    x: glass.x + glass.width + Tokens.spacingSm
                    width: parent.width - x - Tokens.spacingMd
                    height: parent.height
                    verticalAlignment: TextInput.AlignVCenter
                    color: Appearance.darkColors.text
                    selectionColor: Appearance.colors.accent
                    selectedTextColor: Appearance.colors.accentText
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    clip: true
                    focus: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: qsTr("Search")
                    Accessible.description: qsTr("Type to filter applications")

                    onTextChanged: {
                        if (win.shown)
                            root.controller.setQuery(text);
                    }
                    Keys.onPressed: event => host.handleKey(event, true)

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: field.text === "" && field.preeditText === ""
                        text: qsTr("Search")
                        textFormat: Text.PlainText
                        color: Appearance.darkColors.textSecondary
                        font: field.font
                    }
                }
            }

            // Paged grid.
            AppsGrid {
                id: grid
                x: host.gridX
                y: host.gridY
                controller: root.controller
                host: host
            }

            Text {
                anchors.centerIn: parent
                visible: root.controller.searching && root.controller.items.length === 0
                text: qsTr("No results")
                textFormat: Text.PlainText
                color: Appearance.darkColors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyTitleSize
            }

            // Page dots.
            Row {
                id: dots
                visible: root.controller.pageCount > 1
                spacing: 0
                x: (host.width - width) / 2
                y: host.height - Tokens.appsDotBottom - Tokens.appsDotSize
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Pages")

                Repeater {
                    model: root.controller.pageCount

                    Item {
                        id: dot

                        required property int index
                        readonly property bool current: index === root.controller.page

                        width: Tokens.appsDotSize + Tokens.appsDotGap
                        height: Tokens.appsDotSize + Tokens.appsDotGap
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Page %1").arg(index + 1)
                        Accessible.checked: current
                        Accessible.onPressAction: root.controller.setPage(index)

                        Rectangle {
                            anchors.centerIn: parent
                            width: Tokens.appsDotSize
                            height: Tokens.appsDotSize
                            radius: width / 2
                            color: Appearance.darkColors.text
                            opacity: dot.current ? 1 : Tokens.appsDotInactiveOpacity
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.controller.setPage(dot.index)
                        }
                    }
                }
            }

            // Open folder.
            MouseArea {
                anchors.fill: parent
                visible: root.controller.folder !== null
                acceptedButtons: Qt.AllButtons
                onClicked: host.closeFolderCommitted()

                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, Tokens.appsBackdropOpacity)
                }
            }

            Item {
                id: panel

                readonly property var folder: root.controller.folder
                readonly property int count: folder ? folder.apps.length : 0
                readonly property int cols: Math.max(1, Math.min(Tokens.appsFolderPanelCols, count))
                readonly property int rows: Math.max(1, Math.ceil(count / cols))
                readonly property real cellW: host.g.cellW * Tokens.appsFolderPanelIconScale
                readonly property real cellH: host.g.cellH * Tokens.appsFolderPanelIconScale
                readonly property real pad: Tokens.appsFolderPanelPadding
                readonly property real nameHeight: Tokens.appsFolderNameSize * 2
                readonly property var none: ({kind: "none", key: "", name: ""})

                visible: folder !== null
                width: Math.max(cols * cellW, Tokens.appsFolderNameWidth) + 2 * pad
                height: nameHeight + rows * cellH + 2 * pad
                x: (host.width - width) / 2
                y: (host.height - height) / 2
                opacity: folder ? 1 : 0
                scale: Appearance.reduceMotion ? 1 : (folder ? 1 : Tokens.appsOpenScale)
                Accessible.role: Accessible.Dialog
                Accessible.name: folder ? qsTr("Folder %1").arg(folder.name) : ""

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                    }
                }

                Behavior on scale {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionNormal)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curve
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: keys.forceActiveFocus()
                }

                Material {
                    id: panelMaterial
                    anchors.fill: parent
                    radius: Tokens.radiusPanel
                }

                TextInput {
                    id: nameField
                    y: panel.pad / 2
                    x: (panel.width - width) / 2
                    width: Tokens.appsFolderNameWidth
                    height: panel.nameHeight
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    color: Appearance.darkColors.text
                    selectionColor: Appearance.colors.accent
                    selectedTextColor: Appearance.colors.accentText
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.appsFolderNameSize
                    font.weight: Tokens.typographyMenuBoldWeight
                    clip: true
                    maximumLength: 120
                    Accessible.role: Accessible.EditableText
                    Accessible.name: qsTr("Folder name")

                    function commit(): void {
                        const f = root.controller.folder;
                        if (!f)
                            return;
                        if (text === f.name)
                            return;
                        if (text.trim() !== "")
                            root.controller.renameFolderTo(f.key, text);
                        else
                            text = f.name;
                    }

                    onEditingFinished: commit()
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape || event.key === Qt.Key_Tab) {
                            event.accepted = true;
                            // Escape cancels the rename and keeps the folder; the others commit.
                            if (event.key === Qt.Key_Escape && root.controller.folder)
                                text = root.controller.folder.name;
                            else
                                commit();
                            keys.forceActiveFocus();
                            root.controller.keyNav = true;
                            if (root.controller.folderSelected < 0)
                                root.controller.folderSelected = 0;
                            root.controller.renameFolder = false;
                        }
                    }
                }

                Rectangle {
                    // Keyboard focus ring of the title (Up from the first row; Return renames).
                    visible: root.controller.folderSelected < 0 && root.controller.keyNav && !nameField.activeFocus
                    x: nameField.x - Tokens.spacingSm
                    y: nameField.y
                    width: nameField.width + 2 * Tokens.spacingSm
                    height: nameField.height
                    radius: Tokens.radiusControl
                    color: "transparent"
                    border.width: Tokens.appsSelectionWidth
                    border.color: Appearance.colors.accent
                }

                Connections {
                    target: root.controller

                    // `folder` is derived from the items and is not yet set when folderKey changes, so
                    // the name field follows `folder`: it takes the name and, for a folder just
                    // created by a drop, the focus with the text selected.
                    function onFolderChanged(): void {
                        const f = root.controller.folder;
                        if (!f || nameField.activeFocus)
                            return;
                        if (nameField.text !== f.name)
                            nameField.text = f.name;
                        if (root.controller.renameFolder)
                            Qt.callLater(host.startRename);
                    }

                    function onFolderKeyChanged(): void {
                        if (root.controller.folderKey === "")
                            nameField.text = "";
                        if (!root.controller.renameFolder)
                            keys.forceActiveFocus();
                    }
                }

                Repeater {
                    model: panel.count

                    AppsCell {
                        required property int index

                        itemIndex: index
                        info: panel.folder && panel.folder.apps[index] ? panel.folder.apps[index] : panel.none
                        host: host
                        inFolder: true
                        cellW: panel.cellW
                        cellH: panel.cellH
                        iconSize: host.g.icon * Tokens.appsFolderPanelIconScale
                        selected: root.controller.folderSelected === index
                        x: panel.pad + (panel.width - 2 * panel.pad - panel.cols * panel.cellW) / 2 + (index % panel.cols) * panel.cellW
                        y: panel.pad + panel.nameHeight + Math.floor(index / panel.cols) * panel.cellH
                        onActivated: root.controller.launch(info.rec)
                    }
                }
            }

            // Drag ghost.
            Item {
                visible: host.dragging && host.dragInfo !== null
                x: host.dragX - width / 2
                y: host.dragY - height / 2
                width: host.g.icon
                height: host.g.icon
                scale: Tokens.appsDragScale
                opacity: Tokens.appsDragOpacity
                z: 100
                enabled: false

                Loader {
                    active: host.dragging && host.dragInfo !== null
                    anchors.fill: parent
                    sourceComponent: AppsIcon {
                        size: host.g.icon
                        info: host.dragInfo
                    }
                }
            }
        }
    }
}
