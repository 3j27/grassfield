import QtQuick
import QtTest
import "../../shell/dock/DockModel.js" as DockModel

TestCase {
    name: "DockModel"

    readonly property var entries: ({
        "foot": {id: "foot", name: "Foot", icon: "foot"},
        "chromium": {id: "chromium", name: "Chromium", icon: "chromium"},
        "org.gnome.Nautilus": {id: "org.gnome.Nautilus", name: "Files", icon: "nautilus"}
    })

    function lookup(id) {
        // Case-insensitive like the heuristic lookup of desktop entries.
        for (const key in entries) {
            if (key.toLowerCase() === id.toLowerCase())
                return entries[key];
        }
        return null;
    }

    function test_pinnedKeepOrderAndSkipUnknown() {
        const list = DockModel.merge(["chromium", "ghost", "foot"], [], lookup);
        compare(list.map(i => i.key).join(","), "chromium,foot");
        verify(list.every(i => i.pinned && i.windows.length === 0));
    }

    function test_runningPinnedAppAttachesWindows() {
        const list = DockModel.merge(["foot"], [{appId: "foot", ref: "w1"}, {appId: "Foot", ref: "w2"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.join(","), "w1,w2");
        verify(list[0].pinned);
    }

    function test_runningUnpinnedAppsAppendedAfterPinned() {
        const list = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}, {appId: "mystery", ref: "m"}], lookup);
        compare(list.map(i => i.key).join(","), "foot,chromium,mystery");
        verify(!list[1].pinned);
        compare(list[2].name, "mystery");
        compare(list[2].entry, null);
    }

    function test_emptyAppIdIgnoredAndPinsDeduplicated() {
        const list = DockModel.merge(["foot", "FOOT", "foot"], [{appId: "", ref: "x"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.length, 0);
    }

    function test_tailIsSeparatorThenTrash() {
        const list = DockModel.withTail(DockModel.merge(["foot"], [], lookup));
        compare(list.map(i => i.kind).join(","), "app,separator,trash");
        compare(DockModel.withTail([]).map(i => i.kind).join(","), "separator,trash");
    }

    function test_pinUnpin() {
        compare(DockModel.pin(["a"], "b").join(","), "a,b");
        compare(DockModel.pin(["a"], "a").join(","), "a");
        compare(DockModel.pin(undefined, "a").join(","), "a");
        compare(DockModel.unpin(["a", "b"], "a").join(","), "b");
        // Pin written as an alias still unpins by resolved key.
        compare(DockModel.unpinKey(["FOOT", "chromium"], "foot", lookup).join(","), "chromium");
    }

    function test_badgeCounts() {
        const item = {kind: "app", key: "org.gnome.Nautilus", name: "Files"};
        const history = [{appName: "files"}, {appName: "Files"}, {appName: "org.gnome.nautilus"}, {appName: "Other"}];
        compare(DockModel.badgeCount(history, item), 3);
        compare(DockModel.badgeCount(history, {kind: "trash"}), 0);
        compare(DockModel.badgeCount(undefined, item), 0);
        compare(DockModel.badgeText(0), "");
        compare(DockModel.badgeText(7), "7");
        compare(DockModel.badgeText(120), "99+");
    }

    function test_recents() {
        compare(DockModel.pushRecent(["a", "b", "c"], "b", 3).join(","), "b,a,c");
        compare(DockModel.pushRecent(["a", "b", "c"], "d", 3).join(","), "d,a,b");
        const apps = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.withRecents(apps, ["foot", "chromium", "ghost", "org.gnome.Nautilus"], lookup, 3);
        compare(out.map(i => i.key).join(","), "foot,chromium,org.gnome.Nautilus");
        verify(out[2].recent === true && !out[2].pinned && out[2].windows.length === 0);
        compare(DockModel.withRecents(apps, ["org.gnome.Nautilus"], lookup, 0).length, 2);
    }

    function items3() {
        return DockModel.withTail(DockModel.merge(["foot", "chromium"], [{appId: "org.gnome.Nautilus", ref: "n"}], lookup));
    }

    function test_reorderPinned() {
        const r = DockModel.reorder(items3(), 0, 1);
        verify(r.changed);
        compare(r.pinned.join(","), "chromium,foot");
        verify(!DockModel.reorder(items3(), 1, 1).changed);
    }

    function test_reorderUnpinnedBecomesPinnedOnlyBeforePinned() {
        const a = DockModel.reorder(items3(), 2, 0);
        compare(a.pinned.join(","), "org.gnome.Nautilus,foot,chromium");
        verify(a.changed);
        const b = DockModel.reorder(items3(), 2, 2);
        verify(!b.changed);
        compare(DockModel.reorder(items3(), 9, 0).changed, false);
    }

    function test_dropSlotAndDragOut() {
        compare(DockModel.dropSlot([30, 90, 150, 220], 3, 100), 1);
        compare(DockModel.dropSlot([30, 90, 150, 220], 3, 400), 2);
        verify(DockModel.draggedOut(-70, 60));
        verify(!DockModel.draggedOut(-20, 60));
    }

    function test_commandWithFiles() {
        compare(DockModel.commandWithFiles(["gimp", "%U"], ["/a", "/b"]).join(" "), "gimp /a /b");
        compare(DockModel.commandWithFiles(["viewer", "%f"], ["/a", "/b"]).join(" "), "viewer /a");
        compare(DockModel.commandWithFiles(["foot", "--x"], ["/a"]).join(" "), "foot --x /a");
        compare(DockModel.commandWithFiles(["a", "%i", "100%%", "%F"], ["/a"]).join(" "), "a 100% /a");
    }

    function test_bounceKeys() {
        const items = DockModel.merge(["foot", "chromium"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.bounceKeys({foot: 1000, chromium: 1000, old: 0}, items, 5000, 10000);
        compare(Object.keys(out).join(","), "foot");
        compare(Object.keys(DockModel.bounceKeys({foot: 1000}, items, 20000, 10000)).length, 0);
    }
}
