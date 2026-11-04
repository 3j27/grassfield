import QtQuick
import QtTest
import "../../apps/settings/qml/Power.js" as Power

// Settings > Battery: UPower's state, the Low Power Mode choice over Omarchy's two remembered power profiles, the level chart;
// then the page (BatteryPage.qml) over a fake backend: what it reads, the profiles set one after another (the source in use
// last), the charge limit, the (i) sheets asked for, and nothing in a dev session.
TestCase {
    id: testCase
    name: "SettingsPower"
    width: 700
    height: 900
    visible: true
    when: windowShown

    function test_parseState() {
        const st = Power.parseState(JSON.stringify({present: true, onBattery: true, percent: 71.6, state: 2, timeToEmpty: 3900, timeToFull: 0, capacity: 91.5,
            cycles: 212, limitSupported: true, limitEnabled: false, limitEnd: 80, history24: [[100, 80, 2], [200, 75.5, 2], "bad", [1, 2]], history10: []}));
        compare(st.percent, 72);
        compare(st.onBattery, true);
        compare(st.history24.length, 2);
        compare(st.history24[1], [200, 75.5, 2]);
        compare(st.cycles, 212);
        compare(Power.parseState("{}"), null);
        compare(Power.parseState("nope"), null);
        // Out-of-range numbers fall back, never throw.
        const odd = Power.parseState(JSON.stringify({present: true, percent: 300, state: 9, capacity: -5, cycles: "x"}));
        compare(odd.percent, 0);
        compare(odd.state, 0);
        compare(odd.capacity, 0);
        compare(odd.cycles, -1);
    }

    function test_kindDurationHealth() {
        compare(Power.kind(4), "full");
        compare(Power.kind(1), "charging");
        compare(Power.kind(5), "charging");
        compare(Power.kind(2), "discharging");
        compare(Power.kind(0), "unknown");
        compare(Power.duration(3900), "1:05");
        compare(Power.duration(0), "");
        compare(Power.health(91), "normal");
        compare(Power.health(80), "normal");
        compare(Power.health(79.9), "service");
        compare(Power.health(0), "");
    }

    function test_lowPowerModeOverTheTwoProfiles() {
        compare(Power.lowPowerMode("power-saver\n", "power-saver"), "always");
        compare(Power.lowPowerMode("performance", "power-saver"), "battery");
        compare(Power.lowPowerMode("power-saver", "balanced"), "adapter");
        compare(Power.lowPowerMode("", ""), "never");
        const all = ["performance", "balanced", "power-saver"];
        // Low power where asked; elsewhere the remembered profile, or Omarchy's default when it was power-saver.
        compare(Power.profilesFor("battery", "performance", "balanced", all), {ac: "performance", battery: "power-saver"});
        compare(Power.profilesFor("never", "power-saver", "power-saver", all), {ac: "performance", battery: "balanced"});
        compare(Power.profilesFor("never", "power-saver", "power-saver", ["balanced", "power-saver"]), {ac: "balanced", battery: "balanced"});
        compare(Power.profilesFor("always", "balanced", "balanced", all), {ac: "power-saver", battery: "power-saver"});
        compare(Power.profilesFor("adapter", "", "turbo", all), {ac: "power-saver", battery: "balanced"});
        // The source in use is set last: omarchy-powerprofiles-set applies what it remembers at once.
        compare(Power.commands({ac: "performance", battery: "power-saver"}, true),
                [["omarchy-powerprofiles-set", "ac", "performance"], ["omarchy-powerprofiles-set", "battery", "power-saver"]]);
        compare(Power.commands({ac: "performance", battery: "power-saver"}, false),
                [["omarchy-powerprofiles-set", "battery", "power-saver"], ["omarchy-powerprofiles-set", "ac", "performance"]]);
        compare(Power.commands({ac: "turbo", battery: "balanced"}, false), null);
        compare(Power.parseProfiles("performance\nbalanced\npower-saver\nweird\n"), ["performance", "balanced", "power-saver"]);
    }

    function test_bars() {
        // UPower keeps changes only: a bar is the last level at or before its end; none before the first record or after now.
        const h = [[1000, 50, 2], [1500, 40, 2], [2500, 60, 1]];
        const b = Power.bars(h, 4000, 4000, 8, 3200);
        // Buckets of 500 s: [0, 500] has no record yet, [500, 1000] ends on the first one, [3500, 4000] starts after now.
        compare(b.map(x => x.level), [-1, 50, 40, 40, 60, 60, 60, -1]);
        compare(b[4].charging, true);
        compare(b[2].charging, false);
        compare(Power.bars([], 4000, 4000, 4, 4000).map(x => x.level), [-1, -1, -1, -1]);
    }

    function test_windowEnd() {
        const d = new Date(2026, 9, 26, 13, 20, 0);
        const end = new Date(Power.windowEnd(d.getTime() / 1000, 1) * 1000);
        compare(end.getHours(), 15);
        compare(end.getMinutes(), 0);
        const midnight = new Date(Power.windowEnd(d.getTime() / 1000, 10) * 1000);
        compare(midnight.getHours(), 0);
        compare(midnight.getDate(), 27);
    }

    readonly property string onBattery: JSON.stringify({present: true, onBattery: true, percent: 71.6, state: 2, timeToEmpty: 3900, timeToFull: 0,
        capacity: 91.5, cycles: 212, limitSupported: true, limitEnabled: false, limitEnd: 80, history24: [], history10: []})
    readonly property string acFile: "/home/u/.local/state/omarchy/powerprofiles/ac"
    readonly property string batteryFile: "/home/u/.local/state/omarchy/powerprofiles/battery"

    Component {
        id: fakeBackend
        QtObject {
            property bool devSession: false
            readonly property string stateDir: "/home/u/.local/state"
            property var files: ({})
            property var queries: []
            property var busQueries: []
            property var actions: []
            signal finished(string tag, bool ok, string output)
            signal failed(string tag, string reason)
            // ADR-0045: a command on PATH (none here) and Omarchy's read-only checks (recorded nowhere: no answer comes).
            function hasCommand(name: string): bool {
                return false;
            }
            function readOnlyQuery(argv: var, tag: string): void {
            }
            function readText(path: string): var {
                return {exists: files[path] !== undefined, ok: files[path] !== undefined, text: files[path] ?? ""};
            }
            function query(argv: var, tag: string): void {
                queries.push({argv: argv, tag: tag});
            }
            function busQuery(what: string, tag: string): void {
                busQueries.push({what: what, tag: tag});
            }
            function act(what: string, argv: var, tag: string): bool {
                actions.push({argv: argv, tag: tag});
                return true;
            }
            function busAct(what: string, op: var, tag: string): bool {
                actions.push({op: op, tag: tag});
                return true;
            }
        }
    }

    function makePage(dev) {
        const files = {};
        files[testCase.acFile] = "performance\n";
        files[testCase.batteryFile] = "balanced\n";
        const backend = createTemporaryObject(fakeBackend, testCase, {devSession: dev === true, files: files});
        const svc = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/SystemService.qml"));
        compare(svc.status, Component.Ready, svc.errorString());
        const system = createTemporaryObject(svc, testCase, {backend: backend});
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/BatteryPage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {backend: backend, system: system, width: 700, height: 900});
        verify(page);
        return {backend: backend, system: system, page: page};
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

    // Opened: UPower's state, the profiles power-profiles-daemon offers, and the two Omarchy remembers.
    function test_pageReads() {
        const t = makePage(false);
        compare(t.backend.busQueries, [{what: "power.state", tag: "power.state"}]);
        compare(t.backend.queries, [{argv: ["omarchy-powerprofiles-list"], tag: "power.profiles"}]);
        compare(t.page.acProfile, "performance");
        compare(t.page.batteryProfile, "balanced");
        compare(t.page.mode, "never");
        verify(!t.page.answered);
        t.backend.finished("power.state", true, testCase.onBattery);
        verify(t.page.answered);
        compare(t.page.power.percent, 72);
        compare(t.page.subtitle, "72 % · 1:05 remaining", "the toolbar's line under the title");
        t.backend.finished("power.profiles", true, "performance\nbalanced\npower-saver\n");
        compare(t.page.profiles, ["performance", "balanced", "power-saver"]);
        // No battery, or UPower not answering: the line says which.
        t.backend.finished("power.state", true, JSON.stringify({present: false}));
        verify(find(t.page, i => i.text === "This computer has no battery." && i.visible));
        t.backend.finished("power.state", false, "");
        compare(t.page.power, null);
        verify(find(t.page, i => i.text === "The battery cannot be read: UPower did not answer." && i.visible));
    }

    // Low Power Mode: Omarchy's command once per source, one after another, the source in use last; the state files read again.
    function test_lowPowerModeRunsInTurn() {
        const t = makePage(false);
        t.backend.finished("power.state", true, testCase.onBattery);
        t.backend.finished("power.profiles", true, "performance\nbalanced\npower-saver\n");
        t.page.setMode("always");
        compare(t.page.mode, "always", "shown at once");
        compare(t.backend.actions, [{argv: ["omarchy-powerprofiles-set", "ac", "power-saver"], tag: "power.act"}]);
        // Another choice while it runs is ignored.
        t.page.setMode("never");
        compare(t.backend.actions.length, 1);
        t.backend.finished("power.act", true, "");
        compare(t.backend.actions[1], {argv: ["omarchy-powerprofiles-set", "battery", "power-saver"], tag: "power.act"});
        const after = {};
        after[testCase.acFile] = "power-saver\n";
        after[testCase.batteryFile] = "power-saver\n";
        t.backend.files = after;
        t.backend.finished("power.act", true, "");
        compare(t.page.pendingMode, "");
        compare(t.page.mode, "always", "read from Omarchy's files");
        // A failed command stops the rest; its reason shows; the files tell the mode.
        t.page.setMode("battery");
        compare(t.backend.actions.length, 3);
        t.backend.failed("power.act", "omarchy-powerprofiles-set: no such profile");
        t.backend.finished("power.act", false, "");
        compare(t.backend.actions.length, 3);
        compare(t.page.pendingMode, "");
        compare(t.page.mode, "always");
        compare(t.system.errors["power.act"], "omarchy-powerprofiles-set: no such profile");
    }

    // (i): the page asks Main.qml for the sheet; the charge limit comes back to it and UPower is read again.
    function test_infoAndChargeLimit() {
        const t = makePage(false);
        t.backend.finished("power.state", true, testCase.onBattery);
        let asked = null;
        t.page.infoRequested.connect((topic, power) => asked = {topic: topic, percent: power.percent});
        const charging = find(t.page, i => i.accessibleName === "Charging details" && i.clicked !== undefined);
        verify(charging);
        tryVerify(() => charging.visible && charging.width > 0 && charging.mapToItem(null, 0, 0).y > 0);
        waitForRendering(t.page);
        mouseClick(charging);
        compare(asked, {topic: "charging", percent: 72});
        const health = find(t.page, i => i.accessibleName === "Battery Health details" && i.clicked !== undefined);
        mouseClick(health);
        compare(asked.topic, "health");
        t.page.setLimit(true);
        compare(t.backend.actions, [{op: {op: "power.chargeLimit", on: true}, tag: "power.limit"}]);
        const before = t.backend.busQueries.length;
        t.backend.finished("power.limit", true, "");
        compare(t.backend.busQueries.length, before + 1, "UPower read again");
    }

    // A dev session reads but changes nothing: no command, no limit, and the mode does not move.
    function test_devSessionChangesNothing() {
        const t = makePage(true);
        t.backend.finished("power.state", true, testCase.onBattery);
        t.backend.finished("power.profiles", true, "performance\nbalanced\npower-saver\n");
        t.page.setMode("always");
        t.page.setLimit(true);
        compare(t.backend.actions, []);
        compare(t.page.pendingMode, "");
        compare(t.page.mode, "never");
        verify(t.system.suppressedNote);
    }
}
