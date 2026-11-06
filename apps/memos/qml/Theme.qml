import QtQuick
import Grassfield.Ui

// Feeds the shared appearance from the backend (grassfield.json, read only), as every app (Preview's Theme.qml). The memos'
// paper keeps its own colours in both appearances; the alert's buttons and the menus follow the appearance.
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
        property: "increaseContrast"
        value: root.backend.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: root.backend.textScale
    }

    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: root.backend.accentHighlight
    }

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }
}
