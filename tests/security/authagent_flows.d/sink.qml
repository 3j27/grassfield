import QtQuick
import QtTest
import qs.services

// The polkit agent's key sink (AuthAgent.qml in the harness authagent_flows.sh generates; it runs this file as tst_sink.qml).
// When a request replaces the one the user was typing into, the keyboard stays with the window, on the sink: nothing typed
// reaches the new request's field, whatever moves the focus (re-check of b5d7657, MEDIUM-2; check of 38dbfe8, MEDIUM-A), until
// a click past the guard. A request that ends while the sink has the keys leaves it lingering, so the rest of a password never
// reaches the window underneath (check of 38dbfe8, MEDIUM-B). Also the hold after a request (afterRequest).
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
            signal authenticationFailed
            signal authenticationSucceeded
            signal authenticationRequestCancelled
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
        name: "Sink"
        when: windowShown

        property var ag: null

        function init() {
            SessionState.locked = false;
            SessionState.saverShown = false;
            compare(top.agentC.status, Component.Ready, top.agentC.errorString());
            ag = createTemporaryObject(top.agentC, top);
            verify(ag);
        }

        function mkflow(msg, extra) {
            return createTemporaryObject(flowC, top, Object.assign({message: msg}, extra || {}));
        }
        function arriveFlow(f) {
            ag.agentMock.isActive = true;
            ag.agentMock.flow = f;
        }
        function switchTo(f) {
            ag.agentMock.flow = f;
        }
        function endAll() {
            ag.agentMock.isActive = false;
            ag.agentMock.flow = null;
        }
        function dialog() {
            return ag.holderItem.item;
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
        // A was replaced by B while the user typed into it: the keys on the sink.
        function sinkB(extraB) {
            const a = mkflow("A"), b = mkflow("B", extraB);
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("sec");
            switchTo(b);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            verify(ag.sink.activeFocus, "the sink has the focus");
            verify(!field().activeFocus);
            return [a, b];
        }
        // Typed now, then Return: nothing reaches B, and the sink still has the focus.
        function expectNothingReaches(b, why) {
            typeText("ret");
            keyClick(Qt.Key_Return);
            verify(field().empty, why + ": the field stays empty");
            compare(b.submits.length, 0, why + ": nothing submitted");
            verify(ag.sink.activeFocus, why + ": the sink has the focus");
        }

        // MEDIUM-A: a press on the dim backdrop within the guard.
        function test_01_backdropClickWithinGuard() {
            const [a, b] = sinkB();
            compare(ag.model.heldClickAccepted(), false, "guard running");
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, true);
            expectNothingReaches(b, "a backdrop click within the guard");
        }

        // MEDIUM-A: a press on the field itself within the guard (the field takes the focus on a press).
        function test_02_fieldPressWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(field(), 10, 5);
            expectNothingReaches(b, "a press on the field within the guard");
        }

        // A press on Allow within the guard: nothing submitted; Esc then cancels B (it fails closed).
        function test_03_allowPressWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(button("Allow"));
            expectNothingReaches(b, "a press on Allow within the guard");
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }

        // MEDIUM-A: B fails on its own (its helper died, PAM failed); the sheet focuses its field after a failure.
        function test_04_failedWhileSinking() {
            const [a, b] = sinkB();
            b.authenticationFailed();
            expectNothingReaches(b, "B's own failure");
        }

        // Tab, Backtab and Space on an identity row change nothing.
        function test_05_tabSpaceIdentity() {
            const i1 = {displayName: "alice"}, i2 = {displayName: "root"};
            const [a, b] = sinkB({identities: [i1, i2], selectedIdentity: i1});
            keyClick(Qt.Key_Tab);
            keyClick(Qt.Key_Space);
            keyClick(Qt.Key_Backtab);
            keyClick(Qt.Key_Space);
            compare(b.selectedIdentity, i1, "no identity change");
            verify(!field().activeFocus);
            compare(b.cancels, 0);
            compare(b.submits.length, 0);
        }

        // MEDIUM-B: B ends while the keys are sunk: the window stays mapped and keeps them, then lets go a second after the last.
        function test_06_endWhileSinkingLingers() {
            const [a, b] = sinkB();
            endAll();
            compare(ag.lingering, true);
            compare(ag.sheet.visible, true, "still mapped");
            compare(ag.sheet.takesKeys, true, "the keyboard kept: the rest of a password reaches nothing underneath");
            verify(ag.sink.activeFocus);
            typeText("word");
            keyClick(Qt.Key_Return);
            compare(ag.lingering, true);
            tryCompare(ag, "lingering", false, 2000);
            compare(ag.sheet.takesKeys, false);
            compare(ag.sheet.visible, false);
            compare(ag.sinkingKeys, false);
        }

        // Each key keeps the linger, which ends anyway at sinkLingerMaxMs.
        function test_06b_lingerCapped() {
            const [a, b] = sinkB();
            endAll();
            for (let i = 0; i < 8; i++) {
                wait(300);
                keyClick("x");
                compare(ag.lingering, true, "a key keeps it (" + i + ")");
            }
            tryCompare(ag, "lingering", false, 1500, "at most sinkLingerMaxMs");
        }

        // A click, the lock or the screen saver ends the linger.
        function test_06c_clickEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            mouseClick(ag.sheet, 5, 5);
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
        }
        function test_06d_lockEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            SessionState.locked = true;
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
            SessionState.locked = false;
            compare(ag.lingering, false, "not back after the unlock");
            compare(ag.sheet.visible, false);
        }
        function test_06e_saverEndsLinger() {
            const [a, b] = sinkB();
            endAll();
            SessionState.saverShown = true;
            compare(ag.lingering, false);
            compare(ag.sheet.takesKeys, false);
        }

        // A third request while sinking keeps sinking, its guard started over.
        function test_07_thirdWhileSinking() {
            const [a, b] = sinkB();
            const c = mkflow("C");
            switchTo(c);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            expectNothingReaches(c, "C");
            compare(ag.model.heldClickAccepted(), false, "guard restarted");
        }

        // MEDIUM-A: a click within the guard, then a third request: the sink still has the keys.
        function test_08_thirdAfterClickWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(ag.sheet, 5, 5);
            const c = mkflow("C");
            switchTo(c);
            expectNothingReaches(c, "C after a click within the guard");
        }

        // The lock takes the sink's keys; after the unlock B is held without the keyboard, answered after a click.
        function test_09_lockWhileSinking() {
            const [a, b] = sinkB();
            SessionState.locked = true;
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.shown, false);
            SessionState.locked = false;
            compare(ag.sheet.takesKeys, false);
            compare(ag.heldByLock, true);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"]);
        }

        // The screen saver takes the sink's keys; after it, a click past the guard gives the keyboard.
        function test_10_saverWhileSinking() {
            const [a, b] = sinkB();
            SessionState.saverShown = true;
            compare(ag.sinkingKeys, false);
            compare(ag.sheet.takesKeys, false);
            SessionState.saverShown = false;
            compare(ag.sheet.takesKeys, false);
            compare(ag.model.heldClickAccepted(), false);
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sheet.takesKeys, true);
        }

        // After a click past the guard the field has the keys: Esc cancels as usual. Cancel within the guard works too.
        function test_11_escapeAfterClick() {
            const [a, b] = sinkB();
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, false);
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
        }
        function test_12_cancelWithinGuard() {
            const [a, b] = sinkB();
            mouseClick(button("Cancel"));
            compare(b.cancels, 1);
        }

        // A key pressed into A and released after B replaced it, then autorepeat: nothing in B's field.
        function test_13_keyHeldAcrossSwitch() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            keyPress("k");
            switchTo(b);
            keyRelease("k");
            keyPress("k", Qt.NoModifier, -1);
            keyPress("k", Qt.NoModifier, -1);
            keyRelease("k");
            verify(field().empty);
        }

        // afterRequest: held within a second after another ended, not after; no keyboard, its own notice.
        function test_14_afterRequestHold() {
            const a = mkflow("A"), b = mkflow("B"), c = mkflow("C");
            arriveFlow(a);
            compare(ag.heldByLock, false);
            endAll();
            arriveFlow(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sheet.takesKeys, false);
            compare(ag.sinkingKeys, false);
            endAll();
            wait(1200);
            arriveFlow(c);
            compare(ag.heldByLock, false, "after a second: not held");
            compare(ag.sheet.takesKeys, true);
        }

        // The hold after a request never lifts a lock's and keeps its reason.
        function test_15_afterRequestWithLock() {
            const a = mkflow("A"), b = mkflow("B");
            arriveFlow(a);
            endAll();
            SessionState.locked = true;
            arriveFlow(b);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "locked");
            SessionState.locked = false;
            compare(ag.sheet.takesKeys, false);
        }

        function test_16_firstArrivalNotHeld() {
            arriveFlow(mkflow("A"));
            compare(ag.heldByLock, false);
            compare(ag.model.followsAnother(), false);
        }

        // Sinking, then a click past the guard: B gets only what is typed after the click.
        function test_17_answerAfterClick() {
            const [a, b] = sinkB();
            typeText("lost");
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.sinkingKeys, false);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(b.submits, ["pw"], "only what was typed after the click");
            compare(a.submits.length, 0);
        }

        // B ends while sinking and C arrives during the linger: C is held and the sink keeps the keys.
        function test_18_nextDuringLinger() {
            const [a, b] = sinkB();
            endAll();
            compare(ag.lingering, true);
            const c = mkflow("C");
            arriveFlow(c);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            tryVerify(() => field() !== null);
            expectNothingReaches(c, "C arrived during the linger");
            wait(1300);
            compare(ag.sinkingKeys, true, "the linger's end does not touch a request's sink");
        }

        // C arrives during the linger more than a second after B ended (the hold after a request is over): still held, with
        // the sink, so a click past its guard gives it the keyboard.
        function test_18b_nextLateInLinger() {
            const [a, b] = sinkB();
            endAll();
            for (let i = 0; i < 4; i++) {
                wait(300);
                keyClick("x");
            }
            compare(ag.lingering, true);
            compare(ag.model.followsAnother(), false, "the hold after a request is over");
            const c = mkflow("C");
            arriveFlow(c);
            compare(ag.heldByLock, true);
            compare(ag.heldWhy, "queued");
            compare(ag.sinkingKeys, true);
            tryVerify(() => field() !== null);
            expectNothingReaches(c, "C arrived late in the linger");
            wait(600);
            mouseClick(ag.sheet, 5, 5);
            compare(ag.userFocused, true);
            tryVerify(() => field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(c.submits, ["pw"]);
        }

        // The sink still holds once the event loop ran (no deferred reset).
        function test_19_sinkHoldsOverTime() {
            const [a, b] = sinkB();
            wait(50);
            compare(ag.sinkingKeys, true);
            compare(ag.sheet.takesKeys, true);
            typeText("x");
            verify(field().empty);
        }

        // LOW-1: Esc on the sink cancels the held request (fail closed); the sink then lingers.
        function test_20_escapeCancelsHeld() {
            const [a, b] = sinkB();
            keyClick(Qt.Key_Escape);
            compare(b.cancels, 1);
            compare(a.cancels, 0);
        }

        // A request answered as usual (not sinking) leaves no linger.
        function test_21_noLingerAfterAnAnswer() {
            const a = mkflow("A");
            arriveFlow(a);
            tryVerify(() => field() && field().activeFocus);
            typeText("pw");
            keyClick(Qt.Key_Return);
            compare(a.submits, ["pw"]);
            endAll();
            compare(ag.lingering, false);
            compare(ag.sheet.visible, false);
            compare(ag.sheet.takesKeys, false);
        }
    }
}
