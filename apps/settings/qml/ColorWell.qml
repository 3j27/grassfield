pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Colour well (macOS model: a round swatch that opens the colour picker). Click, Space or Return opens a popover above
// the page with preset swatches, a saturation/brightness square, a hue slider and a typed #rrggbb field: any colour,
// no contrast guard (like macOS). `color` is the stored colour (#rrggbb); edited(colour) is the user's change, sent at
// most every settingsColorWriteMs while the square or the slider is dragged, and always once more for the colour the
// drag stops on. Keyboard: the well is a tab stop; in the popover the square takes the arrow keys (Shift for a larger
// step), the swatches Left/Right + Return, the hue slider Left/Right/Home/End, Esc closes and returns to the well.
Item {
    id: root

    property string color: Tokens.settingsColorSquareBlack
    property string accessibleName: ""
    // [{color, name}] shown as swatches.
    property var presets: []

    signal edited(string color)

    readonly property bool open: layerItem.visible
    // The colour the user is editing, held until the host sets `color` again (an unbound well still follows the user).
    property string local: ""
    readonly property string shown: root.local !== "" ? root.local : PointerColors.normalize(root.color, Tokens.settingsColorSquareBlack)
    // Hue is kept apart from the colour: a grey or a black has no hue, and dragging the square must not lose it.
    property real hue: 0
    property real sat: 0
    property real val: 0
    // Unit of the arrow keys on the square (a fraction of its side).
    readonly property real keyStep: 0.02
    readonly property real keyStepLarge: 0.1

    implicitWidth: Tokens.settingsColorWellSize + 2 * Tokens.controlFocusOutline
    implicitHeight: implicitWidth
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.description: root.shown
    Accessible.focusable: true
    Accessible.onPressAction: root.show()

    onColorChanged: {
        root.local = "";
        root.syncHsv(PointerColors.normalize(root.color, Tokens.settingsColorSquareBlack));
    }
    Component.onCompleted: root.syncHsv(root.shown)

    // The typed field shows the colour: whatever changed it (a swatch, the square, the slider, the host), except the text
    // the user is typing, which already names this colour (a "#0f0" typed for it stays until editing finishes, then shows
    // "#00ff00").
    onShownChanged: {
        if (PointerColors.parseTyped(hexField.text) !== root.shown)
            hexField.text = root.shown;
    }
    // The typed colour field (tests).
    readonly property alias hexInput: hexField

    function syncHsv(c: string): void {
        const hsv = PointerColors.toHsv(c);
        if (!hsv)
            return;
        // Keep the hue of a colour that has none.
        if (hsv.s > 0 && hsv.v > 0)
            root.hue = hsv.h;
        root.sat = hsv.s;
        root.val = hsv.v;
    }

    // The user picked `c` (final: the drag ended or it was a single action).
    function pick(c: string, final: bool): void {
        root.local = c;
        if (final) {
            throttle.stop();
            root.pending = "";
            root.edited(c);
        } else if (throttle.running) {
            root.pending = c;
        } else {
            root.edited(c);
            throttle.restart();
        }
    }

    property string pending: ""

    // From the square or the slider: h, s, v in 0..1.
    function setHsv(h: real, s: real, v: real, final: bool): void {
        root.hue = Math.max(0, Math.min(1, h));
        root.sat = Math.max(0, Math.min(1, s));
        root.val = Math.max(0, Math.min(1, v));
        root.pick(PointerColors.fromHsv(root.hue, root.sat, root.val), final);
    }

    function show(): void {
        layerItem.visible = true;
        root.place();
        square.forceActiveFocus();
    }

    function hide(): void {
        // The last colour of a drag in progress is never lost.
        if (root.pending !== "")
            root.pick(root.pending, true);
        layerItem.visible = false;
        root.forceActiveFocus();
    }

    // Below the well, flipped above it when that would run past the window bottom, always inside the window.
    function place(): void {
        const below = root.mapToItem(layerItem, 0, root.height + Tokens.spacingXs);
        const above = root.mapToItem(layerItem, 0, -Tokens.spacingXs - card.height);
        const maxY = layerItem.height - card.height - Tokens.spacingSm;
        const y = below.y > maxY && above.y >= Tokens.spacingSm ? above.y : below.y;
        card.x = Math.max(Tokens.spacingSm, Math.min(layerItem.width - card.width - Tokens.spacingSm, below.x + root.width - card.width));
        card.y = Math.max(Tokens.spacingSm, Math.min(maxY, y));
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.show();
            event.accepted = true;
        }
    }

    Timer {
        id: throttle
        interval: Tokens.settingsColorWriteMs
        onTriggered: {
            if (root.pending !== "") {
                const c = root.pending;
                root.pending = "";
                root.edited(c);
                throttle.restart();
            }
        }
    }

    // The shared ring outside the well, after a key only (ADR-0039 step 7).
    KeyFocus {
        id: wellFocus
    }

    Item {
        anchors.fill: parent

        FocusRing {
            shapeRadius: width / 2
            visible: wellFocus.active
        }

        Rectangle {
            anchors.centerIn: parent
            width: Tokens.settingsColorWellSize
            height: width
            radius: width / 2
            color: root.shown
            border.width: Tokens.appsBorderWidth
            border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.ArrowCursor
        onClicked: {
            root.forceActiveFocus();
            // The focus the popover takes after a click is the pointer's: no ring (ADR-0039 step 7).
            squareFocus.pointer = true;
            if (root.open)
                root.hide();
            else
                root.show();
        }
    }

    // Window-sized layer above the page: catches outside clicks and hosts the popover.
    Item {
        id: layerItem
        parent: root.Window.contentItem
        anchors.fill: parent
        visible: false
        z: 1000

        Keys.onEscapePressed: root.hide()

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onClicked: {
                // Closed by a click outside: the well takes the focus back without a ring.
                wellFocus.pointer = true;
                root.hide();
            }
        }

        Item {
            id: card
            // The square, or the preset swatches when they are wider.
            readonly property real contentWidth: Math.max(Tokens.settingsColorSquareWidth, swatches.implicitWidth - 2 * Tokens.menuItemPadding)
            width: card.contentWidth + 2 * Tokens.spacingMd
            height: column.height + 2 * Tokens.spacingMd
            onHeightChanged: if (layerItem.visible) root.place()
            Accessible.role: Accessible.Dialog
            Accessible.name: root.accessibleName

            // A popover on the menus' glass (Material), as every popover Grassfield.Ui draws in an app (ADR-0039 step 15).
            Material {
                anchors.fill: parent
                glassClass: "menu"
                radius: Tokens.radiusMenu
            }

            // Swallows clicks on the card itself.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.ArrowCursor
            }

            Column {
                id: column
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: card.contentWidth
                spacing: Tokens.spacingSm

                SwatchRow {
                    id: swatches
                    // The row pads itself by menuItemPadding on each side; the card pads by spacingMd.
                    x: -Tokens.menuItemPadding
                    accessibleName: qsTr("Preset colours")
                    caption: ""
                    activeFocusOnTab: true
                    model: root.presets.map(p => ({
                                color: p.color,
                                name: p.name,
                                state: p.color.toLowerCase() === root.shown ? 2 : 0
                            }))
                    onChosen: index => {
                        const c = root.presets[index].color.toLowerCase();
                        root.syncHsv(c);
                        root.pick(c, true);
                    }
                }

                // Saturation (left to right) and brightness (bottom to top) of the hue.
                Item {
                    id: square
                    width: card.contentWidth
                    height: Tokens.settingsColorSquareHeight
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Slider
                    Accessible.name: qsTr("Saturation and brightness")
                    Accessible.description: root.shown
                    Accessible.focusable: true

                    function at(x: real, y: real, final: bool): void {
                        root.setHsv(root.hue, x / width, 1 - y / height, final);
                    }

                    Keys.onPressed: event => {
                        const d = (event.modifiers & Qt.ShiftModifier) ? root.keyStepLarge : root.keyStep;
                        if (event.key === Qt.Key_Left)
                            root.setHsv(root.hue, root.sat - d, root.val, true);
                        else if (event.key === Qt.Key_Right)
                            root.setHsv(root.hue, root.sat + d, root.val, true);
                        else if (event.key === Qt.Key_Up)
                            root.setHsv(root.hue, root.sat, root.val + d, true);
                        else if (event.key === Qt.Key_Down)
                            root.setHsv(root.hue, root.sat, root.val - d, true);
                        else
                            return;
                        event.accepted = true;
                    }

                    // The shared ring outside the square, after a key only (ADR-0039 step 7).
                    KeyFocus {
                        id: squareFocus
                    }

                    FocusRing {
                        visible: squareFocus.active
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: Tokens.radiusControl
                        color: PointerColors.fromHsv(root.hue, 1, 1)

                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop {
                                    position: 0
                                    color: Tokens.settingsColorSquareWhite
                                }
                                GradientStop {
                                    position: 1
                                    color: Tokens.settingsColorSquareWhiteClear
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            gradient: Gradient {
                                GradientStop {
                                    position: 0
                                    color: Tokens.settingsColorSquareBlackClear
                                }
                                GradientStop {
                                    position: 1
                                    color: Tokens.settingsColorSquareBlack
                                }
                            }
                        }
                    }

                    Rectangle {
                        x: root.sat * square.width - width / 2
                        y: (1 - root.val) * square.height - height / 2
                        width: Tokens.settingsColorWellSize / 2
                        height: width
                        radius: width / 2
                        color: root.shown
                        border.width: Tokens.menuSwatchRing
                        border.color: Tokens.settingsColorSquareWhite
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.ArrowCursor
                        onPressed: mouse => {
                            square.forceActiveFocus();
                            square.at(Math.max(0, Math.min(square.width, mouse.x)), Math.max(0, Math.min(square.height, mouse.y)), false);
                        }
                        onPositionChanged: mouse => {
                            if (pressed)
                                square.at(Math.max(0, Math.min(square.width, mouse.x)), Math.max(0, Math.min(square.height, mouse.y)), false);
                        }
                        onReleased: mouse => square.at(Math.max(0, Math.min(square.width, mouse.x)), Math.max(0, Math.min(square.height, mouse.y)), true)
                    }
                }

                Slider {
                    width: parent.width
                    accessibleName: qsTr("Hue")
                    from: 0
                    to: 1
                    stepSize: root.keyStep
                    value: root.hue
                    fillColor: PointerColors.fromHsv(root.hue, 1, 1)
                    onMoved: v => root.setHsv(v, root.sat > 0 ? root.sat : 1, root.val > 0 ? root.val : 1, true)
                }

                // The shared text field (its fill, ring and selection colours; ADR-0039 step 15).
                TextField {
                    id: hexField
                    objectName: "hexField"
                    width: Tokens.settingsColorHexWidth
                    height: Tokens.menuItemHeight + Tokens.spacingXs
                    maximumLength: 7
                    inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhPreferLowercase
                    accessibleName: qsTr("Colour (#rrggbb)")
                    // Follows the colour (see root.onShownChanged); not a binding: assigning `text` below would break it.
                    Component.onCompleted: text = root.shown
                    // A complete colour is applied as it is typed; anything else changes nothing.
                    onTextEdited: {
                        const c = PointerColors.parseTyped(text);
                        if (c !== "" && text.trim().length >= 6) {
                            root.syncHsv(c);
                            root.pick(c, true);
                        }
                    }
                    // Return or leaving the field: a short "#0f0" is expanded to "#00ff00" (only #rrggbb is stored); anything else reverts.
                    onEditingFinished: {
                        const c = PointerColors.parseTyped(text);
                        if (c !== "" && c !== root.shown) {
                            root.syncHsv(c);
                            root.pick(c, true);
                        }
                        text = root.shown;
                    }
                    Keys.onEscapePressed: root.hide()
                }
            }
        }
    }
}
