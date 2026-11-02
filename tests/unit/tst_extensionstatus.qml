import QtQuick
import QtTest
import "../../shell/platform/ExtensionStatus.js" as ExtensionStatus

// Why the compositor extension is absent and what the shell does about it (ADR-0009 "Amendment 2026-10-23", GF-033):
// the answers of grassfield-compositor-rebuild --status / --session and the shell's decisions. Test names state the
// user-visible rule.
TestCase {
    name: "ExtensionStatus"

    function test_aMismatchNamesTheHyprlandVersion() {
        const s = ExtensionStatus.parse("state=mismatch\nversion=v0.56.3\nabi=abc_aq_0.15\n");
        compare(ExtensionStatus.notice(s), "mismatch");
        compare(ExtensionStatus.version(s), "v0.56.3");
    }

    // Re-review of c3cb01b: a build in the user's cache made from an older Grassfield is stale, not a Hyprland mismatch:
    // its notice speaks of finishing an update (GF-083 wording), and the opt-in rebuild still runs.
    function test_aStaleBuildIsAnUpdateToFinishNotAHyprlandMismatch() {
        const s = ExtensionStatus.parse("state=mismatch\nversion=v0.56.2\nabi=abc_aq_0.15\nreason=stale-build\n");
        compare(ExtensionStatus.notice(s), "stale");
        verify(ExtensionStatus.rebuilds(s, true, false));
        verify(!ExtensionStatus.rebuilds(s, false, false));
        verify(!ExtensionStatus.rebuilds(s, true, true));
        compare(ExtensionStatus.notice(ExtensionStatus.parse("state=mismatch\nreason=other\n")), "mismatch");
        compare(ExtensionStatus.notice(ExtensionStatus.parse("state=match\nreason=stale-build\n")), "absent");
    }

    // Re-review of b60bc3a..85aaab9: shell.qml posts the notice ExtensionStatus.degradedNotice names; for a stale build
    // that is never one of the texts that say "not built for <Hyprland>" (namesHyprland), with or without the rebuild,
    // and the rebuild's outcome is "updated", never "rebuilt for <Hyprland>".
    function test_aStaleBuildNeverGetsTheHyprlandMismatchText() {
        const stale = ExtensionStatus.parse("state=mismatch\nversion=v0.56.2\nreason=stale-build\n");
        compare(ExtensionStatus.degradedNotice(stale, true, false), "stale-rebuilding");
        compare(ExtensionStatus.degradedNotice(stale, false, false), "stale-manual");
        compare(ExtensionStatus.degradedNotice(stale, true, true), "stale-manual");
        for (const key of ["stale-rebuilding", "stale-manual", "updated-loaded", "updated-built"])
            verify(!ExtensionStatus.namesHyprland(key), key);
        compare(ExtensionStatus.resultNotice(ExtensionStatus.parse("result=loaded\npath=/x\n"), true), "updated-loaded");
        compare(ExtensionStatus.resultNotice(ExtensionStatus.parse("result=built\npath=/x\n"), true), "updated-built");
        compare(ExtensionStatus.resultNotice(ExtensionStatus.parse("result=failed\nreason=build-failed\n"), true), "failed");
        // A real Hyprland mismatch still names it.
        const mismatch = ExtensionStatus.parse("state=mismatch\nversion=v0.56.3\n");
        compare(ExtensionStatus.degradedNotice(mismatch, false, false), "mismatch-manual");
        verify(ExtensionStatus.namesHyprland(ExtensionStatus.degradedNotice(mismatch, true, false)));
        compare(ExtensionStatus.resultNotice(ExtensionStatus.parse("result=built\n"), false), "rebuilt-built");
        compare(ExtensionStatus.degradedNotice(ExtensionStatus.parse(""), true, false), "absent");
    }

    // ADR-0041 step 2d (SP-6): the two notices shown without the opt-in setting carry the rebuild as their click, the
    // ones shown while the rebuild runs and the plain notice do not.
    function test_theManualNoticesCarryTheRebuildAsTheirClick() {
        verify(ExtensionStatus.manualAction("stale-manual"));
        verify(ExtensionStatus.manualAction("mismatch-manual"));
        for (const key of ["stale-rebuilding", "mismatch-rebuilding", "absent", "", "updated-built"])
            verify(!ExtensionStatus.manualAction(key), key);
        const stale = ExtensionStatus.parse("state=mismatch\nversion=v0.56.2\nreason=stale-build\n");
        verify(ExtensionStatus.manualAction(ExtensionStatus.degradedNotice(stale, false, false)), "the setting off: the click");
        verify(!ExtensionStatus.manualAction(ExtensionStatus.degradedNotice(stale, true, false)), "the setting on: the rebuild runs already");
    }

    function test_aMatchingBuildThatIsNotLoadedGetsThePlainNotice() {
        compare(ExtensionStatus.notice(ExtensionStatus.parse("state=match\nversion=v0.56.2\npath=/usr/lib/grassfield/grassfield-compositor.so\n")), "absent");
    }

    function test_noAnswerGetsThePlainNotice() {
        compare(ExtensionStatus.notice(ExtensionStatus.parse("")), "absent");
        compare(ExtensionStatus.notice(ExtensionStatus.parse("state=unknown\nreason=no-headers\n")), "absent");
        compare(ExtensionStatus.notice(ExtensionStatus.parse(undefined)), "absent");
    }

    function test_anUnknownVersionIsNotShown() {
        compare(ExtensionStatus.version(ExtensionStatus.parse("state=mismatch\nversion=unknown\n")), "");
        compare(ExtensionStatus.version(ExtensionStatus.parse("state=mismatch\n")), "");
    }

    function test_oddValuesAndLinesAreDropped() {
        const s = ExtensionStatus.parse("state=mismatch\nversion=<b>0.56</b>\n=x\nnoequals\nextra=1\n");
        compare(s.version, "");
        compare(s.state, "mismatch");
        compare(s.extra, undefined);
        compare(ExtensionStatus.parse("version=" + "1".repeat(65)).version, "");
    }

    function test_theFirstValueOfAKeyCounts() {
        compare(ExtensionStatus.parse("state=match\nstate=mismatch\n").state, "match");
    }

    function test_theRebuildStartsOnlyOnAMismatchWithTheSettingOnAndOnce() {
        const mismatch = ExtensionStatus.parse("state=mismatch\nversion=v0.56.3\n");
        verify(ExtensionStatus.rebuilds(mismatch, true, false));
        verify(!ExtensionStatus.rebuilds(mismatch, false, false));
        verify(!ExtensionStatus.rebuilds(mismatch, true, true));
        verify(!ExtensionStatus.rebuilds(ExtensionStatus.parse("state=match\n"), true, false));
        verify(!ExtensionStatus.rebuilds(ExtensionStatus.parse(""), true, false));
    }

    function test_theRebuildOutcomes() {
        compare(ExtensionStatus.outcome(ExtensionStatus.parse("result=loaded\npath=/x\n")), "loaded");
        compare(ExtensionStatus.outcome(ExtensionStatus.parse("result=built\npath=/x\n")), "built");
        compare(ExtensionStatus.outcome(ExtensionStatus.parse("result=failed\nreason=cannot-build\n")), "cannot-build");
        compare(ExtensionStatus.outcome(ExtensionStatus.parse("result=failed\nreason=build-failed\n")), "failed");
        compare(ExtensionStatus.outcome(ExtensionStatus.parse("")), "failed");
        compare(ExtensionStatus.outcome(undefined), "failed");
    }
}
