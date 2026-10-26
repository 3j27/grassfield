import QtQuick
import QtTest
import "../../apps/settings/qml/Power.js" as Power

// Settings > Battery: UPower's state, the Low Power Mode choice over Omarchy's two remembered power profiles, the level chart.
TestCase {
    name: "SettingsPower"

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
}
