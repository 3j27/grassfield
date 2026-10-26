import QtQuick

// General (macOS 27): a hub. The header card, then rows that open the sub-panes; the toolbar's back button returns here.
// Not built (docs/specs/settings.md § macOS 27 parity inventory): Software Update, Sharing and the Apple-only rows.
SettingsPage {
    id: root

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)

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
            text: qsTr("Storage")
            glyph: "drive"
            onClicked: root.open("storage")
        }
    }

    // macOS 27 keeps Date & Time, Language & Region and Login Items together (after AutoFill & Passwords, not built).
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
    }
}
