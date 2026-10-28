import QtQuick
import Grassfield.Ui

// Grassfield.Ui's Appearance in the Files process, from FilesApp's reading of grassfield.json: appearance, accent, Reduce
// Motion, shortcut style and icon appearance, live. Grassfield Files (Main.qml) and grassfield-portal's Open and Save panels
// (FilePanels.qml) hold one each.
QtObject {
    id: root

    required property var app

    property list<QtObject> bindings: [
        Binding {
            target: Appearance
            property: "dark"
            value: root.app.dark
        },
        // App windows are opaque (master-prompt 5.5): menus drawn with the shared material too.
        Binding {
            target: Appearance
            property: "transparency"
            value: 0
        },
        // The window's own white background and secondary text (Appearance.windowSurface).
        Binding {
            target: Appearance
            property: "windowSurface"
            value: true
        },
        Binding {
            target: Appearance
            property: "reduceMotion"
            value: root.app.reduceMotion
        },
        // Accent colour (accent.color): live like the rest.
        Binding {
            target: Appearance
            property: "accentSetting"
            value: root.app.accentColor
        },
        // Text highlight colour (accent.highlight).
        Binding {
            target: Appearance
            property: "highlightSetting"
            value: root.app.accentHighlight
        },
        // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26).
        Binding {
            target: Appearance
            property: "shortcutStyle"
            value: root.app.shortcutStyle
        },
        // Icon appearance (ADR-0014): file and app icons follow the shell live.
        Binding {
            target: Appearance
            property: "iconMode"
            value: root.app.iconMode
        },
        Binding {
            target: Appearance
            property: "iconTintSetting"
            value: root.app.iconTint
        },
        Binding {
            target: Appearance
            property: "folderColorSetting"
            value: root.app.folderColor
        }
    ]
}
