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
            // The package of this project or the AUR package it conflicts with: WhiteSur is the theme in use either way.
            whitesur: root.pacman(["grassfield-whitesur-icons", "whitesur-icon-theme", "whitesur-icon-theme-git"]),
            cpu: SysInfo.cpu(root.backend.readText("/proc/cpuinfo").text),
            memory: SysInfo.memoryBytes(root.backend.readText("/proc/meminfo").text),
            gpu: SysInfo.gpus(root.backend.run(["lspci"]))
        };
    }

    // "AMD Ryzen 7 (16 threads)", in the UI language.
    function cpuText(cpu: var): string {
        if (!cpu || cpu.model === "")
            return "";
        if (cpu.threads === 1)
            return qsTr("%1 (1 thread)").arg(cpu.model);
        return cpu.threads > 1 ? qsTr("%1 (%2 threads)").arg(cpu.model).arg(cpu.threads) : cpu.model;
    }

    // Binary units with the UI locale's digits and unit names ("31.0 GiB", "31,0 Gio").
    function memoryText(bytes: real): string {
        return bytes > 0 ? Qt.locale().formattedDataSize(bytes, 1, Locale.DataSizeIecFormat) : "";
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

    // Third-party components that the session shows (ADR-0017, licences-audit G10). The licence texts are installed
    // under /usr/share/licenses/<package>/.
    SettingsGroup {
        caption: qsTr("Acknowledgements")
        visible: (root.info.whitesur ?? "") !== ""

        SettingsRow {
            title: qsTr("Icon theme")
            valueText: qsTr("WhiteSur by Vince Liuice, GPL-3.0")
        }
    }

    SettingsGroup {
        caption: qsTr("Hardware")

        SettingsRow {
            title: qsTr("Processor")
            valueText: root.cpuText(root.info.cpu) || root.unknown
        }
        SettingsRow {
            title: qsTr("Memory")
            valueText: root.memoryText(root.info.memory ?? 0) || root.unknown
        }
        SettingsRow {
            title: qsTr("Graphics")
            valueText: root.info.gpu || root.unknown
        }
    }
}
