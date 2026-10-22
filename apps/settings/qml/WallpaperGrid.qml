pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grid of 16:10 wallpaper tiles (Settings > Wallpaper, ADR-0016). One focus stop: arrows, Home and End move, Return or
// Space applies (the IconModePicker pattern). model: [{label, kind, color, thumb, selected}] with kind "art" (the
// Grassfield artwork), "color", "image" (thumb is a file path, "" while it is prepared), "folder" or "add" (a button-like
// tile). `wrap: true` lets a long label take three lines (the online tile) instead of eliding in the middle. The tiles are radio buttons for assistive technology, named after the picture. Names are untrusted: plain text.
Item {
    id: root

    property var model: []
    property string accessibleName: ""
    property int currentIndex: -1

    signal activated(int index)

    readonly property int columns: Tokens.settingsWallpaperTileColumns
    readonly property int gap: Tokens.settingsWallpaperTileGap
    readonly property real tileWidth: Math.max(1, (width - (columns - 1) * gap) / columns)
    readonly property real tileHeight: tileWidth * 10 / 16
    // Two lines of label, three when a tile asks to wrap (the online tile's name is long and the tiles are narrow).
    readonly property int labelLines: root.model.some(m => m.wrap === true) ? 3 : 2
    readonly property real labelHeight: Tokens.typographyCaptionSize * labelLines + Tokens.spacingXs
    readonly property int rows: Math.ceil(root.model.length / columns)

    implicitHeight: rows * (tileHeight + labelHeight) + Math.max(0, rows - 1) * gap
    height: implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Grouping
    Accessible.name: root.accessibleName
    Accessible.focusable: true

    onActiveFocusChanged: {
        if (activeFocus && currentIndex < 0) {
            let first = 0;
            for (let i = 0; i < model.length; i++) {
                if (model[i].selected) {
                    first = i;
                    break;
                }
            }
            currentIndex = model.length > 0 ? first : -1;
        }
    }

    Keys.onPressed: event => {
        const n = root.model.length;
        if (n === 0)
            return;
        let i = Math.max(0, root.currentIndex);
        switch (event.key) {
        case Qt.Key_Right:
            i = Math.min(n - 1, i + 1);
            break;
        case Qt.Key_Left:
            i = Math.max(0, i - 1);
            break;
        case Qt.Key_Down:
            i = Math.min(n - 1, i + root.columns);
            break;
        case Qt.Key_Up:
            i = Math.max(0, i - root.columns);
            break;
        case Qt.Key_Home:
            i = 0;
            break;
        case Qt.Key_End:
            i = n - 1;
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            root.activated(i);
            event.accepted = true;
            return;
        default:
            return;
        }
        root.currentIndex = i;
        event.accepted = true;
    }

    Repeater {
        model: root.model

        delegate: Item {
            id: tile

            required property var modelData
            required property int index

            readonly property bool current: root.activeFocus && root.currentIndex === tile.index

            x: (tile.index % root.columns) * (root.tileWidth + root.gap)
            y: Math.floor(tile.index / root.columns) * (root.tileHeight + root.labelHeight + root.gap)
            width: root.tileWidth
            height: root.tileHeight + root.labelHeight

            Accessible.role: Accessible.RadioButton
            Accessible.name: tile.modelData.label
            Accessible.checked: tile.modelData.selected === true
            Accessible.focusable: true
            Accessible.onPressAction: root.activated(tile.index)

            Rectangle {
                id: face
                width: parent.width
                height: root.tileHeight
                radius: Tokens.settingsWallpaperTileRadius
                clip: true
                color: tile.modelData.kind === "color" ? tile.modelData.color : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                GrassfieldArtwork {
                    anchors.fill: parent
                    visible: tile.modelData.kind === "art"
                }

                Image {
                    anchors.fill: parent
                    visible: tile.modelData.kind === "image" && tile.modelData.thumb !== ""
                    source: tile.modelData.kind === "image" && tile.modelData.thumb !== "" ? "file://" + tile.modelData.thumb : ""
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(Tokens.settingsWallpaperThumbWidth, Tokens.settingsWallpaperThumbWidth)
                }

                Icon {
                    anchors.centerIn: parent
                    visible: tile.modelData.kind === "folder" || tile.modelData.kind === "add" || (tile.modelData.kind === "image" && tile.modelData.thumb === "")
                    name: tile.modelData.kind === "folder" ? "folder" : tile.modelData.kind === "add" ? "chevron-right" : "wallpaper"
                    size: Tokens.settingsListIconSize
                    color: Appearance.colors.textSecondary
                }

                // Selected: an accent ring; keyboard focus: the focus ring on the tile.
                Rectangle {
                    anchors.fill: parent
                    radius: face.radius
                    color: "transparent"
                    border.width: tile.modelData.selected === true || tile.current ? Tokens.controlFocusRing : 1
                    border.color: tile.modelData.selected === true || tile.current ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }
            }

            Text {
                y: root.tileHeight + Tokens.spacingXs
                width: parent.width
                textFormat: Text.PlainText
                text: tile.modelData.label
                elide: tile.modelData.wrap === true ? Text.ElideRight : Text.ElideMiddle
                wrapMode: tile.modelData.wrap === true ? Text.Wrap : Text.NoWrap
                maximumLineCount: tile.modelData.wrap === true ? 3 : 1
                horizontalAlignment: Text.AlignHCenter
                color: tile.modelData.selected === true ? Appearance.colors.text : Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.forceActiveFocus();
                    root.currentIndex = tile.index;
                    root.activated(tile.index);
                }
            }
        }
    }
}
