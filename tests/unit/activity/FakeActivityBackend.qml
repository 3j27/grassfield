import QtQuick

// A stand-in for ActivityApp (apps/activity/src/activityapp.h) for tst_activitymain.qml: the properties the window binds,
// the calls it makes recorded in `calls`, and a table that is a JS array of rows (a ListView model) carrying the table's
// methods. Nothing samples.
QtObject {
    id: backend

    property bool dark: false
    property bool reduceMotion: false
    property bool increaseContrast: false
    property real textScale: 1
    property string accentColor: "multicolor"
    property string accentHighlight: "automatic"
    property string titlebarDoubleClick: "zoom"
    property bool canMinimize: true
    property string shortcutStyle: "pc"

    property string tab: "cpu"
    readonly property var tabs: [
        {key: "cpu", title: "CPU"},
        {key: "memory", title: "Memory"},
        {key: "energy", title: "Energy"},
        {key: "disk", title: "Disk"},
        {key: "network", title: "Network"}
    ]
    property string view: "all"
    readonly property string viewTitle: backend.views.find(v => v.key === backend.view)?.title ?? ""
    readonly property var views: [
        {key: "all", title: "All Processes"},
        {key: "mine", title: "My Processes"},
        {key: "system", title: "System Processes"}
    ]
    property string search: ""
    property int interval: 5
    property int savedWidth: 0
    property int savedHeight: 0
    property bool ready: true
    property int processSamples: 1
    property bool devSession: false
    property string sortKey: "cpuPercent"
    property bool sortDescending: true
    property var columns: [
        {key: "name", title: "Process Name", shown: true, optional: false, hideable: false, numeric: false, width: 0},
        {key: "cpuPercent", title: "% CPU", shown: true, optional: false, hideable: true, numeric: true, width: 0},
        {key: "wakeUps", title: "Wake Ups", shown: false, optional: true, hideable: true, numeric: true, width: 0},
        {key: "pid", title: "PID", shown: true, optional: false, hideable: true, numeric: true, width: 0},
        {key: "user", title: "User", shown: true, optional: false, hideable: true, numeric: false, width: 0}
    ]
    readonly property var shownColumns: backend.columns.filter(c => c.shown)
    property var calls: []

    function record(call: string): void {
        backend.calls = backend.calls.concat([call]);
    }
    function sortBy(key: string): void {
        backend.record("sortBy:" + key);
        backend.sortDescending = backend.sortKey === key ? !backend.sortDescending : true;
        backend.sortKey = key;
    }
    function setColumnShown(key: string, shown: bool): void {
        backend.record("setColumnShown:" + key + ":" + shown);
        backend.columns = backend.columns.map(c => c.key === key ? Object.assign({}, c, {shown: shown}) : c);
    }
    function setColumnWidth(key: string, width: int): void {
        backend.record("setColumnWidth:" + key + ":" + width);
    }
    function copySelection(): void {
        backend.record("copy");
    }
    function saveSize(width: int, height: int): void {
        backend.record("saveSize");
    }
    function setGraphMode(graph: string, mode: string): void {
        backend.record("setGraphMode:" + graph + ":" + mode);
    }

    // The summary (apps/activity/src/summary.h): the tab's blocks as the backend lists them.
    readonly property QtObject summary: QtObject {
        property int capacity: 1
        property var blocks: [
            {kind: "figures", rows: [{label: "System:", value: "5.0%", swatch: "activityGraphSystem"},
                                     {label: "User:", value: "25.0%", swatch: "activityGraphUser"},
                                     {label: "Idle:", value: "70.0%", swatch: ""}]},
            {kind: "graph", key: "cpu", title: "CPU Load", style: "stacked", max: 1,
             series: [{values: [-1, 0.05, 0.1], color: "activityGraphSystem"}, {values: [-1, 0.25, 0.3], color: "activityGraphUser"}]},
            {kind: "figures", rows: [{label: "Threads:", value: "1734", swatch: ""}, {label: "Processes:", value: "412", swatch: ""}]}
        ]
    }
    readonly property var diskBlocks: [
        {kind: "figures", rows: [{label: "Reads in:", value: "1000", swatch: ""}]},
        {kind: "graph", key: "disk", title: "Reads and Writes", style: "mirrored", max: 10,
         series: [{values: [3, 4], color: "activityGraphRead"}, {values: [9, 1], color: "activityGraphWrite"}],
         modes: [{key: "io", title: "IO"}, {key: "data", title: "Data"}], mode: "io"},
        {kind: "figures", rows: [{label: "Data read:", value: "5.00 MB", swatch: ""}]}
    ]

    // Quit, Force Quit and Send Signal (apps/activity/src/actions.h): the answers each test sets, the calls recorded.
    readonly property var signalList: [
        {number: 1, title: "Hangup (SIGHUP)"}, {number: 2, title: "Interrupt (SIGINT)"}, {number: 3, title: "Quit (SIGQUIT)"},
        {number: 6, title: "Abort (SIGABRT)"}, {number: 9, title: "Kill (SIGKILL)"}, {number: 14, title: "Alarm (SIGALRM)"},
        {number: 15, title: "Terminate (SIGTERM)"}, {number: 10, title: "User Defined 1 (SIGUSR1)"},
        {number: 12, title: "User Defined 2 (SIGUSR2)"}, {number: 19, title: "Stop (SIGSTOP)"}, {number: 18, title: "Continue (SIGCONT)"}
    ]
    readonly property QtObject actions: QtObject {
        property bool canQuit: false
        property bool canSignal: false
        property string refusal: ""
        property var sheet: ({ok: true, count: 1, name: "foot", pid: 2001, session: "", self: false, signals: backend.signalList})
        property var quitResult: ({done: true})
        property var forceQuitResult: ({done: true})
        property var sendResult: ({done: true})

        signal closeWindowRequested

        function prepare(action: string): var {
            backend.record("prepare:" + action);
            return this.sheet;
        }
        function quit(): var {
            backend.record("quit");
            return this.quitResult;
        }
        function forceQuit(): var {
            backend.record("forceQuit");
            return this.forceQuitResult;
        }
        function send(signal: int): var {
            backend.record("send:" + signal);
            return this.sendResult;
        }
        function release(): void {
            backend.record("release");
        }
    }

    // Inspect (apps/activity/src/activityapp.h, inspection.h): the window opens one Inspect window per inspection.
    property bool canInspect: false
    property var focusWindow: null
    signal inspectRequested(var inspection)
    function inspectSelection(): void {
        backend.record("inspectSelection");
    }
    function inspectRow(row: int): void {
        backend.record("inspectRow:" + row);
    }
    function closeInspection(inspection: var): void {
        backend.record("closeInspection:" + inspection.key);
    }
    // A stand-in for an Inspection: its texts, its tab and its own actions; `calls` as the backend's.
    readonly property Component inspectionComponent: Component {
        QtObject {
            id: inspection
            property string title: "foot (2001)"
            property string key: "2001:500"
            property int pid: 2001
            property bool ready: true
            property bool own: true
            property string parentText: "fish (1990)"
            property bool canInspectParent: true
            property string groupText: "foot (2001)"
            property string userText: "alice (1000)"
            property string cpuText: "0.4"
            property string hangsText: "—"
            // The models are arrays here: a delegate reads a row as `modelData` either way.
            property var memoryModel: [{label: "Real Memory Size:", value: "51.2 MB"}, {label: "Proportional Memory Size:", value: "30.1 MB"}]
            property var statisticsModel: [{label: "Threads:", value: "4"}, {label: "Command:", value: "foot --server"}]
            property var filesModel: [{fd: 0, text: "/dev/null"}, {fd: 3, text: "TCP 127.0.0.1:8080 (listening)"}]
            readonly property var rowLabels: (inspection.tab === "statistics" ? inspection.statisticsModel : inspection.memoryModel).map(r => r.label)
            property string filesNote: ""
            property string tab: "memory"
            property bool shownNow: false
            property var watched: null
            signal ended
            signal changed
            function watch(window: var): void {
                inspection.watched = window;
                backend.record("watch:" + inspection.key);
            }
            function setShown(shown: bool): void {
                inspection.shownNow = shown;
            }
            function inspectParent(): void {
                backend.record("inspectParent:" + inspection.key);
            }
            readonly property QtObject actions: QtObject {
                property bool canQuit: true
                property bool canSignal: true
                property string refusal: ""
                property var sheet: ({ok: true, count: 1, name: "foot", pid: 2001, session: "", self: false, signals: backend.signalList})
                signal closeWindowRequested
                function prepare(action: string): var {
                    backend.record("inspect-prepare:" + action);
                    return this.sheet;
                }
                function quit(): var {
                    backend.record("inspect-quit");
                    return {done: true};
                }
                function forceQuit(): var {
                    backend.record("inspect-forceQuit");
                    return {done: true};
                }
                function send(signal: int): var {
                    return {done: true};
                }
                function release(): void {
                    backend.record("inspect-release");
                }
            }
        }
    }

    function row(name: string, cpu: string, pid: string): var {
        return {name: name, icon: "", selected: false, accessibleText: name + ", % CPU " + cpu, cells: [name, cpu, pid, "alice"],
                depth: 0, expandable: false, expanded: true, group: false};
    }

    // A table of `rows` with the table's methods, the calls they get recorded in `clicks`.
    function makeTable(rows: var): var {
        rows.selectedCount = 0;
        rows.currentRow = -1;
        rows.clicks = [];
        rows.click = (r, modifiers) => {
            rows.clicks.push(r + ":" + modifiers);
            rows.currentRow = r;
            rows.selectedCount = 1;
        };
        rows.moveCurrent = (delta, extend) => {
            rows.clicks.push("move:" + delta + ":" + extend);
            rows.currentRow = Math.max(0, Math.min(rows.length - 1, rows.currentRow + delta));
        };
        rows.selectAll = () => {
            rows.clicks.push("selectAll");
            rows.selectedCount = rows.length;
        };
        rows.clearSelection = () => {
            rows.selectedCount = 0;
        };
        rows.setExpanded = (r, expanded) => {
            rows.clicks.push("expanded:" + r + ":" + expanded);
        };
        rows.toggleExpanded = r => {
            rows.clicks.push("toggle:" + r);
        };
        return rows;
    }
    property var table: backend.makeTable([backend.row("firefox", "12.3", "1234"), backend.row("Hyprland", "4.0", "812"),
                                           backend.row("foot", "0.1", "2001")])
}
