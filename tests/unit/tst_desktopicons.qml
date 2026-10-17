import QtQuick
import QtTest
import "../../shell/desktop/IconsLogic.js" as Logic

// Desktop icons logic: grid placement (top-right, column-first), moves, navigation, rename
// validation, positions persistence and pruning, URI lists, launcher parsing, folder resolution.
TestCase {
    id: testCase
    name: "DesktopIcons"

    function test_gridSize() {
        compare(Logic.gridSize(1000, 500, 100, 100).cols, 10);
        compare(Logic.gridSize(1000, 500, 100, 100).rows, 5);
        compare(Logic.gridSize(10, 10, 100, 100).cols, 1);
    }

    function test_layoutFillsTopRightColumnFirst() {
        const lay = Logic.layout(["c", "a", "b", "d"], {}, 3, 2);
        compare(lay.a, {col: 0, row: 0});
        compare(lay.b, {col: 0, row: 1});
        compare(lay.c, {col: 1, row: 0});
        compare(lay.d, {col: 1, row: 1});
    }

    function test_layoutSortIsCaseInsensitive() {
        const lay = Logic.layout(["b", "A", "c"], {}, 3, 3);
        compare(lay.A, {col: 0, row: 0});
        compare(lay.b, {col: 0, row: 1});
        compare(lay.c, {col: 0, row: 2});
    }

    function test_layoutKeepsSavedAndFillsAround() {
        const lay = Logic.layout(["a", "b", "c"], {b: {col: 0, row: 0}}, 2, 2);
        compare(lay.b, {col: 0, row: 0});
        compare(lay.a, {col: 0, row: 1});
        compare(lay.c, {col: 1, row: 0});
    }

    function test_layoutRejectsInvalidAndDuplicateSlots() {
        const saved = {a: {col: 9, row: 0}, b: {col: 0, row: 0}, c: {col: 0, row: 0}, d: {col: -1, row: 0}, e: "x"};
        const lay = Logic.layout(["a", "b", "c", "d", "e"], saved, 2, 3);
        compare(lay.b, {col: 0, row: 0});
        const seen = {};
        for (const n of Object.keys(lay)) {
            verify(!seen[lay[n].col + "," + lay[n].row], "slot reused by " + n);
            seen[lay[n].col + "," + lay[n].row] = true;
        }
        compare(Object.keys(lay).length, 5);
    }

    function test_layoutFullGridDropsTheOverflow() {
        const lay = Logic.layout(["a", "b", "c"], {}, 1, 2);
        compare(Object.keys(lay).length, 2);
        verify(lay.c === undefined);
    }

    function test_slotMath() {
        // Area 1000 wide, cells 100x100: col 0 is the right-most.
        compare(Logic.slotPos(0, 0, 1000, 100, 100), {x: 900, y: 0});
        compare(Logic.slotPos(2, 3, 1000, 100, 100), {x: 700, y: 300});
        compare(Logic.slotAt(905, 10, 1000, 100, 100, 10, 5), {col: 0, row: 0});
        compare(Logic.slotAt(690, 290, 1000, 100, 100, 10, 5), {col: 2, row: 3});
        compare(Logic.slotAt(-500, 9999, 1000, 100, 100, 10, 5), {col: 9, row: 4});
    }

    function test_moveGroupShiftsAndAvoidsOthers() {
        const lay = {a: {col: 0, row: 0}, b: {col: 0, row: 1}, c: {col: 2, row: 2}};
        const next = Logic.moveGroup(lay, ["a", "b"], "a", {col: 1, row: 0}, 3, 3);
        compare(next.a, {col: 1, row: 0});
        compare(next.b, {col: 1, row: 1});
        compare(next.c, {col: 2, row: 2});
        // Onto an occupied slot: nearest free one.
        const hit = Logic.moveGroup(lay, ["a"], "a", {col: 2, row: 2}, 3, 3);
        verify(hit.a.col !== 2 || hit.a.row !== 2);
        compare(hit.c, {col: 2, row: 2});
    }

    function test_navigate() {
        const lay = {a: {col: 0, row: 0}, b: {col: 0, row: 1}, c: {col: 1, row: 0}};
        compare(Logic.navigate(lay, "", "down"), "a");
        compare(Logic.navigate(lay, "a", "down"), "b");
        compare(Logic.navigate(lay, "a", "left"), "c");
        compare(Logic.navigate(lay, "c", "right"), "a");
        compare(Logic.navigate(lay, "a", "up"), "a");
        compare(Logic.navigate({}, "", "down"), "");
    }

    function test_rubberBandHits() {
        const rects = {a: {x: 0, y: 0, w: 10, h: 10}, b: {x: 50, y: 50, w: 10, h: 10}};
        compare(Logic.inRect(rects, {x: 5, y: 5, w: 10, h: 10}), ["a"]);
        compare(Logic.inRect(rects, {x: 0, y: 0, w: 100, h: 100}).sort(), ["a", "b"]);
        compare(Logic.inRect(rects, {x: 20, y: 20, w: 5, h: 5}), []);
    }

    function test_renameValidation() {
        const existing = ["a.txt", "b.txt"];
        compare(Logic.validateName("c.txt", "a.txt", existing), "");
        compare(Logic.validateName("", "a.txt", existing), "empty");
        compare(Logic.validateName("   ", "a.txt", existing), "empty");
        compare(Logic.validateName("a/b", "a.txt", existing), "slash");
        compare(Logic.validateName("..", "a.txt", existing), "dots");
        compare(Logic.validateName(".", "a.txt", existing), "dots");
        compare(Logic.validateName("b.txt", "a.txt", existing), "exists");
        compare(Logic.validateName("a.txt", "a.txt", existing), "same");
        compare(Logic.validateName("x\ny", "a.txt", existing), "control");
        compare(Logic.validateName("x".repeat(256), "a.txt", existing), "long");
        compare(Logic.validateName("x".repeat(255), "a.txt", existing), "");
        // 4-byte characters count by bytes.
        compare(Logic.validateName("\u{1F600}".repeat(64), "a.txt", existing), "long");
        compare(Logic.validateName(".hidden", "a.txt", existing), "");
    }

    function test_uniqueName() {
        compare(Logic.uniqueName("a.txt", []), "a.txt");
        compare(Logic.uniqueName("a.txt", ["a.txt"]), "a 2.txt");
        compare(Logic.uniqueName("a.txt", ["a.txt", "a 2.txt"]), "a 3.txt");
        compare(Logic.uniqueName("folder", ["folder"]), "folder 2");
        compare(Logic.uniqueName(".bashrc", [".bashrc"]), ".bashrc 2");
    }

    function test_positionsRoundTripAndPrune() {
        const pos = {"b.txt": {col: 1, row: 2}, "a.txt": {col: 0, row: 0}, "gone.txt": {col: 3, row: 3}};
        const text = Logic.serialize(pos);
        const r = Logic.parse(text);
        verify(r.ok);
        compare(r.positions, pos);
        compare(JSON.parse(text).version, 1);
        compare(Object.keys(JSON.parse(text).positions), ["a.txt", "b.txt", "gone.txt"]);
        compare(Logic.prune(pos, ["a.txt", "b.txt", "new.txt"]), {"a.txt": {col: 0, row: 0}, "b.txt": {col: 1, row: 2}});
        compare(Logic.prune(pos, []), {});
    }

    function test_parseRejectsBadFiles() {
        verify(!Logic.parse("").ok);
        verify(!Logic.parse("not json").ok);
        verify(!Logic.parse("[]").ok);
        verify(!Logic.parse('{"version":2,"positions":{}}').ok);
        verify(!Logic.parse('{"version":1,"positions":[]}').ok);
        const r = Logic.parse('{"version":1,"positions":{"a":{"col":1,"row":1},"b":{"col":-1,"row":0},"c":{"col":1.5,"row":0},"d":null,"e":"x"}}');
        verify(r.ok);
        compare(Object.keys(r.positions), ["a"]);
    }

    function test_renameKeepsPosition() {
        const out = Logic.renamed({a: {col: 1, row: 1}, b: {col: 0, row: 0}}, "a", "z");
        compare(out, {z: {col: 1, row: 1}, b: {col: 0, row: 0}});
        compare(Logic.renamed({b: {col: 0, row: 0}}, "a", "z"), {b: {col: 0, row: 0}});
    }

    function test_uriListRoundTrip() {
        const paths = ["/home/u/Desktop/a b.txt", "/home/u/Desktop/é#?%.png", "/x/(y)!'*"];
        const text = Logic.uriList(paths);
        verify(text.indexOf("a%20b.txt") > 0);
        verify(text.endsWith("\r\n"));
        compare(Logic.parseUriList(text), paths);
    }

    function test_parseUriListFilters() {
        const text = "# comment\r\nfile:///a/b\r\nhttp://example.com/x\r\nfile://localhost/c/d\r\nfile://remote/e\r\nrelative\r\nfile:///bad%ZZ\r\n\r\n";
        compare(Logic.parseUriList(text), ["/a/b", "/c/d"]);
    }

    function test_baseAndDirName() {
        compare(Logic.baseName("/a/b/c.txt"), "c.txt");
        compare(Logic.baseName("/a/b/"), "b");
        compare(Logic.dirName("/a/b/c.txt"), "/a/b");
        compare(Logic.dirName("/a"), "/");
    }

    function test_icons() {
        compare(Logic.iconName("x", true), "folder");
        compare(Logic.iconName("a.PNG", false), "image-x-generic");
        compare(Logic.iconName("a.pdf", false), "application-pdf");
        compare(Logic.iconName("noext", false), "text-x-generic");
        verify(Logic.isImage("a.JPG"));
        verify(!Logic.isImage("a.txt"));
        verify(Logic.isLauncher("Foo.desktop"));
        verify(!Logic.isLauncher(".desktop"));
    }

    function test_parseLauncherIsPlainText() {
        const r = Logic.parseLauncher("[Desktop Action x]\nName=Wrong\n[Desktop Entry]\nName=Foo $(rm -rf)\nName[fr]=Truc\nIcon=foo-icon\nExec=evil\n");
        compare(r.name, "Foo $(rm -rf)");
        compare(r.icon, "foo-icon");
        compare(Logic.parseLauncher("garbage"), {name: "", icon: ""});
    }

    function test_desktopDir() {
        compare(Logic.desktopDir("/tmp/sb/", "/home/u/Bureau", "/home/u"), "/tmp/sb");
        compare(Logic.desktopDir("", "/home/u/Bureau\n", "/home/u"), "/home/u/Bureau");
        // XDG answers that mean "no desktop folder": ~/Desktop.
        compare(Logic.desktopDir("", "/home/u/", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "", "/home/u"), "/home/u/Desktop");
        compare(Logic.desktopDir("", "relative", "/home/u"), "/home/u/Desktop");
    }
}
