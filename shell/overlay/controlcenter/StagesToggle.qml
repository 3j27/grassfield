import QtQuick
import qs.platform
import qs.services

// Quick Settings: the Stages switch (docs/specs/stages.md; macOS: the Stage Manager tile). A 2x1 capsule that exists only while
// the compositor plugin reports `stages-available` (nothing to switch otherwise). Off by default; the setting is persisted
// (windows.stages) and the shell pushes it to the plugin (platform/Compositor.qml). The host places it.
Module {
    id: root

    // Left and right inset of the icon disk inside the capsule (as the other 2x1 capsules).
    property real inset: 0
    // The row, for the host's focus handling.
    readonly property alias row: stagesRow

    visible: StagesLink.available
    cols: 2

    RadioRow {
        id: stagesRow
        width: parent.width
        height: parent.height
        inset: root.inset
        iconName: "overview"
        title: qsTr("Stages")
        subtitle: Settings.windowsStages ? qsTr("On") : qsTr("Off")
        on: Settings.windowsStages
        available: StagesLink.available
        onToggled: Settings.setStagesEnabled(!Settings.windowsStages)
    }
}
