pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// Sidebar: Favorites (standard folders that exist), Locations (system volume, Solid volumes with
// eject, Network when a KIO network worker is installed, Trash) and Tags (the tags in use: a click lists the items
// with that tag in the shown folder and below, a drop tags the dropped items, the context menu removes the tag from
// the sidebar). Items accept drops.
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

    // A place or a tag row (a tag lists its items in the shown folder and below).
    function openEntry(entry: PlaceRow): void {
        if (entry.kind === "tag") {
            if (root.tab)
                root.tab.showTag(entry.tag);
        } else {
            root.openRow(entry.index, entry.url, entry.mounted);
        }
    }

    // The Tags section's context menu (on a tag or on the header): Remove from Sidebar (a tag only) and, while some tags
    // are removed, Show Hidden Tag > the tags to list again (the way back; the files keep their tags either way).
    function openTagMenu(tag: string, x: real, y: real): void {
        if (!root.tab)
            return;
        const items = [];
        if (tag !== "")
            items.push({id: "forget", text: qsTr("Remove from Sidebar")});
        const hidden = root.app.hiddenTags;
        if (hidden.length > 0) {
            if (items.length > 0)
                items.push({separator: true});
            items.push({id: "showHidden", text: qsTr("Show Hidden Tag"), submenu: hidden.map(t => ({id: "show:" + t, text: root.app.tagName(t)}))});
        }
        if (items.length === 0)
            return;
        root.tab.win.menuLayer.open(items, x, y, id => {
            if (id === "forget")
                root.app.forgetTag(tag);
            else if (id.startsWith("show:"))
                root.app.showTag(id.substring(5));
        }, list, false);
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
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
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
                    root.openEntry(item);
                event.accepted = true;
            }
        }

        section.property: "section"
        section.delegate: Item {
            id: header
            required property string section
            width: ListView.view.width
            height: Tokens.filesSidebarHeaderHeight
            // The Tags header has a menu (Show Hidden Tag) that a right click opens: the same menu through an accessible
            // action (A11Y-09). The other headers are plain headings.
            Accessible.role: header.section === "tags" ? Accessible.Button : Accessible.Heading
            Accessible.name: header.section === "favorites" ? qsTr("Favorites") : header.section === "tags" ? qsTr("Tags menu") : qsTr("Locations")
            Accessible.onPressAction: {
                if (header.section === "tags") {
                    const p = header.mapToItem(null, header.width / 2, header.height / 2);
                    root.openTagMenu("", p.x, p.y);
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.RightButton
                enabled: header.section === "tags"
                onClicked: event => {
                    const p = mapToItem(null, event.x, event.y);
                    root.openTagMenu("", p.x, p.y);
                }
            }

            Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Tokens.spacingSm
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Tokens.spacingXs
                text: header.section === "favorites" ? qsTr("Favorites") : header.section === "tags" ? qsTr("Tags") : qsTr("Locations")
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
        required property string tag
        required property int tagColor

        readonly property bool current: entry.index === root.currentRow
        readonly property bool keyed: list.activeFocus && entry.index === root.keyRow
        readonly property bool isTag: entry.kind === "tag"

        width: ListView.view.width
        height: Tokens.filesSidebarItemHeight
        Accessible.role: Accessible.ListItem
        Accessible.name: entry.name
        Accessible.selectable: true
        Accessible.selected: entry.current
        Accessible.onPressAction: root.openEntry(entry)

        Rectangle {
            anchors.fill: parent
            radius: Tokens.radiusControl
            color: entry.current ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 1.5)
                 : mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
            border.width: entry.keyed || drop.containsDrag ? Tokens.controlFocusOutline : 0
            border.color: Appearance.focusRingColor
        }

        ThemeIcon {
            id: glyph
            visible: !entry.isTag
            x: Tokens.spacingSm
            anchors.verticalCenter: parent.verticalCenter
            name: entry.iconName
            size: Tokens.filesSidebarIconSize
            color: Appearance.colors.accent
        }

        // A tag: its colour dot, or a hollow ring for a tag without a colour (from another application).
        Rectangle {
            visible: entry.isTag
            anchors.centerIn: glyph
            width: Tokens.filesTagDotSize + Tokens.spacingXs
            height: width
            radius: width / 2
            color: entry.tagColor >= 0 ? TagColors.at(Tokens, entry.tagColor) : "transparent"
            border.width: entry.tagColor >= 0 ? 0 : Tokens.appsBorderWidth * 2
            border.color: Appearance.colors.textSecondary
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
            accessibleName: qsTr("Eject %1").arg(entry.name)
            onClicked: root.places.eject(entry.index)

            ThemeIcon {
                anchors.centerIn: parent
                name: "media-eject-symbolic"
                size: Tokens.filesToolbarIconSize
                tint: true
                color: Appearance.colors.text
            }
        }

        DropArea {
            id: drop
            anchors.fill: parent
            enabled: entry.mounted && entry.kind !== "network"
            keys: ["text/uri-list"]
            onDropped: event => {
                if (!event.hasUrls || !root.tab)
                    return;
                // A drop on a tag tags the items (local files only; FilesApp reports the others).
                if (entry.isTag)
                    root.app.addTag(event.urls, entry.tag);
                else
                    root.tab.dropUrls(event.urls, entry.url, null);
                event.accept(Qt.CopyAction);
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: eject.visible ? eject.width : 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: event => {
                root.keyRow = entry.index;
                if (event.button === Qt.RightButton) {
                    // Tags only: the sidebar lists the tags in use; removing one leaves the files' tags alone.
                    if (entry.isTag) {
                        const p = mouse.mapToItem(null, event.x, event.y);
                        root.openTagMenu(entry.tag, p.x, p.y);
                    }
                    return;
                }
                root.openEntry(entry);
            }
        }
    }
}
