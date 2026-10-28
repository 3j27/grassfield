pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A section of Settings > Wallpaper as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Wallpaper): on the
// window's background, no group: its title (bold) and, when the tiles run past one row, Show All (n) at the right (Show Fewer
// once shown), then its WallpaperGrid. `lead`: the title's baseline below the section's top. The section ends where the next
// title is wallpaperAddSectionGap away: on the tiles' bottom, or wallpaperSectionGap minus that under their names. Anything
// declared inside goes under the tiles (a note, the online opt-in).
Item {
    id: root

    property string title: ""
    property alias model: grid.model
    property alias expanded: grid.expanded
    property real lead: Tokens.settingsWallpaperAddSectionGap
    readonly property alias grid: grid
    default property alias extra: extras.data

    signal activated(int index)

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: extras.y + extras.height + (extras.height === 0 && grid.named ? Tokens.settingsWallpaperSectionGap - Tokens.settingsWallpaperAddSectionGap : 0)
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title

    Text {
        id: titleText
        y: root.lead - baselineOffset
        width: parent.width - (more.visible ? more.width + Tokens.spacingLg : 0)
        textFormat: Text.PlainText
        text: root.title
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyMenuBoldWeight
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    // Show All (n) / Show Fewer: plain text in the secondary colour, a button for the keys and assistive technology.
    Text {
        id: more
        visible: grid.overflows
        anchors.right: parent.right
        y: root.lead - baselineOffset
        textFormat: Text.PlainText
        text: grid.expanded ? qsTr("Show Fewer") : qsTr("Show All (%1)").arg(grid.model.length)
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        activeFocusOnTab: visible
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.focusable: true
        Accessible.onPressAction: grid.expanded = !grid.expanded
        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                grid.expanded = !grid.expanded;
                event.accepted = true;
            }
        }

        FocusRing {
            visible: more.activeFocus
            shapeRadius: Tokens.radiusControl
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: grid.expanded = !grid.expanded
        }
    }

    WallpaperGrid {
        id: grid
        y: root.lead + Tokens.settingsWallpaperTilesTop
        width: parent.width
        accessibleName: root.title
        onActivated: index => root.activated(index)
        onExpandRequested: grid.expanded = true
    }

    Column {
        id: extras
        y: grid.y + grid.height
        width: parent.width
    }
}
