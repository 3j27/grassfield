import QtQuick
import Grassfield.Ui

// Grassfield.Ui's Appearance in the Settings process, from grassfield.json (ConfigStore), live: appearance (Auto follows the
// local schedule, re-evaluated each minute while it is selected), accent and highlight, the accessibility text options,
// shortcut style and icon appearance. The Settings window (Main.qml) and the About This Computer window (AboutWindow.qml)
// hold one each, as Files and the portal's panels hold a FilesAppearance.
QtObject {
    id: root

    required property var backend
    required property ConfigStore config

    property date clock: new Date()
    // The device facts for the shortcut style, read once.
    readonly property bool macDevice: MenuShortcut.macDevice(root.backend.readText("/sys/class/dmi/id/sys_vendor").text, root.backend.readText("/proc/bus/input/devices").text)

    property list<QtObject> bindings: [
        // The window's own surface and its secondary text grey (Appearance.windowSurface, Appearance.windowSecondary).
        Binding {
            target: Appearance
            property: "windowSurface"
            value: true
        },
        Binding {
            target: Appearance
            property: "dark"
            value: AutoAppearance.isDark(root.config.value("appearance"), root.clock, Tokens.autoAppearanceDarkFromHour, Tokens.autoAppearanceDarkToHour)
        },
        Timer {
            interval: Tokens.autoAppearanceRecheckInterval
            repeat: true
            running: root.config.value("appearance") === "auto"
            onTriggered: root.clock = new Date()
        },
        // App windows are opaque: menus drawn with the shared material must not show what is behind them.
        Binding {
            target: Appearance
            property: "transparency"
            value: 0
        },
        Binding {
            target: Appearance
            property: "reduceMotion"
            value: root.config.value("accessibility.reduceMotion")
        },
        Binding {
            target: Appearance
            property: "increaseContrast"
            value: root.config.value("accessibility.increaseContrast")
        },
        Binding {
            target: Appearance
            property: "textScale"
            value: root.config.value("accessibility.textSize")
        },
        Binding {
            target: Appearance
            property: "accentSetting"
            value: root.config.value("accent.color")
        },
        Binding {
            target: Appearance
            property: "highlightSetting"
            value: root.config.value("accent.highlight")
        },
        // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26).
        Binding {
            target: Appearance
            property: "shortcutStyle"
            value: MenuShortcut.style(root.config.value("keyboard.shortcutStyle"), root.macDevice)
        },
        // Icon appearance (ADR-0014): the previews and any app icon follow the file live.
        Binding {
            target: Appearance
            property: "iconMode"
            value: root.config.value("icons.mode")
        },
        Binding {
            target: Appearance
            property: "iconTintSetting"
            value: root.config.value("icons.tint")
        },
        Binding {
            target: Appearance
            property: "folderColorSetting"
            value: root.config.value("icons.folderColor")
        }
    ]
}
