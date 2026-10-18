pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// The scrolling grid of the Apps panel: one AppsCell per item, virtualised (only the rows in view and a
// small buffer exist, pooled and reused). `items` is a list of display items {key, id, name, rec}.
GridView {
    id: root

    property var items: []
    property int selectedIndex: -1
    // True while the keyboard (or a search) owns the selection ring.
    property bool ringVisible: false

    signal activated(var item)

    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    keyNavigationEnabled: false
    // Delegates leaving the view are pooled and reused: a keystroke that brings back many rows
    // (clearing the field) rebinds cells instead of creating them.
    reuseItems: true
    // One row beyond the view is enough to scroll smoothly; the default buffer creates several more rows on every restore.
    cacheBuffer: cellHeight
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Applications")

    model: ScriptModel {
        id: scriptModel
    }

    // The list is replaced in two steps (empty, then the new items): a filter reorders and drops most rows,
    // and rebinding the few pooled cells in view is much cheaper than diffing and moving every row.
    onItemsChanged: {
        scriptModel.values = [];
        scriptModel.values = items;
    }

    delegate: AppsCell {
        id: cell

        required property var modelData
        required property int index

        info: modelData
        cellW: root.cellWidth
        cellH: root.cellHeight
        selected: root.selectedIndex === index && root.ringVisible
        onActivated: root.activated(modelData)
    }
}
