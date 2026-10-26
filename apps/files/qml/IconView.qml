pragma ComponentBehavior: Bound
import QtQuick
import QtQml.Models
import Grassfield.Ui
import "Nav.js" as Nav

// Icon view: a grid of thumbnails or type icons with names below. Click selects (Shift extends,
// Ctrl toggles), double click opens, drag on empty space draws a selection rectangle, items drag
// out as text/uri-list, folders and the background accept drops. With View > Group By, each group is one row under its
// header, scrolled sideways, and Show All lays the group out in full (Finder).
FocusScope {
    id: root

    required property var tab
    required property var model

    readonly property int columns: Math.max(1, Math.floor(grid.width / Tokens.filesIconCellWidth))
    readonly property real cellWidth: Math.floor(grid.width / root.columns)
    readonly property int pageRows: Math.max(1, Math.floor(grid.height / grid.cellHeight))
    readonly property bool grouped: root.model !== null && root.model.groupBy > 0
    readonly property var groups: root.grouped ? root.model.groups : []
    // Groups shown in full (Show All), by title; forgotten with the folder.
    property var expanded: ({})
    // The flickable that holds the items now.
    readonly property Flickable flick: root.grouped ? groupedView : grid
    // The content has moved up under the toolbar (the window draws the toolbar's hairline then, macOS).
    readonly property bool scrolled: root.flick.contentY > root.flick.originY

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Files")

    function applyPrefs(): void {
    }

    function focusView(): void {
        root.flick.forceActiveFocus();
    }

    // The group holding `row` (an index into root.groups), -1 without groups.
    function groupOfRow(row: int): int {
        for (let g = 0; g < root.groups.length; g++) {
            if (row < root.groups[g].first + root.groups[g].count)
                return g;
        }
        return -1;
    }

    function setExpanded(title: string, on: bool): void {
        const next = Object.assign({}, root.expanded);
        next[title] = on;
        root.expanded = next;
    }

    // The groups as Nav.groupedIconMove sees them: a collapsed group is one row of all its items.
    function navGroups(): var {
        return root.groups.map(g => ({first: g.first, count: g.count, columns: root.expanded[g.title] === true ? root.columns : g.count}));
    }

    // Scrolls `row` into view (its group, then within the group's row).
    function reveal(row: int): void {
        if (!root.grouped) {
            grid.positionViewAtIndex(row, GridView.Contain);
            return;
        }
        const g = root.groupOfRow(row);
        if (g < 0)
            return;
        groupedView.positionViewAtIndex(g, ListView.Contain);
        const item = groupedView.itemAtIndex(g);
        if (item)
            item.reveal(row - root.groups[g].first);
    }

    // Window coordinates of a row (keyboard context menu).
    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        if (root.grouped) {
            const item = groupedView.itemAtIndex(root.groupOfRow(row));
            return item ? item.rowPosition(row) : root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        }
        const col = row % root.columns;
        const r = Math.floor(row / root.columns);
        return grid.mapToItem(null, (col + 0.5) * grid.cellWidth, r * grid.cellHeight - grid.contentY + grid.originY + Tokens.filesIconSize);
    }

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCurrentRowChanged(): void {
            if (root.model.currentRow >= 0)
                root.reveal(root.model.currentRow);
        }
        function onRevealRequested(row: int, rename: bool): void {
            root.reveal(row);
            if (rename)
                root.tab.startRename(root.model, row);
        }
        // The group rows are made again when the groups change (a new list): the scroll position is kept.
        function onGroupsChanged(): void {
            const y = groupedView.contentY;
            Qt.callLater(() => groupedView.contentY = Math.max(groupedView.originY, Math.min(y, groupedView.contentHeight - groupedView.height + groupedView.originY)));
        }
        function onUrlChanged(): void {
            root.expanded = {};
        }
    }

    // Drag source shared by all cells (the system drag starts when Drag.active turns true).
    Item {
        id: dragProxy
        width: Tokens.filesIconSize
        height: Tokens.filesIconSize
        visible: false
        Drag.dragType: Drag.Automatic
        // No link: Wayland drag and drop has none (a drop proposing it is refused); Files makes an alias itself
        // for Option-Cmd (FilesApp.drop).
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
        Drag.proposedAction: Qt.MoveAction
        Drag.hotSpot.x: Tokens.filesIconSize / 2
        Drag.hotSpot.y: Tokens.filesIconSize / 2
        Drag.onDragFinished: dropAction => {
            dragProxy.Drag.active = false;
            root.tab.dragFinished(dropAction);
        }
    }

    function startDrag(iconName: string, thumbnail: string): void {
        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
        dragProxy.Drag.imageSource = thumbnail !== "" ? thumbnail : "image://icon/" + iconName;
        dragProxy.Drag.active = true;
    }

    // The rows a band covers in the grouped layout: the group rows on screen, each by its own geometry.
    function groupedRowsInBand(left: real, top: real, right: real, bottom: real): var {
        const out = [];
        for (let g = 0; g < root.groups.length; g++) {
            const item = groupedView.itemAtIndex(g);
            if (item)
                out.push(...item.rowsInBand(left, top - item.y, right, bottom - item.y));
        }
        return out;
    }

    // Background: empty-space clicks, rubber band selection, context menu and drops into this folder.
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: drop => {
            if (drop.hasUrls) {
                root.tab.dropUrls(drop.urls, root.model.url, root.model);
                drop.accept(Qt.CopyAction);
            }
        }
    }

    MouseArea {
        id: background
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point origin
        property bool banding: false
        property var baseSelection: []

        onPressed: mouse => {
            root.focusView();
            if (mouse.button === Qt.RightButton) {
                const p = background.mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
                return;
            }
            const f = root.flick;
            origin = Qt.point(mouse.x - f.x, mouse.y - f.y + f.contentY - f.originY);
            baseSelection = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.model.selectedUrls() : [];
            if (baseSelection.length === 0)
                root.model.clearSelection();
            banding = false;
        }
        onPositionChanged: mouse => {
            if (!pressed || mouse.buttons !== Qt.LeftButton)
                return;
            const f = root.flick;
            const y = mouse.y - f.y + f.contentY - f.originY;
            const x = mouse.x - f.x;
            if (!banding && Math.abs(x - origin.x) + Math.abs(y - origin.y) < Tokens.filesDragThreshold)
                return;
            banding = true;
            band.x = f.x + Math.min(x, origin.x);
            band.width = Math.abs(x - origin.x);
            band.contentTop = Math.min(y, origin.y);
            band.height = Math.abs(y - origin.y);
            const rows = root.grouped ? root.groupedRowsInBand(Math.min(x, origin.x), Math.min(y, origin.y), Math.max(x, origin.x), Math.max(y, origin.y))
                                      : Nav.cellsInRect(origin.x, origin.y, x, y, grid.cellWidth, grid.cellHeight, root.columns, grid.count);
            const urls = baseSelection.slice();
            for (let i = 0; i < rows.length; i++)
                urls.push(root.model.urlAt(rows[i]));
            root.model.selectUrls(urls);
            // Scroll while the band reaches past the edges.
            if (mouse.y > f.y + f.height)
                f.contentY = Math.min(f.contentY + Tokens.spacingSm, Math.max(f.originY, f.contentHeight - f.height + f.originY));
            else if (mouse.y < f.y)
                f.contentY = Math.max(f.originY, f.contentY - Tokens.spacingSm);
        }
        onReleased: banding = false
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm + scrollBar.width
        visible: !root.grouped
        cellWidth: root.cellWidth
        cellHeight: Tokens.filesIconCellHeight
        model: root.grouped ? null : root.model
        clip: true
        focus: !root.grouped
        activeFocusOnTab: !root.grouped
        keyNavigationEnabled: false
        // Mouse drags select and drag files instead of flicking; the wheel still scrolls.
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Tokens.filesIconCellHeight * 2
        currentIndex: root.model && !root.grouped ? root.model.currentRow : -1
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.gridMove(root.model.currentRow, key, root.columns, grid.count, root.pageRows))

        delegate: IconCell {}
    }

    // Grouped layout: one section per group (FolderModel.groups), its items in one row or, after Show All, in full.
    ListView {
        id: groupedView
        anchors.fill: grid
        visible: root.grouped
        model: root.groups
        clip: true
        focus: root.grouped
        activeFocusOnTab: root.grouped
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Tokens.filesIconCellHeight * 2
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.groupedIconMove(root.model.currentRow, key, root.navGroups()))

        delegate: Item {
            id: section

            required property var modelData
            required property int index

            readonly property bool full: root.expanded[section.modelData.title] === true
            readonly property int first: section.modelData.first
            readonly property int count: section.modelData.count
            readonly property bool overflows: section.count * root.cellWidth > groupedView.width
            readonly property Flickable items: section.full ? sectionGrid : sectionRow

            width: groupedView.width
            height: Tokens.filesIconGroupHeight + (section.full ? Math.ceil(section.count / root.columns) : 1) * Tokens.filesIconCellHeight
            Accessible.role: Accessible.Grouping
            Accessible.name: section.modelData.title

            function reveal(index: int): void {
                section.items.positionViewAtIndex(index, section.full ? GridView.Contain : ListView.Contain);
            }

            function rowPosition(row: int): point {
                const i = row - section.first;
                const col = section.full ? i % root.columns : i;
                const r = section.full ? Math.floor(i / root.columns) : 0;
                return section.items.mapToItem(null, (col + 0.5) * root.cellWidth - section.items.contentX, r * Tokens.filesIconCellHeight + Tokens.filesIconSize);
            }

            // Rows under the band, in this section's coordinates.
            function rowsInBand(left: real, top: real, right: real, bottom: real): var {
                const y0 = Tokens.filesIconGroupHeight;
                if (section.full)
                    return Nav.cellsInRect(left, top - y0, right, bottom - y0, root.cellWidth, Tokens.filesIconCellHeight, root.columns, section.count).map(i => section.first + i);
                if (bottom < y0 || top > y0 + Tokens.filesIconCellHeight)
                    return [];
                return Nav.cellsInRect(left + sectionRow.contentX, 0, right + sectionRow.contentX, 0, root.cellWidth, Tokens.filesIconCellHeight, section.count, section.count).map(i => section.first + i);
            }

            Text {
                textFormat: Text.PlainText
                x: Tokens.spacingSm
                anchors.verticalCenter: header.verticalCenter
                width: showAll.x - x - Tokens.spacingSm
                text: section.modelData.title
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }

            Item {
                id: header
                width: parent.width
                height: Tokens.filesIconGroupHeight
            }

            Text {
                id: showAll
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingSm
                anchors.verticalCenter: header.verticalCenter
                visible: section.overflows || section.full
                text: section.full ? qsTr("Show Less") : qsTr("Show All")
                color: Appearance.colors.accent
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                Accessible.role: Accessible.Button
                Accessible.name: text
                Accessible.onPressAction: root.setExpanded(section.modelData.title, !section.full)

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Tokens.spacingXs
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setExpanded(section.modelData.title, !section.full)
                }
            }

            // This group's rows of the listing.
            DelegateModel {
                id: range
                model: root.model
                groups: [
                    DelegateModelGroup {
                        name: "range"
                        includeByDefault: false
                    }
                ]
                filterOnGroup: "range"
                delegate: IconCell {
                    row: DelegateModel.itemsIndex
                }
                Component.onCompleted: range.items.addGroups(section.first, section.count, ["range"])
            }

            ListView {
                id: sectionRow
                y: Tokens.filesIconGroupHeight
                width: parent.width
                height: Tokens.filesIconCellHeight
                visible: !section.full
                orientation: ListView.Horizontal
                model: section.full ? null : range
                clip: true
                interactive: false
                acceptedButtons: Qt.NoButton
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: root.cellWidth * 4

                // A sideways wheel or trackpad swipe scrolls the row; a vertical one is left to the page (a horizontal-only
                // flickable would take it).
                WheelHandler {
                    orientation: Qt.Horizontal
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: event => {
                        // A wheel notch is 120 eighths of a degree (Qt): one item per notch.
                        const dx = event.pixelDelta.x !== 0 ? event.pixelDelta.x : event.angleDelta.x / 120 * root.cellWidth;
                        if (dx === 0) {
                            event.accepted = false;
                            return;
                        }
                        const max = Math.max(0, sectionRow.contentWidth - sectionRow.width);
                        sectionRow.contentX = Math.max(0, Math.min(max, sectionRow.contentX - dx));
                    }
                }
            }

            GridView {
                id: sectionGrid
                y: Tokens.filesIconGroupHeight
                width: parent.width
                height: parent.height - y
                visible: section.full
                cellWidth: root.cellWidth
                cellHeight: Tokens.filesIconCellHeight
                model: section.full ? range : null
                interactive: false
                acceptedButtons: Qt.NoButton
            }
        }
    }

    Rectangle {
        id: band
        property real contentTop: 0
        visible: background.banding
        y: root.flick.y + contentTop - root.flick.contentY + root.flick.originY
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.filesRubberBandOpacity)
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.colors.accent
    }

    ScrollBar {
        id: scrollBar
        flickable: root.flick
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }

    Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.model !== null && root.model.count === 0 && !root.model.loading
        text: root.tab.searchText !== "" ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        width: parent.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    // One item: icon or thumbnail, name, tag dots, inline rename, drop target and drag source.
    component IconCell: FocusScope {
        id: cell

        required property int index
        // The item's row in the listing (the grouped rows give it: their own index counts within the group).
        property int row: cell.index
        required property string name
        required property url url
        required property string iconName
        required property string thumbnail
        required property string emblem
        required property bool selected
        required property bool isDir
        required property string folderColor
        required property string folderGlyph
        required property bool canPreview
        required property bool hidden
        required property var tagColors

        readonly property bool renaming: root.tab.isRenaming(root.model, cell.url)
        readonly property bool focused: root.activeFocus
        // Room taken by the tag dots left of the name.
        readonly property real dotsRoom: dots.visible ? dots.width + Tokens.spacingXs : 0

        width: root.cellWidth
        height: Tokens.filesIconCellHeight
        opacity: cell.hidden ? Tokens.filesHiddenOpacity : 1
        Accessible.role: Accessible.ListItem
        Accessible.name: DisplayName.text(cell.name)
        Accessible.selectable: true
        Accessible.selected: cell.selected
        Accessible.onPressAction: root.tab.activate(cell.row, root.model, Qt.NoModifier)

        Component.onCompleted: if (cell.canPreview) root.model.requestPreview(cell.row)
        onCanPreviewChanged: if (cell.canPreview) root.model.requestPreview(cell.row)
        // Scrolled away before its thumbnail was started: drop the request.
        Component.onDestruction: if (root.model) root.model.cancelPreview(cell.url)

        Rectangle {
            id: backdrop
            anchors.horizontalCenter: icon.horizontalCenter
            anchors.verticalCenter: icon.verticalCenter
            width: Tokens.filesIconSize + 2 * Tokens.filesIconBackdropPadding
            height: width
            radius: Tokens.radiusControl
            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            visible: cell.selected || drop.containsDrag
            border.width: drop.containsDrag ? Tokens.filesDropBorder : 0
            border.color: Appearance.colors.accent
        }

        FileIcon {
            id: icon
            anchors.horizontalCenter: parent.horizontalCenter
            y: Tokens.spacingSm
            size: Tokens.filesIconSize
            iconName: cell.iconName
            isDir: cell.isDir
            folderColor: cell.folderColor
            folderGlyph: cell.folderGlyph
            thumbnail: cell.thumbnail
            emblem: cell.emblem
        }

        Rectangle {
            visible: cell.selected && !cell.renaming
            anchors.horizontalCenter: label.horizontalCenter
            y: label.y - Tokens.spacingXs / 2
            width: Math.min(label.paintedWidth + 2 * Tokens.spacingXs, cell.width - Tokens.spacingXs)
            height: label.paintedHeight + Tokens.spacingXs
            radius: Tokens.radiusControl / 2
            color: cell.focused ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)
        }

        // Colour tags: dots before the first line of the name; dots and name are centred together.
        TagDots {
            id: dots
            visible: !cell.renaming && colors.length > 0
            colors: cell.tagColors
            x: label.x + (label.width - label.paintedWidth) / 2 - width - Tokens.spacingXs
            y: label.y + (label.paintedHeight / Math.max(1, label.lineCount) - height) / 2
        }

        Text {
            id: label
            textFormat: Text.PlainText
            visible: !cell.renaming
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: cell.dotsRoom / 2
            anchors.top: icon.bottom
            anchors.topMargin: Tokens.spacingXs + Tokens.spacingXs / 2
            width: cell.width - 2 * Tokens.spacingXs - cell.dotsRoom
            horizontalAlignment: Text.AlignHCenter
            text: DisplayName.text(cell.name)
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: Tokens.filesIconLabelLines
            elide: Text.ElideRight
            color: cell.selected && cell.focused ? Appearance.colors.selectionText : Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize + 1
        }

        Loader {
            active: cell.renaming
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: icon.bottom
            anchors.topMargin: Tokens.spacingXs
            width: cell.width - Tokens.spacingXs
            sourceComponent: RenameField {
                originalName: cell.name
                baseLength: root.tab.app.baseNameLength(cell.name, cell.isDir)
                horizontalAlignment: TextInput.AlignHCenter
                onCommitted: name => root.tab.commitRename(name)
                onCanceled: root.tab.cancelRename()
            }
        }

        DropArea {
            id: drop
            anchors.fill: parent
            enabled: cell.isDir && !cell.selected
            keys: ["text/uri-list"]
            onEntered: root.tab.springHover(cell.url)
            onExited: root.tab.springLeave(cell.url)
            onDropped: event => {
                if (event.hasUrls) {
                    root.tab.dropUrls(event.urls, cell.url, root.model);
                    event.accept(Qt.CopyAction);
                }
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            enabled: !cell.renaming
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            drag.target: dragProxy
            drag.threshold: Tokens.filesDragThreshold
            property bool collapseOnRelease: false

            onPressed: event => {
                root.focusView();
                if (event.button === Qt.RightButton) {
                    const p = mouse.mapToItem(null, event.x, event.y);
                    root.tab.contextMenu(root.model, cell.row, p.x, p.y, false);
                    return;
                }
                const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                collapseOnRelease = cell.selected && mods === 0;
                if (!cell.selected || mods !== 0)
                    root.model.select(cell.row, mods);
            }
            onReleased: {
                if (collapseOnRelease && !drag.active)
                    root.model.select(cell.row, 0);
                collapseOnRelease = false;
            }
            onDoubleClicked: event => {
                if (event.button === Qt.LeftButton)
                    root.tab.activate(cell.row, root.model, event.modifiers);
            }
            drag.onActiveChanged: {
                if (drag.active) {
                    collapseOnRelease = false;
                    root.startDrag(cell.iconName, cell.thumbnail);
                }
            }
        }
    }
}
