pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell.Io
import Grassfield.Ui
import "SystemStats.js" as Stats

// One shared /proc sampler for every System widget (a second widget costs nothing extra). It runs
// only while at least one widget is active (`users` > 0), reads /proc/stat every
// Tokens.widgetSampleMs and /proc/meminfo every fourth tick (memory moves slowly), and publishes
// whole-percent values so an unchanged reading causes no repaint.
Item {
    id: root

    // Number of active System widgets (each adds 1 while active, removes it when not).
    property int users: 0
    property real cpu: 0
    property real memory: 0
    property real memUsedGb: 0
    property real memTotalGb: 0
    property bool haveSample: false
    // Previous /proc/stat totals {idle, total}.
    property var lastCpu: null
    property int tick: 0

    function sample(): void {
        statFile.reload();
        if (tick % 4 === 0)
            memFile.reload();
        tick++;
    }

    onUsersChanged: {
        if (users <= 0) {
            // The next visit starts a fresh delta.
            lastCpu = null;
            haveSample = false;
            tick = 0;
        }
    }

    Timer {
        interval: Tokens.widgetSampleMs
        running: root.users > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    FileView {
        id: statFile
        path: "/proc/stat"
        printErrors: false
        onLoaded: {
            const now = Stats.parseCpu(statFile.text());
            if (now === null)
                return;
            if (root.lastCpu !== null) {
                const load = Math.round(Stats.cpuLoad(root.lastCpu, now) * 100) / 100;
                if (load !== root.cpu)
                    root.cpu = load;
                root.haveSample = true;
            }
            root.lastCpu = now;
        }
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        printErrors: false
        onLoaded: {
            const m = Stats.parseMemory(memFile.text());
            if (m === null)
                return;
            const mem = Math.round(m.used / m.total * 100) / 100;
            if (mem !== root.memory)
                root.memory = mem;
            const used = Math.round(m.used / 104857.6) / 10;
            if (used !== root.memUsedGb)
                root.memUsedGb = used;
            root.memTotalGb = Math.round(m.total / 104857.6) / 10;
        }
    }
}
