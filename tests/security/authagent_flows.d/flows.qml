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

        function test_00_firstArrival_data() {
            return [{tag: "isActive first", first: true}, {tag: "flow first", first: false}];
        }
        function test_00_firstArrival(d) {
            const a = mkflow("A");
            arriveFlow(a, d.first);
            verify(ag.model.active);
            compare(ag.shownFlow, a);
            compare(ag.heldByLock, false);
            compare(ag.sheet.takesKeys, true);
            endAll(d.first);
            compare(ag.model.active, false);
            compare(ag.shownFlow, null);
            compare(ag.heldByLock, false);
            compare(ag.requestStartedAt, null);
            compare(ag.sheet.visible, false, "a request answered as usual leaves nothing mapped");
            compare(ag.sheet.takesKeys, false);
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

        // `pkexec a; pkexec b`: B comes right after A ended, through no request: held, without the keyboard.
        function test_03_endThenQuickNext() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a, true);
            endAll(true);
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
