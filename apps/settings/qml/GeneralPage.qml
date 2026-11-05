import QtQuick

// General (macOS 27): a hub. The header card, then rows that open the sub-panes; the toolbar's back button returns here.
// Sharing holds Remote Login only (ADR-0045 OC-7). Not built (docs/specs/settings.md § macOS 27 parity inventory): the
// Apple-only rows.
SettingsPage {
    id: root

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)

    // Available updates (Software Update's red count, U19).
    property int updateCount: 0

    title: qsTr("General")

    PaneHero {
        icon: "gear"
        tileColor: "graphite"
        title: qsTr("General")
        text: qsTr("Manage your overall setup and preferences for this computer, such as storage, language, the date and time, and more.")
    }

    SettingsGroup {
        NavigationRow {
            text: qsTr("About")
            glyph: "laptop"
            onClicked: root.open("about")
        }
        NavigationRow {
            text: qsTr("Software Update")
            glyph: "gear"
            badge: root.updateCount
            onClicked: root.open("software-update")
        }
        NavigationRow {
            text: qsTr("Storage")
            glyph: "drive"
            onClicked: root.open("storage")
        }
    }

    // macOS 27 keeps Date & Time, Language & Region, Login Items and Sharing together (after AutoFill & Passwords, not built).
    SettingsGroup {
        NavigationRow {
            text: qsTr("Date & Time")
            glyph: "clock"
            tileColor: "blue"
            onClicked: root.open("datetime")
        }
        NavigationRow {
            text: qsTr("Language & Region")
            glyph: "globe"
            tileColor: "blue"
            onClicked: root.open("language")
        }
        NavigationRow {
            text: qsTr("Login Items")
            glyph: "list"
            onClicked: root.open("login")
        }
        // ADR-0045 OC-7: Sharing holds Remote Login only (superseding the owner decision of 2026-10-26 for exactly that).
        NavigationRow {
            text: qsTr("Sharing")
            glyph: "remote-desktop"
            onClicked: root.open("sharing")
        }
    }
}
