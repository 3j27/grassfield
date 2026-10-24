import QtQuick
import QtTest
import "../../shell/security/polkit"

// Polkit dialog model with a mock AuthFlow: cancel path, no auto-approve, password handling.
TestCase {
    id: test

    name: "AuthDialogModel"

    component MockFlow: QtObject {
        property string message: "Authentication is needed to run `/usr/bin/true' as the super user"
        property string actionId: "org.freedesktop.policykit.exec"
        property string iconName: ""
        property var identities: [{displayName: "ada"}]
        property var selectedIdentity: identities[0]
        property bool isResponseRequired: false
        property string inputPrompt: "Password: "
        property bool responseVisible: false
        property string supplementaryMessage: ""
        property bool supplementaryIsError: false
        property int submits: 0
        property int cancels: 0
        property var submitted: []

        signal authenticationFailed
        signal authenticationSucceeded
        signal authenticationRequestCancelled

        function submit(value: string): void {
            submits += 1;
            submitted = submitted.concat([value]);
        }

        function cancelAuthenticationRequest(): void {
            cancels += 1;
            authenticationRequestCancelled();
        }
    }

    Component {
        id: flowComponent
        MockFlow {}
    }

    Component {
        id: modelComponent
        AuthDialogModel {}
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    property var flow: null
    property var model: null
    property var clearSpy: null

    function init() {
        flow = createTemporaryObject(flowComponent, test);
        model = createTemporaryObject(modelComponent, test);
        clearSpy = createTemporaryObject(spyComponent, test, {target: model, signalName: "clearRequested"});
        model.flow = flow;
    }

    function test_showsRequestDetails() {
        verify(model.active);
        compare(model.actionId, "org.freedesktop.policykit.exec");
        verify(model.message.indexOf("/usr/bin/true") !== -1);
        compare(model.identityName, "ada");
        compare(model.prompt, "Password");
    }

    // D-4: the action's theme icon is shown (with a lock badge); only a plain theme icon name passes.
    function test_iconNameIsAPlainThemeName() {
        compare(model.iconName, "");
        flow.iconName = "org.gnome.Software";
        compare(model.iconName, "org.gnome.Software");
        flow.iconName = "drive-harddisk_x-1";
        compare(model.iconName, "drive-harddisk_x-1");
        const refused = ["/usr/share/icons/x.png", "file:///etc/passwd", "http://127.0.0.1:9/x.png", "../x", "a b", "image://icon/x", "x\ny", "‮x", "x".repeat(129)];
        for (let i = 0; i < refused.length; i++) {
            flow.iconName = refused[i];
            compare(model.iconName, "", JSON.stringify(refused[i]).slice(0, 40));
        }
        model.flow = null;
        compare(model.iconName, "");
    }

    function test_neverAutoApproves() {
        // Polkit asks, fails, asks again, sends info: the model never answers on its own.
        flow.isResponseRequired = true;
        flow.supplementaryMessage = "info";
        flow.authenticationFailed();
        flow.isResponseRequired = false;
        flow.isResponseRequired = true;
        compare(flow.submits, 0);
        compare(flow.cancels, 0);
    }

    function test_cancelCancelsAndClears() {
        flow.isResponseRequired = true;
        const clears = clearSpy.count;
        model.cancel();
        compare(flow.cancels, 1);
        compare(flow.submits, 0);
        verify(clearSpy.count > clears);
        verify(!model.submitted);
    }

    function test_cancelWithoutFlowIsSafe() {
        model.flow = null;
        verify(!model.active);
        model.cancel();
        compare(flow.cancels, 0);
    }

    function test_submitOnlyWhenAskedAndNonEmpty() {
        verify(!model.submit("pw")); // polkit did not ask
        flow.isResponseRequired = true;
        verify(!model.submit(""));
        compare(flow.submits, 0);
        verify(model.submit("pw"));
        compare(flow.submitted, ["pw"]);
        verify(model.submitted);
        verify(!model.submit("again")); // one answer per prompt
        compare(flow.submits, 1);
    }

    function test_failureClearsAndAllowsRetry() {
        flow.isResponseRequired = true;
        model.submit("wrong");
        const clears = clearSpy.count;
        flow.authenticationFailed();
        verify(clearSpy.count > clears);
        verify(!model.submitted);
        verify(model.feedbackIsError);
        compare(model.feedback, "Incorrect password. Try again.");
        verify(model.submit("second"));
        compare(flow.submits, 2);
    }

    // Untrusted strings are flattened to one capped plain line (R12 review).
    function test_untrustedTextIsOneCappedLine() {
        compare(model.plainLine("a\nb\r\n\tc\u0007d\u009be", 100), "a b c d e");
        compare(model.plainLine("x\u2028y\u2029z", 100), "x y z");
        compare(model.plainLine("\u202eevil\u202c \u2066iso\u2069 \u200fmark\u200e", 100), "evil iso mark");
        compare(model.plainLine(undefined, 10), "");
        compare(model.plainLine(null, 10), "");
        compare(model.plainLine("abcdefghijkl", 5), "abcd\u2026");
        compare(model.plainLine("\u00e9 \u00fc \u65e5\u672c", 100), "\u00e9 \u00fc \u65e5\u672c");

        flow.message = "Run /usr/bin/true\n\nAction: org.example.fake\n" + "y".repeat(5000);
        verify(model.message.indexOf("\n") === -1);
        verify(model.message.length <= model.maxMessageLength);
        verify(model.message.endsWith("\u2026"));
        flow.actionId = "org.example\nAction: fake";
        compare(model.actionId, "org.example Action: fake");
        flow.supplementaryMessage = "line1\nline2";
        compare(model.feedback, "line1 line2");
        flow.selectedIdentity = {displayName: "root\n\u202eeve"};
        compare(model.identityName, "root eve");
    }

    // Review of 1d2c856: a held request takes the keyboard only through a click, and only heldGuardMs after it appeared.
    function test_heldGuard() {
        compare(model.heldGuardMs, 500);
        verify(!model.heldClickAccepted(0));
        verify(!model.heldClickAccepted(499));
        verify(model.heldClickAccepted(500));
        verify(model.heldClickAccepted(5000));
        const notice = model.heldNotice(new Date(2026, 9, 24, 14, 5).getTime());
        verify(notice.indexOf("while the screen was locked") !== -1, notice);
        verify(notice.indexOf(Qt.formatTime(new Date(2026, 9, 24, 14, 5), Qt.locale().timeFormat(Locale.ShortFormat))) !== -1, notice);
    }

    function test_newFlowResetsState() {
        flow.isResponseRequired = true;
        model.submit("pw");
        const other = createTemporaryObject(flowComponent, test);
        model.flow = other;
        verify(!model.submitted);
        compare(model.feedback, "");
    }
}
