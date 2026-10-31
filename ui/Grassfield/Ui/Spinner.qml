pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The indeterminate progress indicator of every app (ADR-0039 D4: Settings' spinner, shared since step 23): beside a section
// title while something is under way (macOS 27 Wi-Fi > Other Networks while it scans), in a view that loads (Files). Spokes
// around a centre, the head one in the secondary colour and the others fading behind it, one step at a time. It runs only
// while visible, and stands still under Reduce Motion (ADR-0039 step 5): the fading spokes still say "under way".
Item {
    id: root

    property bool running: true
    property int step: 0

    implicitWidth: Tokens.controlSpinnerSize
    implicitHeight: Tokens.controlSpinnerSize
    Accessible.role: Accessible.ProgressBar
    Accessible.name: qsTr("In progress")

    Timer {
        interval: Tokens.controlSpinnerStepMs
        running: root.running && root.visible && !Appearance.reduceMotion
        repeat: true
        onTriggered: root.step = (root.step + 1) % Tokens.controlSpinnerSpokes
    }

    Repeater {
        model: Tokens.controlSpinnerSpokes

        Rectangle {
            id: spoke
            required property int index
            // How far behind the head this spoke is: 0 is the head.
            readonly property int behind: (root.step - spoke.index + Tokens.controlSpinnerSpokes) % Tokens.controlSpinnerSpokes

            x: (root.width - width) / 2
            y: root.height / 2 - Tokens.controlSpinnerSize / 2
            width: Tokens.controlSpinnerSpokeWidth
            height: Tokens.controlSpinnerSpokeLength
            radius: width / 2
            color: Appearance.windowSecondary
            opacity: 1 - (1 - Tokens.controlSpinnerTailOpacity) * spoke.behind / (Tokens.controlSpinnerSpokes - 1)
            transform: Rotation {
                origin.x: spoke.width / 2
                origin.y: Tokens.controlSpinnerSize / 2
                angle: spoke.index * 360 / Tokens.controlSpinnerSpokes
            }
        }
    }
}
