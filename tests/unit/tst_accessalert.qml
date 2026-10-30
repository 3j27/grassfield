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

    // Access as AccessAlerts.qml sees it: the requests it opens and closes, the windows presented and the ones queued.
    QtObject {
        id: fakeAccess
        signal opened(int id, var request)
        signal closed(int id)
        property var presented: []
        property var queued: []
        function present(id: int, window: var): void {
            fakeAccess.presented = fakeAccess.presented.concat([id]);
            window.show();
        }
        function queue(id: int): void {
            fakeAccess.queued = fakeAccess.queued.concat([id]);
        }
        function fail(id: int): void {
        }
        function answer(id: int, grant: bool, choices: var): void {
            fakeAccess.closed(id);
        }
    }

    Component {
        id: managerComponent
        AccessAlerts {}
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
        tryVerify(() => alert.armed, 2000, "armed again after the click");
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
        tryVerify(() => alert.armed, 2000, "armed again after the click");
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
        compare(fakeHost.answers[0].grant, true);
    }

    // A held alert left for a moment and back keeps its hold: only a click in it ends it (integrator re-review of 1745c0c,
    // mutant N5).
    function test_a_held_alert_left_briefly_keeps_its_hold(): void {
        const alert = test.openAlert({}, {shownAt: 1});
        verify(alert.keysHeld);
        alert.inactiveSince = Date.now();
        alert.becameActive();
        verify(alert.keysHeld, "still held after a short time away");
        tryVerify(() => alert.armed, 2000);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        wait(50);
        compare(fakeHost.answers.length, 0, "Return and Space answer nothing");
        mouseClick(alert.contentItem, 10, 10);
        verify(!alert.keysHeld, "the click ended the hold");
        compare(fakeHost.answers.length, 0, "and answered nothing");
    }

    // The first click after the unlock ends the hold, whether the alert was armed or not, and whether that click came just
    // before the alert became active or after (integrator nested pass of 1745c0c, MINOR 2: it took three clicks).
    function test_the_first_click_after_the_unlock_ends_the_hold(): void {
        const alert = test.openAlert({}, {shownAt: 1}, false);
        verify(alert.keysHeld && !alert.armed, "held and not armed yet");
        mouseClick(alert.contentItem, 10, 10);
        verify(!alert.keysHeld, "that click ended the hold");
        compare(fakeHost.answers.length, 0, "and answered nothing");
        tryVerify(() => alert.armed, 2000);
        keyClick(Qt.Key_Return);
        tryVerify(() => fakeHost.answers.length === 1);
    }

    // The press in the alert that made it active may come just before the activation: it is that click, and no hold follows.
    function test_the_click_that_made_it_active_is_that_click(): void {
        const alert = test.openAlert({}, {}, false);
        mouseClick(alert.contentItem, 10, 10);
        alert.inactiveSince = Date.now() - 2 * Tokens.filesPanelLateFocusMs;
        alert.becameActive();
        verify(!alert.keysHeld, "the click that made it active counts");
        compare(fakeHost.answers.length, 0);
    }

    // MAJOR 1 of the integrator's nested pass of 1745c0c: two labels that do not fit side by side (French) stack, both inside the
    // alert, the default button on top as macOS stacks them (re-review of a4740a2, MINOR 1); short ones stay side by side.
    function test_buttons_that_do_not_fit_stack(): void {
        const wide = test.openAlert({denyLabel: "Ne pas autoriser", grantLabel: "Autoriser"});
        const deny = test.button(wide, "Ne pas autoriser");
        const grant = test.button(wide, "Autoriser");
        const d = deny.mapToItem(wide.contentItem, 0, 0);
        const g = grant.mapToItem(wide.contentItem, 0, 0);
        verify(g.y < d.y, "one above the other, the default on top");
        compare(d.x, g.x);
        compare(deny.width, grant.width);
        verify(g.x >= 0 && g.x + grant.width <= wide.width, "inside the alert: " + (g.x + grant.width) + " of " + wide.width);
        verify(d.y + deny.height <= wide.height, "inside the alert's height");
        verify(deny.implicitWidth <= deny.width, "the label is not cut");
    }

    // With no default (the camera), "Don't Allow" stays on top when they stack.
    function test_stacked_without_a_default_dont_allow_on_top(): void {
        const alert = test.openAlert({icon: "camera-web-symbolic", noDefault: true, denyLabel: "Ne pas autoriser", grantLabel: "Autoriser"});
        const deny = test.button(alert, "Ne pas autoriser");
        const grant = test.button(alert, "Autoriser");
        verify(!grant.primary, "no default");
        verify(deny.mapToItem(alert.contentItem, 0, 0).y < grant.mapToItem(alert.contentItem, 0, 0).y, "Don't Allow on top");
        verify(grant.mapToItem(alert.contentItem, 0, 0).y + grant.height <= alert.height, "inside the alert's height");
    }

    // An armed alert that stops being the active window answers nothing until it is active again and armed from then (integrator
    // re-review of a4740a2, NIT 2).
    function test_an_alert_that_goes_inactive_is_disarmed(): void {
        const alert = test.openAlert({});
        verify(alert.armed);
        alert.becameInactive();
        verify(!alert.armed, "disarmed when another window is active");
        wait(alert.armMs + 200);
        verify(!alert.armed, "and stays so while inactive");
        alert.becameActive();
        verify(!alert.armed, "not at once on its return");
        tryVerify(() => alert.armed, 2000);
        const grant = test.button(alert, "Allow");
        mouseClick(grant, grant.width / 2, grant.height / 2);
        tryVerify(() => fakeHost.answers.length === 1);
    }

    function test_short_buttons_stay_side_by_side(): void {
        const alert = test.openAlert({denyLabel: "No", grantLabel: "Yes"});
        const no = test.button(alert, "No");
        const yes = test.button(alert, "Yes");
        const n = no.mapToItem(alert.contentItem, 0, 0);
        const y = yes.mapToItem(alert.contentItem, 0, 0);
        compare(n.y, y.y, "side by side");
        verify(y.x > n.x, "the default on the right");
        compare(no.width, yes.width);
        verify(y.x + yes.width <= alert.width);
    }

    // MINOR 4 of the integrator's nested pass of 1745c0c: the hint takes the buttons' place while the keys are held, so the
    // alert keeps its size and nothing moves under the pointer.
    function test_the_hint_takes_the_buttons_place(): void {
        const alert = test.openAlert({});
        const height = alert.height;
        const hint = test.find(alert.contentItem, i => i.text === "Click the alert before you answer it.");
        verify(hint !== null && !hint.visible);
        alert.inactiveSince = Date.now() - 2 * Tokens.filesPanelLateFocusMs;
        alert.becameActive();
        verify(alert.keysHeld);
        verify(hint.visible, "the hint shows");
        verify(!test.button(alert, "Allow").visible, "in the buttons' place");
        compare(alert.height, height, "the alert keeps its size");
        mouseClick(alert.contentItem, 10, 10);
        verify(!hint.visible && test.button(alert, "Allow").visible);
        compare(alert.height, height);
    }

    // MINOR 3 of the integrator's nested pass of 1745c0c: the question's symbol (an application without an icon of its own) is
    // drawn in the text colour; an application's own icon keeps its colours.
    function test_the_symbol_is_in_the_text_colour(): void {
        const alert = test.openAlert({icon: "camera-web-symbolic", appIcon: ""});
        const symbol = test.find(alert.contentItem, i => i.name === "camera-web-symbolic" && i.tint !== undefined);
        verify(symbol !== null && symbol.visible, "the symbol");
        verify(symbol.tint, "tinted");
        verify(Qt.colorEqual(symbol.color, Appearance.colors.text), "the text colour: " + symbol.color);
    }

    function test_an_applications_own_icon_keeps_its_colours(): void {
        const alert = test.openAlert({icon: "camera-web-symbolic", appIcon: "foot"});
        const symbol = test.find(alert.contentItem, i => i.tint !== undefined && i.name !== undefined);
        verify(symbol !== null && !symbol.visible, "the application's own icon instead of the symbol");
    }

    // MINOR 5 of the integrator's nested pass of 1745c0c: one alert at a time, the others waiting in order with no deadline
    // (Access::queue); a waiting one the application closes leaves the line; the next shows when the one on screen goes.
    function test_one_alert_at_a_time(): void {
        fakeAccess.presented = [];
        fakeAccess.queued = [];
        const manager = createTemporaryObject(managerComponent, test, {host: fakeAccess});
        fakeAccess.opened(1, test.request({}));
        fakeAccess.opened(2, test.request({title: "Second"}));
        fakeAccess.opened(3, test.request({title: "Third"}));
        compare(fakeAccess.presented, [1], "the first only");
        compare(fakeAccess.queued, [2, 3], "the others wait");
        verify(manager.alerts[1].visible);
        fakeAccess.closed(2);
        manager.alerts[1].answer(false);
        compare(fakeAccess.presented, [1, 3], "the next waiting one");
        verify(manager.alerts[3] !== undefined && manager.alerts[1] === undefined);
        fakeAccess.closed(3);
        compare(Object.keys(manager.alerts).length, 0);
        compare(manager.waiting.length, 0);
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
        wait(50);
        compare(fakeHost.answers.length, 0, "a second click right after it (a double click) answers nothing");
        tryVerify(() => alert.armed, 2000, "armed again after the click");
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
