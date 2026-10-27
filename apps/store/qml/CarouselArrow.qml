import QtQuick
import Grassfield.Ui

// The round arrow of a carousel (hero, cards): shown while the pointer is over it, out of the Tab chain (the keys move the
// carousel). A material disc with the chevron, as macOS 27.
ToolButton {
    property bool back: false
    property bool shown: false

    capsule: true
    buttonSize: Tokens.storeCarouselArrowSize
    iconName: "chevron-right"
    iconRotation: back ? 180 : 0
    focusPolicy: Qt.NoFocus
    accessibleName: back ? qsTr("Previous") : qsTr("Next")
    opacity: shown ? 1 : 0
    visible: opacity > 0
    z: 2

    Behavior on opacity {
        enabled: !Appearance.reduceMotion
        NumberAnimation {
            duration: Tokens.motionFast
        }
    }

    Rectangle {
        z: -1
        anchors.fill: parent
        radius: height / 2
        color: Appearance.withAlpha(Appearance.colors.windowBackground, Tokens.storeCarouselArrowFillOpacity)
    }
}
