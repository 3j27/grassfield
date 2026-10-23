import QtQuick
import QtTest
import "../../shell/dock/Stacks.js" as Stacks
import "../../shell/dock/DockModel.js" as DockModel

// Dock folder stacks (REQ-DOCK-PAR-d7): pure logic of shell/dock/Stacks.js and the folder tiles of DockModel.
TestCase {
    name: "DockStacks"

    readonly property string rs: "\x1e"
    readonly property string us: "\x1f"

    function record(born, modified, changed, type, name) {
        return [born, modified, changed, type, name].join(us) + rs;
    }

    function test_folderListIsCleanAbsoluteAndDistinct() {
        const list = Stacks.folderList(["~/Downloads", "/home/u/Downloads/", "relative", "/a/../etc", 5, "", "/", "/srv//x/./y", "~"], "/home/u", 12);
        compare(list.join(","), "/home/u/Downloads,/srv/x/y,/home/u");
        compare(Stacks.folderList(null, "/home/u", 12).length, 0);
        compare(Stacks.folderList(["/a", "/b", "/c"], "/h", 2).join(","), "/a,/b");
    }

    function test_optionsDefaultsAndValidation() {
        const d = Stacks.optionsFor({}, "/a");
        compare(d.sort, "dateAdded");
        compare(d.view, "automatic");
        compare(d.display, "stack");
        const o = Stacks.optionsFor({"/a": {sort: "bogus", view: "list", display: 3}}, "/a");
        compare(o.sort, "dateAdded");
        compare(o.view, "list");
        compare(o.display, "stack");
        compare(Stacks.optionsFor(null, "/a").view, "automatic");
    }

    function test_withOptionKeepsOnlyNonDefaults() {
        let all = Stacks.withOption({}, "/a", "view", "grid");
        compare(all["/a"].view, "grid");
        all = Stacks.withOption(all, "/b", "sort", "name");
        compare(Object.keys(all).sort().join(","), "/a,/b");
        all = Stacks.withOption(all, "/a", "view", "automatic");
        compare(Object.keys(all).join(","), "/b");
        // junk: relative keys and unknown values never get stored
        all = Stacks.withOption({"rel": {view: "fan"}}, "/c", "sort", "nonsense");
        compare(Object.keys(all).length, 0);
    }

    function test_parseListing() {
        const text = record("100.5", "200.5", "300.5", "d", "Sub")
            + record("0", "50", "60", "f", "a b.txt")
            + record("", "10", "10", "f", ".hidden")
            + record("1", "2", "3", "f", "x" + us + "y")
            + "garbage" + rs;
        const e = Stacks.parseListing(text, "/home/u/Downloads/");
        compare(e.length, 3);
        compare(e[0].path, "/home/u/Downloads/Sub");
        verify(e[0].isDir);
        compare(e[0].created, 100.5);
        compare(e[0].added, 300.5);
        // no birth time: created falls back to the modified time
        compare(e[1].created, 50);
        compare(e[1].added, 60);
        verify(!e[1].isDir);
        compare(e[2].name, "x" + us + "y");
        compare(Stacks.parseListing("", "/a").length, 0);
        compare(Stacks.parseListing(null, "/a").length, 0);
    }

    readonly property var sample: [
        {name: "b.png", isDir: false, created: 10, modified: 30, added: 20},
        {name: "A.txt", isDir: false, created: 30, modified: 10, added: 10},
        {name: "Dir", isDir: true, created: 20, modified: 20, added: 30},
        {name: "c", isDir: false, created: 5, modified: 5, added: 5}
    ]

    function names(sort) {
        return Stacks.sortEntries(sample, sort).map(e => e.name).join(",");
    }

    function test_sortOrders() {
        compare(names("name"), "A.txt,b.png,c,Dir");
        compare(names("dateAdded"), "Dir,b.png,A.txt,c");
        compare(names("dateModified"), "b.png,Dir,A.txt,c");
        compare(names("dateCreated"), "A.txt,Dir,b.png,c");
        // kind: folders first, then by extension, files without one last
        compare(names("kind"), "Dir,b.png,A.txt,c");
        compare(names("bogus"), names("dateAdded"));
        compare(Stacks.sortEntries(null, "name").length, 0);
    }

    function test_sortDoesNotModifyItsInput() {
        const copy = JSON.stringify(sample);
        Stacks.sortEntries(sample, "name");
        compare(JSON.stringify(sample), copy);
    }

    function test_automaticViewIsFanThenGrid() {
        compare(Stacks.resolveView("automatic", 3, 9), "fan");
        compare(Stacks.resolveView("automatic", 9, 9), "fan");
        compare(Stacks.resolveView("automatic", 10, 9), "grid");
        compare(Stacks.resolveView("list", 2, 9), "list");
        compare(Stacks.resolveView("grid", 2, 9), "grid");
        compare(Stacks.resolveView(undefined, 2, 9), "fan");
    }

    function test_fanLayout() {
        const l = Stacks.fanLayout(5, 56, 80);
        compare(l.length, 5);
        compare(l[0].out, 0);
        compare(l[0].side, 0);
        compare(l[4].out, 224);
        compare(l[4].side, 80);
        verify(l[2].side < 40, "the curve is quadratic, the middle has drifted less than half");
        compare(Stacks.fanLayout(1, 56, 80)[0].side, 0);
        compare(Stacks.fanLayout(0, 56, 80).length, 0);
    }

    function test_gridColumns() {
        compare(Stacks.gridColumns(1, 5), 1);
        compare(Stacks.gridColumns(10, 5), 4);
        compare(Stacks.gridColumns(100, 5), 5);
        compare(Stacks.gridColumns(0, 5), 1);
    }

    function test_keyStep() {
        compare(Stacks.step(-1, 5, 3, "down"), 0);
        compare(Stacks.step(0, 5, 3, "down"), 3);
        compare(Stacks.step(3, 5, 3, "down"), 3);
        compare(Stacks.step(4, 5, 3, "up"), 1);
        compare(Stacks.step(1, 5, 3, "up"), 1);
        compare(Stacks.step(0, 5, 3, "left"), 0);
        compare(Stacks.step(2, 5, 3, "right"), 3);
        compare(Stacks.step(4, 5, 3, "right"), 4);
        compare(Stacks.step(2, 5, 1, "left"), 2, "a list has no sideways move");
        compare(Stacks.step(2, 5, 1, "end"), 4);
        compare(Stacks.step(2, 5, 1, "home"), 0);
        compare(Stacks.step(0, 0, 1, "down"), -1);
    }

    function test_iconCandidates() {
        compare(Stacks.iconCandidates("image/png", false)[0], "image-png");
        compare(Stacks.iconCandidates("image/png", false)[1], "image-x-generic");
        compare(Stacks.iconCandidates("application/pdf", false)[0], "application-pdf");
        compare(Stacks.iconCandidates("", false)[0], "text-x-generic");
        compare(Stacks.iconCandidates("image/png", true).join(), "folder");
        verify(Stacks.hasPreview("image/jpeg"));
        verify(!Stacks.hasPreview("application/pdf"));
    }

    function test_folderIconAndFileUrl() {
        compare(Stacks.folderIconName("/home/u/Downloads", "/home/u"), "folder-download");
        compare(Stacks.folderIconName("/home/u/work", "/home/u"), "folder");
        compare(Stacks.folderIconName("/srv/Downloads", "/home/u"), "folder");
        compare(Stacks.fileUrl("/a b/c#d.png"), "file:///a%20b/c%23d.png");
        compare(Stacks.baseName("/home/u/Downloads/"), "Downloads");
    }

    function test_folderTilesSitBetweenTheSeparatorAndTheTrash() {
        const folders = DockModel.folderItems(["/home/u/Downloads", "/srv/docs"]);
        compare(folders[0].kind, "folder");
        compare(folders[0].name, "Downloads");
        compare(folders[1].key, "/srv/docs");
        const items = DockModel.withTail([{kind: "app", key: "foot"}], [{kind: "minimized", key: "min:1"}], folders);
        compare(items.map(i => i.kind).join(), "app,separator,folder,folder,minimized,trash");
        compare(DockModel.tileKey(items[2]), "folder:/home/u/Downloads");
        compare(DockModel.withTail([]).map(i => i.kind).join(), "separator,trash");
    }

    function test_keyOfAFolderIsUniqueAmongTiles() {
        const items = DockModel.withTail([], [], DockModel.folderItems(["/a/x", "/b/x"]));
        const keys = items.map(DockModel.tileKey);
        compare(keys.length, new Set(keys).size);
    }

    // ---- adding a folder by dropping it on the Dock ----

    function test_insertFoldersAtASlot() {
        const list = ["/a", "/b", "/c"];
        compare(Stacks.insertFolders(list, ["/x"], 0, "/h", 12).join(), "/x,/a,/b,/c");
        compare(Stacks.insertFolders(list, ["/x"], 2, "/h", 12).join(), "/a,/b,/x,/c");
        compare(Stacks.insertFolders(list, ["/x"], 3, "/h", 12).join(), "/a,/b,/c,/x");
        compare(Stacks.insertFolders(list, ["/x"], 99, "/h", 12).join(), "/a,/b,/c,/x");
        compare(Stacks.insertFolders(list, ["/x"], -4, "/h", 12).join(), "/x,/a,/b,/c");
        compare(Stacks.insertFolders([], ["/x", "/y"], 0, "/h", 12).join(), "/x,/y");
    }

    function test_insertFoldersMovesAnExistingOneAndExpandsHome() {
        compare(Stacks.insertFolders(["/a", "/b", "/c"], ["/a"], 3, "/h", 12).join(), "/b,/c,/a", "moved to the end, not doubled");
        compare(Stacks.insertFolders(["/a", "/b", "/c"], ["/c"], 0, "/h", 12).join(), "/c,/a,/b");
        compare(Stacks.insertFolders(["/a", "/b"], ["/b"], 1, "/h", 12).join(), "/a,/b", "dropped on itself: unchanged");
        compare(Stacks.insertFolders(["~/Downloads"], ["/h/Music"], 1, "/h", 12).join(), "/h/Downloads,/h/Music");
    }

    function test_insertFoldersRefusesJunkAndCaps() {
        compare(Stacks.insertFolders(["/a"], ["rel", "/x/../y", "", 4], 1, "/h", 12).join(), "/a");
        compare(Stacks.insertFolders(["/a", "/b"], ["/x"], 1, "/h", 2).join(), "/a,/x");
        compare(Stacks.insertFolders(null, ["/x"], 0, "/h", 12).join(), "/x");
        compare(Stacks.insertFolders(["/a"], ["/x"], undefined, "/h", 12).join(), "/a,/x");
    }

    function test_folderVerdict() {
        const dir = "inode/directory";
        compare(Stacks.folderVerdict(["/a"], {"/a": dir}), "yes");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": dir, "/b": dir}), "yes");
        compare(Stacks.folderVerdict(["/a"], {}), "pending");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": dir}), "pending");
        compare(Stacks.folderVerdict(["/a", "/b"], {"/a": "text/plain"}), "no", "a known file is refused at once");
        compare(Stacks.folderVerdict(["/a"], {"/a": "-"}), "no");
        compare(Stacks.folderVerdict([], {}), "no");
        compare(Stacks.folderVerdict(null, null), "no");
    }

    function test_folderSlot() {
        // tiles: 0 files, 1 apps, 2 foot, 3 separator, 4 folder A, 5 folder B, 6 trash
        const centers = [20, 80, 140, 200, 260, 320, 380];
        compare(Stacks.folderSlot(150, centers, 3, 2), -1, "left of the divider: refused");
        compare(Stacks.folderSlot(199, centers, 3, 2), -1);
        compare(Stacks.folderSlot(210, centers, 3, 2), 0, "right of the divider, before folder A");
        compare(Stacks.folderSlot(300, centers, 3, 2), 1, "between A and B");
        compare(Stacks.folderSlot(340, centers, 3, 2), 2, "after B");
        compare(Stacks.folderSlot(900, centers, 3, 2), 2, "over the Trash: last folder slot");
        compare(Stacks.folderSlot(250, centers, 3, 0), 0, "no folder yet");
        compare(Stacks.folderSlot(250, centers, -1, 2), -1, "no divider");
    }
}
