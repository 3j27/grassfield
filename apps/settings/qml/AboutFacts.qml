import QtQuick
import Grassfield.Ui
import "SysInfo.js" as SysInfo

// The computer's processor, memory and graphics in the UI language: Settings > General > About and the About This Computer
// window (AboutWindow.qml, ADR-0040 ID-19) show the same lines, the window the processor's name alone (`processorShort`:
// About This Mac names the chip alone; its thread count made the French line wrap or cut the model, the integrator's nested
// pass of 85c2c10). "" for what could not be read.
// Nothing here waits on the GUI thread (review of ce69dc6): lspci runs as a read-only query (Backend.readOnlyQuery: the
// allow-list in every session) and fills `graphics` when it answers (`graphicsDone`); /proc/cpuinfo and /proc/meminfo are
// kernel memory, read in place in microseconds, as Main.qml reads /proc/bus/input/devices.
QtObject {
    id: root

    required property var backend

    readonly property var cpu: SysInfo.cpu(root.backend.readText("/proc/cpuinfo").text)
    readonly property real memoryBytes: SysInfo.memoryBytes(root.backend.readText("/proc/meminfo").text)

    // The model name of /proc/cpuinfo ("11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz": About This Computer's tooltip) and
    // the name shown (SysInfo.cpuShortName: "Intel Core i7-1165G7").
    readonly property string processorName: root.cpu ? root.cpu.model : ""
    readonly property string processorShort: root.processorName !== "" ? SysInfo.cpuShortName(root.processorName) : ""
    // General > About: "Intel Core i7-1165G7 (8 threads)".
    readonly property string processor: {
        if (root.processorShort === "")
            return "";
        if (root.cpu.threads === 1)
            return qsTr("%1 (1 thread)").arg(root.processorShort);
        return root.cpu.threads > 1 ? qsTr("%1 (%2 threads)").arg(root.processorShort).arg(root.cpu.threads) : root.processorShort;
    }
    // The installed memory as macOS shows it ("32 GB"): MemTotal leaves out what the firmware keeps (SysInfo.installedGiB).
    readonly property string memory: {
        const gib = SysInfo.installedGiB(root.memoryBytes);
        return gib > 0 ? qsTr("%1 GB").arg(gib) : "";
    }
    // The adapters' marketing names from lspci ("Intel Iris Xe Graphics"), once it has answered.
    property string graphics: ""
    property bool graphicsDone: false

    // One lspci for every reader in the process (a shared query: the About window and General > About ask together).
    readonly property string graphicsTag: "facts.lspci"

    property Connections answers: Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== root.graphicsTag)
                return;
            root.graphics = ok ? SysInfo.gpus(output) : "";
            root.graphicsDone = true;
        }
    }

    Component.onCompleted: root.backend.readOnlyQuery(["lspci"], root.graphicsTag, Tokens.settingsAboutQueryTimeout, true)
}
