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
}
