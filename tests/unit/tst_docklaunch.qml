import QtQuick
import QtTest
import "../../shell/dock/Launch.js" as Launch

TestCase {
    name: "DockLaunch"

    readonly property int timeout: 12000

    function test_idleLaunchingRunning() {
        compare(Launch.stateOf({}, "foot", 0, 1000, timeout), "idle");
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1500, timeout), "launching");
        // The first window ends the launch, whatever the map says.
        compare(Launch.stateOf({foot: 1000}, "foot", 1, 1500, timeout), "running");
        compare(Launch.stateOf({}, "foot", 2, 1500, timeout), "running");
    }

    function test_timeoutEndsLaunching() {
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1000 + timeout, timeout), "launching");
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1001 + timeout, timeout), "idle");
    }

    function test_clickStartsOnce() {
        const first = Launch.click({}, "foot", 1000, timeout);
        verify(first.start);
        compare(first.launching.foot, 1000);
        // Double click: the second click does nothing and keeps the first start time.
        const second = Launch.click(first.launching, "foot", 1150, timeout);
        verify(!second.start);
        compare(second.launching.foot, 1000);
    }

    function test_clickAfterTimeoutStartsAgain() {
        const again = Launch.click({foot: 1000}, "foot", 1000 + timeout + 1, timeout);
        verify(again.start);
        compare(again.launching.foot, 1000 + timeout + 1);
    }

    function test_otherTilesAreIndependent() {
        const a = Launch.click({}, "foot", 1000, timeout);
        const b = Launch.click(a.launching, "chromium", 1100, timeout);
        verify(b.start);
        compare(Object.keys(b.launching).length, 2);
    }

    function test_clickDoesNotMutateTheMap() {
        const before = {};
        Launch.click(before, "foot", 1, timeout);
        compare(Object.keys(before).length, 0);
    }

    function w(ref, stamp, minimized, here) {
        return {ref: ref, stamp: stamp, minimized: minimized, here: here};
    }

    function test_planAllWindowsHereMostRecentLast() {
        const plan = Launch.activationPlan([w("a", 5, false, true), w("b", 9, false, true), w("c", 1, false, true)]);
        compare(plan.join(","), "c,a,b");
    }

    function test_planOtherDesktopSwitchesToTheMostRecent() {
        const plan = Launch.activationPlan([w("a", 5, false, false), w("b", 9, false, false)]);
        compare(plan.join(","), "b");
    }

    function test_planLeavesWindowsOfOtherDesktopsAlone() {
        const plan = Launch.activationPlan([w("a", 5, false, false), w("b", 2, false, true)]);
        compare(plan.join(","), "b");
    }

    function test_planAllMinimizedRestoresTheMostRecentOnly() {
        const plan = Launch.activationPlan([w("a", 5, true, true), w("b", 9, true, true)]);
        compare(plan.join(","), "b");
    }

    function test_planMinimizedAreNotRaisedWithVisibleOnes() {
        const plan = Launch.activationPlan([w("a", 5, true, true), w("b", 2, false, true)]);
        compare(plan.join(","), "b");
    }

    function test_planWithoutWindows() {
        compare(Launch.activationPlan([]).length, 0);
        compare(Launch.activationPlan(null).length, 0);
    }

    // A-D1 (ADR-0038 AQ5, AM63): End Task after Quit while the setting is on; absent with Option (Force Quit is there), on
    // the Files tile and while the setting is off; after Force Quit for an app that does not respond.
    function test_quitRowsEndTask() {
        compare(Launch.quitRows({alt: false, hung: false, endTask: false, fixed: false}).join(","), "hide,quit");
        compare(Launch.quitRows({alt: false, hung: false, endTask: true, fixed: false}).join(","), "hide,quit,endtask");
        compare(Launch.quitRows({alt: false, hung: true, endTask: true, fixed: false}).join(","), "hide,forcequitHung,endtask");
        compare(Launch.quitRows({alt: true, hung: false, endTask: true, fixed: false}).join(","), "hideOthers,forcequit");
        compare(Launch.quitRows({alt: false, hung: false, endTask: true, fixed: true}).join(","), "hide,quit");
    }

    function wi(ref, title, stamp, minimized) {
        return {ref: ref, title: title, stamp: stamp, minimized: minimized};
    }

    // Window list at the top of an app's Dock menu (macOS): most recent first, a check on the most recent visible window.
    function test_menuWindowsSameTitleIsNumberedInWindowOrder() {
        Launch.resetNumbers();
        const rows = Launch.menuWindows([wi("a", "foot", 1, false), wi("b", "foot", 9, false), wi("c", "", 5, false), wi("d", "App", 2, false)], 40, "App");
        compare(rows.map(r => r.ref).join(","), "b,c,d,a");
        compare(rows.map(r => r.title).join("|"), "foot (2)|App|App (2)|foot");
        compare(rows[0].checked, true);
        compare(rows.filter(r => r.checked).length, 1);
    }

    function test_menuWindowsLongSameTitlesStayDistinct() {
        Launch.resetNumbers();
        const long1 = "builder@archlinux: ~/workspace/grassfield-a";
        const long2 = "builder@archlinux: ~/workspace/grassfield-b";
        const rows = Launch.menuWindows([wi("p", long1, 2, false), wi("q", long2, 1, false)], 40, "App");
        // Elided to the same 40 characters: the number follows the cut and every row is told apart.
        compare(rows.length, 2);
        verify(rows[0].title !== rows[1].title);
        verify(rows.some(r => /\(2\)$/.test(r.title)));
        verify(rows.every(r => r.title.length <= 44));
    }

    function test_menuWindowsNumberStaysWithItsWindow() {
        Launch.resetNumbers();
        const all = [wi("x", "foot", 3, false), wi("y", "foot", 2, false), wi("z", "foot", 1, false)];
        let rows = Launch.menuWindows(all, 40, "App");
        compare(rows.map(r => r.title).join("|"), "foot|foot (2)|foot (3)");
        // The first window closes: the others keep their numbers.
        rows = Launch.menuWindows(all.slice(1), 40, "App");
        compare(rows.map(r => r.title).join("|"), "foot (2)|foot (3)");
        // Only one left: no number at all.
        rows = Launch.menuWindows([all[2]], 40, "App");
        compare(rows[0].title, "foot");
        Launch.resetNumbers();
    }

    function test_menuWindowsOtherAppsDoNotRenumber() {
        Launch.resetNumbers();
        const a = [wi("a1", "foot", 2, false), wi("a2", "foot", 1, false)];
        compare(Launch.menuWindows(a, 40, "Foot", "foot").map(r => r.title).join("|"), "foot|foot (2)");
        // Another app's menu, with a window of the same title.
        compare(Launch.menuWindows([wi("b1", "foot", 3, false), wi("b2", "foot", 2, false), wi("b3", "foot", 1, false)], 40, "Kitty", "kitty").map(r => r.title).join("|"), "foot|foot (2)|foot (3)");
        compare(Launch.menuWindows(a, 40, "Foot", "foot").map(r => r.title).join("|"), "foot|foot (2)");
        Launch.resetNumbers();
    }

    function test_menuWindowsLiteralLabelIsNotDuplicated() {
        Launch.resetNumbers();
        const rows = Launch.menuWindows([wi("p", "foot", 3, false), wi("q", "foot", 2, false), wi("r", "foot (2)", 1, false)], 40, "App", "t");
        compare(rows.length, 3);
        const titles = rows.map(r => r.title);
        compare(new Set(titles).size, 3, titles.join("|"));
        verify(titles.indexOf("foot (2)") >= 0);
        Launch.resetNumbers();
    }

    function test_menuWindowsRecentFirstWithCheck() {
        const rows = Launch.menuWindows([wi("a", "Old", 1, false), wi("b", "New", 9, false), wi("c", "Mid", 5, false)], 40, "App");
        compare(rows.map(r => r.ref).join(","), "b,c,a");
        compare(rows.map(r => r.checked).join(","), "true,false,false");
    }

    function test_menuWindowsMinimizedIsMarkedAndNeverChecked() {
        const rows = Launch.menuWindows([wi("a", "Visible", 1, false), wi("b", "Hidden away", 9, true)], 40, "App");
        compare(rows[0].ref, "b");
        verify(rows[0].minimized);
        verify(!rows[0].checked);
        verify(rows[1].checked);
    }

    function test_menuWindowsAllMinimizedNoCheck() {
        const rows = Launch.menuWindows([wi("a", "A", 1, true), wi("b", "B", 2, true)], 40, "App");
        compare(rows.filter(r => r.checked).length, 0);
    }

    function test_menuWindowsTitleElidedAndNormalised() {
        const rows = Launch.menuWindows([wi("a", "x".repeat(60), 1, false), wi("b", "  two\n  lines  ", 0, false), wi("c", "", 0, false)], 40, "App");
        compare(rows[0].title.length, 40);
        verify(rows[0].title.endsWith("…"));
        compare(rows[1].title, "two lines");
        // An empty title falls back to the app name, as the Window menu does.
        compare(rows[2].title, "App");
    }

    function test_forceQuitPidsAreDistinctAndPlain() {
        compare(Launch.forceQuitPids([4242, 4242, 4300]).join(","), "4242,4300");
        // Unknown (0), init (1), negative and fractional PIDs are never targets.
        compare(Launch.forceQuitPids([0, 1, -5, 2.5, 77]).join(","), "77");
        compare(Launch.forceQuitPids([]).length, 0);
        compare(Launch.forceQuitPids(null).length, 0);
    }

    // Options rows (macOS): Remove from Dock for every Dock app that is not running, pinned or recent.
    function test_optionRows() {
        const rows = (fixed, running, pinned, recent) => Launch.optionRows({fixed: fixed, running: running, pinned: pinned, recent: recent});
        compare(JSON.stringify(rows(false, false, true, false)), JSON.stringify({keep: false, remove: true}));
        compare(JSON.stringify(rows(false, false, false, true)), JSON.stringify({keep: true, remove: true}));
        compare(JSON.stringify(rows(false, true, true, false)), JSON.stringify({keep: true, remove: false}));
        compare(JSON.stringify(rows(false, true, false, false)), JSON.stringify({keep: true, remove: false}));
        compare(JSON.stringify(rows(true, false, true, false)), JSON.stringify({keep: false, remove: false}));
        compare(JSON.stringify(Launch.optionRows(null)), JSON.stringify({keep: false, remove: false}));
    }

    function test_menuWindowsEmpty() {
        compare(Launch.menuWindows([], 40, "App").length, 0);
        compare(Launch.menuWindows(null, 40, "App").length, 0);
    }

    function cw(ref, minimized, here, focused, stamp, fullscreen) {
        return {ref: ref, minimized: minimized, here: here, focused: focused, fullscreen: !!fullscreen, stamp: stamp};
    }

    function test_clickFrontmostMinimizesAllVisible() {
        const plan = Launch.clickPlan([cw("a", false, true, false, 5), cw("b", false, true, true, 9), cw("c", false, false, false, 7), cw("d", true, true, false, 1)], true);
        compare(plan.action, "minimize");
        compare(plan.refs, ["a", "b"]);
    }

    function test_clickFrontmostSkipsFullscreen() {
        compare(Launch.clickPlan([cw("a", false, true, true, 5, true), cw("b", false, true, false, 9)], true).refs, ["b"]);
        const only = Launch.clickPlan([cw("a", false, true, true, 5, true)], true);
        compare(only.action, "forward");
    }

    function test_clickAllMinimizedRestoresAll() {
        const plan = Launch.clickPlan([cw("a", true, true, false, 5), cw("b", true, true, false, 9), cw("c", true, true, false, 2)], true);
        compare(plan.action, "restore");
        compare(plan.refs, ["c", "a", "b"]);
    }

    function test_clickNotFrontmostComesForward() {
        const plan = Launch.clickPlan([cw("a", false, true, false, 5), cw("b", false, true, false, 9)], true);
        compare(plan.action, "forward");
        compare(plan.refs, ["a", "b"]);
        // Focused window on another Desktop: the app is not frontmost here.
        compare(Launch.clickPlan([cw("a", false, false, true, 5), cw("b", false, true, false, 9)], true).action, "forward");
        // Some minimized, none focused: forward (visible ones come forward).
        compare(Launch.clickPlan([cw("a", true, true, false, 5), cw("b", false, true, false, 9)], true).action, "forward");
    }

    function test_clickRestoreStaysOnThisDesktop() {
        // A minimized here, B visible on another Desktop (here false): restore A, do not switch to B.
        const plan = Launch.clickPlan([cw("a", true, true, false, 5), cw("b", false, false, false, 9)], true);
        compare(plan.action, "restore");
        compare(plan.refs, ["a"]);
        // Nothing minimized and nothing here: today's switch to the other Desktop.
        compare(Launch.clickPlan([cw("b", false, false, false, 9)], true).action, "forward");
    }

    function test_clickSplitViewFallsBackToForward() {
        const w = cw("a", false, true, true, 5);
        w.split = true;
        const plan = Launch.clickPlan([w], true);
        compare(plan.action, "forward");
        compare(plan.refs, ["a"]);
        // A split member next to a free window: only the free one minimizes.
        const f = cw("b", false, true, false, 9);
        compare(Launch.clickPlan([w, f], true).refs, ["b"]);
    }

    function test_clickSettingOffIsMacos() {
        compare(Launch.clickPlan([cw("a", false, true, true, 5), cw("b", false, true, false, 9)], false), {action: "forward", refs: ["a", "b"]});
        compare(Launch.clickPlan([cw("a", true, true, false, 5), cw("b", true, true, false, 9)], false), {action: "forward", refs: ["b"]});
        compare(Launch.clickPlan([], true).refs.length, 0);
    }
}
