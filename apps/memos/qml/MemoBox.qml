import QtQuick
import Grassfield.Ui

// A box of a memo's strip (ADR-0051 D-5): the close box (an outlined square) or the collapse box (the square with a bar at its
// foot). The hit area is the strip's height, wider than the drawn square.
Item {
    id: root

    property bool collapse: false
    property string accessibleName: ""

    signal activated

    width: Tokens.memosStripHeight
    height: Tokens.memosStripHeight
    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.onPressAction: root.activated()

    Rectangle {
        anchors.centerIn: parent
        width: Tokens.memosBoxSize
        height: Tokens.memosBoxSize
        color: "transparent"
        border.width: Tokens.memosBoxStroke
        border.color: Tokens.memosInk
        opacity: tap.pressed ? 1 : Tokens.memosBoxOpacity

        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            visible: root.collapse
            height: Tokens.memosBoxStroke * 3
            color: Tokens.memosInk
        }
    }

    TapHandler {
        id: tap
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.activated()
    }
}
