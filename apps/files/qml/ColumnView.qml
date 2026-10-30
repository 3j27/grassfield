pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Nav.js" as Nav

// Column view: one column per folder from the first path segment to the tab's location, each with its
// own KIO listing. Selecting a folder opens it in the next column; selecting a file shows a preview
// column. Left/Right move between columns.
FocusScope {
    id: root

    required property var tab

    property int activeColumn: -1
    // Set while the column view itself changes the tab location (keeps the focused column).
    property bool internalNav: false
    // Counts the columns made and removed: itemAt() is no property, and the Repeater may make a column after activeColumn
    // names it (the location a panel starts in: the binding stayed null, so the panel read another listing's selection;
    // integrator nested pass of f9a25ce, follow-up 1).
    property int columnsMade: 0
    readonly property Item activeItem: {
        root.columnsMade;
        return root.activeColumn >= 0 ? columns.itemAt(root.activeColumn) : null;
    }
    readonly property var activeModel: root.activeItem ? (root.activeItem as FileColumn).model : null
    readonly property var previewInfo: {
        const m = root.activeModel;
        if (!m || root.activeColumn !== columnsModel.count - 1 || m.selectedCount !== 1)
            return null;
        const r = m.selectedRows()[0];
        return m.isDirAt(r) ? null : m.info(r);
    }

    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Columns")

    function applyPrefs(): void {
        for (let i = 0; i < columns.count; i++) {
            const c = columns.itemAt(i) as FileColumn;
            if (c && c.model)
                root.tab.applyPrefs(c.model);
        }
    }

    function rowPosition(model: var, row: int): point {
        const c = root.activeItem as FileColumn;
        if (!c)
            return root.mapToItem(null, Tokens.spacingLg, Tokens.spacingLg);
        return c.rowPosition(row);
    }

    function focusView(): void {
        const c = root.activeItem as FileColumn;
        if (c)
            c.focusList();
    }

    // Keep the columns that still match the location, replace the rest.
    function sync(): void {
        const urls = root.tab.segments.map(s => String(s.url));
        const current = [];
        for (let i = 0; i < columnsModel.count; i++)
            current.push(columnsModel.get(i).url);
        const keep = Nav.commonPrefix(current, urls);
        if (columnsModel.count > keep)
            columnsModel.remove(keep, columnsModel.count - keep);
        for (let i = keep; i < urls.length; i++)
            columnsModel.append({url: urls[i]});
        // Each column selects the folder shown in the column after it.
        for (let i = 0; i < columnsModel.count - 1; i++) {
            const c = columns.itemAt(i) as FileColumn;
            if (c && c.model)
                c.model.expect(urls[i + 1], false);
        }
        if (!root.internalNav)
            root.activeColumn = columnsModel.count - 1;
        root.internalNav = false;
        Qt.callLater(root.scrollToEnd);
        Qt.callLater(root.focusView);
    }

    function scrollToEnd(): void {
        flick.contentX = Math.max(0, flick.contentWidth - flick.width);
    }

    // A user selection in column `index`: folders open in the next column, files truncate to a preview.
    function userSelected(index: int): void {
        const c = columns.itemAt(index) as FileColumn;
        if (!c || !c.model)
            return;
        root.activeColumn = index;
        const m = c.model;
        if (m.selectedCount !== 1) {
            root.internalNav = true;
            root.tab.navigate(c.url, false);
            return;
        }
        const r = m.selectedRows()[0];
        root.internalNav = true;
        root.tab.navigate(m.isDirAt(r) ? m.urlAt(r) : c.url, false);
    }

    function enterNext(index: int): void {
        const next = columns.itemAt(index + 1) as FileColumn;
        if (!next || !next.model || next.model.count === 0)
            return;
        root.activeColumn = index + 1;
        next.model.select(0, 0);
        root.userSelected(index + 1);
        next.focusList();
    }

    function leavePrevious(index: int): void {
        if (index <= 0)
            return;
        root.activeColumn = index - 1;
        root.userSelected(index - 1);
        (columns.itemAt(index - 1) as FileColumn).focusList();
    }

    Connections {
        target: root.tab
        function onSegmentsChanged(): void {
            root.sync();
        }
    }

    Component.onCompleted: root.sync()

    ListModel {
        id: columnsModel
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: strip.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        acceptedButtons: Qt.NoButton
        clip: true

        Row {
            id: strip
            height: flick.height

            Repeater {
                id: columns
                model: columnsModel
                delegate: FileColumn {}
                onItemAdded: root.columnsMade++
                onItemRemoved: root.columnsMade++
            }

            // Preview column for a selected file (View > Show Preview, the column view's own setting): the preview pane on the
            // window's white.
            Loader {
                active: root.previewInfo !== null && root.tab.app.columnPreview
                width: active ? Tokens.filesPreviewPaneWidth : 0
                height: strip.height
                sourceComponent: PreviewPane {
                    tab: root.tab
                    model: root.activeModel
                    filled: false
                }
            }
        }
    }

    component FileColumn: FocusScope {
        id: col

        required property int index
        required property string url
        property var model: null
        readonly property bool active: root.activeColumn === col.index

        width: Tokens.filesColumnWidth
        height: strip.height
        Accessible.role: Accessible.List
        Accessible.name: col.model ? col.model.title : ""

        function focusList(): void {
            lv.forceActiveFocus();
        }

        // Rubber band from the column's empty space (Finder): the rows it covers, added to the selection with Shift or
        // Cmd. Points in lv.contentItem coordinates.
        property bool banding: false
        property point bandOrigin
        property point bandEnd
        property var bandBase: []

        function rowPosition(row: int): point {
            return lv.mapToItem(null, Tokens.spacingLg, (Math.max(0, row) + 1) * Tokens.filesColumnRowHeight - lv.contentY + lv.originY);
        }

        Component.onCompleted: {
            col.model = root.tab.createModel(col);
            col.model.url = col.url;
            // The folder of the next column, if any, is selected here once listed.
            if (col.index + 1 < columnsModel.count)
                col.model.expect(columnsModel.get(col.index + 1).url, false);
        }

        Connections {
            target: col.model
            ignoreUnknownSignals: true
            function onCurrentRowChanged(): void {
                if (col.model.currentRow >= 0)
                    lv.positionViewAtIndex(col.model.currentRow, ListView.Contain);
            }
            function onRevealRequested(row: int, rename: bool): void {
                lv.positionViewAtIndex(row, ListView.Contain);
                if (rename)
                    root.tab.startRename(col.model, row);
            }
        }

        Rectangle {
            anchors.right: parent.right
            width: Tokens.appsBorderWidth
            height: parent.height
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        DropArea {
            anchors.fill: parent
            keys: ["text/uri-list"]
            onDropped: drop => {
                if (drop.hasUrls) {
                    root.tab.dropUrls(drop.urls, col.url, col.model);
                    drop.accept(Qt.CopyAction);
                }
            }
        }

        MouseArea {
            id: colBackground
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // The band keeps the pointer: the strip of columns would take a sideways drag for its own scroll.
            preventStealing: true
            onPressed: mouse => {
                root.activeColumn = col.index;
                lv.forceActiveFocus();
                if (mouse.button === Qt.RightButton) {
                    const p = mapToItem(null, mouse.x, mouse.y);
                    root.tab.contextMenu(col.model, -1, p.x, p.y, false);
                    return;
                }
                col.bandOrigin = colBackground.mapToItem(lv.contentItem, mouse.x, mouse.y);
                col.bandEnd = col.bandOrigin;
                col.bandBase = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? col.model.selectedUrls() : [];
                col.banding = false;
            }
            onPositionChanged: mouse => {
                if (!pressed || mouse.buttons !== Qt.LeftButton)
                    return;
                const p = colBackground.mapToItem(lv.contentItem, mouse.x, mouse.y);
                if (!col.banding && Math.abs(p.x - col.bandOrigin.x) + Math.abs(p.y - col.bandOrigin.y) < Tokens.filesDragThreshold)
                    return;
                col.banding = true;
                col.bandEnd = p;
                const rows = Nav.cellsInRect(0, col.bandOrigin.y, 0, p.y, 1, Tokens.filesColumnRowHeight, 1, lv.count);
                const urls = col.bandBase.slice();
                for (let i = 0; i < rows.length; i++)
                    urls.push(col.model.urlAt(rows[i]));
                col.model.selectUrls(urls);
                if (mouse.y > lv.y + lv.height)
                    lv.contentY = Math.min(lv.contentY + Tokens.spacingSm, Math.max(lv.originY, lv.contentHeight - lv.height + lv.originY));
                else if (mouse.y < lv.y)
                    lv.contentY = Math.max(lv.originY, lv.contentY - Tokens.spacingSm);
            }
            onReleased: {
                // A band changed the selection: the columns after this one follow it; a plain click keeps them.
                if (col.banding)
                    root.userSelected(col.index);
                col.banding = false;
            }
            onCanceled: col.banding = false
        }

        ListView {
            id: lv
            anchors.fill: parent
            anchors.rightMargin: Tokens.appsBorderWidth
            anchors.topMargin: Tokens.spacingXs
            model: col.model
            clip: true
            focus: col.active
            activeFocusOnTab: col.active
            keyNavigationEnabled: false
            acceptedButtons: Qt.NoButton
            boundsBehavior: Flickable.StopAtBounds
            onActiveFocusChanged: if (activeFocus) root.activeColumn = col.index
            Accessible.role: Accessible.List
            Accessible.name: col.model ? col.model.title : ""

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Right && !(event.modifiers & Qt.ControlModifier)) {
                    root.enterNext(col.index);
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Left && !(event.modifiers & Qt.ControlModifier)) {
                    root.leavePrevious(col.index);
                    event.accepted = true;
                    return;
                }
                const before = col.model.currentRow;
                root.tab.handleViewKey(event, col.model, key => Nav.listMove(col.model.currentRow, key, lv.count, Math.max(1, Math.floor(lv.height / Tokens.filesColumnRowHeight))));
                if (col.model.currentRow !== before)
                    root.userSelected(col.index);
            }

            delegate: FocusScope {
                id: entry

                required property int index
                required property string name
                required property url url
                required property string iconName
                required property string emblem
                required property bool selected
                required property bool isDir
                required property string folderColor
                required property string folderGlyph
                required property bool hidden
                // A file the Open or Save panel cannot take (FolderModel.chooser).
                required property bool dimmed
                required property var tagColors

                readonly property bool renaming: root.tab.isRenaming(col.model, entry.url)
                readonly property bool emphasized: entry.selected && col.active && lv.activeFocus

                width: lv.width
                height: Tokens.filesColumnRowHeight
                opacity: entry.dimmed ? Tokens.materialDisabledOpacity : entry.hidden ? Tokens.filesHiddenOpacity : 1
                Accessible.role: Accessible.ListItem
                Accessible.name: DisplayName.text(entry.name)
                Accessible.selectable: true
                Accessible.selected: entry.selected

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: Tokens.spacingXs
                    anchors.rightMargin: Tokens.spacingXs
                    radius: Tokens.radiusControl
                    visible: entry.selected || entryDrop.containsDrag
                    color: entry.emphasized ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)
                    border.width: entryDrop.containsDrag ? Tokens.filesDropBorder : 0
                    border.color: Appearance.colors.accent
                }

                FileIcon {
                    id: entryIcon
                    x: Tokens.spacingSm + Tokens.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.filesListIconSize
                    overAccent: entry.emphasized
                    iconName: entry.iconName
                    isDir: entry.isDir
                    folderColor: entry.folderColor
                    folderGlyph: entry.folderGlyph
                    emblem: entry.emblem
                }

                Text {
                    textFormat: Text.PlainText
                    visible: !entry.renaming
                    anchors.left: entryIcon.right
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: entryDots.visible ? entryDots.left : chevron.left
                    anchors.rightMargin: Tokens.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    text: DisplayName.text(entry.name)
                    elide: Text.ElideMiddle
                    color: entry.emphasized ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                Loader {
                    active: entry.renaming
                    anchors.left: entryIcon.right
                    anchors.leftMargin: Tokens.spacingXs
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height - Tokens.spacingXs / 2
                    sourceComponent: RenameField {
                        originalName: entry.name
                        baseLength: root.tab.app.baseNameLength(entry.name, entry.isDir)
                        onCommitted: name => root.tab.commitRename(name)
                        onCanceled: root.tab.cancelRename()
                    }
                }

                // Colour tags at the end of the row, before the folder chevron.
                TagDots {
                    id: entryDots
                    visible: !entry.renaming && entryDots.shown.length > 0
                    colors: entry.tagColors
                    anchors.right: chevron.left
                    anchors.rightMargin: Tokens.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    ringColor: entry.emphasized ? Appearance.colors.selection : Appearance.windowFill
                }

                Icon {
                    id: chevron
                    visible: entry.isDir
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron-right"
                    size: Tokens.filesChevronSize
                    color: entry.emphasized ? Appearance.colors.selectionText : Appearance.colors.textSecondary
                }

                DropArea {
                    id: entryDrop
                    anchors.fill: parent
                    enabled: entry.isDir && !entry.selected
                    keys: ["text/uri-list"]
                    onEntered: root.tab.springHover(entry.url)
                    onExited: root.tab.springLeave(entry.url)
                    onDropped: event => {
                        if (event.hasUrls) {
                            root.tab.dropUrls(event.urls, entry.url, col.model);
                            event.accept(Qt.CopyAction);
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !entry.renaming
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: event => {
                        root.activeColumn = col.index;
                        lv.forceActiveFocus();
                        if (event.button === Qt.RightButton) {
                            const p = mapToItem(null, event.x, event.y);
                            root.tab.contextMenu(col.model, entry.index, p.x, p.y, false);
                            return;
                        }
                        col.model.select(entry.index, event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier));
                        root.userSelected(col.index);
                    }
                    onDoubleClicked: event => {
                        if (event.button === Qt.LeftButton && Nav.columnDoubleClickOpens(entry.isDir, (event.modifiers & Qt.ControlModifier) !== 0))
                            root.tab.activate(entry.index, col.model, event.modifiers);
                    }
                }
            }
        }

        Rectangle {
            parent: lv.contentItem
            z: 1
            visible: col.banding
            x: Math.min(col.bandOrigin.x, col.bandEnd.x)
            y: Math.min(col.bandOrigin.y, col.bandEnd.y)
            width: Math.abs(col.bandEnd.x - col.bandOrigin.x)
            height: Math.abs(col.bandEnd.y - col.bandOrigin.y)
            color: Appearance.withAlpha(Appearance.colors.accent, Tokens.filesRubberBandOpacity)
            border.width: Tokens.appsBorderWidth
            border.color: Appearance.colors.accent
        }

        ScrollBar {
            flickable: lv
            anchors.right: parent.right
            anchors.rightMargin: Tokens.appsBorderWidth
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: Tokens.spacingXs
        }
    }
}
