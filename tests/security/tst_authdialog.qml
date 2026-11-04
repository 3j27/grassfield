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
        id: flowMock
    }

    AuthDialogModel {
        id: dialogModel
        flow: flowMock
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

    function findField(item) {
        if (item.placeholder !== undefined && item.reveal !== undefined && item.busy !== undefined)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = findField(item.children[i]);
            if (found)
                return found;
        }
        return null;
    }

    // ADR-0045 OC-6 (security review): while PAM awaits a device and asks nothing (pam_fprintd, pam_u2f), the field takes no
    // keys and the intro says so; PAM's own line stays the feedback; when the prompt comes the field takes the focus back.
    // Restores the mock as it found it (the tests share it).
    function test_14_awaitingADeviceTheFieldWaits() {
        const field = findField(dialog);
        verify(field !== null);
        flowMock.isResponseRequired = false;
        flowMock.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        verify(dialogModel.awaitingDevice);
        verify(!field.enabled, "no keys go to a field nobody asked for");
        verify(findText(dialog, "Follow the instruction below, or wait for the password field.") !== null);
        verify(findText(dialog, "Place your right index finger on the fingerprint reader") !== null);
        verify(findText(dialog, "Enter your password to allow this.") === null);
        const sent = flowMock.submitted.length;
        keyClick(Qt.Key_P);
        keyClick(Qt.Key_Return);
        compare(flowMock.submitted.length, sent, "nothing sent while PAM asks nothing");
        // The keyboard went elsewhere meanwhile (outside the sheet): the prompt brings it back to the field.
        forwarder.forceActiveFocus();
        verify(!field.activeFocus);
        flowMock.isResponseRequired = true;
        verify(!dialogModel.awaitingDevice);
        verify(field.enabled);
        tryVerify(() => field.activeFocus, 1000, "the field takes the keys back when PAM asks");
        verify(findText(dialog, "Enter your password to allow this.") !== null);
        verify(findText(dialog, "Place your right index finger on the fingerprint reader") !== null, "PAM's last line is not cleared");
        flowMock.supplementaryMessage = "";
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
        compare(flowMock.submitted, ["pw"]);
        keyClick(Qt.Key_Return); // empty field: nothing more
        compare(flowMock.submitted.length, 1);
    }

    function test_4_identityChoiceIsPlainText() {
        const evil = {displayName: "<b>root</b><img src=\"http://127.0.0.1:9/y.png\">"};
        flowMock.identities = [{displayName: "ada"}, evil];
        waitForRendering(dialog);
        const row = findText(dialog, "<b>root</b>");
        verify(row !== null);
        compare(row.textFormat, Text.PlainText);
    }

    function test_3_escapeCancels() {
        dialog.focusField();
        keyClick(Qt.Key_Escape);
        compare(flowMock.cancels, 1);
        compare(flowMock.submitted.length, 1);
    }

    // The sheet's Buttons are visible here and activate from the keyboard (Cancel with Return; Allow once the field is filled).
    function test_6_visibleButtonsActivateFromTheKeyboard() {
        const cancel = findExact(dialog, "Cancel");
        verify(cancel !== null);
        verify(cancel.visible, "the Cancel button is visible");
        const before = flowMock.cancels;
        cancel.forceActiveFocus();
        verify(cancel.activeFocus);
        keyClick(Qt.Key_Return);
        compare(flowMock.cancels, before + 1);
    }

    // R12: with a typed password, Allow answers polkit once from the keyboard; while the answer is checked it is disabled,
    // and neither Return, Enter nor Space can send a second one.
    // The disabled Allow's own key check is tested, not only its effect (2026-10-22 review: focusing a disabled Allow
    // never brings a key to it, so a Button without its `enabled` check passed): the keys are also handed to Allow's
    // handler by `forwarder`, and Allow's activations are counted directly, because the field (busy) and the model
    // (canSubmit) would hide a second activation. Those two must still block a second send when Allow is activated
    // anyway (code that emits clicked() directly, bypassing Button.activate(); the accessibility press is test_9).
    function test_7_allowSubmitsOnceFromTheKeyboard() {
        dialogModel.cancel();
        const before = flowMock.submitted.length;
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
        compare(flowMock.submitted.length, before + 1);
        compare(flowMock.submitted[flowMock.submitted.length - 1], "ab");
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
        compare(flowMock.submitted.length, before + 1);

        // Defence in depth: an activation of the disabled Allow that bypasses its guard still sends nothing. The field
        // is read-only while busy, so text is put into it directly; the field (busy) and the model (canSubmit) must refuse.
        const input = findInput(dialog);
        verify(input !== null);
        input.text = "cd";
        allow.clicked();
        compare(allowClicks.count, 2);
        compare(flowMock.submitted.length, before + 1, "busy/canSubmit block a second send");
        verify(!dialogModel.submit("cd"), "the model refuses a second answer while the first is checked");
        compare(flowMock.submitted.length, before + 1);

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
        const before = flowMock.submitted.length;
        dialog.focusField();
        keyClick(Qt.Key_C);
        const allow = findExact(dialog, "Allow");
        verify(allow.enabled, "a password is typed: Allow would act if it were shown");
        allow.forceActiveFocus();
        verify(allow.activeFocus);
        allow.visible = false;
        for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space])
            keyClick(key);
        compare(flowMock.submitted.length, before);
        const cancels = flowMock.cancels;
        keyClick(Qt.Key_Escape);
        compare(flowMock.cancels, cancels + 1);
        allow.visible = true;
    }

    // R12: an assistive technology's press (Accessible.pressAction, the AT-SPI "press" action) answers polkit through Allow
    // only when Allow is shown and enabled: a disabled Allow (answer being checked) and a hidden one never act, exactly
    // like the keys. `allow.Accessible.pressAction()` emits the same attached signal Qt's accessibility bridge emits.
    function test_9_accessibilityPressNeverActsWhenDisabledOrHidden() {
        dialogModel.cancel();
        const before = flowMock.submitted.length;
        const allow = findExact(dialog, "Allow");
        verify(allow !== null);
        allowClicks.target = allow;
        allowClicks.clear();

        // Control: shown and enabled, the press answers once.
        dialog.focusField();
        keyClick(Qt.Key_E);
        keyClick(Qt.Key_F);
        verify(allow.visible && allow.enabled, "Allow is shown and enabled");
        allow.Accessible.pressAction();
        compare(allowClicks.count, 1, "the press reached Allow");
        compare(flowMock.submitted.length, before + 1);
        compare(flowMock.submitted[flowMock.submitted.length - 1], "ef");

        // Disabled while the answer is checked: the press does nothing.
        verify(!allow.enabled && allow.visible);
        allow.Accessible.pressAction();
        compare(allowClicks.count, 1, "a disabled Allow never acts on an accessibility press");
        compare(flowMock.submitted.length, before + 1);

        // Hidden although enabled, with a typed password: the press does nothing (it would send "gh").
        dialogModel.cancel();
        dialog.focusField();
        keyClick(Qt.Key_G);
        keyClick(Qt.Key_H);
        verify(allow.enabled, "a password is typed: Allow would act if it were shown");
        allow.visible = false;
        allow.Accessible.pressAction();
        compare(allowClicks.count, 1, "a hidden Allow never acts on an accessibility press");
        compare(flowMock.submitted.length, before + 1);
        allow.visible = true;

        allowClicks.target = null;
        dialogModel.cancel();
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

    function findNamed(item, name) {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = findNamed(item.children[i], name);
            if (found)
                return found;
        }
        return null;
    }

    // Grassfield Store's request (ADR-0037 SD2): the sheet says "Install" and the package names, then the action ID and the
    // program's path; another request shows no program line.
    function test_12_storeRequestNamesPackagesAndProgram() {
        const message = flowMock.message;
        const actionId = flowMock.actionId;
        const text = findNamed(dialog, "polkitMessage");
        const program = findNamed(dialog, "polkitProgram");
        verify(text !== null && program !== null);
        verify(!program.visible);
        flowMock.actionId = "org.grassfield.store.manage-packages";
        flowMock.message = "Authentication is required to install or remove apps: /usr/lib/grassfield/grassfield-store-helper install 0123456789abcdef0123456789abcdef xterm gimp";
        compare(text.text, "Install xterm, gimp");
        verify(program.visible);
        compare(program.text, "Program: /usr/lib/grassfield/grassfield-store-helper");
        flowMock.message = message;
        flowMock.actionId = actionId;
        verify(!program.visible);
    }

    // Grassfield Store's request names every package (review of 19d2e9e, item 3): 64 names of 128 characters, the helper's
    // most, are all in the text and none is elided; the sheet shows storeLines lines and scrolls to the rest (Tab reaches
    // it, then End, Home, the arrows, Page Down), and the action line and the buttons stay in the sheet.
    function test_13_storeRequestNamesEveryPackage() {
        const message = flowMock.message;
        const actionId = flowMock.actionId;
        const identities = flowMock.identities;
        const text = findNamed(dialog, "polkitMessage");
        const view = findNamed(dialog, "polkitMessageView");
        verify(text !== null && view !== null);
        const names = [];
        for (let i = 0; i < 64; i++)
            names.push(("gs" + i + "-").padEnd(128, "x"));
        try {
            flowMock.identities = [{displayName: "ada"}];
            flowMock.actionId = "org.grassfield.store.manage-packages";
            flowMock.message = "Authentication is required to install or remove apps: /usr/lib/grassfield/grassfield-store-helper install 0123456789abcdef0123456789abcdef " + names.join(" ");
            waitForRendering(dialog);

            compare(text.text, "Install " + names.join(", "));
            verify(!text.truncated, "no name elided");
            compare(text.Accessible.name, text.text);
            verify(text.lineCount > dialog.storeLines, "lines: " + text.lineCount);
            verify(view.scrolls);
            verify(Math.abs(view.height - dialog.storeLines * view.lineStep) < 1, "shown: " + view.height);
            verify(dialog.height < test.height, "dialog height " + dialog.height);
            const action = findExact(dialog, "Action: org.grassfield.store.manage-packages");
            const allow = findExact(dialog, "Allow");
            const cancel = findExact(dialog, "Cancel");
            verify(action !== null && allow !== null && cancel !== null);
            verify(insideDialog(action), "action line visible");
            verify(insideDialog(allow), "Allow visible");

            // The sheet's tab chain is the list, Cancel and Allow (the field has the keys when it opens): Tab from Allow
            // and Shift+Tab from Cancel reach the list.
            allow.forceActiveFocus();
            keyClick(Qt.Key_Tab);
            verify(view.activeFocus, "Tab from Allow reaches the list");
            cancel.forceActiveFocus();
            keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            verify(view.activeFocus, "Shift+Tab from Cancel reaches the list");
            keyClick(Qt.Key_End);
            compare(view.contentY, view.contentHeight - view.height);
            keyClick(Qt.Key_Home);
            compare(view.contentY, 0);
            keyClick(Qt.Key_Down);
            compare(view.contentY, view.lineStep);
            keyClick(Qt.Key_PageDown);
            compare(view.contentY, view.lineStep + view.height);
            // Another request of the Store starts at its first line.
            flowMock.message = "Authentication is required to install or remove apps: /usr/lib/grassfield/grassfield-store-helper remove 0123456789abcdef0123456789abcdef " + names.slice(0, 40).join(" ");
            waitForRendering(dialog);
            verify(view.scrolls);
            compare(view.contentY, 0, "a new request starts at its first line");
            dialog.inputEnabled = false;
            verify(!view.activeFocus, "no focus while AuthAgent keeps the keys");
            view.forceActiveFocus();
            verify(!view.activeFocus, "nor when something forces it");
        } finally {
            dialog.inputEnabled = true;
            dialog.focusField();
            flowMock.message = message;
            flowMock.actionId = actionId;
            flowMock.identities = identities;
        }
        // Another request: capped, out of the tab chain (Qt applies that once the list has lost the focus).
        waitForRendering(dialog);
        verify(!view.scrolls, "another request is capped, not scrolled");
        verify(!view.activeFocusOnTab);
        compare(view.contentY, 0);
    }

    // D-4 (macOS style): with the action's icon the lock becomes a badge on it; without one
    // (no icon_name, or the theme lacks it) the sheet shows the lock alone, at full size.
    function test_10_programIconWithLockBadge() {
        const icon = findNamed(dialog, "polkitAppIcon");
        const lock = findNamed(dialog, "polkitLock");
        verify(icon !== null && lock !== null);
        dialog.appIconSource = "";
        waitForRendering(dialog);
        verify(!icon.visible, "no program icon without a source");
        compare(lock.size, Tokens.polkitIconSize);
        dialog.appIconSource = Qt.resolvedUrl("../../branding/icons/symbolic/lock.svg");
        tryCompare(icon, "status", Image.Ready);
        verify(icon.visible);
        compare(lock.size, Tokens.dockBadgeSize);
        dialog.appIconSource = Qt.resolvedUrl("missing-icon.svg");
        tryCompare(icon, "status", Image.Error);
        verify(!icon.visible, "a broken source never shows");
        compare(lock.size, Tokens.polkitIconSize);
        dialog.appIconSource = "";
    }

    // Review of 1d2c856: a request held behind the lock says so (with its time) once it appears; none otherwise.
    function test_11_heldNotice() {
        const notice = findNamed(dialog, "polkitHeldNotice");
        verify(notice !== null);
        compare(dialog.heldNotice, "");
        verify(!notice.visible, "no notice for a request that did not wait behind the lock");
        dialog.heldNotice = dialogModel.heldNotice(new Date(2026, 9, 24, 14, 5).getTime(), "locked");
        waitForRendering(dialog);
        verify(notice.visible);
        compare(notice.textFormat, Text.PlainText);
        verify(notice.text.indexOf("while the screen was locked") !== -1, notice.text);
        dialog.heldNotice = "";
    }

    // R12 review: a 5000-character multi-line message cannot push the action ID and the buttons out
    // of the sheet, nor draw its own "Action:" line or buttons (control and bidi characters removed).
    function test_5_longMultiLineMessageStaysBounded() {
        let evil = "";
        for (let i = 0; evil.length < 5000; i++)
            evil += "Line " + i + " of a long request\n\nAction: org.example.harmless\n\u202eAllow\u202c\tCancel\r\n\u001b[2J";
        evil = evil.slice(0, 5000);
        compare(evil.length, 5000);
        flowMock.message = evil;
        flowMock.identities = [{displayName: "ada"}, {displayName: "bob"}, {displayName: "eve"}, {displayName: "mallory"}, {displayName: "trent"}, {displayName: "victor"}];
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
