pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "../platform/WindowTiling.js" as WindowTiling

// The tiling suggestions (docs/specs/tiling.md TL28; Windows' Snap Assist, taken by the owner as T1c): popup kind
// "tilingSuggest", opened by services/TilingSuggest in the first empty zone of the layout a window is filling (the overlay
// centres it in that zone). It offers the windows that can take the zone, each a live thumbnail (ScreencopyView) with its
// app's icon and title, on glass; a click or Return places the chosen window there and the plugin's next suggestion follows
// for the next empty zone; the arrows move between the windows; Esc or a click outside ends the suggestions.
FocusScope {
    id: root

    readonly property var suggestion: Popups.data.suggestion !== undefined ? Popups.data.suggestion : null
    // The windows still open, in the plugin's order: [{address, toplevel}].
    readonly property var windows: root.suggestion ? root.suggestion.windows.map(a => ({
                address: a,
                toplevel: Compositor.toplevelByAddress(a)
            })).filter(w => w.toplevel !== null) : []
    readonly property real labelHeight: Tokens.menuItemHeight
    readonly property var grid: WindowTiling.suggestionGrid(root.windows.length, root.width, root.height, Tokens.tilingSuggestThumbAspect, root.labelHeight, Tokens.spacingMd,
                                                            Tokens.tilingSuggestTileWidth)
    // The keyboard's window: the first when a suggestion opens (a visible focus at once; Return takes it).
    property int current: root.windows.length > 0 ? 0 : -1
    // A window was picked: the plugin's next suggestion (or the end) follows; no second pick meanwhile.
    property bool picked: false

    width: Math.max(1, (Popups.data.width ?? 0) - 2 * Tokens.spacingSm)
    height: Math.max(1, (Popups.data.height ?? 0) - 2 * Tokens.spacingSm)
    activeFocusOnTab: true
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Choose a window for this zone")

    onSuggestionChanged: {
        root.picked = false;
        root.current = root.windows && root.windows.length > 0 ? 0 : -1; // windows is not evaluated yet at creation
    }
    // Every window offered closed meanwhile: the suggestions end.
    onWindowsChanged: {
        if (root.windows.length === 0)
            Qt.callLater(TilingSuggest.dismiss);
    }

    // A refused pick (the zone was taken meanwhile) changes nothing: the suggestion stays and takes a pick again (TL28).
    Connections {
        target: Compositor

        function onTilingNotice(notice: var): void {
            if (notice.reason === "invalid" || notice.reason === "locked")
                root.picked = false;
        }
    }

    function choose(index: int): void {
        if (root.picked || index < 0 || index >= root.windows.length)
            return;
        root.picked = TilingSuggest.pick(root.windows[index].address);
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Escape:
            TilingSuggest.dismiss();
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            root.choose(root.current);
            break;
        case Qt.Key_Left:
        case Qt.Key_Right:
        case Qt.Key_Up:
        case Qt.Key_Down:
        case Qt.Key_Home:
        case Qt.Key_End:
            root.current = WindowTiling.gridStep(root.current, root.windows.length, root.grid.columns, {
                [Qt.Key_Left]: "left",
                [Qt.Key_Right]: "right",
                [Qt.Key_Up]: "up",
                [Qt.Key_Down]: "down",
                [Qt.Key_Home]: "home",
                [Qt.Key_End]: "end"
            }[event.key]);
            break;
        default:
            return;
        }
        event.accepted = true;
    }

    // Menu glass, as the popover (the overlay blurs a popup at the menu radius).
    Material {
        anchors.fill: parent
        glassClass: "menu"
        radius: Tokens.radiusMenu
    }

    Grid {
        anchors.centerIn: parent
        columns: Math.max(1, root.grid.columns)
        spacing: Tokens.spacingMd

        Repeater {
            model: root.grid.columns > 0 ? root.windows : []

            Item {
                id: tile

                required property var modelData
                required property int index
                readonly property bool highlighted: root.current === tile.index
                readonly property var entry: Apps.lookup(tile.modelData.toplevel.appId)

                width: root.grid.tileWidth
                height: root.grid.tileHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: tile.modelData.toplevel.title
                Accessible.onPressAction: root.choose(tile.index)

                // The keyboard's and the pointer's window, a neutral highlight as the popover's rows.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    radius: Tokens.radiusMenu - Tokens.menuPadding
                    color: Appearance.withAlpha(Appearance.colors.text, Tokens.materialHoverOpacity)
                    visible: tile.highlighted
                }

                Item {
                    id: thumb

                    width: parent.width
                    height: root.grid.thumbHeight

                    // The window fitted in its box with its own aspect, live.
                    ScreencopyView {
                        readonly property real ratio: implicitWidth > 0 && implicitHeight > 0 ? implicitWidth / implicitHeight : Tokens.tilingSuggestThumbAspect

                        anchors.centerIn: parent
                        width: ratio >= thumb.width / thumb.height ? thumb.width : thumb.height * ratio
                        height: ratio >= thumb.width / thumb.height ? thumb.width / ratio : thumb.height
                        captureSource: tile.modelData.toplevel
                        live: true
                        paintCursor: false
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: thumb.height
                    height: root.labelHeight
                    spacing: Tokens.spacingXs

                    TintedIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        size: Tokens.menuIconSize
                        source: ThemeIcons.appIcon(tile.entry ? tile.entry.icon : "", "application-x-executable")
                        asynchronous: true
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, tile.width - Tokens.menuIconSize - Tokens.spacingXs)
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: tile.modelData.toplevel.title
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyMenuSize
                        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.current = tile.index
                    onClicked: root.choose(tile.index)
                }
            }
        }
    }
}
