import QtQuick
import QtTest
import Grassfield.Ui
import "activity"

// The activity monitor's window (apps/activity/qml/Main.qml, ADR-0038 step 2a) with a fake backend: the title with the view
// as its subtitle, the five tabs, the live search, the table's headers (sort, the columns menu) and rows, the keyboard and
// the accessible names. The backend's own logic has its gtest cases (tests/unit/activity/window).
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
