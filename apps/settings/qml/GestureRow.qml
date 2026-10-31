pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A row of Mouse and Trackpad as macOS 27 draws it (docs/audits/settings-parity-2026-10-26.md § Mouse and Trackpad): the title
// at the top left with its explanation under it, the control beside the title (a row without an explanation centres it). The
// row under the pointer, or holding the keyboard focus, is highlighted across the group with its separators, and asks the pane
// to show its gesture on the device card (`showing`).
FocusScope {
    id: root

    property string title: ""
    property string subtitle: ""
    // The gesture the device card shows for this row (MouseTrackpad.GESTURES).
    property string gesture: ""
    // The row's own height, its separator apart (Tracking speed sets 50).
    property real rowHeight: root.subtitle !== "" ? Tokens.settingsGestureRowHeight : Tokens.settingsRowHeight - 1
    default property alias control: slot.data

    readonly property bool first: root.Positioner.index <= 0
    readonly property bool last: root.Positioner.isLastItem
    readonly property real separatorGap: root.first ? 0 : 1
    readonly property bool active: hover.hovered || root.activeFocus

    signal showing(string gesture, bool on)

    onActiveChanged: root.showing(root.gesture, root.active)

    width: parent ? parent.width : implicitWidth
    implicitHeight: root.separatorGap + root.rowHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title
    Accessible.description: root.subtitle

    HoverHandler {
        id: hover
    }

    // The highlight: the group's corners where the row meets them (a taller rectangle, clipped to the row).
    Item {
        visible: root.active
        y: root.separatorGap
        width: parent.width
        height: root.rowHeight
        clip: true

        Rectangle {
            y: root.first ? 0 : -Tokens.radiusGroup
            width: parent.width
            height: parent.height + (root.first ? 0 : Tokens.radiusGroup) + (root.last ? 0 : Tokens.radiusGroup)
            radius: Tokens.radiusGroup
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsGestureHoverOpacity)
        }
    }

    // The separator above, inset (across the whole group while the row is highlighted), and the one below while it is.
    Rectangle {
        visible: !root.first
        x: root.active ? 0 : Tokens.settingsRowInset
        width: parent.width - 2 * x
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Rectangle {
        visible: root.active && !root.last
        y: root.height
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Text {
        id: titleText
        textFormat: Text.PlainText
        x: Tokens.settingsRowInset
        y: root.separatorGap + Tokens.settingsGestureTitleBaseline - baselineOffset
        width: slot.x - x - Tokens.spacingLg
        elide: Text.ElideRight
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        Accessible.ignored: true
    }

    Text {
        textFormat: Text.PlainText
        visible: root.subtitle !== ""
        x: Tokens.settingsRowInset
        y: root.separatorGap + Tokens.settingsGestureSubtitleBaseline - baselineOffset
        width: titleText.width
        elide: Text.ElideRight
        text: root.subtitle
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        Accessible.ignored: true
    }

    Row {
        id: slot
        x: root.width - width - Tokens.settingsRowInset
        y: root.separatorGap + Math.round((root.subtitle !== "" ? Tokens.settingsGestureControlCenter : root.rowHeight / 2) - height / 2)
        spacing: Tokens.spacingSm
    }
}
