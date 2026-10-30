import QtQuick
import QtTest
import Grassfield.Ui
import "activity"

// The activity monitor's window (apps/activity/qml/Main.qml, ADR-0038 steps 2a to 2c) with a fake backend: the title with
// the view as its subtitle, the five tabs, the live search, the table's headers (sort, the columns menu) and rows, the
// keyboard and the accessible names, the summary's figures and graphs, the Disk pop-up and the Network tab's line, the
// Stop button, the action and context menus and the sheets of Quit, Force Quit and Send Signal. The backend's own logic
// has its gtest cases (tests/unit/activity/window).
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

    // Each item once: a ListView's rows are reached through its children and through its contentItem.
    function findAll(item, pred, out) {
        out = out || [];
        if (!item)
            return out;
        if (pred(item) && out.indexOf(item) < 0)
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
        for (const text of ["System:", "5.0%", "User:", "Idle:", "70.0%", "Threads:", "1734", "Processes:", "412", "CPU Load"])
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

    // AM5, AM8: a value below 0 is a gap: the fill stops there and starts again after it, never drawn as zero.
    function test_graphGaps() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/activity/qml/Graph.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const g = createTemporaryObject(comp, testCase, {width: 100, height: 50, capacity: 5,
            graph: {style: "area", max: 1, series: [{values: [0.5, -1, 0.2, 0.4, -1], color: "activityGraphUser"}]}});
        verify(g);
        compare(g.lower.length, 2); // [0.5] and [0.2, 0.4]
        const second = g.lower[1];
        verify(second.every(p => p.y >= 0 && p.y <= 50));
        g.graph = {style: "mirrored", max: 10, series: [{values: [5, 10], color: "activityGraphRead"}, {values: [-1, 5], color: "activityGraphWrite"}]};
        compare(g.lower.length, 1);
        compare(g.upper.length, 1);
        verify(g.lower[0].every(p => p.y <= 25.001), "reads above the middle");
        verify(g.upper[0].every(p => p.y >= 24.999), "writes below it");
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
        // Open, then the next sample: the same pop-up, still open (a rebuilt delegate would close it).
        combo.popup.open();
        tryVerify(() => combo.popup.opened);
        t.backend.summary.blocks = t.backend.diskBlocks.map(b => Object.assign({}, b));
        wait(50); // a delegate replaced would be gone by now
        const now = findAll(t.win.summary, i => i.objectName === "graphMode-disk");
        compare(now.length, 1);
        compare(now[0], combo);
        verify(combo.popup.opened);
        combo.popup.close();
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

    // AM13, AM49: an outline's rows are indented by level; the triangle and Right/Left open and close a row; a GPU's header
    // has no icon.
    function test_outlineRows() {
        const t = make();
        const r = (name, depth, expandable, group) => Object.assign(t.backend.row(name, "1.0", group ? "" : "10"), {depth: depth, expandable: expandable, expanded: true, group: group});
        t.backend.view = "tree";
        t.backend.table = t.backend.makeTable([r("systemd", 0, true, false), r("Hyprland", 1, false, false), r("Intel UHD Graphics", 0, true, true)]);
        const rowsNow = () => findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.Row);
        tryVerify(() => rowsNow().length === 3 && rowsNow()[2].Accessible.name.startsWith("Intel"));
        const rows = rowsNow().sort((a, b) => a.y - b.y);
        // Qt 6.12 states the disclosure to a screen reader, Qt 6.11.2 cannot (ProcessList sets it only where it exists, and
        // A-W1 checks it on 6.12): the rows load either way. The guard's test sees a state Qt has and not one it lacks.
        verify("checked" in rows[0].Accessible && !("disclosed" in rows[0].Accessible));
        if ("expanded" in rows[0].Accessible) {
            verify(rows[0].Accessible.expandable);
            verify(rows[0].Accessible.expanded);
            verify(!rows[1].Accessible.expandable);
        }
        verify(!rows[2].Accessible.selectable, "a GPU's header is not a process");
        const triangles = findAll(t.win.contentItem, i => i.objectName === "disclosure" && i.visible);
        compare(triangles.length, 2); // systemd's and the header's
        const glyphs = findAll(rows[1], i => i.source !== undefined && String(i.source).startsWith("image://icon/") && i.visible);
        const first = findAll(rows[0], i => i.source !== undefined && String(i.source).startsWith("image://icon/") && i.visible);
        compare(glyphs[0].x - first[0].x, Tokens.activityTreeIndent, "one level further in");
        compare(findAll(rows[2], i => i.source !== undefined && String(i.source).startsWith("image://icon/") && i.visible).length, 0);
        const p = triangles[0].mapToItem(rows[0], triangles[0].width / 2, triangles[0].height / 2);
        mouseClick(rows[0], p.x, p.y);
        verify(t.backend.table.clicks.indexOf("toggle:0") >= 0);
        compare(t.backend.table.clicks.filter(c => c.startsWith("0:")).length, 0, "the triangle does not select");
        mouseClick(rows[1], 120, 5);
        keyClick(Qt.Key_Left);
        verify(t.backend.table.clicks.indexOf("expanded:1:false") >= 0);
        keyClick(Qt.Key_Right);
        verify(t.backend.table.clicks.indexOf("expanded:1:true") >= 0);
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

    // ---- Step 2c: Quit, Force Quit and Send Signal (AM50 to AM56) -----------------------------------------------------
    function buttons(sheet) {
        return findAll(sheet, i => i.text !== undefined && i.clicked !== undefined && i.visible && i.width > 0);
    }
    function buttonNamed(sheet, text) {
        return buttons(sheet).find(b => b.text === text);
    }
    function calls(t) {
        return t.backend.calls.filter(c => !c.startsWith("saveSize"));
    }

    // AM50: the Stop button follows the selection; its tooltip says why it is off.
    function test_stopButtonFollowsTheSelection() {
        const t = make();
        verify(!t.win.stopButton.enabled);
        t.backend.actions.refusal = "You can only quit your own processes.";
        const tip = findAll(t.win.contentItem, i => i.objectName === "toolbarTip")[0];
        mouseMove(t.win.stopButton, t.win.stopButton.width / 2, t.win.stopButton.height / 2);
        tryCompare(tip, "text", "You can only quit your own processes.");
        t.backend.actions.canQuit = true;
        t.backend.actions.refusal = "";
        verify(t.win.stopButton.enabled);
        compare(tip.text, "Quit the selected processes");
        // A disabled Stop opens nothing (View > Quit Process's key too).
        t.backend.actions.canQuit = false;
        keyClick(Qt.Key_Q, Qt.ControlModifier | Qt.AltModifier);
        verify(!t.win.sheets.shown);
        compare(calls(t).filter(c => c.startsWith("prepare")).length, 0);
    }

    // AM50, AM52: the sheet's title and buttons; Quit is the default (Return); the sheet closes and lets its processes go.
    function test_quitSheet() {
        const t = make();
        t.backend.actions.canQuit = true;
        mouseClick(t.win.stopButton);
        const sheet = t.win.sheets.quitSheet;
        verify(sheet.shown);
        compare(sheet.title, "Are you sure you want to quit this process?");
        compare(sheet.message, "“foot” (PID 2001)");
        verify(buttonNamed(sheet, "Force Quit") && buttonNamed(sheet, "Cancel") && buttonNamed(sheet, "Quit"));
        keyClick(Qt.Key_Return);
        verify(!sheet.shown);
        compare(calls(t), ["prepare:quit", "quit", "release"]);
        // Several processes; Force Quit; Esc cancels.
        t.backend.actions.sheet = Object.assign({}, t.backend.actions.sheet, {count: 3});
        keyClick(Qt.Key_Q, Qt.ControlModifier | Qt.AltModifier);
        compare(sheet.title, "Are you sure you want to quit these 3 processes?");
        compare(sheet.message, "");
        mouseClick(buttonNamed(sheet, "Force Quit"));
        verify(!sheet.shown);
        compare(calls(t).slice(3), ["prepare:quit", "forceQuit", "release"]);
        keyClick(Qt.Key_Q, Qt.ControlModifier | Qt.AltModifier);
        keyClick(Qt.Key_Escape);
        verify(!sheet.shown);
        compare(calls(t).slice(6), ["prepare:quit", "release"]);
    }

    // AM52, AM53: Quit that cannot be done safely leaves Force Quit alone, which Return does not trigger; an error stays shown.
    function test_quitUnsafeLeavesForceQuit() {
        const t = make();
        t.backend.actions.canQuit = true;
        t.backend.actions.quitResult = {done: false, unsafe: true, error: "The process couldn't be quit safely."};
        mouseClick(t.win.stopButton);
        const sheet = t.win.sheets.quitSheet;
        keyClick(Qt.Key_Return);
        verify(sheet.shown);
        compare(sheet.errorText, "The process couldn't be quit safely.");
        compare(buttons(sheet).map(b => b.text).filter(x => x === "Quit").length, 0);
        verify(buttonNamed(sheet, "Force Quit") && buttonNamed(sheet, "Cancel"));
        keyClick(Qt.Key_Return); // cancels: a forced quit is never the default
        verify(!sheet.shown);
        compare(calls(t).indexOf("forceQuit"), -1);
        // Again, and Force Quit fails: its message is shown, the sheet stays.
        t.backend.actions.forceQuitResult = {done: false, unsafe: false, error: "The process couldn't be quit."};
        mouseClick(t.win.stopButton);
        keyClick(Qt.Key_Return);
        mouseClick(buttonNamed(sheet, "Force Quit"));
        verify(sheet.shown);
        compare(sheet.errorText, "The process couldn't be quit.");
        verify(calls(t).indexOf("forceQuit") >= 0);
        keyClick(Qt.Key_Escape);
    }

    // AM54: a session process gets the warning first; Cancel (the default) stops there, Continue shows the action's sheet.
    function test_sessionProcessWarnsFirst() {
        const t = make();
        t.backend.actions.canQuit = true;
        t.backend.actions.canSignal = true;
        t.backend.actions.sheet = Object.assign({}, t.backend.actions.sheet, {name: "Hyprland", session: "Hyprland"});
        mouseClick(t.win.stopButton);
        const warning = t.win.sheets.sessionSheet;
        verify(warning.shown);
        verify(!t.win.sheets.quitSheet.shown);
        compare(warning.title, "Quitting “Hyprland” may end your session or stop part of it.");
        keyClick(Qt.Key_Return);
        verify(!warning.shown);
        verify(!t.win.sheets.quitSheet.shown);
        compare(calls(t), ["prepare:quit", "release"]);
        mouseClick(t.win.stopButton);
        mouseClick(buttonNamed(warning, "Continue"));
        verify(t.win.sheets.quitSheet.shown);
        keyClick(Qt.Key_Escape);
        // Send Signal's warning, then its sheet.
        t.win.sheets.openSignal();
        compare(warning.title, "Sending a signal to “Hyprland” may end your session or stop part of it.");
        mouseClick(buttonNamed(warning, "Continue"));
        verify(t.win.sheets.signalSheet.shown);
        keyClick(Qt.Key_Escape);
    }

    // AM55: from the action menu; Terminate first chosen; the signal picked is sent; the app itself is refused.
    function test_sendSignal() {
        const t = make();
        t.backend.actions.canQuit = true;
        t.backend.actions.canSignal = true;
        t.backend.table.selectedCount = 1;
        mouseClick(t.win.moreButton);
        verify(t.win.actionMenu.opened);
        compare(t.win.actionMenu.items.filter(i => !i.separator).map(i => i.text), ["Quit Process", "Send Signal to Process…", "Copy"]);
        compare(t.win.actionMenu.items[0].shortcut, "Ctrl+Alt+Q");
        t.win.actionMenu.chosen("signal");
        t.win.actionMenu.close();
        const sheet = t.win.sheets.signalSheet;
        tryVerify(() => sheet.shown);
        compare(sheet.title, "Choose a signal to send to “foot” (PID 2001).");
        compare(t.win.sheets.signalPicker.displayText, "Terminate (SIGTERM)");
        compare(t.win.sheets.signalPicker.model.length, 11);
        t.win.sheets.signalPicker.picked("10");
        compare(t.win.sheets.signalPicker.displayText, "User Defined 1 (SIGUSR1)");
        mouseClick(buttonNamed(sheet, "Send"));
        verify(!sheet.shown);
        compare(calls(t), ["prepare:signal", "send:10", "release"]);
        // The app's own row: refused before anything is sent.
        t.backend.actions.sheet = Object.assign({}, t.backend.actions.sheet, {self: true});
        t.win.sheets.openSignal();
        compare(sheet.errorText, "This app can't force quit itself.");
        verify(!buttonNamed(sheet, "Send").enabled);
        keyClick(Qt.Key_Return);
        verify(sheet.shown);
        keyClick(Qt.Key_Escape);
        compare(calls(t).filter(c => c.startsWith("send")).length, 1);
    }

    // AM50: a row's context menu selects the row under the pointer, then shows the action menu there.
    function test_rowContextMenu() {
        const t = make();
        const rows = findAll(t.win.contentItem, i => i.Accessible && i.Accessible.role === Accessible.Row).sort((a, b) => a.y - b.y);
        mouseClick(rows[2], 40, 5, Qt.RightButton);
        compare(t.backend.table.clicks[0], "2:0");
        verify(t.win.actionMenu.opened);
        compare(t.win.actionMenu.items.length, 4);
        t.win.actionMenu.close();
    }

    // AM54: the app's own row quit: the window closes.
    function test_selfQuitClosesTheWindow() {
        const t = make();
        verify(t.win.visible);
        t.backend.actions.closeWindowRequested();
        verify(!t.win.visible);
    }
}
