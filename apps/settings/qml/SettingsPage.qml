import QtQuick
import Grassfield.Ui

// Scrolling detail pane: the groups stacked with groupGap. The title is the window toolbar's (ADR-0015), not repeated here.
Flickable {
    id: root

    property string title: ""
    default property alias groups: column.data

    contentWidth: width
    contentHeight: column.y + column.height + 2 * Tokens.spacingLg
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Column {
        id: column
        x: Math.max(Tokens.settingsContentMargin, (root.width - width) / 2)
        y: Tokens.settingsPageTop
        width: Math.min(Tokens.settingsContentMaxWidth, root.width - 2 * Tokens.settingsContentMargin)
        spacing: Tokens.settingsGroupGap
    }
}
