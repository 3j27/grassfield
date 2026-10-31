import QtQuick
import QtTest
import "../../shell/platform/QuickLook.js" as QuickLook
import "../../shell/dock/DockModel.js" as DockModel
import "../../shell/switcher/SwitcherModel.js" as Switcher

// Capture defect 7: Glance (the quick look panel of Preview, app id org.grassfield.Preview.Glance) belongs to the app that opened
// it. It is no Dock tile and no switcher app. (The bar and the menus staying with the opener are Compositor.frontToplevel and
// MenuBridge.updateFocus, checked by the nested pass.)
TestCase {
    name: "QuickLook"

    readonly property var entries: ({
            "org.grassfield.Files": {id: "org.grassfield.Files", name: "Files", icon: "org.grassfield.Files"},
            "org.grassfield.Preview": {id: "org.grassfield.Preview", name: "Preview", icon: "org.grassfield.Preview"}
        })

    function lookup(id) {
        return entries[id] !== undefined ? entries[id] : null;
    }

    function test_theGlanceIdIsAQuickLook() {
        verify(QuickLook.isQuickLook("org.grassfield.Preview.Glance"));
        verify(QuickLook.isQuickLook("org.grassfield.preview.glance"));
        verify(QuickLook.isQuickLook("org.grassfield.Preview.Glance.desktop"));
    }

    function test_otherWindowsAreNot() {
        verify(!QuickLook.isQuickLook("org.grassfield.Preview"));
        verify(!QuickLook.isQuickLook("org.grassfield.Files"));
        verify(!QuickLook.isQuickLook("org.grassfield.Preview.Glances"));
        verify(!QuickLook.isQuickLook(""));
        verify(!QuickLook.isQuickLook(undefined));
        verify(!QuickLook.isQuickLook(null));
    }

    function test_noDockTileForAQuickLook() {
        const running = [{appId: "org.grassfield.Files", ref: "f1"}, {appId: "org.grassfield.Preview.Glance", ref: "g1"}];
        const list = DockModel.merge([], running, lookup);
        compare(list.map(a => a.key), ["org.grassfield.Files"]);
        compare(list[0].windows, ["f1"]);
    }

    function test_theOpenersTileKeepsItsOwnWindows() {
        const running = [{appId: "org.grassfield.Preview", ref: "p1"}, {appId: "org.grassfield.Preview.Glance", ref: "g1"}, {appId: "org.grassfield.Preview", ref: "p2"}];
        const list = DockModel.merge([], running, lookup);
        compare(list.length, 1);
        compare(list[0].windows, ["p1", "p2"]);
    }

    function test_noSwitcherAppForAQuickLook() {
        const windows = [{appId: "org.grassfield.Files", ref: "f1"}, {appId: "org.grassfield.Preview.Glance", ref: "g1"}];
        const apps = Switcher.apps(DockModel.merge, windows, lookup, () => 0, []);
        compare(apps.map(a => a.key), ["org.grassfield.Files"]);
    }

    // Who a quick look belongs to (review MINOR 2 and the re-review's regression): the sequences of a session through QuickLook.frontAfter.
    function run(events) {
        let front = "window";
        for (const e of events)
            front = QuickLook.frontAfter(front, e);
        return front;
    }

    readonly property var held: ({type: "desktopHeld"})
    readonly property var windowFocus: ({type: "regularFocused"})
    readonly property var settledOnWindow: ({type: "settled", focusedRegular: true})
    readonly property var settledOnOther: ({type: "settled", focusedRegular: false})

    function test_desktopThenSpaceIsTheDesktop() {
        compare(run([windowFocus, held]), "desktop", "a click on the desktop, then Space: the desktop is the opener");
        // Glance maps and is clicked: the desktop lets go, the focus lands on Glance (not a regular window).
        compare(run([windowFocus, held, settledOnOther]), "desktop", "the desktop lets go for a quick look: it stays the opener");
    }

    // The regression: Files, the desktop, Files again. Hyprland kept Files active all along, so no focus change is announced; the
    // desktop letting go with a regular window focused is what says the user is back in it.
    function test_filesDesktopFilesThenSpaceIsFiles() {
        compare(run([windowFocus, held, settledOnWindow]), "window");
        compare(run([windowFocus, held, settledOnWindow, held, settledOnWindow]), "window", "and again, any number of times");
    }

    function test_aWindowFocusedWhileTheDesktopIsInFrontTakesItBack() {
        compare(run([held, windowFocus]), "window");
    }

    function test_theOpenerSurvivesWhateverElseHappens() {
        compare(run([held, settledOnOther, settledOnOther]), "desktop", "a shell popup coming and going changes nothing");
        compare(run([held, {type: "nonsense"}]), "desktop");
        compare(QuickLook.frontAfter("window", undefined === 1 ? null : {type: "settled"}), "window", "no focusedRegular: unchanged");
    }

    function test_aPinnedAppWithOnlyAQuickLookIsNotRunning() {
        const list = DockModel.merge(["org.grassfield.Preview"], [{appId: "org.grassfield.Preview.Glance", ref: "g1"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows, []);
    }
}
