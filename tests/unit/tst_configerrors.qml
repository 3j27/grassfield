import QtQuick
import QtTest
import "../../shell/platform/ConfigErrors.js" as Logic
import "../../shell/notifications/Sanitizer.js" as Sanitizer

// ADR-0035 D-2: Hyprland's config errors become one Grassfield notice per new set, withdrawn when they are gone.
TestCase {
    name: "ConfigErrors"

    function test_hyprctlRepliesAreRead() {
        // Hyprland 0.56.2's reply when there is no error: one empty line.
        compare(Logic.parse('[\n\t""\n]\n'), []);
        compare(Logic.parse('[\n\t"session.lua:12: unknown option general.nosuchoption",\n\t"require(\\"grassfield.displays\\"): boom"\n]\n'),
            ["session.lua:12: unknown option general.nosuchoption", "require(\"grassfield.displays\"): boom"]);
        // Blank lines and repeats are dropped.
        compare(Logic.parse('["a", "", "  ", "a", "b"]'), ["a", "b"]);
        compare(Logic.parse("[]"), []);
    }

    function test_anythingElseIsNoAnswer() {
        compare(Logic.parse("Couldn't connect to /run/user/1000/hypr/x/.socket.sock. (4)"), null);
        compare(Logic.parse(""), null);
        compare(Logic.parse(undefined), null);
        compare(Logic.parse('{"errors": []}'), null);
        compare(Logic.parse('["a", 2]'), null);
        compare(Logic.parse("null"), null);
    }

    function test_oneNoticePerNewSet() {
        const first = ["a", "b"];
        compare(Logic.action(first, ""), "post");
        // The same set after a reload: nothing new.
        compare(Logic.action(first, Logic.key(first)), "keep");
        // Another set replaces the notice.
        compare(Logic.action(["a", "c"], Logic.key(first)), "post");
        // The errors are gone: the notice goes.
        compare(Logic.action([], Logic.key(first)), "clear");
        compare(Logic.action([], ""), "keep");
        // No answer changes nothing.
        compare(Logic.action(null, Logic.key(first)), "keep");
        compare(Logic.action(null, ""), "keep");
    }

    function test_theBodyIsText() {
        // Lua's own messages hold "<eof>" and "<name>": a notification body is markup, so they are escaped.
        compare(Logic.noticeBody(["'end' expected near <eof>", "a & b"], ""), "'end' expected near &lt;eof>\na &amp; b");
        compare(Logic.noticeBody(["a", "b", "c"], "and 2 more"), "a\nb\nc\nand 2 more");
        compare(Logic.noticeBody([], ""), "");
        // Through the notification's sanitizer the user reads the lines as Hyprland wrote them.
        compare(Sanitizer.plain(Logic.noticeBody(["'end' expected near <eof>", "x <name> & y"], "and 1 more")),
            "'end' expected near <eof>\nx <name> & y\nand 1 more");
        // Control: unescaped, the sanitizer drops "<eof>".
        verify(Sanitizer.plain("'end' expected near <eof>").indexOf("<eof>") < 0);
    }

    function test_theNoticeListsThreeLines() {
        compare(Logic.summary(["a"]), {lines: ["a"], more: 0});
        compare(Logic.summary(["a", "b", "c"]), {lines: ["a", "b", "c"], more: 0});
        compare(Logic.summary(["a", "b", "c", "d", "e"]), {lines: ["a", "b", "c"], more: 2});
        compare(Logic.summary([]), {lines: [], more: 0});
    }
}
