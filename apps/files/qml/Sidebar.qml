pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Sidebar: Favorites (standard folders that exist) and Locations (system volume, Solid volumes with
// eject, Network when a KIO network worker is installed, Trash). Items accept drops.
FocusScope {
    id: root

    required property var app
    // The current BrowserTab.
    property var tab: null

    readonly property var places: root.app.places
    readonly property int currentRow: root.tab ? root.places.rowForUrl(root.tab.url) : -1
    property int keyRow: -1

    Accessible.role: Accessible.List
    Accessible.name: qsTr("Sidebar")

    function openRow(row: int, url: url, mounted: bool): void {
        if (!root.tab)
            return;
        if (!mounted)
            root.places.mount(row);
        else
            root.tab.navigate(url, true);
    }

    Connections {
        target: root.places
        function onMounted(url: url): void {
            if (root.tab)
                root.tab.navigate(url, true);
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.filesStripeOpacity)
    }

    Rectangle {
        anchors.right: parent.right
        width: Tokens.appsBorderWidth
        height: parent.height
        color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
    }

    ListView {
        id: list
        anchors.fill: parent
        anchors.topMargin: Tokens.spacingSm
        anchors.leftMargin: Tokens.spacingSm
        anchors.rightMargin: Tokens.spacingSm + Tokens.appsBorderWidth
        model: root.places
        clip: true
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false
        acceptedButtons: Qt.NoButton
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Sidebar")

        onActiveFocusChanged: if (activeFocus && root.keyRow < 0) root.keyRow = Math.max(0, root.currentRow)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Down) {
                root.keyRow = Math.min(list.count - 1, root.keyRow + 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Up) {
                root.keyRow = Math.max(0, root.keyRow - 1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                const item = list.itemAtIndex(root.keyRow) as PlaceRow;
                if (item)
                    root.openRow(item.index, item.url, item.mounted);
                event.accepted = true;
            }
        }

        section.property: "section"
        section.delegate: Item {
            id: header
            required property string section
            width: ListView.view.width
            height: Tokens.filesSidebarHeaderHeight

            Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Tokens.spacingSm
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Tokens.spacingXs
                text: header.section === "favorites" ? qsTr("Favorites") : qsTr("Locations")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
        }

        delegate: PlaceRow {}
    }

    component PlaceRow: Item {
        id: entry

        required property int index
        required property string name
        required property url url
        required property string iconName
        required property string kind
        required property bool mounted
        required property bool ejectable
        required property bool busy

        readonly property bool current: entry.index === root.currentRow
        readonly property bool keyed: list.activeFocus && entry.index === root.keyRow

        width: ListView.view.width
        height: Tokens.filesSidebarItemHeight
        Accessible.role: Accessible.ListItem
        Accessible.name: entry.name
        Accessible.selectable: true
        Accessible.selected: entry.current
        Accessible.onPressAction: root.openRow(entry.index, entry.url, entry.mounted)

        Rectangle {
            anchors.fill: parent
            radius: Tokens.radiusControl
            color: entry.current ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 1.5)
                 : mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
            border.width: entry.keyed || drop.containsDrag ? Tokens.controlFocusRing : 0
            border.color: Appearance.colors.accent
        }

        ThemeIcon {
            id: glyph
            x: Tokens.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            name: entry.iconName
            size: Tokens.filesSidebarIconSize
            color: Appearance.colors.accent
        }

        Text {
            textFormat: Text.PlainText
            anchors.left: glyph.right
            anchors.leftMargin: Tokens.spacingSm
            anchors.right: eject.visible ? eject.left : parent.right
            anchors.rightMargin: Tokens.spacingXs
            anchors.verticalCenter: parent.verticalCenter
            text: entry.name
            elide: Text.ElideRight
            color: entry.mounted ? Appearance.colors.text : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        ToolButton {
            id: eject
            visible: entry.ejectable
            enabled: !entry.busy
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.filesSidebarItemHeight
            height: Tokens.filesSidebarItemHeight
            themeIconName: "media-eject-symbolic"
            accessibleName: qsTr("Eject %1").arg(entry.name)
            onClicked: root.places.eject(entry.index)
        }

        DropArea {
            id: drop
            anchors.fill: parent
            enabled: entry.mounted && entry.kind !== "network"
            keys: ["text/uri-list"]
            onDropped: event => {
                if (event.hasUrls && root.tab) {
                    root.tab.dropUrls(event.urls, entry.url, null);
                    event.accept(Qt.CopyAction);
                }
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: eject.visible ? eject.width : 0
            hoverEnabled: true
            onClicked: {
                root.keyRow = entry.index;
                root.openRow(entry.index, entry.url, entry.mounted);
            }
        }
    }
}
