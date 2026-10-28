import QtQuick
import Grassfield.Ui

// Accessibility as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Accessibility): a header card, then the
// sub-panes by section as rows: Vision (Zoom, Display, Motion), Physical and Motor (Keyboard). A row opens its sub-pane
// (open, Main.qml); the toolbar's back button returns here. Not built: macOS's VoiceOver, Hover Text, Read & Speak, Audio
// Descriptions, Voice Control, Pointer Control, Switch Control and the Hearing, Speech and General sections.
SettingsPage {
    id: root

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)

    title: qsTr("Accessibility")

    PaneBanner {
        icon: "person"
        tileColor: "blue"
        title: qsTr("Accessibility")
        text: qsTr("Adapt this computer to the way you see and the way you move: zoom, the display, motion and the keyboard.")
    }

    SettingsGroup {
        caption: qsTr("Vision")

        NavigationRow {
            compact: true
            text: qsTr("Zoom")
            glyph: "zoom-in"
            onClicked: root.open("accessibility-zoom")
        }
        NavigationRow {
            compact: true
            text: qsTr("Display")
            glyph: "display"
            tileColor: "blue"
            onClicked: root.open("accessibility-display")
        }
        NavigationRow {
            compact: true
            text: qsTr("Motion")
            glyph: "motion"
            tileColor: "green"
            onClicked: root.open("accessibility-motion")
        }
    }

    SettingsGroup {
        caption: qsTr("Physical and Motor")

        NavigationRow {
            compact: true
            text: qsTr("Keyboard")
            glyph: "keyboard"
            onClicked: root.open("accessibility-keyboard")
        }
    }
}
