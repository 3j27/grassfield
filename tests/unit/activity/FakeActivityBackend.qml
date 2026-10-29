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
            {kind: "figures", rows: [{label: "System:", value: "5.0 %", swatch: "activityGraphSystem"},
                                     {label: "User:", value: "25.0 %", swatch: "activityGraphUser"},
                                     {label: "Idle:", value: "70.0 %", swatch: ""}]},
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

    function row(name: string, cpu: string, pid: string): var {
        return {name: name, icon: "", selected: false, accessibleText: name + ", % CPU " + cpu, cells: [name, cpu, pid, "alice"]};
    }

    property var table: {
        const rows = [backend.row("firefox", "12.3", "1234"), backend.row("Hyprland", "4.0", "812"), backend.row("foot", "0.1", "2001")];
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
        return rows;
    }
}
