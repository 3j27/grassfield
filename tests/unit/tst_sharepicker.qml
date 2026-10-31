import QtQuick
import QtTest
import "../../shell/services/SharePicker.js" as Logic

// ADR-0035 D-6, step 7a: the screen-sharing picker's decisions. The shell takes only the stand-in's form of request, reads
// only that request's window list, and answers only a listed choice in xdph's grammar; the panel's keys move in the grid.
TestCase {
    name: "SharePicker"

    readonly property string run: "/run/user/1000"
    readonly property string id: "0123456789abcdef0123456789abcdef"
    readonly property string sock: "/run/user/1000/grassfield/picker/fedcba9876543210fedcba9876543210.sock"

    function test_onlyTheStandInsFormOfRequest() {
        verify(Logic.validRequest(id, sock, run));
        verify(Logic.validRequest(id, sock, run + "/"), "a runtime directory with a trailing slash");
        verify(!Logic.validRequest(id.slice(1), sock, run), "an id shorter than 128 bits");
        verify(!Logic.validRequest(id.toUpperCase(), sock, run), "an id in upper case");
        verify(!Logic.validRequest(id + "0", sock, run), "a longer id");
        verify(!Logic.validRequest("-" + id.slice(1), sock, run), "an id that starts as an option");
        verify(!Logic.validRequest(id, "/tmp/grassfield/picker/fedcba9876543210fedcba9876543210.sock", run), "another directory");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/../picker/fedcba9876543210fedcba9876543210.sock", run), "a path with ..");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/x/fedcba9876543210fedcba9876543210.sock", run), "a subdirectory");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/fedcba9876543210fedcba9876543210.socket", run), "another suffix");
        verify(!Logic.validRequest(id, run + "/grassfield/picker/.sock", run), "no name");
        verify(!Logic.validRequest(id, sock, ""), "no runtime directory");
        verify(!Logic.validRequest(id, "grassfield/picker/fedcba9876543210fedcba9876543210.sock", "grassfield"), "a relative runtime directory");
        verify(!Logic.validRequest(undefined, sock, run));
        verify(!Logic.validRequest(id, null, run));
    }

    function test_theWindowListOfThatRequestOnly() {
        const line = id + " list " + JSON.stringify([
            {handle: "123456", class: "org.gnome.TextEditor", title: "notes.txt", address: "0x55d48e82834e"},
            {handle: "4294967295", class: "firefox", title: "A page", address: ""}
        ]);
        compare(Logic.parseList(line, id), [
            {handle: "123456", appId: "org.gnome.TextEditor", title: "notes.txt", address: "0x55d48e82834e"},
            {handle: "4294967295", appId: "firefox", title: "A page", address: ""}
        ]);
        compare(Logic.parseList(line, "f" + id.slice(1)), null, "another request's list");
        compare(Logic.parseList(id + " wait", id), null);
        compare(Logic.parseList(id + " list {", id), null, "not JSON");
        compare(Logic.parseList(id + " list {}", id), null, "not a list");
        compare(Logic.parseList(id + " list []", id), []);
    }

    function test_aWindowThatDoesNotReadIsLeftOut() {
        const listed = Logic.parseList(id + " list " + JSON.stringify([
            {handle: "4294967296", class: "a", title: "past 32 bits", address: ""},
            {handle: "12x", class: "a", title: "not a number", address: ""},
            {handle: 12, class: "a", title: "a number, not text", address: ""},
            {handle: "-1", class: "a", title: "negative", address: ""},
            null, "text",
            {handle: "7", class: 3, title: {}, address: "55d4"},
            {handle: "7", class: "dup", title: "the same handle again", address: ""},
            {handle: "8", class: "x".repeat(300), title: "y".repeat(300), address: "0x" + "f".repeat(17)}
        ]), id);
        compare(listed.map(w => w.handle), ["7", "8"]);
        compare(listed[0], {handle: "7", appId: "", title: "", address: ""}, "a class or title that is not text, an address without 0x");
        compare(listed[1].appId.length, 256, "an app id capped");
        compare(listed[1].title.length, 256, "a title capped");
        compare(listed[1].address, "", "an address past 64 bits");
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push({handle: String(i), class: "a", title: "", address: ""});
        compare(Logic.parseList(id + " list " + JSON.stringify(many), id).length, 256, "at most 256 windows");
    }

    function test_windowsGroupedByAppThenTitle() {
        const names = {"org.gnome.TextEditor": "Text Editor", firefox: "Firefox", foot: "Foot"};
        const w = (h, a, t) => ({handle: h, appId: a, title: t, address: ""});
        compare(Logic.ordered([w("1", "org.gnome.TextEditor", "b"), w("2", "foot", "~"), w("3", "firefox", "z"), w("4", "org.gnome.TextEditor", "a")],
            id => names[id]).map(x => x.handle), ["3", "2", "4", "1"]);
    }

    function test_theAnswerIsAListedChoiceInXdphsGrammar() {
        const windows = [{handle: "123456", appId: "a", title: "", address: ""}];
        compare(Logic.selection("screen", "DP-1", false, ["DP-1", "HDMI-A-1"], windows), "/screen:DP-1");
        compare(Logic.selection("screen", "HDMI-A-1", true, ["DP-1", "HDMI-A-1"], windows), "r/screen:HDMI-A-1", "Remember this choice: the r flag");
        compare(Logic.selection("window", "123456", false, [], windows), "/window:123456");
        compare(Logic.selection("window", "123456", true, [], windows), "r/window:123456");
        compare(Logic.selection("screen", "DP-2", false, ["DP-1"], windows), "", "a display that is not there");
        compare(Logic.selection("screen", "DP-1\n/window:1", false, ["DP-1\n/window:1"], windows), "", "a name with a line break");
        compare(Logic.selection("window", "999", false, [], windows), "", "a window xdph did not list");
        compare(Logic.selection("region", "DP-1@0,0,1,1", false, ["DP-1"], windows), "", "no region in step 7a");
        compare(Logic.selection("screen", "DP-1", "yes", ["DP-1"], windows), "/screen:DP-1", "only true ticks Remember");
    }

    function test_theArrowsMoveInTheGrid() {
        // Seven tiles, three to a row.
        compare(Logic.moved(-1, "right", 7, 3), 0, "nothing selected: the first tile");
        compare(Logic.moved(0, "right", 7, 3), 1);
        compare(Logic.moved(0, "left", 7, 3), 0, "nothing before the first");
        compare(Logic.moved(1, "down", 7, 3), 4);
        compare(Logic.moved(4, "down", 7, 3), 4, "no tile below");
        compare(Logic.moved(3, "down", 7, 3), 6);
        compare(Logic.moved(4, "up", 7, 3), 1);
        compare(Logic.moved(1, "up", 7, 3), 1);
        compare(Logic.moved(6, "right", 7, 3), 6);
        compare(Logic.moved(9, "left", 7, 3), 0, "a selection past the tiles starts again");
        compare(Logic.moved(0, "down", 0, 3), -1, "no tile");
        compare(Logic.moved(0, "down", 2, 0), 1, "at least one column");
    }

    function test_columnsThatFit() {
        compare(Logic.columnsFor(564, 176, 12), 3);
        compare(Logic.columnsFor(551, 176, 12), 2);
        compare(Logic.columnsFor(100, 176, 12), 1, "at least one");
    }
}
