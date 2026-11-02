pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// Wallpaper thumbnails as macOS 27 lays them out (Settings > Wallpaper, ADR-0016, docs/audits/settings-parity-2026-10-26.md
// § Wallpaper): fixed tiles in one row that runs off the pane's right edge or, `expanded` (Show All), wrapped in as many
// columns as fit. Each tile's name is under it; an "add" tile holds its symbol and its name. The chosen tile shows its picture
// inset in a light ring. One focus stop (the ChoicePicker pattern): arrows, Home and End move, Return or Space applies;
// moving past the row's last whole tile asks for Show All (expandRequested).
// model: [{label, fullName, kind, color, thumb, selected, icon}] with kind "art" (the Grassfield artwork), "color", "image" or
// "video" (thumb is a file path, "" while it is prepared; a video tile has a play badge), "folder" or "add" (icon: its
// symbol). The tiles are radio buttons for assistive technology (an add tile is a button), named after the picture (fullName
// when the label is a short form). Names are untrusted: plain text.
Item {
    id: root

    property var model: []
    property string accessibleName: ""
    property int currentIndex: -1
    // Show All: every tile, wrapped; otherwise one row: the tiles that fit and the one the pane's edge cuts.
    property bool expanded: false

    signal activated(int index)
    // The keyboard moved past the row's last whole tile.
    signal expandRequested

    readonly property real pitch: Tokens.settingsWallpaperTileWidth + Tokens.settingsWallpaperTileGap
    // Whole tiles in a row of this width.
    readonly property int columns: Math.max(1, Math.floor((root.width + Tokens.settingsWallpaperTileGap) / root.pitch))
    readonly property bool overflows: root.model.length > root.columns
    // How many tiles are drawn (and need their thumbnails).
    readonly property int shown: root.expanded ? root.model.length : Math.min(root.model.length, root.columns + 1)
    readonly property int rows: root.shown === 0 ? 0 : (root.expanded ? Math.ceil(root.shown / root.columns) : 1)
    // Names under the tiles: any tile that is not an add tile has one.
    readonly property bool named: root.model.some(m => m.kind !== "add")
    // A tile and its name: the grid ends on the last name's baseline (on the tiles' bottom without names). Wrapped rows are
    // wallpaperTilesTop apart, as a section's tiles are from its title (no Show All capture was measured).
    readonly property real rowHeight: Tokens.settingsWallpaperTileHeight + (root.named ? Tokens.settingsWallpaperLabelBaseline : 0)

    implicitHeight: root.rows === 0 ? 0 : root.rows * root.rowHeight + (root.rows - 1) * Tokens.settingsWallpaperTilesTop
    height: implicitHeight
    activeFocusOnTab: root.model.length > 0
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
            if (!expanded && currentIndex > columns - 1)
                root.expandRequested();
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
            if (!root.expanded)
                return;
            i = Math.min(n - 1, i + root.columns);
            break;
        case Qt.Key_Up:
            if (!root.expanded)
                return;
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
        // A tile past the row's whole tiles: Show All first, so that it is seen.
        if (!root.expanded && i > root.columns - 1)
            root.expandRequested();
        root.currentIndex = i;
        event.accepted = true;
    }

    // The rounded shape every picture is cut to (one mask, stretched to the picture's size).
    Rectangle {
        id: mask
        visible: false
        layer.enabled: true
        width: Tokens.settingsWallpaperTileWidth
        height: Tokens.settingsWallpaperTileHeight
        radius: Tokens.settingsWallpaperTileRadius
    }

    Repeater {
        model: root.model.slice(0, root.shown)

        delegate: Item {
            id: tile

            required property var modelData
            required property int index

            readonly property bool adds: tile.modelData.kind === "add"
            readonly property bool chosen: tile.modelData.selected === true
            readonly property bool focused: root.activeFocus && root.currentIndex === tile.index
            readonly property bool pictured: (tile.modelData.kind === "image" || tile.modelData.kind === "video") && tile.modelData.thumb !== ""

            x: (root.expanded ? tile.index % root.columns : tile.index) * root.pitch
            y: (root.expanded ? Math.floor(tile.index / root.columns) : 0) * (root.rowHeight + Tokens.settingsWallpaperTilesTop)
            width: Tokens.settingsWallpaperTileWidth
            height: root.rowHeight

            Accessible.role: tile.adds ? Accessible.Button : Accessible.RadioButton
            Accessible.name: tile.modelData.fullName || tile.modelData.label
            Accessible.checkable: !tile.adds
            Accessible.checked: tile.chosen
            Accessible.focusable: true
            Accessible.onPressAction: root.activated(tile.index)

            // An add tile: the group fill, its symbol and its name inside.
            Rectangle {
                visible: tile.adds
                width: parent.width
                height: Tokens.settingsWallpaperTileHeight
                radius: Tokens.settingsWallpaperTileRadius
                color: Appearance.colors.groupFill

                Icon {
                    x: Math.round((parent.width - width) / 2)
                    y: Tokens.settingsWallpaperAddIconTop
                    name: tile.modelData.icon || "plus"
                    size: Tokens.settingsWallpaperAddIconSize
                    color: Appearance.windowSecondary
                }

                Text {
                    x: Tokens.spacingXs
                    y: Tokens.settingsWallpaperAddLabelBaseline - baselineOffset
                    width: parent.width - 2 * x
                    textFormat: Text.PlainText
                    text: tile.modelData.label
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                }
            }

            // The picture, cut to the tile's rounded shape; the chosen one sits inset in its ring.
            Item {
                id: picture
                visible: !tile.adds
                readonly property real inset: tile.chosen ? Tokens.settingsWallpaperChosenInset : 0
                x: inset
                y: inset
                width: Tokens.settingsWallpaperTileWidth - 2 * inset
                height: Tokens.settingsWallpaperTileHeight - 2 * inset
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: mask
                }

                Rectangle {
                    anchors.fill: parent
                    color: tile.modelData.kind === "color" ? tile.modelData.color : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
                }

                GrassfieldArtwork {
                    anchors.fill: parent
                    visible: tile.modelData.kind === "art"
                    artwork: tile.modelData.artwork ?? "grassfield"
                    variant: tile.modelData.variant ?? "evening.dark"
                }

                Image {
                    anchors.fill: parent
                    visible: tile.pictured
                    source: tile.pictured ? "file://" + tile.modelData.thumb : ""
                    asynchronous: true
                    cache: false
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(Tokens.settingsWallpaperThumbWidth, Tokens.settingsWallpaperThumbWidth)
                }

                // Nothing to show yet (a picture being prepared) or a folder: its symbol on the fill.
                Icon {
                    anchors.centerIn: parent
                    visible: tile.modelData.kind === "folder" || ((tile.modelData.kind === "image" || tile.modelData.kind === "video") && !tile.pictured)
                    name: tile.modelData.kind === "folder" ? "folder" : tile.modelData.kind === "video" ? "media-play" : "wallpaper"
                    size: Tokens.settingsListIconSize
                    color: Appearance.colors.textSecondary
                }

                // A video tile with its frame: a play badge in the corner (frosted chip, so that it reads over any frame).
                Rectangle {
                    visible: tile.modelData.kind === "video" && tile.pictured
                    x: Tokens.spacingXs
                    y: parent.height - height - Tokens.spacingXs
                    width: Tokens.settingsListIconSize + Tokens.spacingXs
                    height: width
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)

                    Icon {
                        anchors.centerIn: parent
                        name: "media-play"
                        size: Tokens.settingsListIconSize - Tokens.spacingXs
                        color: Appearance.colors.text
                    }
                }
            }

            // Chosen: a light ring from just outside the tile (the text colour, faint).
            Rectangle {
                visible: tile.chosen && !tile.focused
                x: -Tokens.settingsWallpaperRingOutset
                y: x
                width: Tokens.settingsWallpaperTileWidth - 2 * x
                height: Tokens.settingsWallpaperTileHeight - 2 * x
                radius: Tokens.settingsWallpaperTileRadius - x
                color: "transparent"
                border.width: Tokens.settingsWallpaperRingWidth
                border.color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsWallpaperRingOpacity)
            }

            // Keyboard focus: the focus ring around the tile.
            Item {
                width: Tokens.settingsWallpaperTileWidth
                height: Tokens.settingsWallpaperTileHeight

                FocusRing {
                    visible: tile.focused
                    shapeRadius: Tokens.settingsWallpaperTileRadius
                }
            }

            Text {
                visible: !tile.adds
                y: Tokens.settingsWallpaperTileHeight + Tokens.settingsWallpaperLabelBaseline - baselineOffset
                width: parent.width
                textFormat: Text.PlainText
                text: tile.modelData.label
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            MouseArea {
                width: parent.width
                height: Tokens.settingsWallpaperTileHeight + (tile.adds ? 0 : Tokens.settingsWallpaperLabelBaseline)
                onClicked: {
                    root.forceActiveFocus();
                    root.currentIndex = tile.index;
                    root.activated(tile.index);
                }
            }
        }
    }
}
