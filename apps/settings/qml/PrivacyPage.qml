pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Privacy.js" as Privacy

// Privacy & Security as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Privacy & Security): a header card,
// Location Services with the number of applications allowed, then the categories, each with how many applications hold it.
// A row opens the category's sub-pane (open, Main.qml: PrivacyCategoryPage). Grassfield's categories are those the
// xdg-desktop-portal permission store keeps (ADR-0030): location, running in the background, the camera, and the screens chosen
// once for remote desktop and screen sharing. Only sandboxed applications ask the portals; the footnote says so. Not built:
// macOS's Apple app categories, Full Disk Access, FileVault and the security section.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)

    title: qsTr("Privacy & Security")

    // "None", "1 app", "3 apps" (macOS's subtitles); nothing until the store has answered.
    function countText(key: string): string {
        if (!grants.loaded || grants.error !== "")
            return "";
        if (Privacy.portalMissing(grants.state, key))
            return qsTr("Not used on this system");
        const n = Privacy.count(grants.state, key);
        return n === 0 ? qsTr("None") : n === 1 ? qsTr("1 app") : qsTr("%1 apps").arg(n);
    }

    PrivacyState {
        id: grants
        backend: root.backend
        system: root.system
    }

    PaneBanner {
        icon: "hand"
        tileColor: "blue"
        title: qsTr("Privacy")
        text: qsTr("Control which apps can use your location and your camera, keep running in the background, and share a screen you chose before.")
    }

    SettingsGroup {
        NavigationRow {
            compact: true
            text: qsTr("Location Services")
            glyph: "location"
            tileColor: "blue"
            value: grants.loaded && grants.error === "" ? String(Privacy.count(grants.state, "location")) : ""
            onClicked: root.open("privacy-location")
        }
    }

    SettingsGroup {
        footnote: grants.error !== "" ? qsTr("The permissions cannot be read: %1.").arg(grants.error) : qsTr("Only sandboxed apps (Flatpak, Snap) are limited by these permissions; other apps are not.")

        Repeater {
            model: [{key: "background", section: "privacy-background", text: qsTr("Background Apps"), glyph: "background", tile: "graphite"},
                {key: "camera", section: "privacy-camera", text: qsTr("Camera"), glyph: "camera", tile: "graphite"},
                {key: "remoteDesktop", section: "privacy-remote-desktop", text: qsTr("Remote Desktop"), glyph: "remote-desktop", tile: "blue"},
                {key: "screencast", section: "privacy-screen-sharing", text: qsTr("Screen Sharing"), glyph: "screen-share", tile: "purple"}]

            LargeRow {
                id: category
                required property var modelData
                text: category.modelData.text
                subtitle: root.countText(category.modelData.key)
                glyph: category.modelData.glyph
                tileColor: category.modelData.tile
                pictureSize: Tokens.settingsNavCompactTileSize
                pictureX: Tokens.settingsNavCompactTileInset
                titleX: Tokens.settingsNavCompactLabelInset
                onClicked: root.open(category.modelData.section)
            }
        }
    }
}
