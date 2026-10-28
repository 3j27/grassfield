pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > General > Software Update (ADR-0033; docs/specs/updates.md U8, U10-U14, U19, U21, U22; A11): the badge of the
// General row, the check when the pane opens (the shell asked first, the checker run here without one), what each state shows,
// the exact commands of Set Up…, Repair…, Turn Off…, Beta Updates and Update Now, the password's wait and the one-line
// refusal, Log Out… and Restart… after an update, and the dev guard. The backend is a fake: nothing runs.
TestCase {
    id: testCase
    name: "SettingsSoftwareUpdate"
    width: 700
    height: 1100
    visible: true
    when: windowShown

    readonly property string stateFile: "/state/grassfield/software-update.json"
    readonly property string repositoryReady: "GRASSFIELD_REPO_BASE=https://packages.example.org\nGRASSFIELD_SIGNING_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567\n"
    readonly property string repositoryPlaceholder: "GRASSFIELD_REPO_BASE=https://packages.grassfield.invalid\nGRASSFIELD_SIGNING_FINGERPRINT=\n"

    function iso(ms) {
        return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
    }

    function answer(state, extra, at) {
        return Object.assign({version: 1, state: state, channel: "stable", checkedAt: iso(at === undefined ? Date.now() : at)}, extra || {});
    }

    function available(at) {
        return answer("available", {
            grassfield: {installed: "1.0.0-1", available: "1.0.1-1", notes: [{version: "1.0.1-1", date: "2026-10-30", notes: {en: "Faster Dock.", fr: "Dock plus rapide."}}], notesError: null},
            omarchy: {installed: "4.0.4-1", available: "4.0.6-1"},
            others: 2,
            otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"}, {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]
        }, at);
    }

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            property bool omarchyUpdate: true
            property string homeDir: "/home/u"
            property string softwareUpdateFile: testCase.stateFile
            property var pendingActions: ({})
            property var files: ({})
            property var watched: []
            property var queries: []
            property var actions: []
            property var launches: []
            property var asks: []
            property var runs: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            signal fileChanged(string path)
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function watch(path: string): bool {
                watched.push(path);
                return true;
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push({argv: argv, tag: tag});
                const p = Object.assign({}, pendingActions);
                p[tag] = what;
                pendingActions = p;
                return true;
            }
            function launch(what: string, argv: var): bool {
                launches.push(argv);
                return true;
            }
            function askShellToCheck(tag: string): void {
                asks.push(tag);
            }
            function runUpdateChecker(tag: string): void {
                runs.push(tag);
            }
            // The Backend's end of a channel change: the latch released, then the answer.
            function endAction(tag: string, ok: bool, reason: string): void {
                const p = Object.assign({}, pendingActions);
                delete p[tag];
                pendingActions = p;
                if (!ok)
                    failed(tag, reason);
                finished(tag, ok, "");
            }
            function write(path: string, text: string): void {
                const f = Object.assign({}, files);
                if (text === null)
                    delete f[path];
                else
                    f[path] = text;
                files = f;
                fileChanged(path);
            }
        }
    }

    Component {
        id: storeComp
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                writes.push(e);
                values = Object.assign({}, values, e);
                return true;
            }
        }
    }

    Component {
        id: serviceComp
        SettingsQml.SystemService {}
    }

    Component {
        id: stateComp
        SettingsQml.SoftwareUpdateState {
            rebootMarker: "/home/u/.local/state/omarchy/reboot-required"
            kernelReleaseFile: "/proc/osrelease"
            modulesDir: "/modules"
        }
    }

    Component {
        id: pageComp
        SettingsQml.SoftwareUpdatePage {
            anchors.fill: parent
        }
    }

    Component {
        id: generalComp
        SettingsQml.GeneralPage {
            anchors.fill: parent
        }
    }

    Component {
        id: sheetComp
        SettingsQml.SoftwareUpdateSheet {
            anchors.fill: parent
        }
    }

    // `file`: software-update.json's object (null: none); `files`: more of the fake machine.
    function make(file, options) {
        const o = options || {};
        const files = Object.assign({"/proc/osrelease": "6.18.1-arch1-1\n", "/modules/6.18.1-arch1-1": "", "/usr/share/grassfield/pacman/repository.conf": o.repository ?? testCase.repositoryReady}, o.files || {});
        if (file !== null)
            files[testCase.stateFile] = JSON.stringify(file);
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: o.dev === true, omarchyUpdate: o.omarchy !== false, files: files});
        const system = createTemporaryObject(serviceComp, testCase, {backend: backend});
        const store = createTemporaryObject(storeComp, testCase);
        const updates = createTemporaryObject(stateComp, testCase, {backend: backend, system: system});
        if (o.channel !== undefined)
            backend.finished("update.channel", true, o.channel + "\n");
        const page = o.noPage ? null : createTemporaryObject(pageComp, testCase, {updates: updates, store: store, system: system});
        return {backend: backend, system: system, store: store, updates: updates, page: page};
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

    function shown(item, pred) {
        return find(item, i => i.visible && pred(i));
    }

    function row(page, title) {
        return shown(page, i => i.title === title && i.valueText !== undefined);
    }

    function button(page, text) {
        return shown(page, i => i.text === text && i.push === true);
    }

    // The badge (U19): the releases the last success found, read from the shell's file; General's row shows it.
    function test_theBadgeCountsTheReleases() {
        const t = make(available(), {noPage: true});
        compare(t.updates.count, 2);
        verify(t.backend.watched.indexOf(testCase.stateFile) >= 0, "the file is watched");
        verify(t.backend.watched.indexOf("/etc/pacman.d/grassfield.conf") >= 0, "and the channel's file");
        const general = createTemporaryObject(generalComp, testCase, {updateCount: t.updates.count});
        const nav = shown(general, i => i.text === "Software Update" && i.badge !== undefined);
        verify(nav);
        compare(nav.badge, 2);
        compare(nav.Accessible.name, "Software Update, 2 updates");
        const badge = shown(nav, i => i.count === 2 && i.spoken !== undefined);
        verify(badge, "the red count is drawn");
        // The shell writes a new answer: the badge follows.
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}})));
        compare(t.updates.count, 0);
        // A failure keeps the releases found (ADR-0033 d.6).
        const kept = SoftwareUpdateLogic.combine(available(), answer("failed", {error: "offline"}));
        t.backend.write(testCase.stateFile, JSON.stringify(kept));
        compare(t.updates.count, 2);
        t.backend.write(testCase.stateFile, "{half");
        compare(t.updates.count, 0, "a file that is not JSON counts nothing");
    }

    // U8: the pane checks when it opens, unless a check finished less than a minute ago; the shell is asked first.
    function test_thePaneChecksWhenItOpens() {
        const stale = make(available(Date.now() - 2 * 60 * 1000));
        compare(stale.backend.asks, ["update.ask"]);
        verify(stale.updates.checking);
        compare(stale.page.view.kind, "checking");
        verify(row(stale.page, "Checking for updates…"));
        verify(!button(stale.page, "Check Now").enabled, "one check at a time");
        const fresh = make(available(Date.now() - 20 * 1000));
        compare(fresh.backend.asks, [], "a check finished 20 s ago");
        verify(!fresh.updates.checking);
        const never = make(null);
        compare(never.backend.asks, ["update.ask"], "never checked");
    }

    // The shell runs the check (it answered "ok"): the pane waits for the file's next answer, not for the pending logout alone.
    function test_theShellsAnswerEndsTheWait() {
        const t = make(available(Date.now() - 5 * 60 * 1000));
        t.backend.finished("update.ask", true, "ok\n");
        verify(t.updates.checking);
        compare(t.backend.runs, []);
        t.backend.write(testCase.stateFile, JSON.stringify(Object.assign(available(Date.now() - 5 * 60 * 1000), {logoutPending: true})));
        verify(t.updates.checking, "the pending logout written alone is no answer");
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}})));
        verify(!t.updates.checking);
        verify(row(t.page, "This computer is up to date"));
        verify(row(t.page, "This computer is up to date").subtitle.indexOf("Grassfield 1.0.1, Omarchy 4.0.6") === 0);
        verify(button(t.page, "Check Now").enabled);
        button(t.page, "Check Now").clicked();
        compare(t.backend.asks, ["update.ask", "update.ask"], "Check Now, whatever the last check's age");
    }

    // U10: no shell (or a dev session without one): Settings runs the checker and keeps its answer in memory.
    function test_withoutAShellSettingsChecksItself() {
        const t = make(null);
        t.backend.finished("update.ask", false, "");
        compare(t.backend.runs, ["update.run"]);
        verify(t.updates.checking);
        t.backend.finished("update.run", true, JSON.stringify(available()) + "\n");
        verify(!t.updates.checking);
        compare(t.updates.count, 2);
        compare(t.page.view.kind, "available");
        t.updates.check();
        t.backend.finished("update.ask", true, "refused\n");
        compare(t.backend.runs.length, 2, "a refusal is no check either");
        t.backend.finished("update.run", false, "");
        compare([t.page.view.kind, t.page.view.message], ["failed", "the checker could not run"]);
        compare(t.updates.count, 2, "what was found stays");
        verify(row(t.page, "Software Update could not check for updates"));
    }

    // U21: the releases, the notes, Omarchy's, the other updates and Update Now with its exact command (U11).
    function test_availableUpdates() {
        const t = make(available());
        verify(row(t.page, "Updates are available"));
        const gf = row(t.page, "Grassfield 1.0.1");
        verify(gf);
        compare(gf.subtitle, "Installed: 1.0.0");
        const info = [];
        t.page.infoRequested.connect(topic => info.push(topic));
        shown(gf, i => i.text === "More Info…" && i.activated !== undefined).activated();
        verify(row(t.page, "Omarchy 4.0.6"));
        compare(row(t.page, "Omarchy 4.0.6").subtitle, "Omarchy's release notes are on its project page.");
        const others = row(t.page, "2 other updates");
        verify(others);
        shown(others, i => i.accessibleName === "Other updates").clicked();
        compare(info, ["notes", "others"]);
        const update = button(t.page, "Update Now");
        verify(update.enabled);
        update.clicked();
        compare(t.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
        verify(t.updates.updateRunning);
        verify(!button(t.page, "Update Now").enabled, "while Omarchy's terminal runs the update");
        verify(button(t.page, "Check Now").enabled, "Check Now is never held back by the update's state");
        // The check after the launch finds the lock held: update-running, until the waiter's answer.
        t.updates.launchCheck.triggered();
        compare(t.backend.asks.length, 1, "the pane opened on a fresh check: this is the first ask");
        t.backend.finished("update.ask", true, "ok");
        t.backend.write(testCase.stateFile, JSON.stringify(SoftwareUpdateLogic.combine(available(), answer("update-running", {}, Date.now() + 1000))));
        verify(t.updates.updateRunning);
        verify(row(t.page, "An update is running in Omarchy's terminal"));
        verify(!button(t.page, "Update Now").enabled);
        t.backend.write(testCase.stateFile, JSON.stringify(answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}, Date.now() + 2000)));
        verify(!t.updates.updateRunning);
        verify(!button(t.page, "Update Now"), "nothing left to update");
    }

    // A stored update-running whose waiter ended with the session (a reboot or a log out during the update, a crash) is never
    // kept: the pane checks when it opens, and Check Now stays available (integrator review of a9a5974, MAJOR 3).
    function test_aStaleUpdateRunningIsCheckedAgain() {
        const t = make(SoftwareUpdateLogic.combine(available(Date.now() - 7 * 3600 * 1000), answer("update-running", {}, Date.now() - 6 * 3600 * 1000)));
        compare(t.backend.asks, ["update.ask"], "checked when the pane opens");
        t.backend.finished("update.ask", true, "ok");
        t.backend.write(testCase.stateFile, JSON.stringify(available(Date.now())));
        verify(!t.updates.checking);
        verify(button(t.page, "Check Now").enabled);
        // Even while the stored state still says update-running, Check Now is there.
        const held = make(SoftwareUpdateLogic.combine(available(Date.now() - 3600 * 1000), answer("update-running", {}, Date.now() - 10 * 1000)));
        compare(held.backend.asks, [], "a fresh update-running is not checked again at once");
        verify(!button(held.page, "Update Now").enabled, "Update Now waits while the stored state says the update runs");
        verify(button(held.page, "Check Now").enabled, "Check Now is never held back by the stored state alone");
        button(held.page, "Check Now").clicked();
        compare(held.backend.asks, ["update.ask"]);
    }

    // Grassfield updates off still offers the system's updates (the integrator's decision of 2026-10-28): Omarchy's release,
    // the other updates and Update Now under Set Up….
    function test_turnedOffStillOffersTheSystemsUpdates() {
        const t = make(answer("not-set-up", {channel: null, grassfield: {installed: "1.0.0-1", available: null, notes: [], notesError: null},
            omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 2, otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"},
                {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]}), {channel: "off"});
        verify(row(t.page, "Grassfield updates are not set up"));
        verify(button(t.page, "Set Up…"));
        verify(row(t.page, "Omarchy 4.0.6"));
        verify(row(t.page, "2 other updates"));
        verify(!row(t.page, "Grassfield 1.0.1"));
        verify(button(t.page, "Update Now").enabled);
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, [["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]]);
        compare(t.updates.count, 1, "Omarchy's release on the badge");
        // A failed check while off: what was found stays, Set Up… too.
        const f = make(SoftwareUpdateLogic.combine(answer("not-set-up", {omarchy: {installed: "4.0.4-1", available: "4.0.6-1"}, others: 0, otherPackages: []}),
            answer("failed", {error: "offline"})), {channel: "off"});
        verify(button(f.page, "Set Up…"));
        verify(row(f.page, "Omarchy 4.0.6"));
    }

    // Degraded: not an Omarchy system (no launcher): Update Now is disabled and says why.
    function test_withoutOmarchysUpdateCommand() {
        const t = make(available(), {omarchy: false});
        verify(!button(t.page, "Update Now").enabled);
        verify(row(t.page, "Update Now needs Omarchy's update command, which this system does not have."));
        t.updates.updateNow();
        compare(t.backend.launches, []);
    }

    // U13: Set Up… runs `grassfield-channel-set stable`, through the polkit dialog: the wait, then the refusal in one line.
    function test_setUpWaitsForPermissionAndSaysWhyNot() {
        const t = make(answer("not-set-up"), {channel: "off"});
        verify(row(t.page, "Grassfield updates are not set up"));
        const setUp = button(t.page, "Set Up…");
        verify(setUp);
        setUp.clicked();
        compare(t.backend.actions, [{argv: ["/usr/lib/grassfield/grassfield-channel-set", "stable"], tag: "update.channel.act"}]);
        verify(t.updates.waitingForPermission);
        compare(row(t.page, "Grassfield updates are not set up").subtitle, "Waiting for permission…");
        verify(!button(t.page, "Set Up…").enabled, "no second dialog");
        t.backend.endAction("update.channel.act", false, "grassfield-channel-set: not allowed: the authentication was cancelled or refused, or no authentication agent answered");
        verify(!t.updates.waitingForPermission);
        verify(shown(t.page, i => i.footnote === "Grassfield updates were not set up: not allowed"));
        compare(t.backend.queries.filter(q => q.tag === "update.channel").length, 2, "the channel read again");
        compare(t.backend.asks.length, 0, "nothing changed: no check (the pane opened on a fresh answer)");
        // Accepted: the channel is read again and the pane checks (U12).
        button(t.page, "Set Up…").clicked();
        t.backend.endAction("update.channel.act", true, "");
        compare(t.backend.asks, ["update.ask"]);
        verify(!shown(t.page, i => i.footnote === "Grassfield updates were not set up: not allowed"), "the line goes with the next attempt");
    }

    // Refusals: a build without its key or host hides Set Up… and says so.
    function test_aBuildWithoutRepositoryHidesSetUp() {
        const t = make(answer("not-set-up"), {repository: testCase.repositoryPlaceholder});
        verify(row(t.page, "Software Update is not available in this build"));
        verify(!button(t.page, "Set Up…"));
        const none = make(answer("not-set-up"), {files: {"/usr/share/grassfield/pacman/repository.conf": undefined}, repository: ""});
        verify(!button(none.page, "Set Up…"), "no repository.conf at all");
    }

    // U13: repair, and a custom channel, offer Repair…; U22: blocking offers Turn Off Grassfield Updates….
    function test_repairAndTurnOff() {
        const r = make(answer("repair"));
        button(r.page, "Repair…").clicked();
        compare(r.backend.actions.map(a => a.argv), [["/usr/lib/grassfield/grassfield-channel-set", "repair"]]);
        const custom = make(answer("up-to-date", {channel: "custom", grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}));
        verify(button(custom.page, "Repair…"), "a custom channel is repaired too");
        const b = make(SoftwareUpdateLogic.combine(available(), answer("blocking", {episode: "2026-10-28T09:00:00Z"})));
        verify(row(b.page, "Grassfield's package repository cannot be used"));
        verify(row(b.page, "Grassfield's package repository cannot be used").subtitle.indexOf("every system update stops") > 0);
        verify(!button(b.page, "Update Now").enabled, "every Omarchy update fails while blocking");
        verify(row(b.page, "Omarchy's update cannot run while Grassfield's repository cannot be used."));
        b.updates.updateNow();
        compare(b.backend.launches, []);
        const off = button(b.page, "Turn Off Grassfield Updates…");
        verify(off.destructive);
        off.clicked();
        compare(b.backend.actions.map(a => a.argv), [["/usr/lib/grassfield/grassfield-channel-set", "off"]]);
        b.backend.endAction("update.channel.act", false, "grassfield-channel-set: an Omarchy update is running: try again when it has finished");
        verify(shown(b.page, i => i.footnote === "Grassfield updates were not turned off: an Omarchy update is running: try again when it has finished"));
    }

    // U12: Beta Updates shows the channel grassfield-channel-set prints; the sheet's menu runs the switch.
    function test_betaUpdates() {
        const t = make(available(), {channel: "beta"});
        compare(t.backend.queries[0], {argv: ["/usr/lib/grassfield/grassfield-channel-set"], tag: "update.channel"});
        compare(row(t.page, "Beta Updates").valueText, "Grassfield Beta");
        const info = [];
        t.page.infoRequested.connect(topic => info.push(topic));
        shown(row(t.page, "Beta Updates"), i => i.accessibleName === "Beta Updates details").clicked();
        compare(info, ["beta"]);
        const sheet = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "beta"});
        sheet.open();
        const menu = shown(sheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined);
        verify(menu.enabled);
        compare(menu.value, "beta");
        menu.picked("stable");
        compare(t.backend.actions, [{argv: ["/usr/lib/grassfield/grassfield-channel-set", "stable"], tag: "update.channel.act"}]);
        compare(menu.value, "beta", "the old value until the file changes");
        compare(row(t.page, "Beta Updates").valueText, "Waiting for permission…");
        verify(!menu.enabled);
        t.backend.endAction("update.channel.act", false, "grassfield-channel-set: not allowed: the authentication was cancelled or refused, or no authentication agent answered");
        verify(shown(t.page, i => i.footnote === "Beta updates were not changed: not allowed"));
        // The file changed: the channel is read again.
        const reads = t.backend.queries.length;
        t.backend.fileChanged("/etc/pacman.d/grassfield.conf");
        compare(t.backend.queries.length, reads + 1);
        t.backend.finished("update.channel", true, "stable\n");
        compare(row(t.page, "Beta Updates").valueText, "Off");
        compare(menu.value, "stable");
        // Turn Off Grassfield Updates… in the sheet (U13).
        shown(sheet, i => i.text === "Turn Off Grassfield Updates…" && i.push === true).clicked();
        compare(t.backend.actions[t.backend.actions.length - 1].argv, ["/usr/lib/grassfield/grassfield-channel-set", "off"]);
        // Not set up: the menu waits for Set Up.
        const off = make(answer("not-set-up"), {channel: "off", noPage: true});
        const offSheet = createTemporaryObject(sheetComp, testCase, {updates: off.updates, store: off.store, topic: "beta"});
        offSheet.open();
        verify(!shown(offSheet, i => i.accessibleName === "Beta updates" && i.picked !== undefined).enabled);
    }

    // U7, U21: Automatic Updates' one switch.
    function test_automaticUpdates() {
        const t = make(available());
        compare(row(t.page, "Automatic Updates").valueText, "Check for updates");
        const sheet = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "automatic"});
        sheet.open();
        verify(sheet.message.indexOf("never downloads or installs anything by itself") > 0);
        const toggle = shown(sheet, i => i.accessibleName === "Check for updates" && i.toggled !== undefined);
        verify(toggle.checked);
        toggle.toggled(false);
        compare(t.store.writes, [{"updates.automaticCheck": false}]);
        compare(row(t.page, "Automatic Updates").valueText, "Off");
    }

    // U6: More Info… shows the notes; the other updates are listed; notes that are missing say so.
    function test_notesAndOtherUpdates() {
        const t = make(available(), {noPage: true});
        const notes = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "notes"});
        notes.open();
        compare(notes.title, "Grassfield 1.0.1");
        verify(shown(notes, i => i.text === "Faster Dock."), "plain text, English in an English session");
        const others = createTemporaryObject(sheetComp, testCase, {updates: t.updates, store: t.store, topic: "others"});
        others.open();
        compare(others.title, "Other Updates");
        tryVerify(() => shown(others, i => i.title === "linux" && i.valueText === "6.18.1-1 → 6.18.2-1"));
        const bare = make(answer("available", {grassfield: {installed: "1.0.0-1", available: "1.0.1-1", notes: [], notesError: "unavailable"}, omarchy: {installed: "4.0.4-1", available: null}, others: 0, otherPackages: []}), {noPage: true});
        const none = createTemporaryObject(sheetComp, testCase, {updates: bare.updates, store: bare.store, topic: "notes"});
        compare(none.message, "Release notes are not available.");
    }

    // U14: after an update, Log Out… (GF-083's pending logout) or Restart… (Omarchy's marker, or the kernel's modules gone).
    function test_logOutOrRestartAfterAnUpdate() {
        const t = make(Object.assign(answer("up-to-date"), {logoutPending: true}));
        verify(row(t.page, "Log out to finish updating Grassfield"));
        const asked = [];
        t.page.endSessionRequested.connect(a => asked.push(a));
        button(t.page, "Log Out…").clicked();
        compare(asked, ["logout"]);
        t.updates.endSession("logout");
        compare(t.backend.launches, [["/usr/lib/grassfield/grassfield-session-end", "logout"]]);
        const r = make(answer("up-to-date"), {files: {"/home/u/.local/state/omarchy/reboot-required": ""}});
        verify(row(r.page, "Restart to finish updating"));
        button(r.page, "Restart…").clicked();
        r.updates.endSession("restart");
        compare(r.backend.launches, [["/usr/lib/grassfield/grassfield-session-end", "restart"]]);
        const kernel = make(answer("up-to-date"), {files: {"/modules/6.18.1-arch1-1": undefined}});
        verify(kernel.updates.restartNeeded, "the running kernel's modules are gone");
        const unknown = make(answer("up-to-date"), {files: {"/proc/osrelease": undefined}});
        verify(!unknown.updates.restartNeeded, "an unreadable kernel release says nothing");
        const none = make(answer("up-to-date"));
        verify(!none.updates.restartNeeded && !none.updates.logoutPending);
        verify(!row(none.page, "Log out to finish updating Grassfield"));
    }

    // A dev session: the state is read, nothing is changed or started.
    function test_devGuard() {
        const t = make(available(), {dev: true, channel: "stable"});
        button(t.page, "Update Now").clicked();
        compare(t.backend.launches, []);
        verify(!t.updates.updateRunning);
        t.updates.setChannel("beta", "beta");
        t.updates.endSession("logout");
        compare(t.backend.actions, []);
        compare(t.backend.launches, []);
        verify(t.system.suppressedNote);
        verify(shown(t.page, i => i.text === "dev: not applied"));
    }
}
