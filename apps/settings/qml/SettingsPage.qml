import QtQuick
import Grassfield.Ui

// Scrolling detail pane: the groups stacked with groupGap, contentMargin from the pane's sides and contentTop below the
// toolbar (macOS 27). The title is the window toolbar's (ADR-0015), not repeated here.
Flickable {
    id: root

    property string title: ""
    default property alias groups: column.data
    // The groups' left edge in the pane (a block that spans the whole pane, Wallpaper's line, starts this far to the left).
    readonly property real columnX: column.x

    contentWidth: width
    contentHeight: column.y + column.height + Tokens.settingsContentMargin
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    // The pane's overlay scroll bar, shown while it scrolls or under the pointer (macOS 27; UI audit 2026-11-05 U30).
    ScrollBar.vertical: ScrollBar {}
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Column {
        id: column
        // Whole pixels: the groups' edges stay sharp when the pane is wider than the groups.
        x: Math.max(Tokens.settingsContentMargin, Math.round((root.width - width) / 2))
        y: Tokens.settingsContentTop
        width: Math.min(Tokens.settingsContentMaxWidth, root.width - 2 * Tokens.settingsContentMargin)
        spacing: Tokens.settingsGroupGap
    }
}
