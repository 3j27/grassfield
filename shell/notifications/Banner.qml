pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Grassfield.Ui

// One banner (N2-N5): material card, hover pauses the timeout (the timer lives in Notifications)
// and shows the close button, a drag to the right beyond 30 % of the width dismisses, a click
// runs the default action. Fields come from the banner model row.
Item {
    id: root

    required property string key
    property int nid: -1
    property string appName: ""
    property string appIcon: ""
    property string image: ""
    property string summary: ""
    property string bodyHtml: ""
    property real time: 0
    property int urgency: 1
    property string actionsJson: "[]"
    // Set by the stack: the banner is on its way out (the model already dropped it). It takes no input then, and its
    // hover no longer holds a timer (a banner of the same key may already be in the stack).
    property bool leaving: false
    // The exit's slide (the stack's remove transition), added to the card's own offset.
    property real exitSlide: 0
    // How far the close button stands out of the card's top-left corner (the stack's, on whole device pixels).
    property real closeOverhang: Tokens.notificationCloseSize / 3

    readonly property Item cardItem: card
    // The image as the app's preview setting allows it (the icon tile's stand-in or the trailing thumbnail).
    readonly property string shownImage: Notifications.imageFor(root.image, root.appName)
    // The area of the output whose backdrop the card's glass is judged over (Material.backdropRect; set by the stack).
    property alias backdropRect: material.backdropRect
    readonly property bool hovered: hover.hovered
    // Hover or drag pauses this notification's expiry timer.
    readonly property bool held: hovered || drag.active
    // Entrance offset (slides in from the right edge). Under Reduce Motion the banner fades in where it stands instead
    // (macOS: slides become fades; ADR-0039 step 5).
    property real slide: Appearance.reduceMotion ? 0 : Tokens.notificationBannerWidth
    property real entrance: Appearance.reduceMotion ? 0 : 1

    width: Tokens.notificationBannerWidth
    height: card.height

    Accessible.role: Accessible.AlertMessage
    Accessible.name: Notifications.summaryFor(summary, appName) !== "" ? Notifications.summaryFor(summary, appName) : appName
    Accessible.description: appName
    // The default action (a click on the banner outside its buttons) for assistive technologies too (A11Y-09).
    Accessible.onPressAction: Notifications.activateDefault(root.key)

    Component.onCompleted: {
        slide = 0;
        entrance = 1;
    }

    enabled: !leaving
    onHeldChanged: {
        if (!leaving)
            Notifications.holdBanner(key, held);
    }

    Behavior on entrance {
        enabled: Appearance.reduceMotion
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionNormal)
        }
    }

    // A banner slides in on the panel motion (ADR-0039 Q6, step 20).
    Behavior on slide {
        enabled: !Appearance.reduceMotion
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionPanel)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curvePanel
        }
    }

    HoverHandler {
        id: hover
    }

    Item {
        id: card
        x: root.slide + dragX + root.exitSlide
        width: root.width
        height: content.implicitHeight + 2 * Tokens.spacingMd
        opacity: root.entrance * (1 - Math.min(1, Math.max(0, dragX / root.width)))

        property real dragX: 0

        Material {
            id: material
            glassClass: "notification"
            anchors.fill: parent
            radius: Tokens.radiusBanner
        }

        NotificationContent {
            id: content
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd
            summary: Notifications.summaryFor(root.summary, root.appName)
            appName: root.appName
            urgency: root.urgency
            actionsJson: Notifications.actionsFor(root.actionsJson, root.appName)
            live: root.nid >= 0
            body: Notifications.bodyFor(root.bodyHtml, root.appName)
            timeText: Notifications.timeFor(root.time)
            iconSource: Notifications.appIconSource(root.shownImage, Notifications.appIconFor(root.appIcon, root.appName))
            imageSource: Notifications.thumbnailSource(root.shownImage)
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
                else if (Appearance.reduceMotion)
                    card.dragX = 0;  // back in place at once, no glide (ADR-0039 step 6)
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
            x: -root.closeOverhang
            y: -root.closeOverhang
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
                color: Appearance.withAlpha(Appearance.colors.materialTint, Appearance.fixedGlassAlpha(Tokens.notificationCloseTintOpacity))
                // One device pixel at every scale (UI audit 2026-11-05 U37).
                border.width: 1 / Math.max(1, Screen.devicePixelRatio)
                border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity * Tokens.notificationCloseBorderScale)
            }

            // Pressed: the shared pressed fill over the badge (LOW, UI audit 2026-11-05).
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
                visible: closeArea.pressed
            }

            Icon {
                anchors.centerIn: parent
                size: parent.width - Tokens.notificationCloseGlyphInset
                name: "close-glyph"
            }

            MouseArea {
                id: closeArea
                anchors.fill: parent
                enabled: close.opacity > 0
                cursorShape: Qt.ArrowCursor
                onClicked: Notifications.dismissBanner(root.key)
            }
        }
    }
}
