pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui
import "MouseTrackpad.js" as MT

// The top of Mouse and Trackpad (macOS 27, docs/audits/settings-parity-2026-10-26.md § Mouse and Trackpad): two cards from the
// pane's top, then the tabs. The device card is Grassfield's own drawing (a touchpad, or a two-button mouse with its wheel) with
// the gesture's fingers as dots moving the way it goes, one stroke after another (still with Reduce Motion); the other card is
// the desktop, still: the Grassfield artwork with a window and the Dock (macOS plays a video of the gesture). The first item of
// the page's column: the cards are drawn out to the pane's top.
Item {
    id: root

    // "trackpad" or "mouse".
    property string device: "trackpad"
    property string gesture: ""
    // [{id, text}]; none for a pane without tabs (Grassfield's Mouse).
    property var tabs: []
    property string tab: ""
    // How far the fingers are through the gesture's stroke (0 at rest).
    property real stroke: 0

    signal tabPicked(string id)

    readonly property bool trackpad: root.device === "trackpad"
    readonly property real cardWidth: (root.width - 2 * Tokens.settingsGestureCardInset - Tokens.settingsGestureCardGap) / 2
    readonly property color line: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsDeviceLineOpacity)
    // The desktop picture's drawing, in fractions of the card (Grassfield's own; not a UI surface, as GrassfieldArtwork).
    readonly property var art: ({
            windowX: 0.2,
            windowY: 0.1,
            windowWidth: 0.6,
            windowHeight: 0.6,
            titleHeight: 0.13,
            lines: [0.7, 0.85, 0.6, 0.78, 0.5],
            lineHeight: 0.035,
            lineGap: 0.075,
            dockWidth: 0.5,
            dockHeight: 0.11,
            dockBottom: 0.04,
            dockTint: 0.6,
            dockRadius: 0.33,
            tileSize: 0.7,
            tileRadius: 0.25,
            tileGap: 0.16,
            tiles: ["blue", "purple", "pink", "red", "orange", "yellow", "green"]
        })

    width: parent ? parent.width : implicitWidth
    implicitHeight: (root.tabs.length > 0 ? Tokens.settingsGestureFirstGroupY : Tokens.settingsGestureNoTabsGroupY) - Tokens.settingsContentTop - Tokens.settingsGroupGap
    Accessible.ignored: true

    SequentialAnimation on stroke {
        running: root.visible && root.gesture !== "" && !Appearance.reduceMotion
        loops: Animation.Infinite
        alwaysRunToEnd: false

        NumberAnimation {
            from: 0
            to: 1
            duration: Tokens.settingsGestureTravelMs
            easing.type: Easing.InOutQuad
        }
        PauseAnimation {
            duration: Tokens.settingsGesturePauseMs
        }
    }

    // A new gesture starts from rest.
    onGestureChanged: root.stroke = 0

    Rectangle {
        id: deviceCard
        x: Tokens.settingsGestureCardInset
        y: -Tokens.settingsContentTop
        width: root.cardWidth
        height: Tokens.settingsGestureCardHeight
        radius: Tokens.radiusMenu
        color: Appearance.colors.groupFill

        Item {
            id: drawing
            x: Math.round((parent.width - width) / 2)
            y: root.trackpad ? Tokens.settingsTrackpadTop : Tokens.settingsMouseTop
            width: root.trackpad ? Tokens.settingsTrackpadWidth : Tokens.settingsMouseWidth
            height: root.trackpad ? Tokens.settingsTrackpadHeight : Tokens.settingsMouseHeight

            Rectangle {
                anchors.fill: parent
                radius: root.trackpad ? Tokens.settingsTrackpadRadius : width / 2
                color: "transparent"
                border.width: Tokens.settingsDeviceLineWidth
                border.color: root.line
            }

            // The mouse: the line between its buttons, the buttons' edge and the wheel.
            Rectangle {
                visible: !root.trackpad
                x: (parent.width - width) / 2
                width: Tokens.settingsDeviceLineWidth
                height: Tokens.settingsMouseButtonsHeight
                color: root.line
            }

            Rectangle {
                visible: !root.trackpad
                y: Tokens.settingsMouseButtonsHeight - height / 2
                width: parent.width
                height: Tokens.settingsDeviceLineWidth
                color: root.line
            }

            Rectangle {
                visible: !root.trackpad
                x: (parent.width - width) / 2
                y: (Tokens.settingsMouseButtonsHeight - height) / 2
                width: Tokens.settingsMouseWheelWidth
                height: Tokens.settingsMouseWheelHeight
                radius: width / 2
                color: Appearance.colors.groupFill
                border.width: Tokens.settingsDeviceLineWidth
                border.color: root.line
            }

            Repeater {
                model: MT.fingersAt(root.gesture, root.stroke)

                delegate: Rectangle {
                    required property var modelData

                    x: modelData[0] * drawing.width - width / 2
                    y: modelData[1] * drawing.height - height / 2
                    width: Tokens.settingsGestureDotSize
                    height: width
                    radius: width / 2
                    // A press: the dots shrink in the middle of the stroke and come back.
                    scale: MT.presses(root.gesture) ? 1 - Tokens.settingsGesturePressScale * Math.sin(Math.PI * root.stroke) : 1
                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.settingsGestureDotOpacity)
                }
            }
        }
    }

    // The desktop: drawn in a layer and masked to the card's corners.
    Item {
        id: desktop
        x: deviceCard.x + root.cardWidth + Tokens.settingsGestureCardGap
        y: deviceCard.y
        width: root.cardWidth
        height: Tokens.settingsGestureCardHeight
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
        }

        GrassfieldArtwork {
            anchors.fill: parent
        }

        Rectangle {
            x: Math.round(parent.width * root.art.windowX)
            y: Math.round(parent.height * root.art.windowY)
            width: Math.round(parent.width * root.art.windowWidth)
            height: Math.round(parent.height * root.art.windowHeight)
            radius: Tokens.settingsGesturePreviewRadius
            color: Appearance.colors.windowBackground
            clip: true

            Rectangle {
                width: parent.width
                height: Math.round(parent.height * root.art.titleHeight)
                color: Appearance.colors.groupFill
            }

            Repeater {
                model: root.art.lines

                delegate: Rectangle {
                    required property real modelData
                    required property int index

                    x: Math.round(parent.width * root.art.lineGap)
                    y: Math.round(parent.height * (root.art.titleHeight + root.art.lineGap * (index + 1)))
                    width: Math.round((parent.width - 2 * x) * modelData)
                    height: Math.max(1, Math.round(parent.height * root.art.lineHeight))
                    radius: height / 2
                    color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsDeviceLineOpacity)
                }
            }
        }

        Rectangle {
            id: dock
            x: Math.round((parent.width - width) / 2)
            y: Math.round(parent.height * (1 - root.art.dockBottom - root.art.dockHeight))
            width: Math.round(parent.width * root.art.dockWidth)
            height: Math.round(parent.height * root.art.dockHeight)
            radius: Math.round(height * root.art.dockRadius)
            color: Appearance.withAlpha(Appearance.colors.materialTint, root.art.dockTint)

            Row {
                anchors.centerIn: parent
                spacing: Math.max(1, Math.round(dock.height * root.art.tileGap))

                Repeater {
                    model: root.art.tiles

                    delegate: Rectangle {
                        required property string modelData

                        width: Math.round(dock.height * root.art.tileSize)
                        height: width
                        radius: Math.round(width * root.art.tileRadius)
                        color: Tokens.colorAccentLight[modelData]
                    }
                }
            }
        }
    }

    Rectangle {
        id: mask
        visible: false
        layer.enabled: true
        width: desktop.width
        height: desktop.height
        radius: Tokens.settingsGesturePreviewRadius
    }

    SegmentedControl {
        visible: root.tabs.length > 0
        y: Tokens.settingsGestureTabsY - Tokens.settingsContentTop
        width: root.width
        height: Tokens.controlButtonHeight
        fill: true
        prominent: true
        accessibleName: qsTr("Gestures")
        model: root.tabs
        value: root.tab
        onPicked: id => root.tabPicked(id)
    }
}
