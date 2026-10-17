import QtQuick
import QtTest
import "../../shell/search/Ranking.js" as Ranking
import "../../shell/search/Files.js" as Files

TestCase {
    name: "SearchRanking"

    readonly property var apps: [
        {id: "firefox", name: "Firefox", genericName: "Web Browser", comment: "Browse the World Wide Web", keywords: ["internet", "www"]},
        {id: "foot", name: "Foot", genericName: "Terminal", comment: "Fast terminal emulator", keywords: ["shell", "prompt"]},
        {id: "files", name: "Files", genericName: "File Manager", comment: "Browse your files", keywords: ["folder"]},
        {id: "fire-tool", name: "Hot Fire Tool", genericName: "", comment: "", keywords: []},
        {id: "kitty", name: "kitty", genericName: "Terminal", comment: "", keywords: []}
    ]

    function ids(query, usage) {
        return Ranking.rank(apps, query, usage || Ranking.newUsage()).map(r => r.app.id);
    }

    function test_prefixBeatsWordBeatsSubstring() {
        compare(ids("fire")[0], "firefox");
        compare(ids("fire")[1], "fire-tool");
        compare(ids("foo")[0], "foot");
    }

    function test_noMatchAndEmpty() {
        compare(ids("zzzq").length, 0);
        compare(ids("").length, 0);
        compare(ids("   ").length, 0);
    }

    function test_fuzzy() {
        compare(ids("ffx")[0], "firefox");
        compare(ids("fox")[0], "firefox");
    }

    function test_keywordsGenericNameComment() {
        compare(ids("internet")[0], "firefox");
        compare(ids("terminal").slice(0, 2).sort().join(), "foot,kitty");
        compare(ids("emulator")[0], "foot");
        compare(ids("folder")[0], "files");
    }

    function test_nameBeatsKeyword() {
        compare(ids("shell")[0], "foot");
        const apps2 = [{id: "a", name: "Other", keywords: ["term"]}, {id: "b", name: "Term", keywords: []}];
        compare(Ranking.rank(apps2, "term", Ranking.newUsage())[0].app.id, "b");
    }

    function test_usageBoostReordersEqualMatches() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 10; i++)
            Ranking.bumpUsage(usage, "files", 1000 + i);
        compare(ids("fi", usage)[0], "files");
        verify(Ranking.usageBoost(usage["files"]) > 0);
        verify(Ranking.usageBoost(usage["files"]) <= 20);
    }

    function test_usageBoostNeverCreatesMatch() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 50; i++)
            Ranking.bumpUsage(usage, "kitty", i);
        compare(ids("zzzq", usage).length, 0);
    }

    function test_usageRoundTripAndCorruption() {
        const usage = Ranking.newUsage();
        Ranking.bumpUsage(usage, "foot", 5);
        Ranking.bumpUsage(usage, "foot", 6);
        const back = Ranking.parseUsage(Ranking.serializeUsage(usage));
        compare(back["foot"].count, 2);
        compare(back["foot"].last, 6);
        compare(Object.keys(Ranking.parseUsage("not json")).length, 0);
        compare(Object.keys(Ranking.parseUsage("{\"version\":9,\"usage\":{}}")).length, 0);
        compare(Object.keys(Ranking.parseUsage("{\"version\":1,\"usage\":{\"a\":{\"count\":\"x\",\"last\":1}}}")).length, 0);
    }

    function test_usageCap() {
        const usage = Ranking.newUsage();
        for (let i = 0; i < 700; i++)
            Ranking.bumpUsage(usage, "app" + i, i);
        const back = Ranking.parseUsage(Ranking.serializeUsage(usage));
        compare(Object.keys(back).length, 500);
        verify("app699" in back);
        verify(!("app0" in back));
    }

    function test_performanceOn300Entries() {
        const many = [];
        for (let i = 0; i < 300; i++)
            many.push({id: "app" + i, name: "Application Number " + i, genericName: "Tool", comment: "A long description for entry " + i, keywords: ["alpha", "beta", "gamma"]});
        const t0 = Date.now();
        for (let i = 0; i < 20; i++)
            Ranking.rank(many, "appnum", Ranking.newUsage());
        verify((Date.now() - t0) / 20 < 50);
    }

    function test_filesParsing() {
        const xbel = "<xbel><bookmark href=\"file:///home/u/My%20Doc.txt\" modified=\"2026-01-02T00:00:00Z\"><info><metadata><mime:mime-type type=\"text/plain\"/></metadata></info></bookmark>"
            + "<bookmark href=\"file:///home/u/new&amp;1.md\" modified=\"2026-02-02T00:00:00Z\"><info></info></bookmark>"
            + "<bookmark href=\"https://example.com/x\" modified=\"2026-03-02T00:00:00Z\"></bookmark></xbel>";
        const r = Files.parseXbel(xbel);
        compare(r.length, 2);
        compare(r[0].path, "/home/u/new&1.md");
        compare(r[1].path, "/home/u/My Doc.txt");
        compare(r[1].mime, "text/plain");
        const p = Files.parsePlocate("/etc/x/report\n/home/u/.cache/report\n/home/u/a/old-report.txt\n/home/u/report.md", "report", "/home/u", 20);
        compare(p.join(), "/home/u/report.md,/home/u/a/old-report.txt");
        compare(Files.parseLocalsearch("file:///home/u/a%20b.txt\n  file:///home/u/.hidden/x\nnoise", "/home/u", 20).join(), "/home/u/a b.txt");
        compare(Files.tildePath("/home/u/a", "/home/u"), "~/a");
    }
}
