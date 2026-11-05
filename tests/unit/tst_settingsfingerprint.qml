import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Fingerprint.js" as Fingerprint
import "../../apps/settings/qml" as SettingsQml

// Fingerprint & Security Key (ADR-0045 OC-6, OC-0.7): fprintd's state and the enrolment's state machine (Fingerprint.js), then
// the pane and the enrolment sheet over a fake backend: the reader's presence, Omarchy's setup before anything native, the
// enrolled fingers, where each is used (read from the PAM files Omarchy's setups edit), the security key, the enrolment's
// statuses as fprintd sends them, Cancel stopping it, and nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsFingerprint"
    width: 700
    height: 900
    visible: true
    when: windowShown

    readonly property string sudoPam: "auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed\nauth      sufficient pam_fprintd.so\n#%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\n"
    readonly property string polkitPam: "auth      sufficient pam_fprintd.so\nauth      sufficient pam_u2f.so cue authfile=/etc/fido2/fido2\nauth      required pam_unix.so\n"

    function test_parseState() {
        const s = Fingerprint.parseState(JSON.stringify({present: true, name: "Goodix", stages: 10, scanType: "press",
            fingers: ["left-thumb", "right-index-finger", "nose"]}));
        compare(s.fingers, ["right-index-finger", "left-thumb"], "known names only, in the order new fingers are proposed");
        compare(s.stages, 10);
        compare(Fingerprint.parseState(JSON.stringify({present: false})).fingers, []);
        compare(Fingerprint.parseState(JSON.stringify({present: true, stages: 1000})).stages, 0, "an odd count is unknown");
        compare(Fingerprint.parseState(JSON.stringify({present: true, scanType: "x"})).scanType, "press");
        compare(Fingerprint.parseState("{}"), null);
        compare(Fingerprint.parseState("nope"), null);
        compare(Fingerprint.nextFinger([]), "right-index-finger");
        compare(Fingerprint.nextFinger(["right-index-finger"]), "left-index-finger");
        compare(Fingerprint.nextFinger(Fingerprint.FINGERS), "");
        compare(Fingerprint.FINGERS.length, 10);
        for (const f of Fingerprint.FINGERS)
            verify(Fingerprint.NAMES[f] !== undefined, f);
    }

    function test_enrolment() {
        let s = Fingerprint.start("right-index-finger", 4);
        compare(s.phase, "starting");
        compare(s.message, "place");
        compare(Fingerprint.progress(s), 0);
        verify(Fingerprint.running(s));
        s = Fingerprint.step(s, "enroll-stage-passed");
        compare(s.phase, "scanning");
        compare(s.passed, 1);
        compare(s.message, "again");
        s = Fingerprint.step(s, "enroll-retry-scan");
        compare(s.message, "retry");
        compare(s.passed, 1, "a retry counts nothing");
        s = Fingerprint.step(s, "enroll-stage-passed");
        compare(s.message, "edges", "the second half: the edges, as macOS asks");
        s = Fingerprint.step(s, "enroll-stage-passed");
        s = Fingerprint.step(s, "enroll-stage-passed");
        compare(s.passed, 3, "never full before fprintd says completed");
        compare(Fingerprint.step(s, "enroll-finger-not-centered").message, "center");
        compare(Fingerprint.step(s, "enroll-swipe-too-short").message, "short");
        compare(Fingerprint.step(s, "enroll-remove-and-retry").message, "remove");
        compare(Fingerprint.step(s, "something-new"), s, "an unknown status changes nothing");
        const done = Fingerprint.step(s, "enroll-completed");
        compare(done.phase, "done");
        compare(Fingerprint.progress(done), 1);
        verify(!Fingerprint.running(done));
        compare(Fingerprint.step(done, "enroll-failed"), done, "nothing after the end");
        compare(Fingerprint.finish(done, true, "").phase, "done");
        // fprintd's failures, with their keys; the Backend's answers.
        compare(Fingerprint.step(s, "enroll-data-full").message, "full");
        compare(Fingerprint.step(s, "enroll-disconnected").message, "disconnected");
        compare(Fingerprint.step(s, "enroll-duplicate").message, "duplicate");
        compare(Fingerprint.step(s, "enroll-unknown-error").phase, "failed");
        compare(Fingerprint.finish(s, false, "enroll-stopped").phase, "stopped");
        compare(Fingerprint.finish(s, false, "enroll-failed").message, "failed");
        const refused = Fingerprint.finish(Fingerprint.start("left-thumb", 0), false, "not allowed: the system refused the request");
        compare(refused.phase, "failed");
        compare(refused.message, "error");
        compare(refused.reason, "not allowed: the system refused the request");
        compare(refused.stages, 5, "no count from fprintd: 5");
        compare(Fingerprint.finish(Fingerprint.step(s, "enroll-failed"), false, "x").message, "failed", "fprintd's own status wins");
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property var pendingActions: ({})
            property var files: ({})
            property var commands: ["omarchy-hw-fingerprint", "fprintd-enroll", "pamu2fcfg"]
            property var busQueries: []
            property var busActions: []
            property var queries: []
            property int stops: 0
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal progress(string tag, string status)
            signal suppressed(string what)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function hasCommand(name: string): bool {
                return commands.indexOf(name) >= 0;
            }
            function readOnlyQuery(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function busAct(what: string, op: var, tag: string): bool {
                busActions.push({what: what, op: op, tag: tag});
                return true;
            }
            function stopEnroll(): void {
                stops++;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: pageComp
        SettingsQml.FingerprintPage {
            anchors.fill: parent
        }
    }

    Component {
        id: sheetComp
        SettingsQml.FingerprintEnrollSheet {}
    }

    function make(comp, dev, files, commands) {
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev === true, files: files || {}});
        if (commands !== undefined)
            backend.commands = commands;
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const item = createTemporaryObject(comp, testCase, {backend: backend, system: system});
        verify(item);
        return {backend: backend, system: system, item: item};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function test_paneBeforeOmarchysSetup() {
        // A reader, no fprintd, no PAM line yet: Set Up… only, Omarchy's setup in its terminal.
        const t = make(pageComp, false, {}, ["omarchy-hw-fingerprint"]);
        compare(t.backend.queries[0], {argv: ["omarchy-hw-fingerprint"], tag: "fprint.reader"});
        compare(t.backend.busQueries.length, 0, "no fprintd: nothing asked of it");
        t.backend.finished("fprint.reader", true, "");
        verify(t.item.reader === true);
        verify(!t.item.fingerprintSetUp);
        const asked = [];
        t.item.setupRequested.connect(id => asked.push(id));
        const setUp = find(t.item, i => i.text === "Set Up…" && i.push !== undefined && i.visible && i.Accessible.name === "Set up fingerprint");
        verify(setUp);
        setUp.clicked();
        compare(asked, ["fingerprint-setup"]);
        // No reader: no fingerprint part at all (the security key's stays).
        const n = make(pageComp, false, {}, ["omarchy-hw-fingerprint"]);
        n.backend.finished("fprint.reader", false, "");
        verify(n.item.reader === false);
        // Without Omarchy's detection command: no reader shown, nothing run.
        const z = make(pageComp, false, {}, []);
        compare(z.backend.queries.length, 0);
        verify(z.item.reader === false);
    }

    function test_paneAfterOmarchysSetup() {
        const t = make(pageComp, false, {"/etc/pam.d/sudo": testCase.sudoPam, "/etc/pam.d/polkit-1": testCase.polkitPam,
            "/etc/pam.d/omarchy-lock-fingerprint": "auth required pam_fprintd.so\n", "/etc/fido2/fido2": "alex:abc,def\n"});
        compare(t.backend.busQueries[0], {what: "fprint.state", tag: "fprint.state"});
        t.backend.finished("fprint.reader", true, "");
        verify(t.item.fingerprintSetUp);
        compare(t.item.fingerUse, {lock: true, admin: true, sudo: true});
        verify(t.item.keySetUp);
        compare(t.item.keyUse, {lock: false, admin: true, sudo: false});
        t.backend.finished("fprint.state", true, JSON.stringify({present: true, name: "Goodix", stages: 8, scanType: "press", fingers: ["right-index-finger"]}));
        verify(find(t.item, i => i.title === "Right index finger" && i.valueText !== undefined), "the finger by its name");
        const enrol = [];
        const deletes = [];
        const setups = [];
        t.item.enrollRequested.connect((finger, stages) => enrol.push([finger, stages]));
        t.item.deleteRequested.connect(finger => deletes.push(finger));
        t.item.setupRequested.connect(id => setups.push(id));
        find(t.item, i => i.text === "Add Fingerprint…" && i.push !== undefined).clicked();
        compare(enrol, [["left-index-finger", 8]], "the next finger and fprintd's count of touches");
        find(t.item, i => i.text === "Delete…" && i.push !== undefined).clicked();
        compare(deletes, ["right-index-finger"]);
        find(t.item, i => i.text === "Remove Fingerprint Setup…" && i.push !== undefined).clicked();
        find(t.item, i => i.Accessible.name === "Remove the security key" && i.push !== undefined).clicked();
        compare(setups, ["fingerprint-remove", "fido2-remove"]);
        // A deletion answered: the state is read again.
        const before = t.backend.busQueries.length;
        t.backend.finished("fprint.act", true, "");
        verify(t.backend.busQueries.length > before);
        // fprintd does not answer: the reason under the list.
        t.backend.failed("fprint.state", "the service is not running");
        t.backend.finished("fprint.state", false, "");
        compare(t.item.stateError, "the service is not running");
    }

    function test_securityKeyNotSetUp() {
        const t = make(pageComp, false, {"/etc/pam.d/sudo": testCase.sudoPam}, ["pamu2fcfg"]);
        verify(!t.item.keySetUp, "no registration file: not set up, whatever PAM says");
        const asked = [];
        t.item.setupRequested.connect(id => asked.push(id));
        find(t.item, i => i.Accessible.name === "Set up a security key" && i.push !== undefined).clicked();
        compare(asked, ["fido2-setup"]);
    }

    function test_enrolmentSheet() {
        const t = make(sheetComp, false, {});
        const sheet = t.item;
        let ended = 0;
        sheet.ended.connect(() => ended++);
        sheet.openFor("right-index-finger", 3);
        compare(t.backend.busActions[0].op, {op: "fprint.enroll", finger: "right-index-finger"});
        compare(t.backend.busActions[0].tag, "fprint.enroll");
        compare(sheet.enrolment.phase, "starting");
        verify(!sheet.confirmEnabled);
        t.backend.progress("fprint.enroll", "enroll-stage-passed");
        compare(sheet.enrolment.passed, 1);
        verify(sheet.messageText(sheet.enrolment).indexOf("Lift your finger") === 0);
        t.backend.progress("other.tag", "enroll-stage-passed");
        compare(sheet.enrolment.passed, 1, "another tag's status is not this one's");
        t.backend.progress("fprint.enroll", "enroll-completed");
        t.backend.finished("fprint.enroll", true, "");
        verify(sheet.done);
        verify(sheet.confirmEnabled);
        sheet.confirm();
        verify(!sheet.shown);
        compare(ended, 1);
        compare(t.backend.stops, 1, "Done stops too (a no-op when nothing runs): no job outlives the sheet");
        // A failure from fprintd: Try Again starts over with the same finger, the sheet stays.
        sheet.openFor("left-thumb", 3);
        t.backend.progress("fprint.enroll", "enroll-data-full");
        t.backend.failed("fprint.enroll", "enroll-data-full");
        t.backend.finished("fprint.enroll", false, "");
        verify(sheet.failed);
        compare(sheet.messageText(sheet.enrolment), "The fingerprint reader has no room for another print.");
        compare(sheet.confirmText, "Try Again");
        sheet.confirm();
        verify(sheet.shown);
        compare(t.backend.busActions[t.backend.busActions.length - 1].op, {op: "fprint.enroll", finger: "left-thumb"});
        // Cancel while it runs: fprintd is told to stop.
        sheet.cancel();
        compare(t.backend.stops, 2);
        verify(!sheet.shown);
        compare(ended, 2);
        // The late answer of the stopped enrolment changes nothing.
        t.backend.finished("fprint.enroll", false, "");
        compare(sheet.enrolment, null);
        // A dev session enrols nothing.
        const d = make(sheetComp, true, {});
        d.item.openFor("right-index-finger", 3);
        compare(d.backend.busActions.length, 0);
        verify(d.item.failed);
    }
}
