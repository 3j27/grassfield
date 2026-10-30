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

    function test_aPinnedAppWithOnlyAQuickLookIsNotRunning() {
        const list = DockModel.merge(["org.grassfield.Preview"], [{appId: "org.grassfield.Preview.Glance", ref: "g1"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows, []);
    }
}
