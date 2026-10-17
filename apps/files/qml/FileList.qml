pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Nav.js" as Nav

// List view: Name, Date Modified, Size and Kind columns; clicking a header sorts by it (again: reverses).
FocusScope {
    id: root

    required property var tab
    required property var model

    readonly property real nameWidth: Math.max(Tokens.filesColumnWidth, list.width - Tokens.filesListDateWidth - Tokens.filesListSizeWidth - Tokens.filesListKindWidth)
    readonly property int pageRows: Math.max(1, Math.floor(list.height / Tokens.filesListRowHeight))

    Accessible.role: Accessible.Table
    Accessible.name: qsTr("Files")

    function applyPrefs(): void {
    }

    function focusView(): void {
        list.forceActiveFocus();
    }

    function rowPosition(model: var, row: int): point {
        if (row < 0)
            return root.mapToItem(null, Tokens.spacingLg, header.height + Tokens.spacingLg);
        return list.mapToItem(null, Tokens.spacingLg * 2, (row + 1) * Tokens.filesListRowHeight - list.contentY + list.originY);
    }

    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onCurrentRowChanged(): void {
            if (root.model.currentRow >= 0)
                list.positionViewAtIndex(root.model.currentRow, ListView.Contain);
        }
        function onRevealRequested(row: int, rename: bool): void {
            list.positionViewAtIndex(row, ListView.Contain);
            if (rename)
                root.tab.startRename(root.model, row);
        }
    }

    Item {
        id: dragProxy
        visible: false
        width: Tokens.filesListIconSize
        height: Tokens.filesListIconSize
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.MoveAction
        Drag.onDragFinished: dragProxy.Drag.active = false
    }

    // Header ------------------------------------------------------------------------------------
    Row {
        id: header
        x: list.x
        width: list.width
        height: Tokens.filesListHeaderHeight

        Repeater {
            model: [
                {key: 0, title: qsTr("Name")},
                {key: 2, title: qsTr("Date Modified")},
                {key: 3, title: qsTr("Size")},
                {key: 1, title: qsTr("Kind")}
            ]

            delegate: Item {
                id: column
                required property var modelData
                readonly property bool active: root.tab.app.sortKey === column.modelData.key

                width: column.modelData.key === 0 ? root.nameWidth : column.modelData.key === 2 ? Tokens.filesListDateWidth : column.modelData.key === 3 ? Tokens.filesListSizeWidth : Tokens.filesListKindWidth
                height: header.height
                activeFocusOnTab: false
                Accessible.role: Accessible.ColumnHeader
                Accessible.name: column.modelData.title
                Accessible.onPressAction: root.tab.sortBy(column.modelData.key, true)

                Rectangle {
                    anchors.fill: parent
                    color: headerMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
                }

                Rectangle {
                    visible: column.modelData.key !== 0
                    width: Tokens.appsBorderWidth
                    height: parent.height - Tokens.spacingSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
                }

                Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.spacingSm
                    anchors.right: arrow.left
                    anchors.verticalCenter: parent.verticalCenter
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
                    size: Tokens.filesChevronSize
                    color: Appearance.colors.textSecondary
                    rotation: root.tab.app.sortDescending ? 0 : 180
                }

                MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.tab.sortBy(column.modelData.key, true)
                }
            }
        }
    }

    Rectangle {
        anchors.top: header.bottom
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
    }

    // Background --------------------------------------------------------------------------------
    DropArea {
        anchors.fill: list
        keys: ["text/uri-list"]
        onDropped: drop => {
            if (drop.hasUrls) {
                root.tab.dropUrls(drop.urls, root.model.url, root.model);
                drop.accept(Qt.CopyAction);
            }
        }
    }

    MouseArea {
        anchors.fill: list
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: mouse => {
            list.forceActiveFocus();
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(null, mouse.x, mouse.y);
                root.tab.contextMenu(root.model, -1, p.x, p.y, false);
            } else {
                root.model.clearSelection();
            }
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: Tokens.appsBorderWidth
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: scrollBar.width
        anchors.bottom: parent.bottom
        model: root.model
        clip: true
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: root.model ? root.model.currentRow : -1
        cacheBuffer: Tokens.filesListRowHeight * 20
        Accessible.role: Accessible.Table
        Accessible.name: qsTr("Files")

        Keys.onPressed: event => root.tab.handleViewKey(event, root.model, key => Nav.listMove(root.model.currentRow, key, list.count, root.pageRows))

        delegate: FocusScope {
            id: row

            required property int index
            required property string name
            required property url url
            required property string iconName
            required property string emblem
            required property string modifiedText
            required property string sizeText
            required property string kind
            required property bool selected
            required property bool isDir
            required property bool hidden

            readonly property bool renaming: root.tab.isRenaming(root.model, row.url)
            readonly property bool emphasized: row.selected && list.activeFocus
            readonly property color foreground: row.emphasized ? Appearance.colors.accentText : Appearance.colors.text
            readonly property color secondary: row.emphasized ? Appearance.colors.accentText : Appearance.colors.textSecondary

            width: list.width
            height: Tokens.filesListRowHeight
            opacity: row.hidden ? Tokens.filesHiddenOpacity : 1
            Accessible.role: Accessible.Row
            Accessible.name: row.name
            Accessible.description: [row.modifiedText, row.sizeText, row.kind].join(", ")
            Accessible.selectable: true
            Accessible.selected: row.selected
            Accessible.onPressAction: root.tab.activate(row.index, root.model)

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Tokens.spacingXs
                anchors.rightMargin: Tokens.spacingXs
                radius: Tokens.radiusControl
                color: row.selected ? (row.emphasized ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2))
                     : row.index % 2 === 1 ? Appearance.withAlpha(Appearance.colors.fill, Tokens.filesStripeOpacity) : "transparent"
                border.width: rowDrop.containsDrag ? Tokens.filesDropBorder : 0
                border.color: Appearance.colors.accent
            }

            FileIcon {
                id: icon
                x: Tokens.spacingSm + Tokens.spacingXs
                anchors.verticalCenter: parent.verticalCenter
                size: Tokens.filesListIconSize
                iconName: row.iconName
                emblem: row.emblem
            }

            Text {
                textFormat: Text.PlainText
                visible: !row.renaming
                anchors.left: icon.right
                anchors.leftMargin: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                width: root.nameWidth - icon.x - icon.width - 2 * Tokens.spacingSm
                text: row.name
                elide: Text.ElideMiddle
                color: row.foreground
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Loader {
                active: row.renaming
                anchors.left: icon.right
                anchors.leftMargin: Tokens.spacingXs
                anchors.verticalCenter: parent.verticalCenter
                width: root.nameWidth - icon.x - icon.width - Tokens.spacingSm
                height: parent.height - Tokens.spacingXs / 2
                sourceComponent: RenameField {
                    originalName: row.name
                    baseLength: root.tab.app.baseNameLength(row.name, row.isDir)
                    onCommitted: name => root.tab.commitRename(name)
                    onCanceled: root.tab.cancelRename()
                }
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.spacingSm
                width: Tokens.filesListDateWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                text: row.modifiedText
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.filesListDateWidth + Tokens.spacingSm
                width: Tokens.filesListSizeWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: row.sizeText
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            Text {
                textFormat: Text.PlainText
                x: root.nameWidth + Tokens.filesListDateWidth + Tokens.filesListSizeWidth + Tokens.spacingSm
                width: Tokens.filesListKindWidth - 2 * Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                text: row.kind
                elide: Text.ElideRight
                color: row.secondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            DropArea {
                id: rowDrop
                anchors.fill: parent
                enabled: row.isDir && !row.selected
                keys: ["text/uri-list"]
                onDropped: event => {
                    if (event.hasUrls) {
                        root.tab.dropUrls(event.urls, row.url, root.model);
                        event.accept(Qt.CopyAction);
                    }
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                enabled: !row.renaming
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: dragProxy
                drag.threshold: Tokens.filesDragThreshold
                property bool collapseOnRelease: false

                onPressed: event => {
                    list.forceActiveFocus();
                    if (event.button === Qt.RightButton) {
                        const p = mouse.mapToItem(null, event.x, event.y);
                        root.tab.contextMenu(root.model, row.index, p.x, p.y, false);
                        return;
                    }
                    const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier);
                    collapseOnRelease = row.selected && mods === 0;
                    if (!row.selected || mods !== 0)
                        root.model.select(row.index, mods);
                }
                onReleased: {
                    if (collapseOnRelease && !drag.active)
                        root.model.select(row.index, 0);
                    collapseOnRelease = false;
                }
                onDoubleClicked: event => {
                    if (event.button === Qt.LeftButton)
                        root.tab.activate(row.index, root.model);
                }
                drag.onActiveChanged: {
                    if (drag.active) {
                        collapseOnRelease = false;
                        dragProxy.Drag.mimeData = {"text/uri-list": root.tab.app.uriList(root.model.selectedUrls())};
                        dragProxy.Drag.imageSource = "image://icon/" + row.iconName;
                        dragProxy.Drag.active = true;
                    }
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

    Text {
        textFormat: Text.PlainText
        anchors.centerIn: list
        visible: list.count === 0 && root.model && !root.model.loading
        text: root.tab.searchText !== "" ? qsTr("No Results") : root.model && root.model.error !== "" ? root.model.error : qsTr("This folder is empty.")
        width: list.width - 2 * Tokens.spacingLg
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }
}
