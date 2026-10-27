import QtQuick
import QtTest
import "../../shell/services/NotResponding.js" as Logic

// ADR-0035 D-3: "Not responding". A report marks exactly one process, never a guess; the marks drive Force Quit and the Dock
// menu; Force Quit refuses a pid that no longer owns a window of the chosen class.
TestCase {
    name: "NotResponding"

    readonly property string own: "abc_1_2"

    function win(pid, cls, title) {
        return {pid: pid, cls: cls, title: title};
    }

    function test_theStringArgumentsCarryTheirPrefix() {
        compare(Logic.unprefix("c:org.gnome.Nautilus", "c:"), "org.gnome.Nautilus");
        // A title may itself start with "-" or with another prefix.
        compare(Logic.unprefix("t:-rw-r--r-- notes.txt", "t:"), "-rw-r--r-- notes.txt");
        compare(Logic.unprefix("t:c:x", "t:"), "c:x");
        compare(Logic.unprefix("t:", "t:"), "");
        compare(Logic.unprefix("org.gnome.Nautilus", "c:"), null);
        compare(Logic.unprefix("", "i:"), null);
        compare(Logic.unprefix(undefined, "i:"), null);
    }

    function test_aReportForOneKnownProcessIsAccepted() {
        const windows = [win(4242, "foot", "~"), win(5000, "firefox", "Mozilla Firefox")];
        compare(Logic.decide(77, 4242, "foot", "~", own, own, windows), {ok: true, reason: ""});
        // A window the shell has no pid for yet does not refuse: the stand-in found it in Hyprland's own list.
        compare(Logic.decide(77, 4242, "foot", "~", own, own, [win(0, "foot", "~")]).ok, true);
        compare(Logic.decide(77, 4242, "foot", "~", own, own, []).ok, true);
        // Another process with the same class but another title is not the same window.
        compare(Logic.decide(77, 4242, "foot", "~", own, own, windows.concat([win(4300, "foot", "/tmp")])).ok, true);
    }

    function test_twoProcessesWithTheSameWindowAreNotTold() {
        const windows = [win(4242, "foot", "~"), win(4300, "foot", "~")];
        compare(Logic.decide(77, 4242, "foot", "~", own, own, windows), {ok: false, reason: "ambiguous"});
        compare(Logic.decide(77, 4300, "foot", "~", own, own, windows).reason, "ambiguous");
    }

    function test_badPidsAndMissingFieldsAreRefused() {
        const windows = [win(4242, "foot", "~")];
        compare(Logic.decide(77, 0, "foot", "~", own, own, windows).reason, "pid");
        compare(Logic.decide(77, 1, "foot", "~", own, own, windows).reason, "pid");
        compare(Logic.decide(77, -5, "foot", "~", own, own, windows).reason, "pid");
        compare(Logic.decide(77, 42.5, "foot", "~", own, own, windows).reason, "pid");
        compare(Logic.decide(1, 4242, "foot", "~", own, own, windows).reason, "standin");
        compare(Logic.decide(0, 4242, "foot", "~", own, own, windows).reason, "standin");
        compare(Logic.decide(77, 4242, "", "~", own, own, windows).reason, "window");
        compare(Logic.decide(77, 4242, null, "~", own, own, windows).reason, "window");
        compare(Logic.decide(77, 4242, "foot", null, own, own, windows).reason, "window");
        // An empty title is a title.
        compare(Logic.decide(77, 4242, "foot", "", own, own, [win(4242, "foot", "")]).ok, true);
    }

    function test_aReportFromAnotherCompositorIsRefused() {
        const windows = [win(4242, "foot", "~")];
        compare(Logic.decide(77, 4242, "foot", "~", "nested_9_9", own, windows).reason, "instance");
        compare(Logic.decide(77, 4242, "foot", "~", "", own, windows).reason, "instance");
        compare(Logic.decide(77, 4242, "foot", "~", null, own, windows).reason, "instance");
        // A shell that does not know its own compositor accepts nothing.
        compare(Logic.decide(77, 4242, "foot", "~", "", "", windows).reason, "instance");
    }

    function test_oneMarkPerStandinAndPerProcess() {
        let marks = Logic.withMark([], {standin: 77, pid: 4242, cls: "foot", title: "~"});
        marks = Logic.withMark(marks, {standin: 78, pid: 5000, cls: "firefox", title: "Mozilla Firefox"});
        compare(marks.length, 2);
        // Hyprland runs one dialog per client: a new report for that pid replaces the old one.
        marks = Logic.withMark(marks, {standin: 90, pid: 4242, cls: "foot", title: "~"});
        compare(marks.length, 2);
        compare(marks.filter(m => m.pid === 4242)[0].standin, 90);
        // A stand-in that reports again (a reused pid) carries one mark only.
        marks = Logic.withMark(marks, {standin: 78, pid: 6000, cls: "gimp", title: "GIMP"});
        compare(marks.length, 2);
        verify(!Logic.isMarked(marks, 5000));
        verify(Logic.isMarked(marks, 6000));
        marks = Logic.withoutStandin(marks, 90);
        verify(!Logic.isMarked(marks, 4242));
        compare(marks.length, 1);
    }

    function test_marksDriveForceQuitAndTheDockMenu() {
        const marks = [{standin: 77, pid: 4242, cls: "foot", title: "~"}];
        verify(Logic.isMarked(marks, 4242));
        verify(!Logic.isMarked(marks, 4243));
        verify(!Logic.isMarked(marks, 0));
        verify(!Logic.isMarked([], 4242));
        verify(!Logic.isMarked(undefined, 4242));
        // An app's windows: the marked pids, once each.
        compare(Logic.markedAmong(marks, [4242, 5000, 4242, 0]), [4242]);
        compare(Logic.markedAmong(marks, [5000]), []);
        compare(Logic.markedAmong(marks, []), []);
        // Force Quit opens on the first app that does not respond, else on the first row.
        compare(Logic.initialIndex([5000, 0, 4242, 4242], marks), 2);
        compare(Logic.initialIndex([5000, 6000], marks), 0);
        compare(Logic.initialIndex([], marks), -1);
    }

    function test_forceQuitRefusesAReusedPid() {
        const windows = [win(4242, "foot", "~"), win(5000, "firefox", "Mozilla Firefox")];
        verify(Logic.stillOwns(windows, 4242, "foot"));
        // The app closed and another process took its pid: no window of that class any more.
        verify(!Logic.stillOwns([win(4242, "gimp", "GIMP")], 4242, "foot"));
        verify(!Logic.stillOwns([], 4242, "foot"));
        verify(!Logic.stillOwns(windows, 1, "foot"));
        verify(!Logic.stillOwns(windows, 0, ""));
        // A caller that does not know the class is not checked (the pid still has to be a plain process).
        verify(Logic.stillOwns(windows, 4242, ""));
        verify(Logic.stillOwns(windows, 4242, undefined));
        verify(Logic.stillOwns(windows, 4242, []));
        // The Dock menu: the classes of the app's windows.
        verify(Logic.stillOwns(windows, 4242, ["footclient", "foot"]));
        verify(!Logic.stillOwns(windows, 4242, ["firefox"]));
        verify(!Logic.stillOwns([win(4242, "gimp", "GIMP")], 4242, ["foot", "footclient"]));
    }

    function test_statusListsTheMarks() {
        compare(Logic.statusJson([]), "[]");
        compare(JSON.parse(Logic.statusJson([{standin: 77, pid: 4242, cls: "foot", title: "~", extra: 1}])), [{standin: 77, pid: 4242, cls: "foot", title: "~"}]);
    }
}
