pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Privacy.js" as Privacy
import "Setups.js" as Setups

// Privacy & Security as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Privacy & Security): a header card,
// Location Services with the number of applications allowed, then the categories, each with how many applications hold it.
// A row opens the category's sub-pane (open, Main.qml: PrivacyCategoryPage). Grassfield's categories are those the
// xdg-desktop-portal permission store keeps (ADR-0030): location, running in the background, the camera, and the screens chosen
// once for remote desktop and screen sharing. The store answers only the requests made to the portals: the footnote says whom
// it does not limit (apps that are not sandboxed, sandboxed apps given direct access to devices). Then Disk Encryption, in the
// place of macOS's FileVault (ADR-0045 OC-8, below). Not built: macOS's Apple app categories, Full Disk Access and the rest of
// the security section.
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)
    // Disk Encryption's Change Password…: Main.qml opens DiskPasswordSheet, or the terminal sheet (TerminalSetupSheet).
    signal diskPasswordRequested
    signal setupRequested(string id)

    title: qsTr("Privacy & Security")

    // lsblk's answer (Setups.rootEncryption) and UDisks2's (disk.state: null when it did not answer).
    property var encryption: ({known: false, encrypted: false, device: ""})
    property var disk: null

    function readDisk(): void {
        root.backend.readOnlyQuery(Setups.QUERY.blockDevices, "privacy.disk");
        root.system.queryBus("disk.state", "privacy.udisks");
    }

    Component.onCompleted: root.readDisk()

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "privacy.disk")
                root.encryption = ok ? Setups.rootEncryption(output) : {known: false, encrypted: false, device: ""};
            else if (tag === "privacy.udisks")
                root.disk = ok ? Setups.parseDisk(output) : null;
        }
    }

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
        text: qsTr("Choose what apps that ask the desktop portal may do: use your location and your camera, keep running in the background, and share a screen you chose before.")
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
        footnote: grants.error !== "" ? qsTr("The permissions cannot be read: %1.").arg(grants.error) : qsTr("These permissions apply when an app asks the desktop portal, as sandboxed apps (Flatpak, Snap) do. They do not limit apps that are not sandboxed, nor sandboxed apps given direct access to devices.")

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

    // Disk Encryption (ADR-0045 OC-8), in the place of macOS 27's FileVault row in the Security section: whether the root file
    // system lies on a LUKS device (lsblk, read-only), and Change Password…: UDisks2's own password change in a sheet
    // (DiskPasswordSheet.qml) when UDisks2 found that device, else Omarchy's omarchy-drive-password in its terminal behind a
    // sheet that says why. Encryption cannot be turned on in place: the line says so, with no button.
    SettingsGroup {
        visible: root.encryption.known
        caption: qsTr("Disk Encryption")

        SettingsRow {
            title: qsTr("Disk Encryption")
            glyph: "lock"
            tileColor: "graphite"
            subtitle: root.encryption.encrypted
                ? (root.encryption.device !== "" ? qsTr("On for the start-up disk (%1). Its password is asked when the computer starts.").arg(root.encryption.device)
                    : qsTr("On for the start-up disk. Its password is asked when the computer starts."))
                : qsTr("Off. The start-up disk is not encrypted, and encryption cannot be turned on in place: it is chosen when the system is installed.")

            Button {
                visible: root.encryption.encrypted
                push: true
                text: qsTr("Change Password…")
                Accessible.name: qsTr("Change the disk password")
                onClicked: Setups.passwordRoute(root.disk) === "native" ? root.diskPasswordRequested() : root.setupRequested("drive-password")
            }
        }
    }
}
