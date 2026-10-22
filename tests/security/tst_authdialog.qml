import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/security/polkit"

// Instantiates the authorization sheet offscreen with a mock flow: details are shown as plain
// text (requester rich text is not interpreted), typed text is submitted once, Escape cancels.
// (Offscreen grabs come out blank here, so the visual check needs a registered agent: L2.)
TestCase {
    id: test

    name: "AuthDialog"
    // Shown: a Button of a hidden window is effectively hidden and (shared Button key guard) never activates.
    visible: true
    when: windowShown
    width: 600
    height: 600

    component MockFlow: QtObject {
        property string message: "Authentication is needed to run `/usr/bin/true' as the super user <img src=\"http://127.0.0.1:9/x.png\"><b>bold</b>"
        property string actionId: "org.freedesktop.policykit.exec"
        property var identities: [{displayName: "ada"}]
        property var selectedIdentity: identities[0]
        property bool isResponseRequired: true
        property string inputPrompt: "Password: "
        property bool responseVisible: false
        property string supplementaryMessage: ""
        property bool supplementaryIsError: false
        property int cancels: 0
        property var submitted: []

        signal authenticationFailed
        signal authenticationSucceeded
        signal authenticationRequestCancelled

        function submit(value: string): void {
            submitted = submitted.concat([value]);
        }

        function cancelAuthenticationRequest(): void {
            cancels += 1;
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Tokens.colorDark.materialTint
    }

    MockFlow {
        id: flow
    }

    AuthDialogModel {
        id: dialogModel
        flow: flow
    }

    AuthDialog {
        id: dialog
        x: (test.width - width) / 2
        y: (test.height - height) / 2
        model: dialogModel
    }

    // test_7: hands every key it gets to `target`'s own key handler first (Keys.forwardTo sends the event to the target
    // item whether or not that item is enabled) and records the keys the target did not accept. Qt never gives a disabled
    // item the active focus, so focusing a disabled Allow cannot bring a key to its handler; this does.
    Item {
        id: forwarder

        property Item target: null
        property var reached: []

        Keys.forwardTo: forwarder.target ? [forwarder.target] : []
        Keys.onPressed: event => {
            forwarder.reached = forwarder.reached.concat([event.key]);
            event.accepted = true;
        }
    }

    // test_7: Allow's own activations, whatever the field and the model then do with them.
    SignalSpy {
        id: allowClicks
        signalName: "clicked"
    }

    function findText(item, needle) {
        if (item.text !== undefined && String(item.text).indexOf(needle) !== -1)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = findText(item.children[i], needle);
            if (found)
                return found;
        }
        return null;
    }

    function test_1_rendering() {
        waitForRendering(dialog);
        const title = findText(dialog, "/usr/bin/true");
        verify(title !== null);
        compare(title.textFormat, Text.PlainText);
        verify(findText(dialog, "org.freedesktop.policykit.exec") !== null);
        verify(findText(dialog, "User: ada") !== null);
    }

    function test_2_typedPasswordIsSubmittedOnce() {
        dialog.focusField();
        keyClick(Qt.Key_P);
        keyClick(Qt.Key_W);
        keyClick(Qt.Key_Return);
        compare(flow.submitted, ["pw"]);
        keyClick(Qt.Key_Return); // empty field: nothing more
        compare(flow.submitted.length, 1);
    }

    function test_4_identityChoiceIsPlainText() {
        const evil = {displayName: "<b>root</b><img src=\"http://127.0.0.1:9/y.png\">"};
        flow.identities = [{displayName: "ada"}, evil];
        waitForRendering(dialog);
        const row = findText(dialog, "<b>root</b>");
        verify(row !== null);
        compare(row.textFormat, Text.PlainText);
    }

    function test_3_escapeCancels() {
        dialog.focusField();
        keyClick(Qt.Key_Escape);
        compare(flow.cancels, 1);
        compare(flow.submitted.length, 1);
    }

    // The sheet's Buttons are visible here and activate from the keyboard (Cancel with Return; Allow once the field is filled).
    function test_6_visibleButtonsActivateFromTheKeyboard() {
        const cancel = findExact(dialog, "Cancel");
        verify(cancel !== null);
        verify(cancel.visible, "the Cancel button is visible");
        const before = flow.cancels;
        cancel.forceActiveFocus();
        verify(cancel.activeFocus);
        keyClick(Qt.Key_Return);
        compare(flow.cancels, before + 1);
    }

    // R12: with a typed password, Allow answers polkit once from the keyboard; while the answer is checked it is disabled,
    // and neither Return, Enter nor Space can send a second one.
    // The disabled Allow's own key check is tested, not only its effect (2026-10-22 review: focusing a disabled Allow
    // never brings a key to it, so a Button without its `enabled` check passed): the keys are also handed to Allow's
    // handler by `forwarder`, and Allow's activations are counted directly, because the field (busy) and the model
    // (canSubmit) would hide a second activation. Those two must still block a second send when Allow is activated
    // anyway (an activation that bypasses the key handler, e.g. an accessibility press action).
    function test_7_allowSubmitsOnceFromTheKeyboard() {
        dialogModel.cancel();
        const before = flow.submitted.length;
        const allow = findExact(dialog, "Allow");
        verify(allow !== null);
        allowClicks.target = allow;
        allowClicks.clear();
        dialog.focusField();
        keyClick(Qt.Key_A);
        keyClick(Qt.Key_B);
        verify(allow.visible && allow.enabled, "Allow is shown and enabled");
        allow.forceActiveFocus();
        verify(allow.activeFocus);
        keyClick(Qt.Key_Return);
        compare(allowClicks.count, 1);
        compare(flow.submitted.length, before + 1);
        compare(flow.submitted[flow.submitted.length - 1], "ab");
        verify(!allow.enabled, "Allow is disabled while the answer is checked");
        verify(allow.visible, "Allow stays shown: only its `enabled` check can stop it");

        const keys = [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space];
        // Through the focus, as before (Qt keeps a disabled item from taking it, so these keys go elsewhere).
        for (const key of keys) {
            allow.forceActiveFocus();
            keyClick(key);
        }
        compare(allowClicks.count, 1, "no activation through the focus");
        // Straight to the disabled Allow's key handler. It must swallow the keys without acting: none reaches the
        // forwarder's own handler (proof that Allow's handler got them), and Allow is not activated.
        forwarder.target = allow;
        forwarder.reached = [];
        forwarder.forceActiveFocus();
        verify(forwarder.activeFocus);
        for (const key of keys)
            keyClick(key);
        compare(forwarder.reached, [], "the disabled Allow's handler received and swallowed Return, Enter and Space");
        compare(allowClicks.count, 1, "a disabled Allow never acts on Return, Enter or Space");
        compare(flow.submitted.length, before + 1);

        // Defence in depth: an activation of the disabled Allow that bypasses its key check still sends nothing. The field
        // is read-only while busy, so text is put into it directly; the field (busy) and the model (canSubmit) must refuse.
        const input = findInput(dialog);
        verify(input !== null);
        input.text = "cd";
        allow.clicked();
        compare(allowClicks.count, 2);
        compare(flow.submitted.length, before + 1, "busy/canSubmit block a second send");
        verify(!dialogModel.submit("cd"), "the model refuses a second answer while the first is checked");
        compare(flow.submitted.length, before + 1);

        forwarder.target = null;
        allowClicks.target = null;
        dialogModel.cancel();
    }

    // The password TextInput of the sheet (the only item with an echoMode).
    function findInput(item) {
        if (item.echoMode !== undefined)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = findInput(item.children[i]);
            if (found)
                return found;
        }
        return null;
    }

    // R12: a hidden Allow that still holds the focus never answers polkit (shared Button key guard: Return, Enter and
    // Space are swallowed), and Escape still reaches the sheet and cancels.
    function test_8_hiddenAllowNeverActsAndEscapeStillCancels() {
        dialogModel.cancel();
        const before = flow.submitted.length;
        dialog.focusField();
        keyClick(Qt.Key_C);
        const allow = findExact(dialog, "Allow");
        verify(allow.enabled, "a password is typed: Allow would act if it were shown");
        allow.forceActiveFocus();
        verify(allow.activeFocus);
        allow.visible = false;
        for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space])
            keyClick(key);
        compare(flow.submitted.length, before);
        const cancels = flow.cancels;
        keyClick(Qt.Key_Escape);
        compare(flow.cancels, cancels + 1);
        allow.visible = true;
    }

    function findExact(item, value) {
        if (item.text !== undefined && String(item.text) === value)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = findExact(item.children[i], value);
            if (found)
                return found;
        }
        return null;
    }

    // Shown whenever the sheet is (the offscreen test window may be hidden) and inside its bounds.
    function insideDialog(item) {
        const p = item.mapToItem(dialog, 0, 0);
        return item.visible === dialog.visible && item.opacity > 0 && item.height > 0 && p.y >= 0 && p.y + item.height <= dialog.height;
    }

    // R12 review: a 5000-character multi-line message cannot push the action ID and the buttons out
    // of the sheet, nor draw its own "Action:" line or buttons (control and bidi characters removed).
    function test_5_longMultiLineMessageStaysBounded() {
        let evil = "";
        for (let i = 0; evil.length < 5000; i++)
            evil += "Line " + i + " of a long request\n\nAction: org.example.harmless\n\u202eAllow\u202c\tCancel\r\n\u001b[2J";
        evil = evil.slice(0, 5000);
        compare(evil.length, 5000);
        flow.message = evil;
        flow.identities = [{displayName: "ada"}, {displayName: "bob"}, {displayName: "eve"}, {displayName: "mallory"}, {displayName: "trent"}, {displayName: "victor"}];
        waitForRendering(dialog);

        const title = findText(dialog, "Line 0 of a long request");
        verify(title !== null);
        compare(title.textFormat, Text.PlainText);
        verify(!/[\n\r\t\u001b\u202e\u202c]/.test(title.text), "control/bidi characters removed");
        verify(title.text.length <= dialogModel.maxMessageLength);
        verify(title.lineCount <= dialog.messageLines, "lines: " + title.lineCount);
        verify(title.truncated);

        // Bounded sheet; the real action line and both buttons are inside it.
        verify(dialog.height < test.height, "dialog height " + dialog.height);
        const action = findExact(dialog, "Action: org.freedesktop.policykit.exec");
        const allow = findExact(dialog, "Allow");
        const cancel = findExact(dialog, "Cancel");
        verify(action !== null && allow !== null && cancel !== null);
        verify(insideDialog(action), "action line visible");
        verify(insideDialog(allow), "Allow visible");
        verify(insideDialog(cancel), "Cancel visible");
        // The message is above the action line, which is above the buttons.
        verify(title.mapToItem(dialog, 0, 0).y + title.height <= action.mapToItem(dialog, 0, 0).y);
        verify(action.mapToItem(dialog, 0, 0).y < allow.mapToItem(dialog, 0, 0).y);
    }
}
