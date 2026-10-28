import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/SoftwareUpdateLogic.js" as Logic

// Software Update step 2 (ADR-0033 d; docs/specs/updates.md A9): the checker's answers read, the last success kept through a
// failure, the releases counted for the badge, each new version and `blocking` episode announced once, versions as people
// read them, the checker's arguments and the automatic schedule (fake clock).
TestCase {
    name: "SoftwareUpdate"

    function answer(state, extra) {
        return Object.assign({version: 1, state: state, checkedAt: "2026-10-28T10:00:00Z"}, extra || {});
    }

    function available(gf, om) {
        return answer("available", {
            channel: "stable",
            grassfield: {installed: "1.0.0-1", available: gf || null, notes: [], notesError: null},
            omarchy: {installed: "4.0.4-1", available: om || null},
            others: 2,
            otherPackages: [{name: "glibc", installed: "2.42-1", available: "2.42-2"}, {name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]
        });
    }

    function test_onlyTheCheckersAnswersAreRead() {
        compare(Logic.parse(JSON.stringify(available("1.0.1-1"))).state, "available");
        for (const s of ["not-set-up", "repair", "blocking", "up-to-date", "available", "failed", "update-running", "busy"])
            compare(Logic.parse(JSON.stringify(answer(s))).state, s, s);
        compare(Logic.parse(""), null, "nothing printed");
        compare(Logic.parse("not json"), null);
        compare(Logic.parse("[1]"), null, "not an object");
        compare(Logic.parse("null"), null);
        compare(Logic.parse(JSON.stringify({version: 2, state: "available"})), null, "another version");
        compare(Logic.parse(JSON.stringify({version: 1, state: "installing"})), null, "an unknown state");
        compare(Logic.parse(undefined), null);
        compare(Logic.parse("{\"version\":1,\"state\":\"failed\",\"x\":\"" + "a".repeat(310 * 1024) + "\"}"), null, "longer than any answer");
    }

    function test_aRunWithoutAnAnswerIsAFailure() {
        const a = Logic.noAnswer(Date.UTC(2026, 9, 28, 10, 0, 0), "the checker could not start");
        compare([a.version, a.state, a.error, a.message, a.checkedAt], [1, "failed", "unavailable", "the checker could not start", "2026-10-28T10:00:00Z"]);
    }

    function test_theLastSuccessIsKeptThroughAFailure() {
        let f = Logic.combine(Logic.normalize(null), available("1.0.1-1", "4.0.6-1"));
        compare(f.state, "available");
        compare(f.previous, undefined);
        compare(Logic.releases(f), 2, "Grassfield and Omarchy");
        f = Logic.combine(f, answer("failed", {error: "offline", lastSuccessAt: "2026-10-28T10:00:00Z"}));
        compare([f.state, f.error], ["failed", "offline"]);
        compare(f.previous.grassfield.available, "1.0.1-1", "what was found stays");
        compare(f.previous.otherPackages.length, 2);
        compare(Logic.releases(f), 2, "the badge stays through a failure");
        f = Logic.combine(f, answer("update-running"));
        compare(f.previous.omarchy.available, "4.0.6-1", "and while omarchy update runs");
        f = Logic.combine(f, answer("blocking", {episode: "2026-10-28T09:00:00Z"}));
        compare(Logic.releases(f), 2);
        f = Logic.combine(f, answer("up-to-date", {grassfield: {installed: "1.0.1-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}}));
        compare(f.previous, undefined, "a success replaces it");
        compare(Logic.releases(f), 0);
        f = Logic.combine(Logic.combine(f, available("1.0.2-1")), answer("not-set-up"));
        compare(f.previous, undefined, "turned off: nothing is checked any more, nothing kept");
        compare(Logic.releases(f), 0);
    }

    function test_aBusyAnswerChangesNothing() {
        compare(Logic.combine(Logic.normalize(null), answer("busy")), null);
        compare(Logic.combine(Logic.normalize(null), null), null);
    }

    function test_theFileKeepsTheAnnouncedVersionsAndThePendingLogout() {
        let f = Logic.normalize({version: 1, state: "up-to-date", announced: ["grassfield 1.0.1-1", 7, null], logoutPending: true});
        compare(f.announced, ["grassfield 1.0.1-1"], "only strings");
        f = Logic.combine(f, available("1.0.2-1"));
        compare(f.announced, ["grassfield 1.0.1-1"]);
        compare(f.logoutPending, true);
        f = Logic.withLogoutPending(f, false);
        compare(f.logoutPending, undefined);
        compare(Logic.normalize({version: 3, announced: ["x"]}).announced, [], "another version reads as empty");
        compare(Logic.normalize("junk").state, "");
        let many = Logic.normalize(null);
        for (let i = 0; i < 40; i++)
            many = Logic.withAnnounced(many, [{id: "omarchy 4.0." + i + "-1"}]);
        compare(many.announced.length, 32, "bounded, the oldest dropped");
        compare(many.announced[31], "omarchy 4.0.39-1");
    }

    function test_eachNewReleaseIsAnnouncedOnce() {
        let f = Logic.normalize(null);
        let items = Logic.news(f, available("1.0.1-1", "4.0.6-1"));
        compare(items.map(n => n.id), ["grassfield 1.0.1-1", "omarchy 4.0.6-1"]);
        compare(items[0].installed, "1.0.0-1");
        f = Logic.withAnnounced(Logic.combine(f, available("1.0.1-1", "4.0.6-1")), items);
        compare(Logic.news(f, available("1.0.1-1", "4.0.6-1")), [], "never twice");
        compare(Logic.news(f, available("1.0.2-1", "4.0.6-1")).map(n => n.id), ["grassfield 1.0.2-1"], "a newer version is new");
        compare(Logic.news(f, answer("up-to-date")), []);
        compare(Logic.news(f, answer("failed")), []);
    }

    function test_aBlockingEpisodeIsAnnouncedOnce() {
        let f = Logic.normalize(null);
        const a = answer("blocking", {episode: "2026-10-28T09:00:00Z"});
        const items = Logic.news(f, a);
        compare(items.map(n => n.id), ["blocking 2026-10-28T09:00:00Z"]);
        f = Logic.withAnnounced(Logic.combine(f, a), items);
        compare(Logic.news(f, a), [], "still the same episode");
        compare(Logic.news(f, answer("blocking", {episode: "2026-10-29T09:00:00Z"})).length, 1, "a new episode");
        compare(Logic.news(f, answer("blocking")), [], "no episode, nothing to name");
    }

    function test_releasesCountTheBadge() {
        compare(Logic.releases(Logic.normalize(null)), 0);
        compare(Logic.releases(available("1.0.1-1")), 1);
        compare(Logic.releases(available(null, "4.0.6-1")), 1);
        compare(Logic.releases(available("1.0.1-1", "4.0.6-1")), 2);
        compare(Logic.releases(answer("up-to-date")), 0);
        compare(Logic.releases(answer("available")), 0, "an answer without releases counts none");
    }

    function test_versionsAsPeopleReadThem() {
        compare(Logic.displayVersion("1.0.1-1"), "1.0.1");
        compare(Logic.displayVersion("1.1.0beta1-3"), "1.1.0-beta1");
        compare(Logic.displayVersion("1.0.0rc1-5"), "1.0.0-rc1");
        compare(Logic.displayVersion("2:4.0.6-1"), "4.0.6");
        compare(Logic.displayVersion("4.0.6"), "4.0.6");
        compare(Logic.rebuildOf("1.0.1-3", "1.0.1-4"), "4", "a rebuild for a new Hyprland (O7)");
        compare(Logic.rebuildOf("1.0.0-3", "1.0.1-3"), "");
        compare(Logic.rebuildOf("", "1.0.1-1"), "");
        compare(Logic.releaseName("1.0.1-4", "1.0.1-3"), "1.0.1-4");
        compare(Logic.releaseName("1.0.1-1", "1.0.0-1"), "1.0.1");
        compare(Logic.releaseName("1.1.0beta1-3", "1.0.1-3"), "1.1.0-beta1");
    }

    function test_theCheckersArguments() {
        compare(Logic.checkerArgs("/usr/lib/grassfield/grassfield-update-check", false, false), ["/usr/lib/grassfield/grassfield-update-check"]);
        compare(Logic.checkerArgs("c", true, false), ["c", "--offline"]);
        compare(Logic.checkerArgs("c", false, true), ["c", "--after-update-lock"]);
        compare(Logic.checkerArgs("c", true, true), ["c", "--offline", "--after-update-lock"]);
    }

    function test_theAutomaticSchedule() {
        const min = 60 * 1000, hour = 60 * min, start = Date.UTC(2026, 9, 28, 8, 0, 0);
        const first = 10 * min, every = 6 * hour;
        compare(Logic.nextAutomatic(start, 0, 0, first, every), start + first, "never checked: 10 minutes after the start");
        compare(Logic.nextAutomatic(start, start - 7 * hour, 0, first, every), start + first, "checked long ago");
        compare(Logic.nextAutomatic(start, start - 1 * hour, 0, first, every), start + 5 * hour, "a restarted shell waits for the 6 hours");
        compare(Logic.nextAutomatic(start, start + 30 * min, 0, first, every), start + 30 * min + every, "then every 6 hours");
        compare(Logic.nextAutomatic(start, start + 30 * min, start + 45 * min, first, every), start + 45 * min, "the checker's retry (U3) comes first");
        compare(Logic.timeOf("2026-10-28T10:00:00Z"), Date.UTC(2026, 9, 28, 10, 0, 0));
        compare(Logic.timeOf(undefined), 0);
        compare(Logic.timeOf("never"), 0);
    }

    function test_meteredConnections() {
        verify(Logic.metered("yes\n"));
        verify(Logic.metered("--\nyes (guessed)\n"), "any device");
        verify(!Logic.metered("no\n"));
        verify(!Logic.metered("unknown\n"));
        verify(!Logic.metered(""), "an unreadable answer is not metered");
    }
}
