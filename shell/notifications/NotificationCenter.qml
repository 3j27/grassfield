pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// Notification Center (N7): full-height panel at the right edge, opened from the clock or by
// IPC. Grouped by app, newest first; Clear per group and Clear All; Esc or a click outside
// closes. Widgets are not part of M2 (no empty placeholder region).
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
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: panel
            radius: Tokens.radiusPanel
        }

        onOpenChanged: {
            if (open)
                panel.forceActiveFocus();
        }

        // A popup (menus, Control Center) takes over.
        Connections {
            target: Popups

            function onKindChanged(): void {
                if (Popups.active)
                    Notifications.closeCenter();
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: Notifications.closeCenter()
        }

        FocusScope {
            id: panel

            readonly property real margin: Tokens.spacingSm

            x: win.width - width - margin + (win.open ? 0 : width)
            y: Tokens.menubarHeight + margin
            width: Tokens.notificationCenterWidth
            height: win.height - y - margin
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

            Flickable {
                id: scroller
                x: Tokens.spacingLg
                y: header.y + header.height + Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingLg
                height: parent.height - y - Tokens.spacingLg
                contentWidth: width
                contentHeight: groupsColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: groupsColumn
                    width: scroller.width
                    spacing: Tokens.spacingLg

                    Repeater {
                        model: Notifications.groups

                        delegate: Column {
                            id: groupItem

                            required property var modelData
                            property bool expanded: false
                            readonly property var shown: expanded ? modelData.items : modelData.items.slice(0, Tokens.notificationCenterGroupCollapsed)

                            width: groupsColumn.width
                            spacing: Tokens.spacingSm

                            Item {
                                width: parent.width
                                height: clearGroup.implicitHeight

                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Tokens.spacingSm

                                    Text {
                                        text: groupItem.modelData.appName
                                        textFormat: Text.PlainText
                                        color: Appearance.colors.text
                                        font.family: Appearance.fontFamily
                                        font.pixelSize: Tokens.typographyBodySize
                                        font.weight: Tokens.typographyMenuBoldWeight
                                    }

                                    Text {
                                        textFormat: Text.PlainText
                                        visible: groupItem.modelData.items.length > 1
                                        text: String(groupItem.modelData.items.length)
                                        color: Appearance.colors.textSecondary
                                        font.family: Appearance.fontFamily
                                        font.pixelSize: Tokens.typographyBodySize
                                        font.weight: Tokens.typographyMenuWeight
                                    }
                                }

                                Button {
                                    id: clearGroup
                                    anchors.right: parent.right
                                    text: qsTr("Clear")
                                    onClicked: Notifications.clearApp(groupItem.modelData.appName)
                                }
                            }

                            Repeater {
                                model: groupItem.shown

                                delegate: Item {
                                    id: row

                                    required property var modelData
                                    readonly property bool hovered: rowHover.hovered

                                    width: groupItem.width
                                    height: rowContent.implicitHeight + 2 * Tokens.spacingMd

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Tokens.radiusMenu
                                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2)
                                    }

                                    HoverHandler {
                                        id: rowHover
                                    }

                                    TapHandler {
                                        acceptedButtons: Qt.LeftButton
                                        enabled: row.modelData.nid >= 0
                                        onTapped: {
                                            Notifications.activateDefault(row.modelData.key);
                                            Notifications.closeCenter();
                                        }
                                    }

                                    NotificationContent {
                                        id: rowContent
                                        x: Tokens.spacingMd
                                        y: Tokens.spacingMd
                                        width: parent.width - 2 * Tokens.spacingMd
                                        entry: row.modelData
                                        body: Notifications.bodyFor(row.modelData)
                                        timeText: Notifications.timeFor(row.modelData)
                                        iconSource: Notifications.iconSource(row.modelData)
                                        onActionTriggered: actionId => Notifications.invokeAction(row.modelData.key, actionId)
                                    }

                                    // Remove this entry; shown on hover.
                                    Item {
                                        x: row.width - width - Tokens.spacingXs
                                        y: Tokens.spacingXs
                                        width: Tokens.notificationCloseSize
                                        height: width
                                        opacity: row.hovered ? 1 : 0
                                        Accessible.role: Accessible.Button
                                        Accessible.name: qsTr("Clear notification")
                                        Accessible.onPressAction: Notifications.clear(row.modelData.key)

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: width / 2
                                            color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                                        }

                                        Icon {
                                            anchors.centerIn: parent
                                            size: parent.width - 8
                                            name: "close-glyph"
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: parent.opacity > 0
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Notifications.clear(row.modelData.key)
                                        }
                                    }
                                }
                            }

                            Item {
                                visible: groupItem.modelData.items.length > Tokens.notificationCenterGroupCollapsed
                                width: parent.width
                                height: toggle.implicitHeight

                                Button {
                                    id: toggle
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: groupItem.expanded ? qsTr("Show Less") : qsTr("Show All (%1)").arg(groupItem.modelData.items.length)
                                    onClicked: groupItem.expanded = !groupItem.expanded
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
