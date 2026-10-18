pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "Model.js" as Model

// Apps overlay, one per screen, mapped on the controller's screen only: a transparent full-screen
// layer-shell window (a click outside the panel closes it) holding the floating panel: search field,
// category chips and the scrolling grid. Keyboard exclusive while open. The panel is a frosted
// Material; the compositor blurs the region of `frame` (never faked).
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
            item: frame
            radius: Tokens.launcherPanelRadius
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
                grid.positionViewAtBeginning();
                host.focusZone("search");
                firstFrame.done = false;
            }
        }

        // Logs IPC call -> first rendered frame once per opening (P3).
        Connections {
            id: firstFrame

            property bool done: true

            target: win.shown ? frame.Window.window : null

            function onFrameSwapped(): void {
                if (done)
                    return;
                done = true;
                console.info("grassfield-shell: apps open->visible", Date.now() - root.controller.openStartMs, "ms,", root.controller.items.length, "items");
            }
        }

        // Logs query change -> next rendered frame when a keystroke takes more than three frames.
        Connections {
            target: win.shown && root.controller.searchStartMs > 0 ? frame.Window.window : null

            function onFrameSwapped(): void {
                const start = root.controller.searchStartMs;
                if (start === 0)
                    return;
                root.controller.searchStartMs = 0;
                if (root.controller.trace || Date.now() - start > 50)
                    console.info("grassfield-shell: apps search->frame", Date.now() - start, "ms,", root.controller.items.length, "items");
            }
        }

        // The field follows the controller's query (a chip click clears it).
        Connections {
            target: win.shown ? root.controller : null

            function onQueryChanged(): void {
                if (field.text !== root.controller.query)
                    field.text = root.controller.query;
            }

            function onItemsChanged(): void {
                grid.positionViewAtBeginning();
                host.updateView();
            }

            function onSelectedChanged(): void {
                if (root.controller.selected >= 0)
                    grid.positionViewAtIndex(root.controller.selected, GridView.Contain);
            }
        }

        Item {
            id: host

            readonly property var c: root.controller
            readonly property var zones: ["search", "chips", "grid"]

            anchors.fill: parent

            // Moves the keyboard focus to a zone (the controller records it).
            function focusZone(z: string): void {
                c.setZone(z);
                if (z === "search")
                    field.forceActiveFocus();
                else
                    keys.forceActiveFocus();
            }

            // Tab order: search, chips, grid (the grid is skipped while it is empty).
            function cycleZone(dir: int): void {
                const order = c.items.length > 0 ? zones : ["search", "chips"];
                const i = Math.max(0, order.indexOf(c.zone));
                focusZone(order[(i + dir + order.length) % order.length]);
            }

            // Publishes the first and last item whose row is in the view (IPC status, tests).
            function updateView(): void {
                if (!win.shown)
                    return;
                const n = c.items.length;
                if (n === 0) {
                    c.viewFirst = -1;
                    c.viewLast = -1;
                    return;
                }
                const cols = c.grid.cols;
                const cellH = c.grid.cellH;
                c.viewFirst = Math.min(n - 1, Math.floor(Math.max(0, grid.contentY) / cellH) * cols);
                c.viewLast = Math.min(n - 1, (Math.floor((Math.max(0, grid.contentY) + grid.height - 1) / cellH) + 1) * cols - 1);
            }

            function handleKey(event: var, inField: bool): void {
                event.accepted = true;
                const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
                const pageRows = Model.visibleRows(grid.height, c.grid.cellH);
                switch (event.key) {
                case Qt.Key_Escape:
                    if (field.text !== "")
                        field.text = "";
                    else
                        c.hide();
                    return;
                case Qt.Key_Tab:
                case Qt.Key_Backtab:
                    // Some injectors (wtype) deliver Shift+Tab as Tab with Shift held.
                    cycleZone(event.key === Qt.Key_Backtab || shift ? -1 : 1);
                    return;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    if (c.zone === "chips")
                        c.selectCategory(c.chipFocus);
                    else
                        c.activateSelected();
                    return;
                case Qt.Key_Space:
                    if (c.zone === "chips") {
                        c.selectCategory(c.chipFocus);
                        return;
                    }
                    break;
                case Qt.Key_Left:
                case Qt.Key_Right:
                case Qt.Key_Home:
                case Qt.Key_End:
                    if (c.zone === "search") {
                        // The field handles its own caret; with no text there is nothing to move.
                        event.accepted = field.text === "";
                        return;
                    }
                    if (c.zone === "chips") {
                        if (event.key === Qt.Key_Left)
                            c.moveChip(-1);
                        else if (event.key === Qt.Key_Right)
                            c.moveChip(1);
                        else
                            c.moveChip(event.key === Qt.Key_Home ? -c.chips.length : c.chips.length);
                        return;
                    }
                    c.move(event.key === Qt.Key_Left ? "left" : (event.key === Qt.Key_Right ? "right" : (event.key === Qt.Key_Home ? "home" : "end")), pageRows);
                    return;
                case Qt.Key_Up:
                case Qt.Key_Down:
                case Qt.Key_PageUp:
                case Qt.Key_PageDown: {
                    const down = event.key === Qt.Key_Down || event.key === Qt.Key_PageDown;
                    if (c.zone === "search") {
                        if (down && c.items.length > 0)
                            focusZone("grid");
                        return;
                    }
                    if (c.zone === "chips") {
                        if (down) {
                            if (c.items.length > 0)
                                focusZone("grid");
                        } else {
                            focusZone("search");
                        }
                        return;
                    }
                    const key = event.key === Qt.Key_Up ? "up" : (event.key === Qt.Key_Down ? "down" : (event.key === Qt.Key_PageUp ? "pageup" : "pagedown"));
                    // Up from the first row leaves the grid: to the chips, or to the field while searching.
                    if (!c.move(key, pageRows))
                        focusZone(c.searching ? "search" : "chips");
                    return;
                }
                default:
                    break;
                }
                // Anything else: typing in the chips or the grid goes to the field.
                if (inField) {
                    event.accepted = false;
                } else if (event.text !== "" && event.text.charCodeAt(0) >= 32 && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier)) === 0) {
                    focusZone("search");
                    field.insert(field.length, event.text);
                } else if (event.key === Qt.Key_Backspace && field.text !== "") {
                    focusZone("search");
                    field.text = field.text.slice(0, -1);
                }
            }

            // Outside the panel: a click closes.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: root.controller.hide()
            }

            FocusScope {
                id: keys
                anchors.fill: parent
                Keys.onPressed: event => host.handleKey(event, false)
            }

            // The panel's footprint: unscaled, so that the blur region does not follow the open animation.
            Item {
                id: frame

                x: host.c.panel.x
                y: host.c.panel.y
                width: host.c.panel.w
                height: host.c.panel.h
                Accessible.role: Accessible.Pane
                Accessible.name: qsTr("Apps")

                Item {
                    id: panel

                    anchors.fill: parent
                    opacity: win.progress
                    scale: Appearance.reduceMotion ? 1 : Tokens.launcherOpenScale + (1 - Tokens.launcherOpenScale) * win.progress

                    // Swallows clicks on the panel itself.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.AllButtons
                        onPressed: keys.forceActiveFocus()
                    }

                    Material {
                        anchors.fill: parent
                        radius: Tokens.launcherPanelRadius
                    }

                    // Search field.
                    Rectangle {
                        id: searchBox

                        x: Tokens.launcherPadding
                        y: Tokens.launcherPadding
                        width: panel.width - 2 * Tokens.launcherPadding
                        height: Tokens.launcherSearchHeight
                        radius: height / 2
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        border.width: field.activeFocus ? Tokens.controlFocusRing : 0
                        border.color: Appearance.colors.accent
                        Accessible.role: Accessible.Pane
                        Accessible.name: qsTr("Search")

                        Icon {
                            id: glass
                            x: Tokens.spacingMd
                            y: (parent.height - height) / 2
                            size: Tokens.menuIconSize
                            name: "search"
                            color: Appearance.colors.textSecondary
                        }

                        TextInput {
                            id: field
                            x: glass.x + glass.width + Tokens.spacingSm
                            width: parent.width - x - Tokens.spacingMd
                            height: parent.height
                            verticalAlignment: TextInput.AlignVCenter
                            color: Appearance.colors.text
                            selectionColor: Appearance.colors.accent
                            selectedTextColor: Appearance.colors.accentText
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            clip: true
                            focus: true
                            // No blinking caret in the visual fixture: a captured frame must not depend on the blink phase.
                            cursorVisible: activeFocus && !VisualFixtures.active
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
                                color: Appearance.colors.textSecondary
                                font: field.font
                            }
                        }
                    }

                    // Category chips (scroll sideways when the panel is narrower than the row).
                    Flickable {
                        id: chipFlick

                        x: Tokens.launcherPadding
                        y: searchBox.y + searchBox.height + Tokens.spacingMd
                        width: panel.width - 2 * Tokens.launcherPadding
                        height: Tokens.launcherChipHeight
                        contentWidth: chipRow.width
                        contentHeight: height
                        clip: true
                        flickableDirection: Flickable.HorizontalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentWidth > width
                        Accessible.role: Accessible.Pane
                        Accessible.name: qsTr("Categories")

                        Row {
                            id: chipRow
                            spacing: Tokens.launcherChipGap

                            Repeater {
                                model: root.controller.chips

                                AppsChip {
                                    id: chip

                                    required property string modelData

                                    label: root.controller.categoryLabels[modelData]
                                    // While searching no chip is selected: the results span every category.
                                    active: !root.controller.searching && root.controller.category === modelData
                                    focused: root.controller.zone === "chips" && root.controller.chipFocus === modelData
                                    onClicked: root.controller.selectCategory(modelData)
                                    onFocusedChanged: {
                                        if (focused)
                                            chipFlick.contentX = Math.max(0, Math.min(chipFlick.contentWidth - chipFlick.width, x + width / 2 - chipFlick.width / 2));
                                    }
                                }
                            }
                        }
                    }

                    // Scrolling grid, alphabetical (or ranked while searching).
                    GridView {
                        id: grid

                        x: Tokens.launcherPadding
                        y: chipFlick.y + chipFlick.height + Tokens.spacingXs
                        width: panel.width - 2 * Tokens.launcherPadding
                        // Down to the panel's edge (inside its border): rows scroll out under it, the last one clears it.
                        height: panel.height - y - Tokens.appsBorderWidth
                        // Room for the focus ring above the first row and below the last one.
                        topMargin: Tokens.spacingSm
                        bottomMargin: Tokens.spacingMd
                        cellWidth: root.controller.grid.cellW
                        cellHeight: root.controller.grid.cellH
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        keyNavigationEnabled: false
                        onContentYChanged: {
                            host.updateView();
                            scrollbar.poke();
                        }
                        onHeightChanged: host.updateView()
                        Accessible.role: Accessible.List
                        Accessible.name: qsTr("Applications")

                        model: ScriptModel {
                            values: root.controller.items
                            objectProp: "key"
                        }

                        delegate: AppsCell {
                            id: cell

                            required property var modelData
                            required property int index

                            info: modelData
                            cellW: grid.cellWidth
                            cellH: grid.cellHeight
                            selected: root.controller.selected === index && (root.controller.keyNav || root.controller.searching)
                            onActivated: root.controller.activate(modelData)
                        }
                    }

                    Text {
                        anchors.horizontalCenter: grid.horizontalCenter
                        y: grid.y + grid.height / 3
                        visible: root.controller.items.length === 0
                        text: qsTr("No results")
                        textFormat: Text.PlainText
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyTitleSize
                    }

                    // Overlay scroll indicator: shown while scrolling, fades after Tokens.launcherScrollbarIdleMs.
                    Rectangle {
                        id: scrollbar

                        readonly property bool needed: grid.contentHeight > grid.height
                        property bool recent: false

                        function poke(): void {
                            recent = true;
                            idle.restart();
                        }

                        x: grid.x + grid.width + (Tokens.launcherPadding - width) / 2
                        y: grid.y + (grid.contentHeight > 0 ? grid.height * (grid.contentY + grid.topMargin) / (grid.contentHeight + grid.topMargin + grid.bottomMargin) : 0)
                        width: Tokens.launcherScrollbarWidth
                        height: grid.contentHeight > 0 ? Math.max(Tokens.launcherScrollbarWidth * 4, grid.height * grid.height / (grid.contentHeight + grid.topMargin + grid.bottomMargin)) : 0
                        radius: width / 2
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.launcherScrollbarOpacity)
                        visible: needed && opacity > 0.01
                        opacity: recent || grid.moving ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Appearance.duration(Tokens.motionNormal)
                            }
                        }

                        Timer {
                            id: idle
                            interval: Tokens.launcherScrollbarIdleMs
                            onTriggered: scrollbar.recent = false
                        }
                    }
                }
            }
        }
    }
}
