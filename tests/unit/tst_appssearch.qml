import QtQuick
import QtTest
import "../../shell/search/Ranking.js" as Ranking

// Apps search keystroke cost (A4, P4): ranking about 194 entries must stay well inside a frame.
TestCase {
    name: "AppsSearchTiming"

    readonly property var words: ["alpha", "beta", "gamma", "delta", "terminal", "editor", "browser", "music", "video", "photo", "mail", "chat", "game", "calc", "notes", "clock", "maps", "files", "archive", "paint"]

    function fakeApps(n) {
        const out = [];
        for (let i = 0; i < n; i++) {
            out.push({
                id: "fake" + i + ".desktop",
                name: words[i % words.length] + " " + words[(i * 7 + 3) % words.length] + " " + i,
                genericName: i % 3 === 0 ? "Utility" : "",
                comment: "Fake application number " + i + " for timing",
                keywords: [words[(i * 5) % words.length], words[(i * 11) % words.length]]
            });
        }
        return out;
    }

    // Min-of-N: the fastest of 10 batches of 20 rank() calls, in ms per call (Date.now() is too
    // coarse for a single call).
    function minMs(apps, query) {
        let best = Infinity;
        for (let r = 0; r < 10; r++) {
            const t0 = Date.now();
            for (let k = 0; k < 20; k++)
                Ranking.rank(apps, query, Ranking.newUsage(), 0);
            best = Math.min(best, (Date.now() - t0) / 20);
        }
        return best;
    }

    function test_keystrokeCost_194entries() {
        const apps = fakeApps(194);
        for (const q of ["a", "al", "alp", "term", "zzz", "alpha ter"]) {
            const best = minMs(apps, q);
            console.info("apps rank", q, best, "ms per keystroke, 194 entries");
            // Load-tolerant bound (min of N): ranking must stay well inside one 16 ms frame.
            verify(best <= 12, "rank('" + q + "') took " + best + " ms (budget 12 ms of the 16 ms frame)");
        }
    }

    function test_resultsMatchOnRepeat() {
        // The per-app normalization cache must not change results between calls.
        const apps = fakeApps(194);
        const a = Ranking.rank(apps, "alpha", Ranking.newUsage(), 0).map(r => r.app.id);
        const b = Ranking.rank(apps, "alpha", Ranking.newUsage(), 0).map(r => r.app.id);
        verify(a.length > 0);
        compare(a.join(), b.join());
        compare(Ranking.rank(apps, "  ", Ranking.newUsage(), 0).length, 0);
    }
}
