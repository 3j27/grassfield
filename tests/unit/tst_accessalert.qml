pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// grassfield-portal's permission alert (apps/files/qml/AccessAlert.qml; ADR-0035 D-5, docs/specs/system-dialogs.md section 2,
// AC1-AC3) offscreen, over a stand-in Access (the answers it gets): the buttons and their labels, the default button only
// where macOS has one (AC2), Esc and the window closed, the choices, no answer before the alert is armed, and the hold rule
// for an alert that gets the keyboard late (AC3).
TestCase {
    id: test
    name: "AccessAlert"
    when: windowShown

    QtObject {
        id: fakeHost
        property var answers: []
        function answer(id: int, grant: bool, choices: var): void {
            fakeHost.answers = fakeHost.answers.concat([{id: id, grant: grant, choices: choices}]);
        }
    }

    QtObject {
        id: fakeManager
        property string testAnswer: ""
    }

    Component {
        id: alertComponent
        AccessAlert {
            host: fakeHost
            manager: fakeManager
            requestId: 4
        }
    }

    function request(fields: var): var {
        return Object.assign({appId: "org.example.App", appIcon: "", title: "Allow Example to Access Your Location?",
                              subtitle: "Example wants to use your location", body: "Location access can be changed at any time from the privacy settings",
                              denyLabel: "", grantLabel: "", icon: "find-location-symbolic", modal: true, parented: false, noDefault: false,
                              choices: []}, fields);
    }

    // An alert for `fields`, shown, active and armed (unless `armed` is false).
    function openAlert(fields: var, extra: var, armed: var): var {
        fakeHost.answers = [];
        const alert = createTemporaryObject(alertComponent, test, Object.assign({request: test.request(fields)}, extra || {}));
        verify(alert !== null, "AccessAlert");
        alert.show();
        alert.requestActivate();
        tryVerify(() => alert.active, 2000, "the alert is active");
        if (armed !== false)
            tryVerify(() => alert.armed, 2000, "armed after its first frame");
        return alert;
    }

    function find(item: var, matches: var): var {
        if (matches(item))
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = test.find(item.children[i], matches);
            if (found)
                return found;
        }
        return null;
    }

    function button(alert: var, text: string): var {
        return test.find(alert.contentItem, i => i instanceof Button && i.text === text);
    }

    function cleanup(): void {
        fakeManager.testAnswer = "";
    }

    function test_the_labels_are_grassfields_or_the_frontends(): void {
        const alert = test.openAlert({});
        verify(test.button(alert, "Don't Allow") !== null);
        verify(test.button(alert, "Allow") !== null);
        const deny = test.button(alert, "Don't Allow");
        const grant = test.button(alert, "Allow");
        compare(deny.width, grant.width, "one width");
        verify(deny.capsule && grant.capsule, "alert capsules");
        verify(deny.x + deny.width <= grant.x, "Allow on the right");
        verify(grant.x + grant.width <= alert.width, "inside the alert");
        const given = test.openAlert({denyLabel: "Deny Access", grantLabel: "Grant Access"});
        verify(test.button(given, "Deny Access") !== null);
        verify(test.button(given, "Grant Access") !== null);
    }

    function test_return_grants_where_the_grant_button_is_the_default(): void {
        const alert = test.openAlert({});
        verify(test.button(alert, "Allow").primary);
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
        compare(fakeHost.answers[0].id, 4);
    }

    // AC2: for the camera and screen capture neither button is the default; Return does nothing until a button has the
    // keyboard.
    function test_no_default_button_for_the_camera(): void {
        const alert = test.openAlert({icon: "camera-web-symbolic", noDefault: true});
        verify(!test.button(alert, "Allow").primary, "no default button");
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Enter);
        wait(50);
        compare(fakeHost.answers.length, 0, "Return answers nothing");
        keyClick(Qt.Key_Tab);
        keyClick(Qt.Key_Tab);
        verify(test.button(alert, "Allow").activeFocus || test.button(alert, "Don't Allow").activeFocus, "Tab reaches the buttons");
        keyClick(Qt.Key_Space);
        tryVerify(() => fakeHost.answers.length === 1);
    }

    function test_escape_and_the_window_closed_deny(): void {
        const alert = test.openAlert({});
        keyClick(Qt.Key_Escape);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, false);
        keyClick(Qt.Key_Return);
        wait(50);
        compare(fakeHost.answers.length, 1, "answered once");

        const closed = test.openAlert({});
        closed.close();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, false);
    }

    function test_a_click_on_a_button_answers(): void {
        const alert = test.openAlert({});
        const deny = test.button(alert, "Don't Allow");
        mouseClick(deny, deny.width / 2, deny.height / 2);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, false);
    }

    // A click or a key in the first moments after the alert drew answers nothing: one meant for what was there before never
    // grants.
    function test_nothing_answers_before_the_alert_is_armed(): void {
        const alert = test.openAlert({}, {armMs: 3000}, false);
        verify(!alert.armed);
        const grant = test.button(alert, "Allow");
        mouseClick(alert.contentItem, grant.mapToItem(alert.contentItem, 0, 0).x + grant.width / 2, grant.mapToItem(alert.contentItem, 0, 0).y + grant.height / 2);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Escape);
        compare(fakeHost.answers.length, 0, "not armed yet: nothing answered");
        tryVerify(() => alert.armed, 5000);
        mouseClick(grant, grant.width / 2, grant.height / 2);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
    }

    // ADR-0035 5a-5 (review of step 5a, M2): the keyboard starts on the alert, never on a button: Space typed for another window
    // never grants; Return grants where Allow is the default.
    function test_space_never_grants_from_the_start(): void {
        const alert = test.openAlert({});
        verify(!test.button(alert, "Allow").activeFocus && !test.button(alert, "Don't Allow").activeFocus, "no button has the keyboard");
        keyClick(Qt.Key_Space);
        wait(50);
        compare(fakeHost.answers.length, 0, "Space answers nothing");
    }

    // Keys typed on while the alert is not armed start its time again: typing for another window never arms it.
    function test_keys_typed_on_keep_it_unarmed(): void {
        const alert = test.openAlert({}, {armMs: 400}, false);
        for (let i = 0; i < 6; i++) {
            keyClick(Qt.Key_A);
            wait(150);
        }
        verify(!alert.armed, "still typing: not armed");
        keyClick(Qt.Key_Return);
        compare(fakeHost.answers.length, 0);
        tryVerify(() => alert.armed, 2000);
    }

    // A close before the alert is armed (one meant for the window before it) is refused; after it, it denies.
    function test_a_close_before_it_is_armed_is_refused(): void {
        const alert = test.openAlert({}, {armMs: 3000}, false);
        alert.close();
        wait(50);
        verify(alert.visible, "still shown");
        compare(fakeHost.answers.length, 0);
        tryVerify(() => alert.armed, 5000);
        alert.close();
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, false);
    }

    // Each time the alert becomes the active window again it is armed again, and the keyboard is back on the alert, never on
    // the button it had (counter-review of step 5a).
    function test_becoming_active_again_rearms_it(): void {
        const alert = test.openAlert({});
        keyClick(Qt.Key_Tab);
        verify(test.button(alert, "Allow").activeFocus || test.button(alert, "Don't Allow").activeFocus, "Tab reached a button");
        // Away a moment, then the active window again (onActiveChanged's calls: the offscreen platform moves no activation
        // between windows; the first activation, which openAlert waits on, goes through the same function).
        alert.inactiveSince = Date.now();
        alert.becameActive();
        verify(!alert.armed, "not armed right after it became active again");
        verify(!alert.keysHeld, "back after a moment: no hold");
        verify(!test.button(alert, "Allow").activeFocus && !test.button(alert, "Don't Allow").activeFocus, "the keyboard is on the alert");
        const grant = test.button(alert, "Allow");
        mouseClick(grant, grant.width / 2, grant.height / 2);
        keyClick(Qt.Key_Space);
        wait(50);
        compare(fakeHost.answers.length, 0, "the click and the key that came with it answer nothing");
        tryVerify(() => alert.armed, 2000);
    }

    // AC3: an alert that gets the keyboard late (it opened behind the lock) takes keys only after a click in it.
    function test_an_alert_that_gets_the_keyboard_late_waits_for_a_click(): void {
        const alert = test.openAlert({}, {shownAt: 1});
        verify(alert.keysHeld);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Escape);
        wait(50);
        compare(fakeHost.answers.length, 0, "a key does not answer it");
        mousePress(alert.contentItem, 10, 10);
        mouseRelease(alert.contentItem, 10, 10);
        verify(!alert.keysHeld);
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
    }

    // Back after a long time away (it was open when the lock or another window came in front of it): keys wait for a click
    // again, as for an alert that first gets the keyboard late (integrator review of e24ea5c, MINOR 1: a Return after the
    // unlock granted a location alert).
    function test_back_after_a_long_time_away_waits_for_a_click(): void {
        const alert = test.openAlert({});
        verify(!alert.keysHeld, "active at once: no hold");
        alert.inactiveSince = Date.now() - 2 * Tokens.filesPanelLateFocusMs;
        alert.becameActive();
        verify(alert.keysHeld, "held after a long time away");
        tryVerify(() => alert.armed, 2000);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        wait(50);
        compare(fakeHost.answers.length, 0, "Return and Space answer nothing");
        const grant = test.button(alert, "Allow");
        const at = grant.mapToItem(alert.contentItem, grant.width / 2, grant.height / 2);
        mouseClick(alert.contentItem, at.x, at.y);
        wait(50);
        verify(!alert.keysHeld, "the click ended the hold");
        compare(fakeHost.answers.length, 0, "and answered nothing");
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
    }

    // The click that ends the hold only ends it, even on Allow (review of step 5a, M1: behind the lock, the first click after
    // the unlock went on to the button under it).
    function test_the_click_that_ends_the_hold_is_no_answer(): void {
        const alert = test.openAlert({}, {shownAt: 1});
        verify(alert.keysHeld);
        const grant = test.button(alert, "Allow");
        const at = grant.mapToItem(alert.contentItem, grant.width / 2, grant.height / 2);
        mouseClick(alert.contentItem, at.x, at.y);
        wait(50);
        verify(!alert.keysHeld, "the hold ended");
        compare(fakeHost.answers.length, 0, "and nothing was answered");
        mouseClick(grant, grant.width / 2, grant.height / 2);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
    }

    // The frontend's choices: a check box and a pop-up; every choice is answered.
    function test_the_choices_are_answered(): void {
        const alert = test.openAlert({choices: [{id: "remember", label: "Remember", options: [], initial: "true"},
                                                {id: "level", label: "Accuracy", options: [{id: "city", label: "City"}, {id: "exact", label: "Exact"}], initial: "city"}]});
        const box = test.find(alert.contentItem, i => i instanceof CheckBox && i.text === "Remember");
        verify(box !== null);
        verify(box.checked);
        mouseClick(box, 4, box.height / 2);
        tryVerify(() => !box.checked);
        const grant = test.button(alert, "Allow");
        mouseClick(grant, grant.width / 2, grant.height / 2);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].choices, [{id: "remember", value: "false"}, {id: "level", value: "city"}]);
    }

    function test_the_frontends_text_and_the_dialog_role(): void {
        const alert = test.openAlert({});
        verify(test.find(alert.contentItem, i => i instanceof Text && i.text === "Example wants to use your location") !== null);
        verify(test.find(alert.contentItem, i => i instanceof Text && i.text === "Location access can be changed at any time from the privacy settings") !== null);
        compare(alert.title, "Allow Example to Access Your Location?");
        compare(alert.width, Tokens.panelAlertWidth);
        compare(alert.gfChromeRole, "access-alert");
    }

    // Dev plumbing: the integration test's answers.
    function test_the_test_answer_answers_once(): void {
        fakeManager.testAnswer = "accept";
        const alert = test.openAlert({}, {}, false);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
        wait(100);
        compare(fakeHost.answers.length, 1);
    }
}
