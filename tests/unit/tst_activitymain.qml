import QtQuick
import QtTest
import Grassfield.Ui
import "activity"

// The activity monitor's window (apps/activity/qml/Main.qml, ADR-0038 steps 2a and 2b) with a fake backend: the title with
// the view as its subtitle, the five tabs, the live search, the table's headers (sort, the columns menu) and rows, the
// keyboard and the accessible names, the summary's figures and graphs, the Disk pop-up and the Network tab's line. The backend's own logic has its gtest cases (tests/unit/activity/window).
TestCase {
    id: testCase
    name: "ActivityMain"
    width: 800
    height: 600
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        FakeActivityBackend {}
    }

    function make() {
        const backend = fakeBackend.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/activity/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false});
        verify(win);
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is active");
        wait(50);
        return {backend: backend, win: win};
    }

    function findAll(item, pred, out) {
        out = out || [];
        if (!item)
            return out;
        if (pred(item))
            out.push(item);
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++)
            findAll(kids[i], pred, out);
        if (item.contentItem && item.contentItem !== item)
            findAll(item.contentItem, pred, out);
        return out;
    }

    function texts(root) {
        return findAll(root, i => i.text !== undefined && typeof i.text === "string" && i.visible && i.text !== "").map(i => i.text);
    }

    function test_titleTabsAndHeaders() {
        const t = make();
        compare(t.win.title, "Activity Monitor");
        const shown = texts(t.win.contentItem);
        verify(shown.indexOf("All Processes") >= 0, "the view is the subtitle (AM3)");
        compare(t.win.tabs.model.length, 5);
        compare(t.win.tabs.value, "cpu");
        for (const title of ["Process Name", "% CPU", "PID", "User"])
            verify(shown.indexOf(title) >= 0, title + " is a header");
        verify(shown.indexOf("Wake Ups") < 0, "an optional column stays hidden");
        verify(shown.indexOf("firefox") >= 0 && shown.indexOf("12.3") >= 0, "the rows' cells");
        const headers = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.ColumnHeader);
        compare(headers.length, 4);
        const table = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.Table);
        compare(table.length, 1);
        compare(table[0].Accessible.name, "Processes");
    }

    function test_tabsSearchAndSort() {
        const t = make();
        t.win.tabs.picked("memory");
        compare(t.backend.tab, "memory");
        // AM14: the search filters as it is typed, no Return needed.
        keyClick(Qt.Key_F, Qt.ControlModifier);
        tryVerify(() => t.win.searchField.activeFocus);
        keyClick(Qt.Key_F);
        keyClick(Qt.Key_I);
        compare(t.backend.search, "fi");
        // AM10: a header clicked sorts by its column.
        const pidHeader = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.ColumnHeader && i.Accessible.name === "PID")[0];
        verify(pidHeader);
        mouseClick(pidHeader);
        compare(t.backend.sortKey, "pid");
        verify(t.backend.calls.indexOf("sortBy:pid") >= 0);
    }

    // AM3: every toolbar control has a tooltip, under it.
    function test_toolbarTooltips() {
        const t = make();
        const tip = findAll(t.win.contentItem, i => i.objectName === "toolbarTip")[0];
        verify(tip);
        verify(!tip.visibleNow);
        mouseMove(t.win.tabs, t.win.tabs.width / 2, t.win.tabs.height / 2);
        tryVerify(() => tip.visibleNow, 3000, "the tabs' tooltip");
        compare(tip.text, "Choose the resource the table shows");
        verify(tip.y >= t.win.tabs.mapToItem(t.win.contentItem, 0, t.win.tabs.height).y, "under the control");
        mouseMove(t.win.searchField, t.win.searchField.width / 2, t.win.searchField.height / 2);
        tryVerify(() => tip.text === "Search processes by name, user, command or PID", 3000, "the search field's tooltip");
        verify(tip.visibleNow);
    }

    function test_columnsMenuShowsAnOptionalColumn() {
        const t = make();
        const header = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.ColumnHeader && i.Accessible.name === "% CPU")[0];
        mouseClick(header, 5, 5, Qt.RightButton);
        const menu = t.win.processList.headerMenu;
        tryVerify(() => menu.opened);
        compare(menu.items.map(x => x.id), ["cpuPercent", "wakeUps", "pid", "user"]); // never the name (AM15)
        compare(menu.items.map(x => x.checked), [true, false, true, true]);
        menu.chosen("wakeUps");
        verify(t.backend.calls.indexOf("setColumnShown:wakeUps:true") >= 0);
        tryVerify(() => texts(t.win.contentItem).indexOf("Wake Ups") >= 0);
    }

    // AM5: the tab's figures under the table, the graphs between them; a figure a graph draws has its colour's square.
    function test_summaryFiguresAndGraphs() {
        const t = make();
        const shown = texts(t.win.summary);
        for (const text of ["System:", "5.0 %", "User:", "Idle:", "70.0 %", "Threads:", "1734", "Processes:", "412", "CPU Load"])
            verify(shown.indexOf(text) >= 0, text + " in the summary");
        compare(t.backend.summary.capacity, Tokens.activityHistorySamples);
        const graphs = findAll(t.win.summary, i => i.visible && i.Accessible && i.Accessible.role === Accessible.Graphic);
        compare(graphs.length, 1);
        compare(graphs[0].Accessible.name, "CPU Load");
        verify(t.win.summary.y + t.win.summary.height <= t.win.height + 0.5, "the summary is at the bottom");
        compare(t.win.summary.height, Tokens.activitySummaryHeight);
        verify(t.win.processList.y + t.win.processList.height <= t.win.summary.y + 0.5, "the table ends above it");
        const squares = findAll(t.win.summary, i => i.width === Tokens.activitySwatchSize && i.height === Tokens.activitySwatchSize && i.visible);
        compare(squares.length, 2); // System and User, not Idle
        verify(Qt.colorEqual(squares[0].color, Appearance.colors.activityGraphSystem));
    }

    // AM42: the pop-up above the Disk graph; a new sample leaves it in place (the delegates are kept, not rebuilt).
    function test_graphModePopUp() {
        const t = make();
        t.backend.summary.blocks = t.backend.diskBlocks;
        const combo = findAll(t.win.summary, i => i.objectName === "graphMode-disk")[0];
        verify(combo && combo.visible);
        compare(combo.value, "io");
        combo.picked("data");
        verify(t.backend.calls.indexOf("setGraphMode:disk:data") >= 0);
        t.backend.summary.blocks = t.backend.diskBlocks.map(b => Object.assign({}, b)); // the next sample
        compare(findAll(t.win.summary, i => i.objectName === "graphMode-disk")[0], combo);
    }

    // AM43: the Network tab's line under the table, on that tab only.
    function test_networkNote() {
        const t = make();
        verify(!t.win.networkNote.visible);
        t.backend.tab = "network";
        verify(t.win.networkNote.visible);
        compare(t.win.networkNote.text, "UDP traffic, such as some video, is counted only in the totals below.");
        verify(t.win.processList.y + t.win.processList.height <= t.win.networkNote.y + 0.5);
    }

    function test_rowsAndKeyboard() {
        const t = make();
        const rows = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.Row);
        verify(rows.length >= 3);
        compare(rows[0].Accessible.name, "firefox, % CPU 12.3");
        mouseClick(rows[1], 30, 5);
        compare(t.backend.table.clicks[0], "1:0");
        keyClick(Qt.Key_Down, Qt.ShiftModifier);
        compare(t.backend.table.clicks[1], "move:1:true");
        keyClick(Qt.Key_A, Qt.ControlModifier);
        verify(t.backend.table.clicks.indexOf("selectAll") >= 0);
        keyClick(Qt.Key_C, Qt.ControlModifier);
        verify(t.backend.calls.indexOf("copy") >= 0);
    }

}
