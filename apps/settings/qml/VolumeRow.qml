import QtQuick
import Grassfield.Ui
import "System.js" as System

// Volume slider row of the Sound pane. Writes are coalesced (one wpctl call per throttle interval while dragging) and
// go through SystemService, so a dev session suppresses them and the slider snaps back.
SettingsRow {
    id: root

    required property var system
    property int deviceId: -1
    property real volume: 0
    property bool muted: false
    property string accessibleName: root.title

    // A drag is being applied: the page keeps its older reading out of the slider meanwhile.
    readonly property bool busy: !isNaN(root.pending) || throttle.running
    property real pending: NaN

    function flush(): void {
        const v = root.pending;
        root.pending = NaN;
        if (!root.system.act("volume", System.setVolume(root.deviceId, v), "audio.act"))
            slider.local = NaN;
        throttle.start();
    }

    Icon {
        name: System.volumeGlyph(root.volume, root.muted)
        size: Tokens.settingsListIconSize
        color: Appearance.colors.textSecondary
        anchors.verticalCenter: parent.verticalCenter
    }

    Slider {
        id: slider
        width: Tokens.controlSliderDefaultWidth
        accessibleName: root.accessibleName
        enabled: root.deviceId >= 0
        opacity: enabled ? 1 : Tokens.materialDisabledOpacity
        from: 0
        to: 1
        stepSize: 0.05
        value: root.volume
        onMoved: v => {
            root.pending = v;
            if (!throttle.running)
                root.flush();
        }
    }

    Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Tokens.settingsVolumeValueWidth
        horizontalAlignment: Text.AlignRight
        text: qsTr("%1%").arg(System.percent(root.volume))
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Timer {
        id: throttle
        interval: Tokens.settingsVolumeApplyMs
        onTriggered: {
            if (!isNaN(root.pending))
                root.flush();
        }
    }
}
