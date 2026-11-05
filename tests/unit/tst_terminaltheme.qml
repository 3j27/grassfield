import QtQuick
import QtTest
import "../../shell/services/TerminalThemeLogic.js" as Logic

// Terminal and developer apps follow the appearance (ADR-0045 OC-11): when grassfield-terminal-theme runs. One run per change
// of the effective appearance or of the theme chosen for it, one at login, none while Match Appearance is off or the settings
// are not read yet, none twice for one key, none while a run goes on (decided again when it ends), nothing in a dev session
// (one dev-guard line per change), and the journal line of a run.
TestCase {
    name: "TerminalThemeLogic"

    function inputs(extra) {
        return Object.assign({on: true, loaded: true, dark: false, lightTheme: "Catppuccin Latte", darkTheme: "Tokyo Night", dev: false, running: false}, extra || {});
    }

    function test_keyNamesTheAppearanceAndItsTheme() {
        compare(Logic.key(inputs()), "light\nCatppuccin Latte");
        compare(Logic.key(inputs({dark: true})), "dark\nTokyo Night");
        compare(Logic.key(inputs({on: false})), "", "Match Appearance off");
        compare(Logic.key(inputs({loaded: false})), "", "grassfield.json not read yet");
        compare(Logic.key(inputs({on: "true"})), "", "only a real true turns it on");
        compare(Logic.key(null), "");
        compare(Logic.mode(true), "dark");
        compare(Logic.mode(undefined), "light");
    }

    function test_loginRunsOnce() {
        const first = Logic.decide(inputs({dark: true}), "");
        compare(first.action, "run");
        compare(first.mode, "dark");
        compare(first.last, "dark\nTokyo Night");
        const again = Logic.decide(inputs({dark: true}), first.last);
        compare(again.action, "none", "the same key never runs twice in a row");
    }

    function test_eachAppearanceChangeRuns() {
        let last = Logic.decide(inputs(), "").last;
        // Auto at 19:00, then at 07:00 (Settings.dark flips; the schedule itself is AutoAppearance.js).
        let d = Logic.decide(inputs({dark: true}), last);
        compare(d.action, "run");
        compare(d.mode, "dark");
        last = d.last;
        d = Logic.decide(inputs({dark: false}), last);
        compare(d.action, "run");
        compare(d.mode, "light");
    }

    function test_anotherThemeForTheAppearanceInUseRuns() {
        const last = Logic.decide(inputs(), "").last;
        const d = Logic.decide(inputs({lightTheme: "Rose Pine"}), last);
        compare(d.action, "run");
        compare(d.last, "light\nRose Pine");
        // The other appearance's theme is not in use: nothing to do.
        compare(Logic.decide(inputs({darkTheme: "Nord"}), last).action, "none");
    }

    function test_offForgetsSoOnRunsAgain() {
        const last = Logic.decide(inputs(), "").last;
        const off = Logic.decide(inputs({on: false}), last);
        compare(off.action, "idle");
        compare(off.last, "");
        compare(Logic.decide(inputs(), off.last).action, "run", "turning it on again runs once");
    }

    function test_oneRunAtATime() {
        const last = Logic.decide(inputs(), "").last;
        const busy = Logic.decide(inputs({dark: true, running: true}), last);
        compare(busy.action, "wait");
        compare(busy.last, last, "the key of the run going on is kept");
        compare(Logic.decide(inputs({dark: true}), busy.last).action, "run", "decided again when it ends");
    }

    function test_devSessionRunsNothing() {
        const d = Logic.decide(inputs({dev: true}), "");
        compare(d.action, "suppress");
        compare(Logic.decide(inputs({dev: true}), d.last).action, "none", "one dev-guard line per change");
        compare(Logic.decide(inputs({dev: true, dark: true}), d.last).action, "suppress");
    }

    function test_summary() {
        compare(Logic.summary("applied Tokyo Night (dark)\n", 0), "applied Tokyo Night (dark)");
        compare(Logic.summary("\n  skipped: Match Appearance is off\nmore", 0), "skipped: Match Appearance is off");
        compare(Logic.summary("failed: Theme 'x' does not exist", 1), "failed: Theme 'x' does not exist (exit 1)");
        compare(Logic.summary("", 127), "no answer (exit 127)");
        compare(Logic.summary(undefined, 0), "no answer");
        compare(Logic.summary("a\u001b[31mb", 0), "a [31mb", "no control character reaches the journal");
        const long = Logic.summary("x".repeat(400), 0);
        compare(long.length, 301);
    }
}
