import QtQuick
import QtTest
import qs.security
import qs.services

// The polkit agent (AuthAgent.qml in the harness authagent_flows.sh generates; it runs this file as tst_flows.qml) through the
// request orders Quickshell 0.3.1 produces: a first request (isActive and flow set in either order), one replacing the open
// request (the flow changes, isActive stays true), back-to-back requests, the lock and the screen saver. Real key and mouse
// events.
Item {
    id: top
    width: 800
    height: 600

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
            // test_27: what Quickshell does inside a cancel (the request ends there), else nothing.
            property var onCancel: null
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
                if (onCancel)
                    onCancel();
            }
        }
    }

    // The generated agent, beside this file once authagent_flows.sh copied it (loaded by URL: in the tree there is none).
    readonly property Component agentC: Qt.createComponent(Qt.resolvedUrl("polkit/AgentUnderTest.qml"))

    TestCase {
        name: "AgentFlows"
        when: windowShown

        property var ag: null

        function init() {
            SessionState.locked = false;
            SessionState.saverShown = false;
            compare(top.agentC.status, Component.Ready, top.agentC.errorString());
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
        }

        function mkflow(msg) {
            return createTemporaryObject(flowC, top, {message: msg});
        }
        function arriveFlow(f, isActiveFirst) {
            if (isActiveFirst) {
                ag.agentMock.isActive = true;
                ag.agentMock.flow = f;
            } else {
                ag.agentMock.flow = f;
                ag.agentMock.isActive = true;
            }
        }
        // Quickshell 0.3.1: the active flow goes from A to B at once, isActive stays true.
        function switchTo(f) {
            ag.agentMock.flow = f;
        }
        function endAll(isActiveFirst) {
            if (isActiveFirst) {
                ag.agentMock.isActive = false;
                ag.agentMock.flow = null;
            } else {
                ag.agentMock.flow = null;
                ag.agentMock.isActive = false;
            }
        }
        function dialog() {
            return ag.holderItem.item;
        }
        function find(item, pred) {
            if (pred(item))
                return item;
            for (let i = 0; i < item.children.length; i++) {
                const r = find(item.children[i], pred);
                if (r)
                    return r;
            }
            return null;
        }
        function field() {
            return find(dialog(), i => i.submitted !== undefined && i.clear !== undefined && i.empty !== undefined);
        }
        function button(label) {
            return find(dialog(), i => i.text === label && i.clicked !== undefined);
        }
        function typeText(t) {
            for (const c of t)
                keyClick(c);
        }

        // A first request, then its end. Answered (sent or cancelled) it leaves nothing mapped; ended by its requester while
        // the sheet has the keyboard, the sink keeps it a moment (the user may be typing its password; security
        // counter-review of f9e24e1, LOW-1).
        function test_00_firstArrival_data() {
            return [{tag: "isActive first, sent", first: true, answer: "send"}, {tag: "flow first, sent", first: false, answer: "send"},
                    {tag: "isActive first, cancelled", first: true, answer: "cancel"},
                    {tag: "isActive first, requester gave up", first: true, answer: ""},
                    {tag: "flow first, requester gave up", first: false, answer: ""}];
        }
        function test_00_firstArrival(d) {
            const a = mkflow("A");
            arriveFlow(a, d.first);
            verify(ag.model.active);
            compare(ag.shownFlow, a);
            compare(ag.heldByLock, false);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field() && field().activeFocus);
            if (d.answer === "send") {
                typeText("pw");
                keyClick(Qt.Key_Return);
                compare(a.submits, ["pw"]);
            } else if (d.answer === "cancel") {
                keyClick(Qt.Key_Escape);
                compare(a.cancels, 1);
            }
            endAll(d.first);
            compare(ag.model.active, false);
            compare(ag.shownFlow, null);
            compare(ag.heldByLock, false);
            compare(ag.requestStartedAt, null);
            const lingers = d.answer === "";
            compare(ag.lingering, lingers, lingers ? "ended unanswered with the keyboard: the sink lingers" : "answered: no linger");
            compare(ag.sheet.visible, lingers, lingers ? "still mapped for the linger" : "a request answered as usual leaves nothing mapped");
            compare(ag.sheet.takesKeys, lingers);
        }

        // B replaces A while the user types A's password: held, emptied, the keys on the sink, the guard started over.
        function test_01_replacedWhileTyping() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("secr");
            compare(field().empty, false);
            switchTo(b);
            compare(ag.model.message, "B");
            compare(ag.heldByLock, true, "B held");
            compare(ag.heldWhy, "queued");
            compare(ag.userFocused, false);
            compare(ag.sheet.takesKeys, true, "the keyboard kept, on the sink");
            compare(ag.sinkingKeys, true);
            compare(field().empty, true, "field emptied");
            compare(ag.model.heldClickAccepted(), false, "guard running");
            verify(dialog().heldNotice.indexOf("right after another one") !== -1);
            typeText("et");
            verify(field().empty, "keys typed after the switch reach no field");
            keyClick(Qt.Key_Return);
            compare(b.submits.length, 0, "and Return submits nothing");
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, false, "a click within the guard gives nothing");
            wait(600);
            verify(ag.model.heldClickAccepted());
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            compare(ag.sheet.takesKeys, true);
        }

        // Should Quickshell destroy the flow it abandons before it hands over the next one (0.3.1 overwrites it without deleting
        // it), the model's reference to it reads null and notifies: the open request ends there, under the user's typing, so
        // the sink lingers (security counter-review of f9e24e1, LOW-1: before, the rest of the password went to the window
        // underneath); B, handed over next, is held as one right after another, its field empty, and keeps the sink, as one
        // that arrives during a linger (sink.qml test_18). The agent's own state for a request in the sheet is a flag, never
        // the destroyed flow read back (review of 9ad4307..b38618f).
        function test_01b_oldFlowDestroyedBeforeTheNext() {
            const a = flowC.createObject(top, {message: "A"}), b = mkflow("B");
            arriveFlow(a, true);
            compare(ag.flowShown, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("secr");
            a.destroy();
            wait(0);
            compare(ag.model.active, false, "the destroyed flow ends the open request");
            compare(ag.flowShown, false);
            compare(ag.shownFlow, null);
            compare(ag.lingering, true, "it ended under the typing: the sink keeps the keys");
            verify(ag.sink.activeFocus);
            typeText("et");
            switchTo(b);
            compare(ag.model.message, "B");
            compare(ag.flowShown, true);
            compare(ag.heldByLock, true, "B held");
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true, "B keeps the sink");
            compare(ag.sheet.takesKeys, true, "the keyboard stays on the sink, not B's field");
            tryVerify(() => field() !== null);
            compare(field().empty, true, "B's field starts empty");
            typeText("x");
            keyClick(Qt.Key_Return);
            verify(field().empty, "keys typed after B came reach no field");
            compare(b.submits.length, 0);
            compare(b.cancels, 0);
        }

        // A was held by the lock, the user clicked it; B replaces it: held again, on the sink, the guard started over.
        function test_02_replacedAfterClickThroughLockHold() {
            const a = mkflow("A"), b = mkflow("B");
            SessionState.locked = true;
            arriveFlow(a, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            compare(ag.sheet.shown, false);
            SessionState.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.sheet.takesKeys, false);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            switchTo(b);
            compare(ag.userFocused, false);
            compare(ag.heldByLock, true);
            compare(ag.sheet.takesKeys, true, "it had the keyboard: kept, on the sink");
            compare(ag.sinkingKeys, true);
            compare(ag.model.heldClickAccepted(), false);
        }

        // `pkexec a; pkexec b`: A answered, B comes right after A ended, through no request: held, without the keyboard.
        function test_03_endThenQuickNext() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(a.submits, ["pw"]);
            endAll(true);
            compare(ag.lingering, false, "answered: no linger");
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sheet.takesKeys, false);
        }

        // Within the guard, Cancel still cancels the held request (Cancel at worst), and Allow submits nothing.
        function test_04_cancelHeldWithinGuard() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            switchTo(b);
            mouseClick(button("Cancel"));
            compare(b.cancels, 1);
            compare(a.cancels, 0);
            compare(ag.userFocused, false);
        }
        function test_05_allowHeldWithinGuard() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            switchTo(b);
            mouseClick(button("Allow"));
            compare(b.submits.length, 0, "nothing submitted to B");
            compare(a.submits.length, 0);
        }

        // Past the guard, a click on the field gives it the keyboard: B is answered, then Esc cancels it.
        function test_06_answerHeldAfterClick() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            switchTo(b);
            wait(600);
            mouseClick(field());
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"]);
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }

        // Replaced while locked: not mapped; after the unlock held, without the keyboard, the guard started when shown.
        function test_07_replacedWhileLocked() {
            const a = mkflow("A"), b = mkflow("B");
            SessionState.locked = true;
            arriveFlow(a, true);
            switchTo(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            compare(ag.sheet.shown, false);
            wait(600);
            SessionState.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.model.heldClickAccepted(), false, "guard restarted when shown");
            compare(ag.sheet.takesKeys, false);
        }

        // Replaced under the screen saver: a click goes nowhere; when the saver ends the guard starts over.
        function test_08_replacedUnderSaver() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            SessionState.saverShown = true;
            compare(ag.heldByLock, true);
            switchTo(b);
            compare(ag.heldByLock, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, false, "the saver swallows the click");
            SessionState.saverShown = false;
            compare(ag.model.heldClickAccepted(), false, "guard restarted at the saver's end");
            compare(ag.sheet.takesKeys, false);
        }

        // The same flow set again is not a new arrival.
        function test_10_sameFlowAgain() {
            const a = mkflow("A");
            arriveFlow(a, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            switchTo(a);
            compare(ag.heldByLock, false);
            compare(ag.sheet.takesKeys, true);
        }

        // Under the saver, middle, right and left clicks on Cancel answer nothing.
        function test_11_buttonsSwallowedUnderSaver() {
            const a = mkflow("A");
            arriveFlow(a, true);
            SessionState.saverShown = true;
            const c = button("Cancel");
            mouseClick(c, c.width / 2, c.height / 2, Qt.MiddleButton);
            mouseClick(c, c.width / 2, c.height / 2, Qt.RightButton);
            mouseClick(c);
            compare(a.cancels, 0);
        }

        // ADR-0045 OC-6 (security review of e3542510, MAJOR-2): no device answers a request the user cannot see and answer.
        // Quickshell runs PAM as soon as polkit asks; once pam_fprintd (or pam_u2f) talks without asking for a request that
        // is locked away, under the saver, waiting behind another sheet or held and not clicked, the agent refuses it (the
        // requester is told no) before a touch meant for the lock screen or another request can approve it. PAM asking for a
        // password ends nothing. The mock flow stays after a cancel (Quickshell would end it): the tests count the cancels.
        function reader(f) {
            f.isResponseRequired = false;
            f.supplementaryMessage = "Place your right index finger on the fingerprint reader";
        }

        function test_20_shownRequestKeepsTheReaderUntilTheLock() {
            const a = mkflow("A");
            arriveFlow(a, true);
            compare(ag.heldByLock, false);
            reader(a);
            verify(ag.model.awaitingDevice);
            wait(1);
            compare(a.cancels, 0, "the user sees the sheet and may touch the reader");
            SessionState.locked = true;
            tryCompare(a, "cancels", 1, 1000, "the lock came while the reader waited: refused at once");
            compare(a.submits.length, 0);
        }

        function test_21_arrivedLockedRefusedWhenPamReachesTheReader_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_21_arrivedLockedRefusedWhenPamReachesTheReader(d) {
            const a = mkflow("A");
            SessionState.locked = true;
            arriveFlow(a, d.first);
            wait(1);
            compare(a.cancels, 0, "PAM said nothing yet");
            reader(a);
            tryCompare(a, "cancels", 1);
            compare(a.submits.length, 0);
        }

        // The macOS model kept for a password: PAM asks (pam_faillock's line above the prompt or not), the request waits
        // behind the lock and is shown, held, after the unlock.
        function test_22_passwordPromptWaitsBehindTheLock() {
            const a = mkflow("A");
            SessionState.locked = true;
            arriveFlow(a, true);
            a.supplementaryMessage = "The account is locked due to 3 failed logins.";
            SessionState.locked = false;
            compare(ag.sheet.shown, true);
            compare(ag.heldByLock, true);
            wait(1);
            compare(a.cancels, 0);
        }

        function test_23_underTheSaver() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            reader(a);
            SessionState.saverShown = true;
            tryCompare(a, "cancels", 1, 1000, "open and awaiting the reader when the saver came");
            endAll(true);
            arriveFlow(b, true);
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "arrived under the saver");
        }

        // Held and shown without the keyboard (just after an unlock, right after another request): refused while nobody
        // clicked it past its guard; once clicked, the user turned to it and the reader may answer it.
        function test_24_heldUntilClicked_data() {
            return [{tag: "just after the unlock", why: "unlock"}, {tag: "right after another one", why: "queued"}];
        }
        function test_24_heldUntilClicked(d) {
            const a = mkflow("A"), b = mkflow("B"), c = mkflow("C");
            if (d.why === "unlock") {
                SessionState.locked = true;
                SessionState.locked = false;
            } else {
                arriveFlow(a, true);
                endAll(true);
            }
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, d.why);
            compare(ag.sheet.shown, true);
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "held, nobody turned to it");
            endAll(true);
            wait(1100);
            if (d.why === "unlock") {
                SessionState.locked = true;
                SessionState.locked = false;
            } else {
                arriveFlow(a, true);
                endAll(true);
            }
            arriveFlow(c, true);
            compare(ag.heldByLock, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            reader(c);
            wait(1);
            compare(c.cancels, 0, "clicked past its guard: the user answers it");
            wait(1);
            compare(a.cancels, 0);
        }

        // Replaced: the request that follows is held, on the sink; its reader prompt refuses it.
        function test_25_replacementHeldOnTheSink() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("se");
            switchTo(b);
            compare(ag.sinkingKeys, true);
            reader(b);
            tryCompare(b, "cancels", 1);
        }

        // Waiting behind a secret sheet (the model is handed nothing): the agent still guards the request Quickshell has open.
        function test_26_waitingBehindASecretSheet() {
            const q = createTemporaryObject(queueC, top);
            verify(q.addSecret("network"));
            ag.queue = q;
            compare(ag.waiting, true);
            const a = mkflow("A");
            arriveFlow(a, true);
            compare(ag.model.active, false, "not handed to the sheet");
            wait(1);
            compare(a.cancels, 0);
            reader(a);
            tryCompare(a, "cancels", 1);
        }

        // Quickshell ends the request inside cancelAuthenticationRequest (the session completes, the agent finishes it), so the
        // refusal's end runs inside the lock's or the saver's own change: the agent is left with no request, nothing mapped, no
        // sink, and the next request after the unlock or the saver arrives as usual (held: just after the unlock, or right after
        // another one).
        function test_27_refusalEndsTheRequestInsideTheChange_data() {
            return [{tag: "lock", saver: false}, {tag: "saver", saver: true}];
        }
        function test_27_refusalEndsTheRequestInsideTheChange(d) {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            reader(a);
            a.onCancel = () => endAll(true);
            if (d.saver)
                SessionState.saverShown = true;
            else
                SessionState.locked = true;
            tryCompare(a, "cancels", 1);
            compare(a.submits.length, 0);
            compare(ag.model.active, false);
            compare(ag.requestOpen, false);
            compare(ag.sinkingKeys, false, "no sink left under the lock or the saver");
            compare(ag.sheet.visible, false);
            compare(ag.sheet.takesKeys, false);
            SessionState.saverShown = false;
            SessionState.locked = false;
            arriveFlow(b, true);
            compare(ag.heldByLock, true);
            compare(ag.sheet.takesKeys, false);
            wait(1);
            compare(b.cancels, 0, "PAM said nothing for B yet");
            reader(b);
            tryCompare(b, "cancels", 1, 1000, "the next request is guarded too (no binding left stale by the first end)");
        }
    }

    Component {
        id: queueC
        SheetQueue {}
    }
}
