pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The icon appearance picker (macOS 26 layout): four tiles, each showing a sample icon through the same TintedIcon that
// draws every app and file icon (same shader: the system plate and the fixed recolour), so a tile is what icons get. model: [{id, text}];
// value is the selected id; picked(id) on user change.
// One focus stop like Segmented: Left/Right (and Up/Down) move the choice. The selection is an accent border on the
// tile; the keyboard focus is a separate ring in the text colour, set off from the tile by a gap.
FocusScope {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""
    // Tint colour of the Tinted tile.
    property color tint: Appearance.iconTint

    signal picked(string id)

    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.RadioButton
    Accessible.name: root.accessibleName
    Accessible.description: root.currentIndex >= 0 ? root.model[root.currentIndex].text : ""
    Accessible.focusable: true

    function step(direction: int): void {
        if (root.model.length === 0)
            return;
        const next = Math.max(0, Math.min(root.model.length - 1, (root.currentIndex < 0 ? 0 : root.currentIndex) + direction));
        if (next !== root.currentIndex)
            root.picked(root.model[next].id);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    Row {
        id: row
        spacing: Tokens.iconModePreviewGap

        Repeater {
            model: root.model

            delegate: Item {
                id: tile

                required property var modelData
                required property int index
                readonly property bool selected: tile.index === root.currentIndex

                width: Tokens.iconModePreviewTileWidth
                height: Tokens.iconModePreviewTileHeight + caption.implicitHeight + Tokens.spacingXs
                Accessible.role: Accessible.RadioButton
                Accessible.name: tile.modelData.text
                Accessible.checkable: true
                Accessible.checked: tile.selected
                Accessible.onPressAction: root.picked(tile.modelData.id)

                // Keyboard focus ring: outside the tile, set off by a gap, in the text colour (the selection ring is the
                // accent border of the tile itself, so the two never read as one ring).
                Rectangle {
                    x: -(Tokens.controlFocusOutline + Tokens.iconModePreviewFocusGap)
                    y: x
                    width: plate.width - 2 * x
                    height: plate.height - 2 * x
                    radius: Tokens.iconModePreviewRadius - x
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                    visible: tile.selected && root.activeFocus
                }

                // The tile plate: the surface the icon sits on, as in the Dock or a window.
                Rectangle {
                    id: plate
                    width: parent.width
                    height: Tokens.iconModePreviewTileHeight
                    radius: Tokens.iconModePreviewRadius
                    color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
                    border.width: tile.selected ? Tokens.controlFocusOutline : Tokens.appsBorderWidth
                    border.color: tile.selected ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

                    // A real icon through the real pipeline: the per-tile mode overrides the global one.
                    TintedIcon {
                        anchors.centerIn: parent
                        size: Tokens.iconModePreviewSize
                        source: Appearance.iconSampleSource
                        mode: tile.modelData.id
                        tint: root.tint
                    }
                }

                Text {
                    id: caption
                    textFormat: Text.PlainText
                    y: plate.height + Tokens.spacingXs
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: tile.modelData.text
                    color: tile.selected ? Appearance.colors.text : Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: tile.selected ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ArrowCursor
                    onClicked: {
                        root.forceActiveFocus();
                        root.picked(tile.modelData.id);
                    }
                }
            }
        }
    }
}
