pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "SysInfo.js" as SysInfo
import "General.js" as General

// General > About (macOS 27; the structure of the macOS 15 capture, docs/audits/settings-parity-2026-10-26.md § About): the
// device picture and the model name, then the computer's name (editable: hostname1 through polkit, ADR-0030), processor,
// graphics and memory; Grassfield and the components it runs on; the displays; the start-up disk. Read once when the page
// opens; the name again after a change.
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("About")

    property var info: ({})
    property var host: null
    property var screens: []
    property var volume: null
    // The name sent to hostname1 has no answer yet (the polkit dialog may be up): held by the Backend, so a visit while it is
    // up shows it too and cannot send a second one.
    readonly property bool waiting: (root.backend.pendingActions ?? {})["host.act"] !== undefined

    // The installed versions from `pacman -Q`, as queries off the GUI thread (review of ce69dc6): {package: version, "" when it
    // is not installed} for each answer so far.
    property var versions: ({})
    readonly property var packages: ["hyprland", "quickshell", "quickshell-git"]

    function collect(): var {
        const osRelease = root.backend.readText("/etc/os-release").text;
        return {
            omarchy: SysInfo.osReleaseValue(osRelease, "VERSION_ID") || SysInfo.osLabel(osRelease)
        };
    }

    // The first of `pkgs` installed; "" while pacman has not answered for all of them, "Unknown" when none is installed.
    function versionText(pkgs: var): string {
        let pending = false;
        for (const pkg of pkgs) {
            if (root.versions[pkg] === undefined)
                pending = true;
            else if (root.versions[pkg] !== "")
                return root.versions[pkg];
        }
        return pending ? "" : root.unknown;
    }

    // Processor, memory and graphics, as the About This Computer window shows them.
    readonly property AboutFacts facts: AboutFacts {
        backend: root.backend
    }

    // Decimal units, as macOS shows disks ("210.39 GB").
    function diskText(bytes: real): string {
        return Qt.locale().formattedDataSize(bytes, 2, Locale.DataSizeSIFormat);
    }

    // "27-inch (2560 × 1440)", or the resolution alone when the display gives no size.
    function displayText(s: var): string {
        const pixels = qsTr("%1 × %2").arg(s.pixelWidth).arg(s.pixelHeight);
        const inches = General.diagonalInches(s.physicalWidth, s.physicalHeight);
        return inches > 0 ? qsTr("%1-inch (%2)").arg(Qt.locale().toString(inches, "f", inches % 1 === 0 ? 0 : 1)).arg(pixels) : pixels;
    }

    function rename(text: string): void {
        const current = General.computerName(root.host);
        const wanted = text.trim();
        if (wanted === current || !General.validComputerName(wanted)) {
            nameField.text = current;
            return;
        }
        if (!root.system.act("computer name", General.hostSetName(wanted), "host.act"))
            nameField.text = current;
    }

    Component.onCompleted: {
        root.info = root.collect();
        for (const pkg of root.packages)
            root.backend.readOnlyQuery(["pacman", "-Q", pkg], "about.pacman." + pkg, Tokens.settingsAboutQueryTimeout, true);
        root.screens = root.backend.screens();
        root.volume = General.startupVolume(root.backend.volumes());
        root.system.queryBus("host.state", "host.state");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "host.state") {
                root.host = ok ? General.parseHost(output) : null;
                if (!nameField.activeFocus)
                    nameField.text = General.computerName(root.host);
            } else if (tag === "host.act") {
                root.system.queryBus("host.state", "host.state");
            } else if (tag.startsWith("about.pacman.")) {
                const answered = Object.assign({}, root.versions);
                answered[tag.slice("about.pacman.".length)] = ok ? SysInfo.pacmanVersion(output) : "";
                root.versions = answered;
            }
        }
    }

    readonly property string unknown: qsTr("Unknown")

    // The picture and the model name (macOS: the Mac's picture and its name).
    Item {
        width: parent.width
        height: Tokens.settingsAboutHeaderHeight

        DevicePicture {
            x: Math.round((parent.width - width) / 2)
            y: Tokens.settingsAboutPictureTop
            width: Tokens.settingsAboutPictureWidth
            height: Tokens.settingsAboutPictureHeight
            kind: General.deviceKind(root.host ? root.host.chassis : "")
        }

        Text {
            textFormat: Text.PlainText
            x: Tokens.settingsHeroTextInset
            y: Tokens.settingsAboutNameBaseline - baselineOffset
            width: parent.width - 2 * Tokens.settingsHeroTextInset
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: General.modelName(root.host) || qsTr("Computer")
            color: Appearance.colors.text
            font.family: Appearance.fontFamilyFor(Tokens.settingsAboutNameSize)
            font.pixelSize: Tokens.settingsAboutNameSize
            font.weight: Tokens.typographyMenuBoldWeight
            font.letterSpacing: Appearance.trackingFor(Tokens.settingsAboutNameSize)
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }
    }

    SettingsGroup {
        footnote: root.system.errors["host.act"] !== undefined ? qsTr("The name could not be changed: %1.").arg(root.system.errors["host.act"]) : ""

        SettingsRow {
            title: qsTr("Name")
            subtitle: root.waiting ? qsTr("Waiting for permission…") : ""

            // The name reads as text and becomes a field while it is edited (macOS); Return or leaving it applies, Escape
            // gives the name back.
            TextField {
                id: nameField
                width: Math.min(Tokens.settingsGroupLabelWidth * 2, Math.max(Tokens.settingsGroupLabelWidth, contentWidth + leftPadding + rightPadding))
                horizontalAlignment: TextInput.AlignRight
                fieldColor: activeFocus ? (Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity) : Appearance.colors.windowBackground) : "transparent"
                fieldBorder: activeFocus && !Appearance.dark
                // At rest the name lines up with the values of the other rows.
                leftPadding: activeFocus ? Tokens.spacingSm : 0
                rightPadding: activeFocus ? Tokens.spacingSm : 0
                maximumLength: 64
                enabled: root.host !== null && !root.waiting
                accessibleName: qsTr("Computer name")
                onAccepted: root.rename(text)
                onActiveFocusChanged: if (!activeFocus)
                    root.rename(text)
                Keys.onEscapePressed: {
                    text = General.computerName(root.host);
                    focus = false;
                }
            }
        }
        SettingsRow {
            title: qsTr("Processor")
            valueText: root.facts.processor || root.unknown
        }
        SettingsRow {
            title: qsTr("Graphics")
            valueText: root.facts.graphics || root.unknown
        }
        SettingsRow {
            title: qsTr("Memory")
            valueText: root.facts.memory || root.unknown
        }
    }

    SettingsGroup {
        caption: qsTr("Software")

        SettingsRow {
            title: qsTr("Grassfield")
            glyph: "grassfield-logo"
            tileColor: "green"
            valueText: qsTr("Version %1").arg(root.backend.appVersion)
        }
        SettingsRow {
            title: qsTr("Omarchy")
            valueText: root.info.omarchy || root.unknown
        }
        SettingsRow {
            title: qsTr("Hyprland")
            valueText: root.versionText(["hyprland"])
        }
        SettingsRow {
            title: qsTr("Quickshell")
            valueText: root.versionText(["quickshell", "quickshell-git"])
        }
        SettingsRow {
            title: qsTr("Qt")
            valueText: root.backend.qtVersion
        }
    }

    SettingsGroup {
        caption: qsTr("Displays")
        visible: root.screens.length > 0

        Repeater {
            model: root.screens

            SettingsRow {
                required property var modelData
                title: modelData.model !== "" ? modelData.model : modelData.name
                glyph: "display"
                tileColor: "blue"
                valueText: root.displayText(modelData)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Storage")
        visible: root.volume !== null

        SettingsRow {
            title: root.volume && root.volume.name !== "" ? root.volume.name : qsTr("Startup Disk")
            glyph: "drive"
            valueText: root.volume ? qsTr("%1 available of %2").arg(root.diskText(root.volume.available)).arg(root.diskText(root.volume.total)) : ""
        }
    }

    DevNote {
        system: root.system
    }
}
