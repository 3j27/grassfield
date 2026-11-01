import QtQuick
import QtTest
import "../../shell/security"

// PasswordField's copy rules (shell/security/PasswordField.qml; the opus review of step 9c, MINOR, from its reviewer's probe):
// hidden, Qt's password echo copies nothing; shown (reveal) with copyable false (a secret sheet's Show password), nothing
// can be selected, copied or cut, by keys or the mouse; shown with the default copyable true (the polkit sheet's visible
// answers), the field keeps Qt's own behaviour.
Item {
    id: top
    width: 400
    height: 200

    PasswordField {
        id: secret
        y: 0
        width: 300
    }
    TextInput {
        id: other
        y: 100
        width: 300
        height: 30
    }

    TestCase {
        name: "PasswordField"
        when: windowShown

        function inner() {
            for (let i = 0; i < secret.children.length; i++) {
                if (secret.children[i].echoMode !== undefined)
                    return secret.children[i];
            }
            return null;
        }

        // The clipboard holds "marker"; returns what it holds after `act`.
        function clipboardAfter(act) {
            other.text = "marker";
            other.selectAll();
            other.copy();
            act();
            other.text = "";
            other.paste();
            return other.text;
        }

        function typeSecret() {
            secret.clear();
            secret.forceActiveFocus();
            for (const c of "sec")
                keyClick(c);
        }

        function init() {
            secret.reveal = false;
            secret.copyable = true;
        }

        function test_hiddenCopiesNothing() {
            compare(clipboardAfter(() => {
                typeSecret();
                keySequence(StandardKey.SelectAll);
                keySequence(StandardKey.Copy);
            }), "marker");
        }

        function test_shownGuardedCopiesNothing() {
            secret.reveal = true;
            secret.copyable = false;
            verify(secret.guarded);
            compare(inner().echoMode, TextInput.Normal);
            compare(inner().selectByMouse, false, "no mouse selection (it would fill the primary selection)");
            compare(clipboardAfter(() => {
                typeSecret();
                keySequence(StandardKey.SelectAll);
                keySequence(StandardKey.Copy);
                keySequence(StandardKey.Cut);
                keyClick(Qt.Key_Left, Qt.ShiftModifier);
                keySequence(StandardKey.Copy);
            }), "marker", "neither Select All nor a Shift selection, Copy nor Cut reaches the clipboard");
            compare(secret.length, 3, "Cut took nothing away");
            compare(inner().selectedText, "");
        }

        function test_aSelectionGoesWhenTheTextShows() {
            typeSecret();
            keySequence(StandardKey.SelectAll);
            compare(inner().selectedText.length, 3, "hidden, a selection is possible (password echo copies nothing)");
            secret.copyable = false;
            secret.reveal = true;
            compare(inner().selectedText, "", "dropped as the text shows");
        }

        function test_defaultRevealKeepsQtBehaviour() {
            secret.reveal = true;
            verify(!secret.guarded);
            compare(inner().selectByMouse, true, "the TextInput's default, unchanged");
        }
    }
}
