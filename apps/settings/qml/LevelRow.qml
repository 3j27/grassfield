import QtQuick
import Grassfield.Ui

// A level row laid out as macOS 27's slider rows (docs/audits/settings-parity-2026-10-26.md § Sound, § Displays): the title,
// then a small glyph, the slider and a large glyph. Sound's volumes and Displays' brightness. Writes are coalesced (one command
// per throttle interval while dragging) and go through SystemService, so a dev session suppresses them and the slider snaps back.
SettingsRow {
    id: root

    required property var system
    // The level, 0 to 1, as read.
    property real value: 0
    // The command that sets a level (an argument vector, or null when it cannot be set), what it is called in the log, and the
    // tag its answer comes back with.
    property var command: null
    property string what: ""
    property string tag: ""
    property bool settable: true
    property string accessibleName: root.title
    // The glyphs at the low and high ends, their sizes (the low one centred where an 18-pt one sits), and the slider's span.
    property string lowGlyph: "speaker"
    property string highGlyph: "volume-3"
    property real lowGlyphSize: Tokens.settingsSliderRowGlyphSize
    property real highGlyphSize: Tokens.settingsSliderRowGlyphSize
    property real sliderX: Tokens.settingsSliderRowSliderX
    property real sliderWidth: Tokens.settingsSliderRowSliderWidth

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
        if (!root.command || !root.system.act(root.what, root.command(v), root.tag))
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
        x: root.sliderX
        y: root.center - height / 2
        width: root.sliderWidth
        accessibleName: root.accessibleName
        enabled: root.settable && root.command !== null
        opacity: enabled ? 1 : Tokens.materialDisabledOpacity
        from: 0
        to: 1
        stepSize: 0.05
        value: root.value
        onMoved: v => {
            root.pending = v;
            if (!throttle.running)
                root.flush();
        }
    }

    Icon {
        parent: root
        name: root.highGlyph
        size: root.highGlyphSize
        color: Appearance.windowSecondary
        x: root.width - Tokens.settingsSliderRowHighGlyphInset - width + (root.highGlyphSize - Tokens.settingsSliderRowGlyphSize) / 2
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
