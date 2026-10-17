import QtQuick
import "SysInfo.js" as SysInfo

// Read-only system information. Collected once when the page is first shown.
SettingsPage {
    id: root

    required property var backend

    title: qsTr("About")

    property var info: ({})

    function pacman(pkgs: var): string {
        for (const pkg of pkgs) {
            const v = SysInfo.pacmanVersion(root.backend.run(["pacman", "-Q", pkg]));
            if (v !== "")
                return v;
        }
        return "";
    }

    function collect(): var {
        const osRelease = root.backend.readText("/etc/os-release").text;
        return {
            omarchy: SysInfo.osLabel(osRelease),
            hyprland: root.pacman(["hyprland"]),
            quickshell: root.pacman(["quickshell", "quickshell-git"]),
            cpu: SysInfo.cpu(root.backend.readText("/proc/cpuinfo").text),
            memory: SysInfo.memory(root.backend.readText("/proc/meminfo").text),
            gpu: SysInfo.gpus(root.backend.run(["lspci"]))
        };
    }

    Component.onCompleted: root.info = root.collect()

    readonly property string unknown: qsTr("Unknown")

    SettingsGroup {
        caption: qsTr("Software")

        SettingsRow {
            title: qsTr("Grassfield")
            valueText: root.backend.appVersion
        }
        SettingsRow {
            title: qsTr("Omarchy")
            valueText: root.info.omarchy || root.unknown
        }
        SettingsRow {
            title: qsTr("Hyprland")
            valueText: root.info.hyprland || root.unknown
        }
        SettingsRow {
            title: qsTr("Quickshell")
            valueText: root.info.quickshell || root.unknown
        }
        SettingsRow {
            title: qsTr("Qt")
            valueText: root.backend.qtVersion
        }
    }

    SettingsGroup {
        caption: qsTr("Hardware")

        SettingsRow {
            title: qsTr("Processor")
            valueText: root.info.cpu || root.unknown
        }
        SettingsRow {
            title: qsTr("Memory")
            valueText: root.info.memory || root.unknown
        }
        SettingsRow {
            title: qsTr("Graphics")
            valueText: root.info.gpu || root.unknown
        }
    }
}
