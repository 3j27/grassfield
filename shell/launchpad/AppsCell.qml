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

    // Deleting apps (ADR-0044): while `editing` the icon jiggles (an icon of `position`, each with its own phase); `removable`
    // shows the delete badge, whose click asks for the alert; a press held on the icon asks the owner to start editing.
    property bool editing: false
    property bool removable: false
    property int position: 0

    signal activated
    signal deleteRequested
    signal holdStarted

    // The jiggle's clock, 0..1 over one period; it runs only while the icon jiggles and motion is not reduced.
    property real jiggleClock: 0
    readonly property bool jiggling: editing && !Appearance.reduceMotion
    NumberAnimation on jiggleClock {
        running: root.jiggling
        from: 0
        to: 1
        duration: Tokens.launcherJigglePeriod
        loops: Animation.Infinite
    }

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
        // The focus ring colour: the accent, or the text colour where the accent does not hold (ADR-0039 step 7).
        border.color: Appearance.focusRingColor
    }

    TintedIcon {
        x: (root.cellW - width) / 2
        y: root.iconTop
        size: Tokens.launcherIconSize
        source: ThemeIcons.appIcon(root.info.rec.icon, "application-x-executable")
        asynchronous: true
        rotation: root.jiggling ? UninstallLogic.jiggleAngle(root.jiggleClock * Tokens.launcherJigglePeriod, root.position, Tokens.launcherJiggleAngle, Tokens.launcherJigglePeriod) : 0
    }

    // The delete badge of an app the Store may remove: top-left of the icon, above the hover highlight.
    Rectangle {
        id: badge

        visible: root.editing && root.removable
        x: (root.cellW - Tokens.launcherIconSize) / 2 - width / 2
        y: root.iconTop - height / 2
        width: Tokens.launcherDeleteBadgeSize
        height: width
        radius: width / 2
        color: Appearance.colors.destructive
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Delete “%1”").arg(root.info.name)
        Accessible.onPressAction: root.deleteRequested()

        Icon {
            anchors.centerIn: parent
            name: "close-glyph"
            size: Math.round(badge.width * Tokens.launcherDeleteBadgeGlyphScale)
            color: Appearance.colors.destructiveText
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.deleteRequested()
        }
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
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        // While the icons jiggle a click launches nothing (macOS); a press held on an icon, or the right button, starts it.
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                root.holdStarted();
            else if (!root.editing)
                root.activated();
        }
        onPressAndHold: mouse => {
            if (mouse.button === Qt.LeftButton && !root.editing)
                root.holdStarted();
        }
        pressAndHoldInterval: Tokens.launcherHoldDelay
    }
}
