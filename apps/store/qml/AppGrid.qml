pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Apps in columns (a row block of Discover, a category, the search results, Installed: spec SR4, SR6, SR8, SR23): as many
// columns of AppLockups as the width holds at their minimum width, filled row by row, a separator under each but the last
// row. The arrows move between items.
Grid {
    id: root

    property var apps: []
    property real minColumnWidth: Tokens.storeLockupMinWidth
    property bool showButtons: true

    signal opened(string id)

    columns: Math.max(1, Math.floor((root.width + root.columnSpacing) / (root.minColumnWidth + root.columnSpacing)))
    columnSpacing: Tokens.storeGridColumnGap
    rowSpacing: 0
    readonly property real cellWidth: (root.width - (root.columns - 1) * root.columnSpacing) / root.columns
    readonly property int rows_: Math.ceil(root.apps.length / root.columns)

    function focusItem(index: int): void {
        const item = repeater.itemAt(Math.max(0, Math.min(root.apps.length - 1, index)));
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    Repeater {
        id: repeater
        model: root.apps

        delegate: AppLockup {
            required property var modelData
            required property int index
            width: root.cellWidth
            app: modelData
            showButton: root.showButtons
            separator: Math.floor(index / root.columns) < root.rows_ - 1
            onOpened: id => root.opened(id)
            Keys.onLeftPressed: root.focusItem(index - 1)
            Keys.onRightPressed: root.focusItem(index + 1)
            Keys.onUpPressed: event => {
                if (index >= root.columns)
                    root.focusItem(index - root.columns);
                else
                    event.accepted = false;
            }
            Keys.onDownPressed: event => {
                if (index + root.columns < root.apps.length)
                    root.focusItem(index + root.columns);
                else
                    event.accepted = false;
            }
        }
    }
}
