import QtQuick
import Grassfield.Ui
import "System.js" as System

// Volume slider row of the Sound pane, laid out as macOS 27's Alert volume (docs/audits/settings-parity-2026-10-26.md § Sound):
// the title, then a small glyph, the slider and a large glyph. Writes are coalesced (one wpctl call per throttle interval while
// dragging) and go through SystemService, so a dev session suppresses them and the slider snaps back.
SettingsRow {
    id: root

    required property var system
    property int deviceId: -1
    property real volume: 0
    property bool muted: false
    property string accessibleName: root.title
    // The glyphs at the low and high ends.
    property string lowGlyph: "speaker"
    property string highGlyph: "volume-3"
    // The low-end glyph's size, centred where an 18-pt one sits (a microphone is drawn smaller there).
    property real lowGlyphSize: Tokens.settingsSliderRowGlyphSize

    // A drag is being applied: the page keeps its older reading out of the slider meanwhile.
    readonly property bool busy: !isNaN(root.pending) || throttle.running
    property real pending: NaN
    // Below the separator.
    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0
    readonly property real center: root.contentTop + Tokens.settingsSliderRowCenter

    implicitHeight: root.contentTop + Tokens.settingsSliderRowHeight - 1
    labelsOffset: Tokens.settingsSliderRowTitleOffset

    function flush(): void {
        const v = root.pending;
        root.pending = NaN;
        if (!root.system.act("volume", System.setVolume(root.deviceId, v), "audio.act"))
            slider.local = NaN;
        throttle.start();
    }

    Icon {
        parent: root
        name: root.lowGlyph
        size: root.lowGlyphSize
        color: Appearance.windowSecondary
        x: Tokens.settingsSliderRowLowGlyphX + (Tokens.settingsSliderRowGlyphSize - width) / 2
        y: root.center - height / 2
        opacity: slider.enabled ? 1 : Tokens.materialDisabledOpacity
    }

    Slider {
        id: slider
        parent: root
        x: Tokens.settingsSliderRowSliderX
        y: root.center - height / 2
        width: Tokens.settingsSliderRowSliderWidth
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

    Icon {
        parent: root
        name: root.highGlyph
        size: Tokens.settingsSliderRowGlyphSize
        color: Appearance.windowSecondary
        x: root.width - Tokens.settingsSliderRowHighGlyphInset - width
        y: root.center - height / 2
        opacity: slider.enabled ? 1 : Tokens.materialDisabledOpacity
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
