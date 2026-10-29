pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The table of processes (spec AM10 to AM19): Files' list header and rows (ADR-0038 AD24), with the tab's shown columns.
// A click on a header sorts by it, again reverses; a header's right edge resizes its column; the headers' context menu shows
// and hides the optional columns. The rows keep their identity across samples (the model never resets), so the scroll
// position never jumps (AM11).
FocusScope {
    id: root

    required property var backend
    readonly property var table: root.backend.table
    readonly property var columns: root.backend.shownColumns
    // AM13, AM49: the views whose rows have levels, a disclosure triangle before the name of a row that has rows under it.
    readonly property bool outline: root.backend.view === "tree" || root.backend.view === "byGpu"
    readonly property int pageRows: Math.max(1, Math.floor(list.height / Tokens.activityRowHeight))
    // A column's width while its edge is dragged (key → width); written to activity.json when the drag ends.
    property var liveWidths: ({})
    // The headers' context menu (the tests open it).
    readonly property alias headerMenu: headerMenu

    function baseWidth(column: var): real {
        if (root.liveWidths[column.key] !== undefined)
            return root.liveWidths[column.key];
        if (column.width > 0)
            return column.width;
        return column.key === "name" ? Tokens.activityNameColumnWidth : column.key === "command" ? Tokens.activityCommandColumnWidth : Tokens.activityColumnWidth;
    }
    readonly property real othersWidth: {
        let sum = 0;
        for (const c of root.columns) {
            if (c.key !== "name")
                sum += root.baseWidth(c);
        }
        return sum;
    }
    // The name takes what the other columns leave, never less than its own width: a narrow window scrolls sideways,
    // the header with it (as Files' list).
    function widthOf(column: var): real {
        if (column.key !== "name")
            return root.baseWidth(column);
        return Math.max(root.baseWidth(column), list.width - root.othersWidth);
    }
    readonly property real columnsWidth: {
        let sum = 0;
        for (const c of root.columns)
            sum += root.widthOf(c);
        return sum;
    }

    function headerMenuItems(): var {
        return root.backend.columns.filter(c => c.hideable).map(c => ({id: c.key, text: c.title, checked: c.shown}));
    }

    function move(delta: int, extend: bool): void {
        root.table.moveCurrent(delta, extend);
        if (root.table.currentRow >= 0)
            list.positionViewAtIndex(root.table.currentRow, ListView.Contain);
    }

    // Header ------------------------------------------------------------------------------------
    Row {
        id: headerRow
        objectName: "columnHeaders"
        x: list.x - (list.contentX - list.originX)
        width: list.contentWidth
        height: Tokens.activityHeaderHeight

        Repeater {
            model: root.columns

            delegate: Item {
                id: column
                required property var modelData
                required property int index
                readonly property bool active: root.backend.sortKey === column.modelData.key

                width: root.widthOf(column.modelData)
                height: headerRow.height
                activeFocusOnTab: false
                Accessible.role: Accessible.ColumnHeader
                Accessible.name: column.modelData.title
                Accessible.description: column.active ? (root.backend.sortDescending ? qsTr("Sorted descending") : qsTr("Sorted ascending")) : ""
                Accessible.onPressAction: root.backend.sortBy(column.modelData.key)

                Rectangle {
                    anchors.fill: parent
                    color: headerMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                }

                Rectangle {
                    visible: column.index > 0
                    width: Tokens.appsBorderWidth
                    height: parent.height - Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: arrow.visible ? arrow.left : parent.right
                    anchors.rightMargin: arrow.visible ? 0 : Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: column.modelData.numeric ? Text.AlignRight : Text.AlignLeft
                    text: column.modelData.title
                    elide: Text.ElideRight
                    color: column.active ? Appearance.colors.text : Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyCaptionSize
                    font.weight: column.active ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                }

                Icon {
                    id: arrow
                    visible: column.active
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-down"
                    size: Tokens.activityChevronSize
                    color: Appearance.colors.textSecondary
                    rotation: root.backend.sortDescending ? 0 : 180
                }

                MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            const p = mapToItem(root, mouse.x, mouse.y);
                            headerMenu.items = root.headerMenuItems();
                            headerMenu.openAt(p.x, p.y);
                        } else {
                            root.backend.sortBy(column.modelData.key);
                        }
                    }
                }

                // The column's right edge resizes it (AM15); remembered per tab when the drag ends.
                MouseArea {
                    id: edge
                    property real startX: 0
                    property real startWidth: 0
                    anchors.right: parent.right
                    width: Tokens.spacingSm
                    height: parent.height
                    cursorShape: Qt.SplitHCursor
                    onPressed: mouse => {
                        edge.startX = mapToItem(root, mouse.x, 0).x;
                        edge.startWidth = root.widthOf(column.modelData);
                    }
                    onPositionChanged: mouse => {
                        if (!pressed)
                            return;
                        const w = Math.max(Tokens.activityColumnMinWidth, edge.startWidth + mapToItem(root, mouse.x, 0).x - edge.startX);
                        const live = Object.assign({}, root.liveWidths);
                        live[column.modelData.key] = w;
                        root.liveWidths = live;
                    }
                    onReleased: {
                        const w = root.liveWidths[column.modelData.key];
                        if (w !== undefined)
                            root.backend.setColumnWidth(column.modelData.key, Math.round(w));
                        root.liveWidths = ({});
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.top: headerRow.bottom
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    MenuPopup {
        id: headerMenu
        accessibleName: qsTr("Columns")
        focusBack: list
        onChosen: id => {
            const c = root.backend.columns.find(x => x.key === id);
            if (c)
                root.backend.setColumnShown(id, !c.shown);
        }
    }

    // Rows --------------------------------------------------------------------------------------
    MouseArea {
        anchors.fill: list
        onPressed: {
            list.forceActiveFocus();
            root.table.clearSelection();
        }
    }

    ListView {
        id: list
        objectName: "processRows"
        anchors.top: headerRow.bottom
        anchors.topMargin: Tokens.appsBorderWidth
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: scrollBar.width
        anchors.bottom: parent.bottom
        model: root.table
        clip: true
        contentWidth: Math.max(list.width, root.columnsWidth)
        flickableDirection: Flickable.AutoFlickIfNeeded
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: Tokens.activityRowHeight * 20
        Accessible.role: Accessible.Table
        Accessible.name: qsTr("Processes")

        Keys.onPressed: event => {
            const extend = (event.modifiers & Qt.ShiftModifier) !== 0;
            switch (event.key) {
            case Qt.Key_Up:
                root.move(-1, extend);
                break;
            case Qt.Key_Down:
                root.move(1, extend);
                break;
            case Qt.Key_PageUp:
                root.move(-root.pageRows, extend);
                break;
            case Qt.Key_PageDown:
                root.move(root.pageRows, extend);
                break;
            case Qt.Key_Home:
                root.move(-list.count, extend);
                break;
            case Qt.Key_End:
                root.move(list.count, extend);
                break;
            case Qt.Key_Right: // an outline's row opens, as in a macOS outline view
            case Qt.Key_Left:
                if (!root.outline || root.table.currentRow < 0)
                    return;
                root.table.setExpanded(root.table.currentRow, event.key === Qt.Key_Right);
                break;
            default:
                return;
            }
            event.accepted = true;
        }

        delegate: Item {
            id: row

            required property int index
            required property var cells
            required property string name
            required property string icon
            required property bool selected
            required property string accessibleText
            required property int depth
            required property bool expandable
            required property bool expanded
            required property bool group

            readonly property bool emphasized: row.selected && list.activeFocus
            readonly property color foreground: row.emphasized ? Appearance.colors.selectionText : Appearance.colors.text

            width: list.contentWidth
            height: Tokens.activityRowHeight
            Accessible.role: Accessible.Row
            Accessible.name: row.accessibleText
            Accessible.selectable: !row.group
            Accessible.selected: row.selected
            // Qt 6.12 tells a screen reader which rows open and which are open; Qt 6.11.2 has neither property, and the
            // app must load on it too (integrator, PR #53). They are set only where they exist.
            Component.onCompleted: {
                const accessible = row.Accessible;
                if ("expanded" in accessible) {
                    accessible["expandable"] = Qt.binding(() => row.expandable);
                    accessible["expanded"] = Qt.binding(() => row.expanded);
                }
            }

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingXs
                anchors.rightMargin: Tokens.spacingXs
                radius: Tokens.radiusControl
                color: row.selected ? (row.emphasized ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2))
                     : row.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.fill, Tokens.activityRowAlternate) : "transparent"
            }

            Row {
                height: parent.height

                Repeater {
                    model: root.columns

                    delegate: Item {
                        id: cell
                        required property var modelData
                        required property int index
                        readonly property bool isName: cell.modelData.key === "name"
                        // The outline's indentation: a level per depth, and the triangle's place on every row.
                        readonly property real lead: cell.isName && root.outline ? (row.depth + 1) * Tokens.activityTreeIndent : 0

                        width: root.widthOf(cell.modelData)
                        height: row.height

                        Icon {
                            id: disclosure
                            objectName: "disclosure"
                            visible: cell.isName && root.outline && row.expandable
                            x: Tokens.spacingSm + row.depth * Tokens.activityTreeIndent
                            anchors.verticalCenter: parent.verticalCenter
                            size: Tokens.activityChevronSize
                            name: "chevron-right"
                            color: row.foreground
                            rotation: row.expanded ? 90 : 0
                        }

                        Image {
                            id: glyph
                            visible: cell.isName && !row.group
                            x: Tokens.spacingSm + Tokens.spacingXs + cell.lead
                            anchors.verticalCenter: parent.verticalCenter
                            width: Tokens.activityIconSize
                            height: Tokens.activityIconSize
                            sourceSize.width: Tokens.activityIconSize * 2
                            sourceSize.height: Tokens.activityIconSize * 2
                            source: cell.isName ? "image://icon/" + (row.icon !== "" ? row.icon : "application-x-executable") : ""
                            asynchronous: false
                            smooth: true
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.left: cell.isName && !row.group ? glyph.right : parent.left
                            anchors.leftMargin: cell.isName ? (row.group ? Tokens.spacingSm + Tokens.spacingXs + cell.lead : Tokens.spacingXs) : Tokens.spacingSm
                            anchors.right: parent.right
                            anchors.rightMargin: Tokens.spacingSm
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: cell.modelData.numeric ? Text.AlignRight : Text.AlignLeft
                            // AM17: a name is elided in the middle; the other values at their end.
                            elide: cell.isName ? Text.ElideMiddle : Text.ElideRight
                            text: row.cells[cell.index] ?? ""
                            color: row.foreground
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.weight: row.group ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                            font.features: cell.modelData.numeric ? {"tnum": 1} : {}
                        }
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                onPressed: mouse => {
                    list.forceActiveFocus();
                    // The disclosure triangle (and a little around it) opens or closes the row; elsewhere a click selects.
                    const triangle = Tokens.spacingSm + row.depth * Tokens.activityTreeIndent;
                    if (root.outline && row.expandable && mouse.x >= triangle - Tokens.spacingXs
                        && mouse.x <= triangle + Tokens.activityChevronSize + Tokens.spacingXs) {
                        root.table.toggleExpanded(row.index);
                        return;
                    }
                    root.table.click(row.index, mouse.modifiers);
                }
            }
        }
    }

    ScrollBar {
        id: scrollBar
        flickable: list
        anchors.right: parent.right
        anchors.top: list.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }
}
