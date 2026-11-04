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

    // Keep the scroll position when `items` is replaced (the installed apps changed), otherwise the view
    // returns to the top (a filter).
    property bool keepScroll: false
    // True once the cell pool has been filled by warmPool().
    property bool warmed: false

    // Deleting apps (ADR-0044): the icons jiggle while `editing`; `removable` is the controller's check of one item.
    property bool editing: false
    property var removable: item => false

    signal activated(var item)
    signal deleteRequested(var item)
    signal holdStarted

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
        const y = contentY;
        scriptModel.values = [];
        scriptModel.values = items;
        if (keepScroll) {
            forceLayout();
            contentY = Math.max(0, Math.min(y, contentHeight + topMargin + bottomMargin - height));
        }
    }

    // Scrolls to the first row, with its margin above it. positionViewAtBeginning() alone leaves a view that has never been
    // shown at contentY 0 (the first row 38 px under the chips' bottom, i.e. against them) until a later layout; laying out first
    // and setting the place ourselves is in place on the first opening already, before its first frame.
    function toBeginning(): void {
        forceLayout();
        positionViewAtBeginning();
        contentY = originY - topMargin;
    }

    // Fills the pool of cells without painting anything. The first change of a freshly built view destroys the
    // cells of the first layout and creates a second screenful (about 55 ms for 200 entries, offscreen), which
    // the first keystroke would pay. forceLayout() does that now: the owner calls it while the window is not
    // yet shown (idle time after the list is built), so neither the opening nor a keystroke pays. Once per view.
    function warmPool(): void {
        if (warmed || items.length < 2)
            return;
        warmed = true;
        scriptModel.values = items;
        forceLayout();
        scriptModel.values = [];
        scriptModel.values = items.slice().reverse();
        forceLayout();
        scriptModel.values = items;
        forceLayout();
    }

    delegate: AppsCell {
        id: cell

        required property var modelData
        required property int index

        info: modelData
        cellW: root.cellWidth
        cellH: root.cellHeight
        selected: root.selectedIndex === index && root.ringVisible
        editing: root.editing
        removable: root.editing && root.removable(modelData)
        position: index
        onActivated: root.activated(modelData)
        onDeleteRequested: root.deleteRequested(modelData)
        onHoldStarted: root.holdStarted()
    }
}
