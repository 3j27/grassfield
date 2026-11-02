pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The phase of the day the Grassfield artwork shows (ADR-0040 IQ-W1 C; the rule is TimeOfDay.js): the system's time zone (the
// target of /etc/localtime under the zoneinfo directory, as timedatectl names it; TZ when the session sets one) and tzdata's
// zone1970.tab, zone.tab and tzdata.zi, read once; then one timer to the next change. No location, no network. Recomputed at
// start, at each change, when the clock jumps (a wake from sleep, a clock change: WallClock moves within its cap), at local
// midnight, and with the zone read again when the UTC offset changes. `phase` is "" until the files are read: the artwork then
// shows its Evening, as it did before. Dev hook: `qs ipc call wallpaper phase <dawn|day|evening|night|"">` (Wallpaper.qml).
Singleton {
    id: root

    // "dawn" | "day" | "evening" | "night", or "" before the first computation.
    property string phase: ""
    // Epoch ms of the next change, and how the phase was found ("sun", "fixed: no point", "fixed: polar").
    property double nextChange: 0
    property string how: ""
    property string zone: ""
    // A dev session's forced phase ("" = none).
    property string override: ""
    readonly property string shown: root.override !== "" ? root.override : root.phase

    readonly property string zoneDir: "/usr/share/zoneinfo"
    property var tables: null
    property int offsetMinutes: new Date().getTimezoneOffset()
    property int dayOfMonth: new Date().getDate()

    function recompute(): void {
        if (root.tables === null)
            return;
        const point = TimeOfDay.reference(root.zone, root.tables.z1970, root.tables.ztab, root.tables.links);
        const now = Date.now();
        const r = TimeOfDay.at(now, point, TimeOfDay.rules(Tokens));
        if (r.phase !== root.phase || r.how !== root.how)
            console.info("time of day: " + r.phase + " until " + new Date(r.next).toLocaleTimeString(Qt.locale("C"), "HH:mm") + " (" + r.how + (point ? ", point from " + point.source : "") + ", zone " + (root.zone !== "" ? root.zone : "unknown") + ")");
        root.phase = r.phase;
        root.how = r.how;
        root.nextChange = r.next;
        // One wake at the change (a second late, so that `now` is past it); a day at most.
        timer.interval = Math.max(1000, Math.min(r.next - now + 1000, 86400000));
        timer.restart();
    }

    // The zone's name: TZ when set (":Europe/Paris" or "Europe/Paris"), else the link /etc/localtime points to.
    function readZone(): void {
        const tz = Quickshell.env("TZ");
        if (typeof tz === "string" && tz !== "") {
            root.zone = tz.charAt(0) === ":" ? tz.substring(1) : tz;
            root.recompute();
            return;
        }
        zoneReader.running = true;
    }

    function zoneFromPath(path: string): string {
        const p = path.trim();
        for (const prefix of [root.zoneDir + "/posix/", root.zoneDir + "/right/", root.zoneDir + "/"]) {
            if (p.indexOf(prefix) === 0)
                return p.substring(prefix.length);
        }
        return "";
    }

    Process {
        id: zoneReader
        command: ["readlink", "-f", "/etc/localtime"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.zone = root.zoneFromPath(text);
                root.recompute();
            }
        }
    }

    // The three tables; a missing one reads as empty (a missing zone1970.tab and zone.tab: the fixed hours).
    property int pending: 3
    function tableDone(): void {
        root.pending -= 1;
        if (root.pending > 0)
            return;
        root.tables = {
            z1970: TimeOfDay.parseTable(z1970.ok ? z1970.text() : ""),
            ztab: TimeOfDay.parseTable(ztab.ok ? ztab.text() : ""),
            links: TimeOfDay.parseLinks(zi.ok ? zi.text() : "")
        };
        root.readZone();
    }

    FileView {
        id: z1970
        property bool ok: false
        path: root.zoneDir + "/zone1970.tab"
        printErrors: false
        onLoaded: {
            ok = true;
            root.tableDone();
        }
        onLoadFailed: root.tableDone()
    }

    FileView {
        id: ztab
        property bool ok: false
        path: root.zoneDir + "/zone.tab"
        printErrors: false
        onLoaded: {
            ok = true;
            root.tableDone();
        }
        onLoadFailed: root.tableDone()
    }

    FileView {
        id: zi
        property bool ok: false
        path: root.zoneDir + "/tzdata.zi"
        printErrors: false
        onLoaded: {
            ok = true;
            root.tableDone();
        }
        onLoadFailed: root.tableDone()
    }

    Timer {
        id: timer
        repeat: false
        onTriggered: root.recompute()
    }

    // The clock moves within its cap after a wake or a clock change; a jump past the change, a new day or a new offset (a
    // daylight saving change, another zone) recomputes, the zone read again when the offset moved.
    WallClock {
        onDateChanged: {
            const now = Date.now();
            const offset = new Date(now).getTimezoneOffset();
            const day = new Date(now).getDate();
            if (offset !== root.offsetMinutes) {
                root.offsetMinutes = offset;
                root.dayOfMonth = day;
                root.readZone();
            } else if (day !== root.dayOfMonth || (root.nextChange > 0 && now >= root.nextChange)) {
                root.dayOfMonth = day;
                root.recompute();
            }
        }
    }
}
