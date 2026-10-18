pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.widgets

// Notification Center (N7): full-height panel at the right edge, opened from the clock or by
// IPC. Grouped by app, newest first; Clear per group and Clear All; Esc or a click outside
// closes. Below the notifications (scrolling with them) sits the widgets area: tiles of the
// widgets placed there, and Edit Widgets (gallery overlay, docs/specs/widgets.md).
//
// The window exists per screen but its content (a Loader) only while the Center is open on that
// screen, so a closed Center costs nothing. Rows come from the keyed Notifications.centerModel
// (displayed rows only, ordered by group; the first row of a group draws its header), so new notifications never rebuild the list.
// Keyboard: Tab moves between rows and buttons, Return opens the row's default action, Delete or
// Backspace clears the row.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool open: Notifications.centerOpen && Notifications.centerScreen === modelData.name

        screen: modelData
        visible: open
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-notification-center"
        // Everything except the menu bar strip receives input (the clock toggles the panel).
        // qmllint disable missing-type
        mask: Region {
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open && content.item ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: content.item ? (content.item as CenterContent).panel : null
            radius: Tokens.radiusPanel
        }

        // A popup (menus, Control Center) takes over.
        Connections {
            target: Popups

            function onKindChanged(): void {
                if (Popups.active)
                    Notifications.closeCenter();
            }
        }

        Loader {
            id: content
            anchors.fill: parent
            active: win.open
            sourceComponent: CenterContent {}
        }

        component CenterContent: Item {
            id: host

            readonly property Item panel: panel
            // Slides in from the right edge after creation.
            property bool shown: false

            Component.onCompleted: {
                shown = true;
                panel.forceActiveFocus();
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: Notifications.closeCenter()
            }

            FocusScope {
                id: panel

                readonly property real margin: Tokens.spacingSm

                // Widgets: the gallery overlay and the context menu of a placed widget.
                property bool galleryOpen: false
                property var menuEntry: null
                property real menuX: 0
                property real menuY: 0
                property Item menuReturn: null

                function openWidgetMenu(tile: Item, x: real, y: real, entry: var): void {
                    const p = tile.mapToItem(panel, x, y);
                    menuX = p.x;
                    menuY = p.y;
                    menuReturn = tile;
                    menuEntry = entry;
                }

                function closeWidgetMenu(): void {
                    menuEntry = null;
                    if (menuReturn)
                        menuReturn.forceActiveFocus();
                    else
                        panel.forceActiveFocus();
                }

                function applyWidgetMenu(action: string): void {
                    const entry = menuEntry;
                    menuEntry = null;
                    panel.forceActiveFocus();
                    if (!entry)
                        return;
                    if (action === "remove")
                        Widgets.remove(entry.uid);
                    else if (action.startsWith("size:"))
                        Widgets.setSize(entry.uid, action.substring(5));
                }

                x: host.width - width - margin + (host.shown ? 0 : width)
                y: Tokens.menubarHeight + margin
                width: Tokens.notificationCenterWidth
                height: host.height - y - margin
                Accessible.role: Accessible.Window
                Accessible.name: qsTr("Notifications")
                Keys.onEscapePressed: Notifications.closeCenter()

                Behavior on x {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionNormal)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curve
                    }
                }

                // Swallows clicks on the panel itself.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                Material {
                    anchors.fill: parent
                    radius: Tokens.radiusPanel
                }

                Item {
                    id: header
                    x: Tokens.spacingLg
                    y: Tokens.spacingLg
                    width: parent.width - 2 * Tokens.spacingLg
                    height: clearAll.implicitHeight

                    Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Notifications")
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyTitleSize
                        font.weight: Tokens.typographyMenuBoldWeight
                    }

                    Button {
                        id: clearAll
                        anchors.right: parent.right
                        visible: Notifications.count > 0
                        text: qsTr("Clear All")
                        onClicked: Notifications.clearAll()
                    }
                }

                ListView {
                    id: list
                    x: Tokens.spacingLg
                    y: header.y + header.height + Tokens.spacingMd
                    width: parent.width - 2 * Tokens.spacingLg
                    height: parent.height - y - Tokens.spacingLg
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: Notifications.centerModel
                    header: Item {
                        width: list.width
                        height: Notifications.count === 0 ? emptyText.implicitHeight + 2 * Tokens.spacingLg : 0
                        visible: Notifications.count === 0

                        Text {
                            id: emptyText
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: qsTr("No Notifications")
                            color: Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyTitleSize
                            font.weight: Tokens.typographyMenuWeight
                        }
                    }
                    footer: widgetsArea
                    // Rows near the viewport stay alive so Tab can reach them.
                    cacheBuffer: Tokens.notificationCenterCache
                    delegate: Column {
                        id: item

                        required property int index
                        required property string key
                        required property int nid
                        required property string appName
                        required property string appIcon
                        required property string image
                        required property string summary
                        required property string bodyHtml
                        required property real time
                        required property int urgency
                        required property string actionsJson
        // Group info carried by the rows that need it (see Notifications.syncShown).
        required property int headCount
        required property bool headFirst
        required property int toggleCount

                        readonly property bool expanded: Notifications.expandedApps[appName] === true

                        width: list.width
                        spacing: Tokens.spacingSm

                        // Group header (first row of the group). Before the row in the tab order.
                        Item {
                            id: head

                            visible: item.headCount > 0
                            width: item.width
                            height: visible ? clearGroup.implicitHeight + (item.headFirst ? 0 : Tokens.spacingLg) : 0

                            Row {
                                y: item.headFirst ? 0 : Tokens.spacingLg
                                height: clearGroup.implicitHeight
                                spacing: Tokens.spacingSm

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Notifications.groupLabel(item.appName)
                                    textFormat: Text.PlainText
                                    color: Appearance.colors.text
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    font.weight: Tokens.typographyMenuBoldWeight
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    visible: item.headCount > 1
                                    text: String(item.headCount)
                                    color: Appearance.colors.textSecondary
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    font.weight: Tokens.typographyMenuWeight
                                }
                            }

                            Button {
                                id: clearGroup
                                y: item.headFirst ? 0 : Tokens.spacingLg
                                anchors.right: parent.right
                                text: qsTr("Clear")
                                onClicked: Notifications.clearApp(item.appName)
                            }
                        }

                        Item {
                            id: row

                            readonly property bool hovered: rowHover.hovered
                            readonly property bool live: item.nid >= 0

                            width: item.width
                            height: rowLoader.height
                            activeFocusOnTab: true
                            Accessible.role: Accessible.ListItem
                            Accessible.name: item.summary !== "" ? item.summary : Notifications.groupLabel(item.appName)
                            Accessible.description: item.appName
                            Accessible.focusable: true
                            Accessible.onPressAction: row.open()

                            function open(): void {
                                if (!live)
                                    return;
                                Notifications.activateDefault(item.key);
                                Notifications.closeCenter();
                            }

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    row.open();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                                    Notifications.clear(item.key);
                                    panel.forceActiveFocus();
                                    event.accepted = true;
                                }
                            }

                            onActiveFocusChanged: {
                                if (activeFocus)
                                    list.positionViewAtIndex(item.index, ListView.Contain);
                            }

                            HoverHandler {
                                id: rowHover
                            }

                            TapHandler {
                                acceptedButtons: Qt.LeftButton
                                enabled: row.live
                                onTapped: row.open()
                            }

                            Loader {
                                id: rowLoader
                                width: parent.width
                                sourceComponent: rowBody
                            }

                            // Keyboard focus ring.
                            Rectangle {
                                anchors.fill: parent
                                radius: Tokens.radiusMenu
                                color: "transparent"
                                border.width: row.activeFocus ? Tokens.controlFocusRing : 0
                                border.color: Appearance.colors.accent
                            }

                            // Remove this entry; shown on hover or keyboard focus.
                            Item {
                                x: row.width - width - Tokens.spacingXs
                                y: Tokens.spacingXs
                                width: Tokens.notificationCloseSize
                                height: width
                                opacity: row.hovered || row.activeFocus ? 1 : 0
                                Accessible.role: Accessible.Button
                                Accessible.name: qsTr("Clear notification")
                                Accessible.onPressAction: Notifications.clear(item.key)

                                Rectangle {
                                    anchors.fill: parent
                                    radius: width / 2
                                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                                }

                                Icon {
                                    anchors.centerIn: parent
                                    size: parent.width - Tokens.notificationCloseGlyphInset
                                    name: "close-glyph"
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: parent.opacity > 0
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Notifications.clear(item.key)
                                }
                            }

                            Component {
                                id: rowBody

                                Item {
                                    implicitHeight: rowContent.implicitHeight + 2 * Tokens.spacingMd

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Tokens.radiusMenu
                                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2)
                                    }

                                    NotificationContent {
                                        id: rowContent
                                        x: Tokens.spacingMd
                                        y: Tokens.spacingMd
                                        width: parent.width - 2 * Tokens.spacingMd
                                        summary: item.summary
                                        appName: item.appName
                                        urgency: item.urgency
                                        actionsJson: item.actionsJson
                                        live: row.live
                                        trailingReserve: Tokens.notificationCloseSize + Tokens.spacingXs
                                        body: Notifications.bodyFor(item.bodyHtml)
                                        timeText: Notifications.timeFor(item.time)
                                        iconSource: Notifications.iconSource(item.image, item.appIcon)
                                        onActionTriggered: actionId => Notifications.invokeAction(item.key, actionId)
                                    }
                                }
                            }
                        }

                        Item {
                            visible: item.toggleCount > 0
                            width: parent.width
                            height: visible ? toggle.implicitHeight : 0

                            Button {
                                id: toggle
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: item.expanded ? qsTr("Show Less") : qsTr("Show All (%1)").arg(item.toggleCount)
                                onClicked: {
                                    Notifications.setExpanded(item.appName, !item.expanded);
                                }
                            }
                        }
                    }
                }

                // Widgets area: the footer of the list, so it scrolls with the notifications.
                Component {
                    id: widgetsArea

                    Column {
                        width: list.width
                        topPadding: Tokens.spacingLg
                        spacing: Tokens.spacingMd

                        Text {
                            textFormat: Text.PlainText
                            visible: Widgets.center.length > 0
                            text: qsTr("Widgets")
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyTitleSize
                            font.weight: Tokens.typographyMenuBoldWeight
                        }

                        Flow {
                            width: parent.width
                            spacing: Tokens.widgetGap

                            Repeater {
                                model: Widgets.center

                                delegate: WidgetHost {
                                    id: tile

                                    required property var modelData

                                    entry: modelData
                                    flat: true
                                    cell: (list.width - Tokens.widgetGap) / 2
                                    onMenuRequested: (x, y) => panel.openWidgetMenu(tile, x, y, modelData)
                                    onRemoveRequested: {
                                        Widgets.remove(modelData.uid);
                                        panel.forceActiveFocus();
                                    }
                                    onActiveFocusChanged: {
                                        if (!activeFocus)
                                            return;
                                        const top = tile.mapToItem(list.contentItem, 0, 0).y;
                                        if (top < list.contentY)
                                            list.contentY = top;
                                        else if (top + tile.height > list.contentY + list.height)
                                            list.contentY = top + tile.height - list.height;
                                    }
                                }
                            }
                        }

                        Item {
                            width: parent.width
                            height: editWidgets.implicitHeight + Tokens.spacingSm

                            Button {
                                id: editWidgets
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: qsTr("Edit Widgets")
                                onClicked: panel.galleryOpen = true
                            }
                        }
                    }
                }

                // Widget context menu (sizes, Remove Widget) at the click or the focused tile.
                MouseArea {
                    anchors.fill: parent
                    visible: panel.menuEntry !== null
                    acceptedButtons: Qt.AllButtons
                    onPressed: panel.closeWidgetMenu()
                }

                Loader {
                    id: widgetMenu
                    active: panel.menuEntry !== null
                    x: Math.max(Tokens.spacingSm, Math.min(panel.menuX, panel.width - width - Tokens.spacingSm))
                    y: Math.max(Tokens.spacingSm, Math.min(panel.menuY, panel.height - height - Tokens.spacingSm))
                    sourceComponent: WidgetMenu {
                        entry: panel.menuEntry
                        onChoose: action => panel.applyWidgetMenu(action)
                        onCloseRequested: panel.closeWidgetMenu()
                        Component.onCompleted: forceActiveFocus()
                    }
                }

                Loader {
                    id: gallery
                    anchors.fill: parent
                    active: panel.galleryOpen
                    sourceComponent: WidgetGallery {
                        screenName: win.modelData.name
                        onClosed: {
                            panel.galleryOpen = false;
                            panel.forceActiveFocus();
                        }
                        Component.onCompleted: forceActiveFocus()
                    }
                }
            }
        }
    }
}
