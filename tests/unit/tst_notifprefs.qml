import QtQuick
import QtTest
import Grassfield.Ui

// Per-app notification previews (ADR-0004, C-NOTIF-2): validation, resolution against the global default, the lock state.
TestCase {
    name: "NotificationPrefs"

    readonly property var list: [{app: "Signal", previews: "never"}, {app: "Mail", previews: "always"}]

    function test_validation() {
        compare(NotificationPrefs.problem(list), "");
        compare(NotificationPrefs.problem([]), "");
        verify(NotificationPrefs.problem("x") !== "");
        verify(NotificationPrefs.problem([{app: "", previews: "never"}]) !== "");
        verify(NotificationPrefs.problem([{app: "A", previews: "bogus"}]) !== "");
        verify(NotificationPrefs.problem([{app: "A", previews: "never"}, {app: " a ", previews: "always"}]) !== "");
        verify(NotificationPrefs.problem([{app: "bad\u0001", previews: "never"}]) !== "");
        verify(NotificationPrefs.problem([null]) !== "");
        const many = [];
        for (let i = 0; i < NotificationPrefs.MAX_APPS + 1; i++)
            many.push({app: "a" + i, previews: "never"});
        verify(NotificationPrefs.problem(many) !== "");
    }

    function test_normalizeDropsInvalidAndRepeated() {
        const out = NotificationPrefs.normalize([{app: "A", previews: "never"}, {app: "a", previews: "always"}, {app: "", previews: "never"}, {app: "B", previews: "x"}, 3, null]);
        compare(out.length, 1);
        compare(out[0].previews, "never");
        compare(NotificationPrefs.normalize("nope").length, 0);
    }

    function test_perAppBeatsGlobal() {
        compare(NotificationPrefs.effective(list, "Signal", "always"), "never");
        compare(NotificationPrefs.effective(list, "signal ", "always"), "never");
        compare(NotificationPrefs.effective(list, "Mail", "never"), "always");
        compare(NotificationPrefs.effective(list, "Other", "never"), "never");
        compare(NotificationPrefs.effective(list, "Other", "bogus"), "unlocked");
        compare(NotificationPrefs.effective([], "", "always"), "always");
    }

    function test_valueForAndWithValue() {
        compare(NotificationPrefs.valueFor(list, "Signal"), "never");
        compare(NotificationPrefs.valueFor(list, "Nope"), "default");
        const a = NotificationPrefs.withValue(list, "Signal", "unlocked");
        compare(NotificationPrefs.valueFor(a, "Signal"), "unlocked");
        compare(a.length, 2);
        const b = NotificationPrefs.withValue(a, "signal", "default");
        compare(NotificationPrefs.valueFor(b, "Signal"), "default");
        compare(b.length, 1);
        compare(NotificationPrefs.withValue([], "", "never").length, 0);
        compare(list.length, 2);
    }

    function test_bodyShownFollowsThePolicyAndTheLock() {
        verify(NotificationPrefs.bodyShown("always", true));
        verify(NotificationPrefs.bodyShown("always", false));
        verify(!NotificationPrefs.bodyShown("never", false));
        verify(!NotificationPrefs.bodyShown("unlocked", true));
        verify(NotificationPrefs.bodyShown("unlocked", false));
    }

    function test_hiddenPreviewShowsTheAppNameAndAGenericLine() {
        const hidden = NotificationPrefs.display(false, "Re: salary", "<b>secret</b>", "Mail", "Notification");
        compare(hidden.title, "Mail");
        compare(hidden.body, "Notification");
        const nameless = NotificationPrefs.display(false, "Re: salary", "x", "", "Notification");
        compare(nameless.title, "Notification");
        const shown = NotificationPrefs.display(true, "Re: salary", "text", "Mail", "Notification");
        compare(shown.title, "Re: salary");
        compare(shown.body, "text");
    }

    function test_appsToList() {
        compare(NotificationPrefs.appsToList(["Zed", "mail", "Alpha"], list), ["Alpha", "Mail", "Signal", "Zed"]);
        compare(NotificationPrefs.appsToList(undefined, []), []);
        compare(NotificationPrefs.appsToList(["", 4], []), []);
    }
}
