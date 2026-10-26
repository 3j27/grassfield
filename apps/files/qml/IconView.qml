pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "IconSource.js" as IconSource
import "Nav.js" as Nav

// Icon view: a grid of thumbnails or type icons with names below. Click selects (Shift extends,
// Ctrl toggles), double click opens, drag on empty space draws a selection rectangle, items drag
// out as text/uri-list, folders and the background accept drops.
FocusScope {
    id: root

    required property var tab
    required property var model

    readonly property int columns: Math.max(1, Math.floor(grid.width / Tokens.filesIconCellWidth))
    readonly property int pageRows: Math.max(1, Math.floor(grid.height / grid.cellHeight))

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Files")

    function applyPrefs(): void {
    }

    function focusView(): void {
        grid.forceActiveFocus();
    }

    // Window coordinates of a row (keyboard context menu).
    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        const col = row % root.columns;
        const r = Math.floor(row / root.columns);
        return grid.mapToItem(null, (col + 0.5) * grid.cellWidth, r * grid.cellHeight - grid.contentY + grid.originY + Tokens.filesIconSize);
    }

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCurrentRowChanged(): void {
            if (root.model.currentRow >= 0)
                grid.positionViewAtIndex(root.model.currentRow, GridView.Contain);
        }
        function onRevealRequested(row: int, rename: bool): void {
            grid.positionViewAtIndex(row, GridView.Contain);
            if (rename)
                root.tab.startRename(root.model, row);
        }
    }

    // Drag source shared by all cells (the system drag starts when Drag.active turns true).
    Item {
        id: dragProxy
        width: Tokens.filesIconSize
        height: Tokens.filesIconSize
        visible: false
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.MoveAction
        Drag.hotSpot.x: Tokens.filesIconSize / 2
        Drag.hotSpot.y: Tokens.filesIconSize / 2
        Drag.onDragFinished: dragProxy.Drag.active = false
    }

    function startDrag(iconName: string, thumbnail: string): void {
        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
        dragProxy.Drag.imageSource = thumbnail !== "" ? thumbnail : IconSource.url(iconName);
        dragProxy.Drag.active = true;
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
            grid.forceActiveFocus();
            if (mouse.button === Qt.RightButton) {
                const p = background.mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
                return;
            }
            origin = Qt.point(mouse.x - grid.x, mouse.y - grid.y + grid.contentY - grid.originY);
            baseSelection = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? root.model.selectedUrls() : [];
            if (baseSelection.length === 0)
                root.model.clearSelection();
            banding = false;
        }
        onPositionChanged: mouse => {
            if (!pressed || mouse.buttons !== Qt.LeftButton)
                return;
            const y = mouse.y - grid.y + grid.contentY - grid.originY;
            const x = mouse.x - grid.x;
            if (!banding && Math.abs(x - origin.x) + Math.abs(y - origin.y) < Tokens.filesDragThreshold)
                return;
            banding = true;
            band.x = grid.x + Math.min(x, origin.x);
            band.width = Math.abs(x - origin.x);
            band.contentTop = Math.min(y, origin.y);
            band.height = Math.abs(y - origin.y);
            const rows = Nav.cellsInRect(origin.x, origin.y, x, y, grid.cellWidth, grid.cellHeight, root.columns, grid.count);
            const urls = baseSelection.slice();
            for (let i = 0; i < rows.length; i++)
                urls.push(root.model.urlAt(rows[i]));
            root.model.selectUrls(urls);
            // Scroll while the band reaches past the edges.
            if (mouse.y > grid.y + grid.height)
                grid.contentY = Math.min(grid.contentY + Tokens.spacingSm, Math.max(grid.originY, grid.contentHeight - grid.height + grid.originY));
            else if (mouse.y < grid.y)
                grid.contentY = Math.max(grid.originY, grid.contentY - Tokens.spacingSm);
        }
        onReleased: banding = false
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm + scrollBar.width
        cellWidth: Math.floor(width / root.columns)
        cellHeight: Tokens.filesIconCellHeight
        model: root.model
        clip: true
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        // Mouse drags select and drag files instead of flicking; the wheel still scrolls.
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Tokens.filesIconCellHeight * 2
        currentIndex: root.model ? root.model.currentRow : -1
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.gridMove(root.model.currentRow, key, root.columns, grid.count, root.pageRows))

        delegate: FocusScope {
            id: cell

            required property int index
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
            readonly property bool focused: grid.activeFocus
            // Room taken by the tag dots left of the name.
            readonly property real dotsRoom: dots.visible ? dots.width + Tokens.spacingXs : 0

            width: grid.cellWidth
            height: grid.cellHeight
            opacity: cell.hidden ? Tokens.filesHiddenOpacity : 1
            Accessible.role: Accessible.ListItem
            Accessible.name: DisplayName.text(cell.name)
            Accessible.selectable: true
            Accessible.selected: cell.selected
            Accessible.onPressAction: root.tab.activate(cell.index, root.model)

            Component.onCompleted: if (cell.canPreview) root.model.requestPreview(cell.index)
            onCanPreviewChanged: if (cell.canPreview) root.model.requestPreview(cell.index)
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
                drag.target: root.model.isApplications ? null : dragProxy
                drag.threshold: Tokens.filesDragThreshold
                property bool collapseOnRelease: false

                onPressed: event => {
                    grid.forceActiveFocus();
                    if (event.button === Qt.RightButton) {
                        const p = mouse.mapToItem(null, event.x, event.y);
                        root.tab.contextMenu(root.model, cell.index, p.x, p.y, false);
                        return;
                    }
                    const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                    collapseOnRelease = cell.selected && mods === 0;
                    if (!cell.selected || mods !== 0)
                        root.model.select(cell.index, mods);
                }
                onReleased: {
                    if (collapseOnRelease && !drag.active)
                        root.model.select(cell.index, 0);
                    collapseOnRelease = false;
                }
                onDoubleClicked: event => {
                    if (event.button === Qt.LeftButton)
                        root.tab.activate(cell.index, root.model);
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

    Rectangle {
        id: band
        property real contentTop: 0
        visible: background.banding
        y: grid.y + contentTop - grid.contentY + grid.originY
        color: Appearance.withAlpha(Appearance.colors.accent, Tokens.filesRubberBandOpacity)
        border.width: 1
        border.color: Appearance.colors.accent
    }

    ScrollBar {
        id: scrollBar
        flickable: grid
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingXs
    }

    Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: grid.count === 0 && root.model && !root.model.loading
        text: root.tab.searchText !== "" ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        width: parent.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }
}
