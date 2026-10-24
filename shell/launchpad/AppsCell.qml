pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services

// One cell of the Apps grid: the application icon, its name under it (one or two lines, elided), a hover
// highlight and the keyboard focus ring. A click activates.
Item {
    id: root

    // Display item {key, id, name, rec}.
    required property var info
    property real cellW: Tokens.launcherMinCellWidth
    property real cellH: Tokens.launcherCellHeight
    // True while the keyboard (or a search) owns the selection ring on this cell.
    property bool selected: false

    signal activated

    readonly property real labelHeight: Tokens.launcherLabelSize * Tokens.launcherLabelLineHeight * Tokens.launcherLabelLines
    readonly property real iconTop: (cellH - Tokens.launcherIconSize - Tokens.launcherLabelGap - labelHeight) / 2
    readonly property real highlightSize: Tokens.launcherIconSize + 2 * Tokens.spacingXs

    width: cellW
    height: cellH
    Accessible.role: Accessible.Button
    Accessible.name: info.name
    Accessible.focused: selected
    Accessible.onPressAction: root.activated()

    Rectangle {
        // Hover highlight.
        x: (root.cellW - width) / 2
        y: root.iconTop - Tokens.spacingXs
        width: root.highlightSize
        height: root.highlightSize
        radius: Tokens.launcherIconSize * Tokens.launcherHighlightRadiusScale
        visible: area.containsMouse && !root.selected
        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
    }

    Rectangle {
        // Keyboard focus ring.
        visible: root.selected
        x: (root.cellW - width) / 2
        y: root.iconTop - Tokens.spacingXs
        width: root.highlightSize
        height: root.highlightSize
        radius: Tokens.launcherIconSize * Tokens.launcherHighlightRadiusScale
        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
        border.width: Tokens.launcherSelectionWidth
        border.color: Appearance.colors.accent
    }

    TintedIcon {
        x: (root.cellW - width) / 2
        y: root.iconTop
        size: Tokens.launcherIconSize
        source: ThemeIcons.appIcon(root.info.rec.icon, "application-x-executable")
        asynchronous: true
    }

    Text {
        x: Tokens.spacingXs
        y: root.iconTop + Tokens.launcherIconSize + Tokens.launcherLabelGap
        width: root.cellW - 2 * Tokens.spacingXs
        height: root.labelHeight
        text: root.info.name
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: Tokens.launcherLabelLines
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.launcherLabelSize * Tokens.launcherLabelLineHeight
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignTop
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.launcherLabelSize
        font.weight: Tokens.typographyMenuWeight
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onClicked: root.activated()
    }
}
