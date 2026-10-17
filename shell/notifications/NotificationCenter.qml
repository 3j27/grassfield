pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// Notification Center (N7): full-height panel at the right edge, opened from the clock or by
// IPC. Grouped by app, newest first; Clear per group and Clear All; Esc or a click outside
// closes. Widgets are not part of M2 (no empty placeholder region).
//
// The window exists per screen but its content (a Loader) only while the Center is open on that
// screen, so a closed Center costs nothing. Rows come from the keyed Notifications.centerModel
// (already ordered by group; ListView sections draw the headers), so new notifications never rebuild the list.
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
                // App names whose group is expanded ("Show All").
                property var expanded: ({})

                x: host.width - width - margin + (host.shown ? 0 : width)
                y: Tokens.menubarHeight + margin
                width: Tokens.notificationCenterWidth
                height: host.height - y - margin
                Accessible.role: Accessible.Window
                Accessible.name: qsTr("Notification Center")
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

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: Notifications.count === 0
                    text: qsTr("No Notifications")
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuWeight
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
                    // Rows near the viewport stay alive so Tab can reach them.
                    cacheBuffer: Tokens.notificationCenterCache
                    // One section per app: the header carries the app name, the count and Clear.
                    section.property: "appName"
                    section.criteria: ViewSection.FullString
                    section.delegate: Item {
                        id: head

                        required property string section
                        readonly property bool first: Notifications.firstGroupApp() === section
                        readonly property int groupCount: Notifications.groupSize(section)

                        width: list.width
                        height: clearGroup.implicitHeight + Tokens.spacingSm + (first ? 0 : Tokens.spacingLg)

                        Row {
                            y: head.first ? 0 : Tokens.spacingLg
                            height: clearGroup.implicitHeight
                            spacing: Tokens.spacingSm

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Notifications.groupLabel(head.section)
                                textFormat: Text.PlainText
                                color: Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyBodySize
                                font.weight: Tokens.typographyMenuBoldWeight
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                textFormat: Text.PlainText
                                visible: head.groupCount > 1
                                text: String(head.groupCount)
                                color: Appearance.colors.textSecondary
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyBodySize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        Button {
                            id: clearGroup
                            y: head.first ? 0 : Tokens.spacingLg
                            anchors.right: parent.right
                            text: qsTr("Clear")
                            onClicked: Notifications.clearApp(head.section)
                        }
                    }

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

                        // Position in the app group and group size, from Notifications' O(1) bookkeeping
                        // (no per-row model roles: an insert would have to renumber the whole group).
                        readonly property int rank: Notifications.rankOf(key, appName)
                        readonly property int groupCount: Notifications.groupSize(appName)
                        readonly property bool expanded: panel.expanded[appName] === true
                        readonly property bool rowShown: rank < Tokens.notificationCenterGroupCollapsed || expanded
                        // The last visible row of a long group carries the Show All / Show Less button.
                        readonly property bool carriesToggle: groupCount > Tokens.notificationCenterGroupCollapsed
                            && rank === (expanded ? groupCount - 1 : Tokens.notificationCenterGroupCollapsed - 1)

                        width: list.width
                        height: rowShown ? implicitHeight : 0
                        visible: rowShown
                        spacing: Tokens.spacingSm

                        Item {
                            id: row

                            readonly property bool hovered: rowHover.hovered
                            readonly property bool live: item.nid >= 0

                            width: item.width
                            height: item.rowShown ? rowLoader.height : 0
                            visible: item.rowShown
                            activeFocusOnTab: item.rowShown
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

                            // The row (and its action buttons) exists only while it is shown.
                            Loader {
                                id: rowLoader
                                width: parent.width
                                active: item.rowShown
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
                                visible: item.rowShown
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
                            visible: item.carriesToggle
                            width: parent.width
                            height: visible ? toggle.implicitHeight : 0

                            Button {
                                id: toggle
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: item.expanded ? qsTr("Show Less") : qsTr("Show All (%1)").arg(item.groupCount)
                                onClicked: {
                                    const next = Object.assign({}, panel.expanded);
                                    next[item.appName] = !item.expanded;
                                    panel.expanded = next;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
