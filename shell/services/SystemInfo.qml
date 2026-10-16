pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Read-only facts for "About This Computer": /etc/os-release, /proc and `lspci`.
// Loading is lazy: call refresh() when the panel opens.
Singleton {
    id: root

    readonly property string grassfieldVersion: "0.1.0-m1"

    property string osName: ""
    property string osVersion: ""
    property string kernel: ""
    property string hostname: ""
    property string cpu: ""
    property string memory: ""
    property string graphics: ""
    readonly property string user: Quickshell.env("USER")

    // Pure parsers (exposed for tests).
    function osReleaseValue(text: string, key: string): string {
        const m = text.match(new RegExp("^" + key + "=\"?([^\"\\n]*)\"?$", "m"));
        return m ? m[1] : "";
    }

    function parseCpu(text: string): string {
        const name = text.match(/^model name\s*:\s*(.*)$/m);
        const cores = (text.match(/^processor\s*:/gm) || []).length;
        if (!name)
            return "";
        return cores > 0 ? qsTr("%1 (%2 threads)").arg(name[1].trim()).arg(cores) : name[1].trim();
    }

    function parseMemory(text: string): string {
        const m = text.match(/^MemTotal:\s*(\d+) kB/m);
        if (!m)
            return "";
        return qsTr("%1 GB").arg((parseInt(m[1]) / 1048576).toFixed(1));
    }

    // GPU lines: "00:02.0 VGA compatible controller: Intel ... (rev 05)" -> device description.
    function parseGraphics(text: string): string {
        const out = [];
        const lines = text.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/(?:VGA compatible controller|3D controller|Display controller):\s*(.*?)(?:\s*\(rev [0-9a-f]+\))?$/i);
            if (m)
                out.push(m[1]);
        }
        return out.join("\n");
    }

    function refresh(): void {
        osFile.reload();
        cpuFile.reload();
        memFile.reload();
        kernelFile.reload();
        hostFile.reload();
        lspci.running = true;
    }

    FileView {
        id: osFile
        path: "/etc/os-release"
        printErrors: false
        onLoaded: {
            const t = text();
            root.osName = root.osReleaseValue(t, "NAME");
            root.osVersion = root.osReleaseValue(t, "VERSION_ID");
        }
    }

    FileView {
        id: cpuFile
        path: "/proc/cpuinfo"
        printErrors: false
        onLoaded: root.cpu = root.parseCpu(text())
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        printErrors: false
        onLoaded: root.memory = root.parseMemory(text())
    }

    FileView {
        id: kernelFile
        path: "/proc/sys/kernel/osrelease"
        printErrors: false
        onLoaded: root.kernel = text().trim()
    }

    FileView {
        id: hostFile
        path: "/proc/sys/kernel/hostname"
        printErrors: false
        onLoaded: root.hostname = text().trim()
    }

    Process {
        id: lspci
        command: ["lspci"]
        stdout: StdioCollector {
            onStreamFinished: root.graphics = root.parseGraphics(text)
        }
    }
}
