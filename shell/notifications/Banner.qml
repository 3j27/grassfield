pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "History.js" as History

// One banner (N2-N5): material card, hover pauses the timeout and shows the close button, a
// drag to the right beyond 30 % of the width dismisses, a click runs the default action.
Item {
    id: root

    required property string key
    readonly property var entry: Notifications.entryFor(key)
    readonly property var notif: Notifications.liveByKey[key]
    readonly property Item cardItem: card
    readonly property bool hovered: hover.hovered
    readonly property int timeout: entry && notif ? History.bannerTimeout(entry.urgency, notif.expireTimeout, Tokens.notificationBannerTimeout) : Tokens.notificationBannerTimeout
    // Entrance offset (slides in from the right edge).
    property real slide: Tokens.notificationBannerWidth

    width: Tokens.notificationBannerWidth
    height: entry ? card.height : 0
    visible: entry !== null

    Component.onCompleted: slide = 0

    Behavior on slide {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionNormal)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curve
        }
    }

    Timer {
        id: expiry
        interval: root.timeout
        running: root.timeout > 0 && !root.hovered && !drag.active && root.entry !== null
        onTriggered: Notifications.expireBanner(root.key)
    }

    // A replacement of the same notification (new entry object) restarts the timeout.
    onEntryChanged: {
        if (entry)
            expiry.restart();
    }

    HoverHandler {
        id: hover
    }

    Item {
        id: card
        x: root.slide + dragX
        width: root.width
        height: content.implicitHeight + 2 * Tokens.spacingMd
        opacity: 1 - Math.min(1, Math.max(0, dragX / root.width))

        property real dragX: 0

        Material {
            id: material
            anchors.fill: parent
            radius: Tokens.radiusBanner
        }

        NotificationContent {
            id: content
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd
            entry: root.entry ? root.entry : ({nid: -1, actions: [], summary: "", appName: ""})
            body: root.entry ? Notifications.bodyFor(root.entry) : ""
            timeText: root.entry ? Notifications.timeFor(root.entry) : ""
            iconSource: root.entry ? Notifications.iconSource(root.entry) : ""
            onActionTriggered: actionId => Notifications.invokeAction(root.key, actionId)
        }

        // Click anywhere outside the buttons: default action.
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: Notifications.activateDefault(root.key)
        }

        DragHandler {
            id: drag
            target: null
            xAxis.enabled: true
            yAxis.enabled: false
            onTranslationChanged: card.dragX = Math.max(0, translation.x)
            onActiveChanged: {
                if (active)
                    return;
                if (card.dragX > root.width * Tokens.notificationDismissFraction)
                    Notifications.dismissBanner(root.key);
                else
                    release.start();
            }
        }

        NumberAnimation {
            id: release
            target: card
            property: "dragX"
            to: 0
            duration: Appearance.duration(Tokens.motionFast)
        }

        // Close button, top-left corner, only on hover.
        Item {
            id: close
            x: -Tokens.notificationCloseSize / 3
            y: -Tokens.notificationCloseSize / 3
            width: Tokens.notificationCloseSize
            height: width
            opacity: root.hovered ? 1 : 0
            activeFocusOnTab: false
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Dismiss notification")
            Accessible.onPressAction: Notifications.dismissBanner(root.key)

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(Appearance.colors.materialTint, 0.95)
                border.width: 1
                border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity * 2)
            }

            Icon {
                anchors.centerIn: parent
                size: parent.width - 8
                name: "close-glyph"
            }

            MouseArea {
                anchors.fill: parent
                enabled: close.opacity > 0
                cursorShape: Qt.PointingHandCursor
                onClicked: Notifications.dismissBanner(root.key)
            }
        }
    }
}
