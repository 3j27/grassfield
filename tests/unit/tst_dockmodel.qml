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
}
