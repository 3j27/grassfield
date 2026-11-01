import QtQuick
import QtTest
import qs.security
import qs.services

// The secret sheets and the one queue (tests/security/secret_sheets.sh runs this as tst_sheets.qml beside the generated
// agents): the real SecretAgent and AuthAgent (Quickshell types replaced, logic untouched), the real SecretSheet,
// SecretSheetModel, AuthDialog, AuthDialogModel and SheetQueue, wired as shell.qml wires them; a fake prompter client and
// mock polkit flows. Real key and mouse events. ADR-0035 D-9, master-prompt R12.
Item {
    id: top
    width: 800
    height: 600

    readonly property Component secretC: Qt.createComponent(Qt.resolvedUrl("secret/AgentUnderTest.qml"))
    readonly property Component polkitC: Qt.createComponent(Qt.resolvedUrl("polkit/AgentUnderTest.qml"))

    // shell.qml's wiring: one queue, the polkit sheet's place bound to the agent's.
    Component {
        id: rigC
        Item {
            id: rig
            width: 800
            height: 600
            property var polkit: null
            property var secret: null
            readonly property SheetQueue queue: q

            SheetQueue {
                id: q
                polkitPresent: rig.polkit !== null && rig.polkit.queuePresent
            }
        }
    }

    Component {
        id: flowC
        QtObject {
            property string message: "msg"
            property string actionId: "org.example.action"
            property string iconName: ""
            property var identities: []
            property var selectedIdentity: null
            property bool isResponseRequired: true
            property string inputPrompt: "Password:"
            property bool responseVisible: false
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property int cancels: 0
            property var submits: []
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
            }
        }
    }

    TestCase {
        name: "SecretSheets"
        when: windowShown

        property var rig: null
        property var client: null
        property var shownIds: []

        function init() {
            SessionState.locked = false;
            SessionState.saverShown = false;
            compare(top.secretC.status, Component.Ready, top.secretC.errorString());
            compare(top.polkitC.status, Component.Ready, top.polkitC.errorString());
            rig = createTemporaryObject(rigC, top);
            verify(rig);
            rig.polkit = top.polkitC.createObject(rig, {queue: rig.queue});
            rig.secret = top.secretC.createObject(rig, {queue: rig.queue});
            verify(rig.secret && rig.polkit);
            client = rig.secret.clientMock;
            shownIds = [];
            const seen = shownIds;
            const agent = rig.secret;
            agent.model.requestChanged.connect(() => {
                if (agent.model.request)
                    seen.push(agent.model.request.id);
            });
        }

        function find(item, pred) {
            if (!item)
                return null;
            if (pred(item))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const r = find(item.children[i], pred);
                if (r)
                    return r;
            }
            return null;
        }
        function sheet() {
            return rig.secret.holderItem.item;
        }
        function named(name) {
            return find(sheet(), i => i.objectName === name);
        }
        function polkitField() {
            return find(rig.polkit.holderItem.item, i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }
        function polkitArrives(msg) {
            const f = createTemporaryObject(flowC, top, {message: msg});
            rig.polkit.agentMock.isActive = true;
            rig.polkit.agentMock.flow = f;
            return f;
        }
        function polkitEnds() {
            rig.polkit.agentMock.isActive = false;
            rig.polkit.agentMock.flow = null;
        }
        function shown(id) {
            tryVerify(() => rig.secret.model.active && rig.secret.model.id === id, 3000, id + " on screen");
        }

        // A gcr password request: the bridge's requester row and the caller's text under it, never as the sheet's own; the
        // password typed goes back once, the field is then empty, and the keys stay on the sink a moment (gcr asks again
        // at once after a wrong password).
        function test_01_passwordOnce() {
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, false);
            compare(rig.secret.sheet.shown, true);
            compare(rig.secret.sheet.takesKeys, true);
            compare(named("secretTitle").text, "Keyring asks for a password");
            compare(named("secretCallerIntro").text, "Another program sent this message through Keyring. It is not verified:");
            compare(named("secretCaller_title").text, "Authentication required", "the caller's title, in the caller's block");
            compare(named("secretCaller_message").text, "Unlock the login keyring");
            compare(named("secretGlyph").name, "key");
            verify(find(sheet(), i => i.name === "lock" || i.name === "lock-fill" || i.name === "shield") === null, "no lock or shield glyph");
            compare(named("secretOk").text, "OK", "Grassfield's label, not the caller's (Allow)");
            tryVerify(() => named("secretField").activeFocus);
            const field = named("secretField");
            let emptyAtAnswer = false;
            rig.secret.model.answerRequested.connect(() => emptyAtAnswer = field.empty);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare([client.answers[0].id, client.answers[0].ok, client.answers[0].password], ["p1", true, "pw"]);
            verify(emptyAtAnswer, "the field is emptied before the answer goes out");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true, "the keys stay on the sink a moment");
            compare(rig.secret.lingerWhy, "sent");
            verify(rig.secret.sink.activeFocus);
            typeText("more");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1, "nothing more is sent");
            tryVerify(() => !rig.secret.sheet.visible, 3000);
            tryVerify(() => rig.queue.secretCount === 0);
        }

        // Esc answers "cancel" and gives the keyboard back at once (no linger).
        function test_02_cancel() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("x");
            keyClick(Qt.Key_Escape); // the field's own Esc empties it first
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            compare([client.answers[0].ok, client.answers[0].password], [false, null]);
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, false);
            compare(rig.secret.sheet.visible, false);
            tryVerify(() => rig.queue.secretCount === 0);
        }

        // The caller gives up: a queued request leaves the queue without ever showing; the shown one ends under the user's
        // typing and the rest of the password goes nowhere.
        function test_03_withdrawn() {
            client.prompt("p1", {});
            client.prompt("p2", {});
            shown("p1");
            compare(rig.queue.secretCount, 2);
            client.withdraw("p2");
            compare(rig.queue.secretCount, 1, "p2 left the queue");
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            client.withdraw("p1");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true);
            compare(rig.secret.lingerWhy, "cancelled");
            verify(rig.secret.sink.activeFocus);
            compare(rig.secret.notice.visible, true);
            typeText("ret");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0, "a withdrawn request is never answered");
            tryVerify(() => !rig.secret.sheet.visible, 3000);
            wait(50);
            compare(shownIds, ["p1"], "p2 was never shown");
            compare(rig.queue.secretCount, 0);
        }

        // At most 8 secret requests: the ninth is answered "cancelled" at once and never shown.
        function test_04_ninth() {
            for (let i = 1; i <= 9; i++)
                client.prompt("p" + i, {});
            compare(rig.secret.requestCount, 8);
            compare(client.answers.length, 1);
            compare([client.answers[0].id, client.answers[0].ok], ["p9", false]);
            compare(rig.queue.secretCount, 8);
        }

        // A request that waited in the queue is held when its turn comes: no keyboard until a click past the guard.
        function test_05_queuedIsHeld() {
            client.prompt("p1", {});
            client.prompt("p2", {texts: {title: "", message: "second", description: "", warning: "", "continue": "", cancel: ""}});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            shown("p2");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "waited");
            compare(rig.secret.sheet.takesKeys, false);
            verify(named("secretHeldNotice").text.indexOf("while another one was open") >= 0);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, false, "a click within the guard gives nothing");
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, true);
            compare(rig.secret.sheet.takesKeys, true);
            tryVerify(() => named("secretField").activeFocus);
        }

        // The polkit sheet keeps the keyboard while a gcr request arrives: the gcr sheet waits and is shown after, held.
        function test_06_polkitKeepsTheKeyboard() {
            const f = polkitArrives("A");
            tryVerify(() => polkitField() && polkitField().activeFocus);
            typeText("adm");
            client.prompt("p1", {});
            wait(100);
            compare(rig.secret.model.active, false, "the gcr request waits");
            compare(rig.secret.sheet.visible, false);
            compare(rig.secret.sheet.takesKeys, false);
            verify(polkitField().activeFocus, "the polkit field keeps the keyboard");
            typeText("in");
            keyClick(Qt.Key_Return);
            compare(f.submits, ["admin"]);
            polkitEnds();
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "waited");
            compare(rig.secret.sheet.takesKeys, false);
            compare(client.answers.length, 0);
        }

        // The reverse: a polkit request that arrives while a secret sheet is typed into waits (no flow handed to the
        // polkit sheet), also through the secret sheet's linger, then shows held.
        function test_07_secretKeepsTheKeyboard() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            const f = polkitArrives("A");
            compare(rig.polkit.waiting, true);
            compare(rig.polkit.model.active, false, "no request handed to the polkit sheet");
            compare(rig.polkit.sheet.visible, false);
            compare(rig.polkit.sheet.takesKeys, false);
            verify(named("secretField").activeFocus, "the secret field keeps the keyboard");
            typeText("ret");
            keyClick(Qt.Key_Return);
            compare(client.answers[0].password, "secret");
            tryVerify(() => rig.secret.lingering);
            compare(rig.polkit.waiting, true, "the linger keeps the secret sheet's place");
            compare(rig.polkit.sheet.visible, false);
            tryVerify(() => rig.polkit.model.active, 3000);
            compare(rig.polkit.heldByLock, true, "held: right after another sheet");
            compare(rig.polkit.heldWhy, "queued");
            compare(rig.polkit.sheet.takesKeys, false);
            compare(rig.secret.sheet.visible, false, "one sheet on screen at a time");
            compare(f.submits.length, 0);
        }

        // Nothing over the lock: a request that arrives while locked is neither mapped nor given the keyboard; after the
        // unlock it is held until a click past the guard.
        function test_08_locked() {
            SessionState.locked = true;
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.sheet.shown, false);
            compare(rig.secret.sheet.visible, false);
            compare(rig.secret.sheet.takesKeys, false);
            SessionState.locked = false;
            compare(rig.secret.sheet.shown, true);
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "locked");
            compare(rig.secret.sheet.takesKeys, false);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, false);
            wait(600);
            mouseClick(rig.secret.sheet, 5, 5);
            compare(rig.secret.userFocused, true);
            tryVerify(() => named("secretField").activeFocus);
        }

        // Never a password for a request not on screen with the keyboard: behind the lock, or held within the guard, an
        // "ok" is not sent (a new password may be empty, so a stray click on OK must not answer); Cancel still cancels.
        function test_09_noAnswerOffScreen() {
            SessionState.locked = true;
            client.prompt("p1", {passwordNew: true, strength: true});
            shown("p1");
            compare(rig.secret.model.submit("x", "x"), false, "behind the lock: nothing sent");
            compare(client.answers.length, 0);
            SessionState.locked = false;
            mouseClick(named("secretOk"));
            compare(client.answers.length, 0, "OK on a held sheet within the guard sends nothing");
            compare(rig.secret.model.submit("y", "y"), false, "held, no keyboard: nothing sent");
            compare(client.answers.length, 0);
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 1);
            compare(client.answers[0].ok, false, "Cancel at worst");
        }

        // Shown after an unlock: held ("just as the screen was unlocked").
        function test_10_afterUnlock() {
            SessionState.locked = true;
            SessionState.locked = false;
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "unlock");
            compare(rig.secret.sheet.takesKeys, false);
        }

        // The screen saver holds an open request; its waking click answers nothing; the guard starts over at its end.
        function test_11_saver() {
            client.prompt("p1", {});
            shown("p1");
            SessionState.saverShown = true;
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "saver");
            wait(600);
            mouseClick(named("secretCancel"));
            compare(client.answers.length, 0, "the saver swallows the click");
            SessionState.saverShown = false;
            compare(rig.secret.model.heldClickAccepted(), false, "guard restarted");
        }

        // A lost connection drops every request: the queued ones leave unseen, the shown one ends.
        function test_12_lost() {
            client.prompt("p1", {});
            client.prompt("p2", {});
            shown("p1");
            client.drop();
            tryVerify(() => !rig.secret.model.active);
            tryVerify(() => rig.queue.secretCount === 0, 3000);
            compare(rig.secret.requestCount, 0);
            wait(50);
            compare(shownIds, ["p1"]);
        }

        // A new password: typed twice alike (Return in either field takes both); different, nothing is sent, both fields
        // are emptied and the sheet says why; the strength meter follows the length.
        function test_13_newPassword() {
            client.prompt("p1", {passwordNew: true, strength: true});
            shown("p1");
            tryVerify(() => named("secretNewField").activeFocus);
            compare(named("secretStrength").level, 0);
            typeText("abcdefgh");
            compare(named("secretStrength").level, 2);
            named("secretVerifyField").forceActiveFocus();
            typeText("abcdefgX");
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 0);
            verify(named("secretError").text !== "");
            verify(named("secretNewField").empty && named("secretVerifyField").empty);
            named("secretNewField").forceActiveFocus();
            typeText("same");
            named("secretVerifyField").forceActiveFocus();
            typeText("same");
            named("secretNewField").forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(client.answers[0].password, "same");
        }

        // A confirmation (no field: OK is the default button) with the caller's check box; an unidentified program shows
        // its path under the title.
        function test_14_confirmUnidentified() {
            client.prompt("p1", {kind: "confirm", choice: {label: "Remember", chosen: false},
                                 requester: {role: "unidentified", name: "", desktopId: "", icon: "", path: "/home/u/.local/bin/tool", identified: false, onBehalf: false}});
            shown("p1");
            compare(named("secretTitle").text, "An unidentified program asks you to confirm");
            compare(named("secretPath").text, "/home/u/.local/bin/tool");
            compare(named("secretGlyph").name, "exclamationmark-triangle");
            compare(named("secretField").visible, false);
            tryVerify(() => named("secretOk").activeFocus);
            const box = named("secretChoice");
            // The alert lays out at the next polish (a Column), and the check box moves down once it has: click it there.
            waitForItemPolished(box.parent);
            waitForRendering(rig.secret.sheet);
            mouseClick(box);
            compare(rig.secret.model.choice, true);
            named("secretOk").forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(client.answers.length, 1);
            compare(JSON.parse(client.answers[0].line), {type: "answer", id: "p1", result: "ok", choice: true});
            tryVerify(() => !rig.secret.sheet.visible);
            compare(rig.secret.lingering, false, "a confirmation gives the keyboard back");
        }

        // A gcr request that arrives right after the polkit sheet was answered (the user may still be typing) is held.
        function test_16_rightAfterPolkit() {
            const f = polkitArrives("A");
            tryVerify(() => polkitField() && polkitField().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(f.submits, ["pw"]);
            polkitEnds();
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.heldByLock, true);
            compare(rig.secret.heldWhy, "queued");
            compare(rig.secret.sheet.takesKeys, false);
        }

        // A polkit request is never refused by the bound of 8 (ADR-0035 D-9): with eight secret requests held it queues,
        // and its sheet comes once the secret sheets before it are gone.
        function test_17_polkitNeverRefused() {
            for (let i = 1; i <= 8; i++)
                client.prompt("p" + i, {});
            shown("p1");
            const f = polkitArrives("A");
            compare(rig.polkit.waiting, true);
            compare(f.cancels, 0, "queued, not refused");
            for (let i = 2; i <= 8; i++)
                client.withdraw("p" + i);
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            tryVerify(() => rig.polkit.model.active, 3000);
            compare(rig.polkit.model.message, "A");
            compare(f.cancels, 0);
        }

        // A bridge that restarted counts its ids from p1 again: an earlier answer to "p1" (a cancellation, which gives the
        // keyboard back) never stands for the new p1, withdrawn under the user's typing: the keys stay on the sink.
        function test_18_restartedBridgeReusesIds() {
            client.prompt("p1", {});
            shown("p1");
            tryVerify(() => named("secretField").activeFocus);
            keyClick(Qt.Key_Escape);
            compare(client.answers.length, 1);
            tryVerify(() => !rig.secret.model.active);
            client.drop();
            tryVerify(() => rig.queue.secretCount === 0);
            wait(1100); // past the hold that follows another sheet: the new p1 takes the keyboard at once
            client.prompt("p1", {});
            shown("p1");
            compare(rig.secret.model.canSubmit, true, "the new p1 is unanswered");
            compare(rig.secret.sheet.takesKeys, true);
            tryVerify(() => named("secretField").activeFocus);
            typeText("sec");
            client.withdraw("p1");
            tryVerify(() => !rig.secret.model.active);
            compare(rig.secret.lingering, true, "the rest of the password goes to the sink");
            compare(rig.secret.lingerWhy, "cancelled");
        }

        // The caller's text is plain: markup is shown as typed, never rendered.
        function test_15_plainText() {
            client.prompt("p1", {texts: {title: "<b>Admin</b> password", message: "<img src=x>", description: "", warning: "Wrong!", "continue": "", cancel: ""}});
            shown("p1");
            compare(named("secretCaller_title").text, "<b>Admin</b> password");
            compare(named("secretCaller_title").textFormat, Text.PlainText);
            compare(named("secretCaller_message").textFormat, Text.PlainText);
            compare(named("secretCaller_warning").text, "Wrong!");
            compare(named("secretTitle").text, "Keyring asks for a password");
        }
    }
}
