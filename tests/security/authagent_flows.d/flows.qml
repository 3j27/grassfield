import QtQuick
import QtTest
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
            function submit(p) {
                submits.push(p);
            }
            function cancelAuthenticationRequest() {
                cancels++;
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
    }
}
