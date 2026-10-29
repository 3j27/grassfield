import QtQuick
import "SysInfo.js" as SysInfo

// The computer's processor, memory and graphics in the UI language, read once when created: Settings > General > About and
// the About This Computer window (AboutWindow.qml, ADR-0040 ID-19) show the same lines. "" for what could not be read.
QtObject {
    id: root

    required property var backend

    readonly property var cpu: SysInfo.cpu(root.backend.readText("/proc/cpuinfo").text)
    readonly property real memoryBytes: SysInfo.memoryBytes(root.backend.readText("/proc/meminfo").text)

    // "AMD Ryzen 7 (16 threads)".
    readonly property string processor: {
        if (!root.cpu || root.cpu.model === "")
            return "";
        if (root.cpu.threads === 1)
            return qsTr("%1 (1 thread)").arg(root.cpu.model);
        return root.cpu.threads > 1 ? qsTr("%1 (%2 threads)").arg(root.cpu.model).arg(root.cpu.threads) : root.cpu.model;
    }
    // The installed memory as macOS shows it ("32 GB"): MemTotal leaves out what the firmware keeps (SysInfo.installedGiB).
    readonly property string memory: {
        const gib = SysInfo.installedGiB(root.memoryBytes);
        return gib > 0 ? qsTr("%1 GB").arg(gib) : "";
    }
    // The adapters' marketing names from lspci ("Intel Iris Xe Graphics").
    readonly property string graphics: SysInfo.gpus(root.backend.run(["lspci"]))
}
