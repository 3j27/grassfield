import QtQuick
import QtTest
import "../../shell/security/secret"

// The secret sheet's model (shell/security/secret/SecretSheetModel.qml; ADR-0035 D-9, step 9b): who asks is the bridge's
// requester in Grassfield's words, never the caller's text (master-prompt R12, spec SC3, SC3b); the answers it hands to the
// agent (once, never an empty unlock password, a new password typed twice alike); the holds of the polkit sheet.
TestCase {
    id: test
    name: "SecretSheetModel"

    Component {
        id: modelC
        SecretSheetModel {}
    }

    property int serial: 0

    function request(over) {
        test.serial++;
        const r = {
            id: "p7",
            serial: test.serial,
            kind: "password",
            requester: {role: "keyring", name: "", desktopId: "", icon: "", path: "/usr/bin/gnome-keyring-daemon", identified: true, onBehalf: true},
            texts: {title: "Authentication required", message: "Unlock the login keyring", description: "", warning: "", continueLabel: "Allow", cancelLabel: "Deny"},
            choice: null,
            passwordNew: false,
            strength: false,
            waited: false,
            arrivedAt: new Date()
        };
        return Object.assign(r, over || {});
    }

    // An answering agent: records what the model hands it and notes it as sent.
    function wired(m) {
        const sent = [];
        m.answerRequested.connect((ok, password, choice) => {
            sent.push({ok: ok, password: password, choice: choice});
            m.noteAnswered();
        });
        return sent;
    }

    function test_requesterInGrassfieldWords_data() {
        return [
            {tag: "keyring", req: {role: "keyring", name: "", identified: true, onBehalf: true}, name: "Keyring", glyph: "key", intro: "Another program sent this message through Keyring. It is not verified:"},
            {tag: "gnupg", req: {role: "gnupg", name: "", identified: true, onBehalf: true}, name: "GnuPG", glyph: "key", intro: "Another program sent this message through GnuPG. It is not verified:"},
            {tag: "ssh", req: {role: "ssh", name: "", identified: true, onBehalf: true}, name: "SSH", glyph: "key", intro: "Another program sent this message through SSH. It is not verified:"},
            {tag: "app", req: {role: "app", name: "Firefox", icon: "firefox", identified: true, onBehalf: false}, name: "Firefox", glyph: "apps", intro: "Firefox sent this message:"},
            {tag: "unidentified", req: {role: "unidentified", name: "", path: "/home/u/evil", identified: false, onBehalf: false}, name: "Unidentified program", glyph: "exclamationmark-triangle", intro: "The program sent this message. It is not verified:"}
        ];
    }
    function test_requesterInGrassfieldWords(d) {
        const m = createTemporaryObject(modelC, test, {request: request({requester: Object.assign({desktopId: "", icon: "", path: "/usr/bin/x"}, d.req)})});
        compare(m.requesterName, d.name);
        compare(m.glyph, d.glyph);
        compare(m.callerIntro, d.intro);
        verify(m.title.indexOf("Authentication required") < 0, "the caller's title is never the sheet's");
        verify(m.title.indexOf(d.tag === "unidentified" ? "unidentified program" : d.name) >= 0, m.title);
        compare(m.callerTitle, "Authentication required", "the caller's title is shown as the caller's text");
        compare(m.requesterPath, d.tag === "unidentified" ? "/home/u/evil" : "");
        compare(m.appIcon, d.tag === "app" ? "firefox" : "");
    }

    function test_titles() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        compare(m.title, "Keyring asks for a password");
        m.request = request({kind: "confirm"});
        compare(m.title, "Keyring asks you to confirm");
        m.request = request({passwordNew: true, strength: true});
        compare(m.title, "Keyring asks for a new password");
        verify(m.showsStrength);
    }

    function test_iconNameIsPlain() {
        const m = createTemporaryObject(modelC, test, {request: request({requester: {role: "app", name: "X", desktopId: "x.desktop", icon: "/home/u/fake-lock.png", path: "/usr/bin/x", identified: true, onBehalf: false}})});
        compare(m.appIcon, "", "a path is never an icon name: the glyph shows");
    }

    function test_unlockAnsweredOnce() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        verify(!m.submit("", null), "an empty unlock password is not sent");
        compare(sent.length, 0);
        verify(m.submit("pw", null));
        compare(sent, [{ok: true, password: "pw", choice: false}]);
        verify(m.answered);
        verify(!m.canSubmit);
        verify(!m.submit("pw2", null), "never a second answer");
        m.cancel();
        compare(sent.length, 1, "nor a cancellation after it");
    }

    function test_cancelGivesKeysBack() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        let cleared = 0;
        m.clearRequested.connect(() => cleared++);
        m.cancel();
        compare(sent, [{ok: false, password: null, choice: false}]);
        verify(m.answered);
        verify(cleared > 0, "the field is emptied");
    }

    function test_confirmation() {
        const m = createTemporaryObject(modelC, test, {request: request({kind: "confirm", choice: {label: "Always", chosen: true}})});
        const sent = wired(m);
        compare(m.choice, true, "the check box starts as the caller set it");
        m.choice = false;
        verify(m.submit(null, null));
        compare(sent, [{ok: true, password: null, choice: false}]);
    }

    function test_newPassword() {
        const m = createTemporaryObject(modelC, test, {request: request({passwordNew: true, strength: true})});
        const sent = wired(m);
        verify(!m.submit("abc", "abd"), "two different passwords");
        verify(m.error !== "");
        compare(sent.length, 0);
        verify(m.submit("", ""), "an empty new password is a choice (gcr then offers unencrypted storage)");
        compare(sent, [{ok: true, password: "", choice: false}]);
        compare(m.error, "");
    }

    function test_tooLong() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        const sent = wired(m);
        verify(!m.submit("x".repeat(4097), null));
        compare(sent.length, 0);
        verify(m.error !== "");
        verify(!m.answered, "still open: it can be typed again");
    }

    function test_refusedByTheAgent() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        m.answerRequested.connect(() => {}); // the agent refused (not on screen): no noteAnswered
        verify(!m.submit("pw", null));
        verify(!m.answered);
    }

    function test_newRequestStartsFresh() {
        const m = createTemporaryObject(modelC, test, {request: request()});
        wired(m);
        m.submit("pw", null);
        m.request = request({id: "p7", choice: {label: "x", chosen: true}});
        verify(!m.answered && m.canSubmit && m.error === "", "a new request is unanswered at once, even with the same id (a restarted bridge)");
        compare(m.choice, true);
    }

    function test_strength() {
        const m = createTemporaryObject(modelC, test);
        compare(m.strengthOf(0), 0);
        compare(m.strengthOf(7), 1);
        compare(m.strengthOf(8), 2);
        compare(m.strengthOf(11), 2);
        compare(m.strengthOf(12), 3);
    }

    // The polkit sheet's holds, the same delays (AuthDialogModel).
    function test_holds() {
        const m = createTemporaryObject(modelC, test);
        compare([m.heldGuardMs, m.heldAfterUnlockMs, m.sinkLingerMaxMs], [500, 1000, 3000]);
        verify(!m.heldClickAccepted(), "never shown: no click counts");
        m.noteShown();
        verify(!m.heldClickAccepted(), "within the guard");
        wait(600);
        verify(m.heldClickAccepted());
        m.noteUncovered();
        verify(!m.heldClickAccepted(), "the saver ended: the guard starts over");
        verify(!m.arrivesHeld(false));
        verify(m.arrivesHeld(true), "locked or under the saver");
        m.noteUnlock();
        verify(m.arrivesHeld(false), "right after an unlock");
        wait(1100);
        verify(!m.arrivesHeld(false));
        m.noteEnded();
        verify(m.followsAnother() && m.arrivesHeld(false), "right after another sheet");
    }

    function test_heldNotice() {
        const m = createTemporaryObject(modelC, test);
        verify(m.heldNotice(new Date(), "waited").indexOf("while another one was open") >= 0);
        verify(m.heldNotice(new Date(), "locked").indexOf("locked") >= 0);
        verify(m.heldNotice(new Date(), "confirm").indexOf("no key answers a confirmation") >= 0);
    }
}
