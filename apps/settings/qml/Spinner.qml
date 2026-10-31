pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The progress spinner beside a section title while something is under way (macOS 27 Wi-Fi > Other Networks while it scans):
// spokes around a centre, the head one in the secondary colour and the others fading behind it, one step at a time. It runs
// only while visible, and stands still under Reduce Motion (ADR-0039 step 5): the fading spokes still say "under way".
Item {
    id: root

    property bool running: true
    property int step: 0

    implicitWidth: Tokens.settingsSpinnerSize
    implicitHeight: Tokens.settingsSpinnerSize
    Accessible.role: Accessible.ProgressBar
    Accessible.name: qsTr("In progress")

    Timer {
        interval: Tokens.settingsSpinnerStepMs
        running: root.running && root.visible && !Appearance.reduceMotion
        repeat: true
        onTriggered: root.step = (root.step + 1) % Tokens.settingsSpinnerSpokes
    }

    Repeater {
        model: Tokens.settingsSpinnerSpokes

        Rectangle {
            id: spoke
            required property int index
            // How far behind the head this spoke is: 0 is the head.
            readonly property int behind: (root.step - spoke.index + Tokens.settingsSpinnerSpokes) % Tokens.settingsSpinnerSpokes

            x: (root.width - width) / 2
            y: root.height / 2 - Tokens.settingsSpinnerSize / 2
            width: Tokens.settingsSpinnerSpokeWidth
            height: Tokens.settingsSpinnerSpokeLength
            radius: width / 2
            color: Appearance.windowSecondary
            opacity: 1 - (1 - Tokens.settingsSpinnerTailOpacity) * spoke.behind / (Tokens.settingsSpinnerSpokes - 1)
            transform: Rotation {
                origin.x: spoke.width / 2
                origin.y: Tokens.settingsSpinnerSize / 2
                angle: spoke.index * 360 / Tokens.settingsSpinnerSpokes
            }
        }
    }
}
