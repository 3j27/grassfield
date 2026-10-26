import QtQuick
import Grassfield.Ui

// Feeds the shared appearance from the backend (grassfield.json, read only). App windows are opaque
// (master-prompt 5.5): menus drawn with the shared material must not show what is behind them.
Item {
    id: root

    required property var backend

    visible: false

    Binding {
        target: Appearance
        property: "dark"
        value: root.backend.dark
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: root.backend.reduceMotion
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26).
    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }
}
