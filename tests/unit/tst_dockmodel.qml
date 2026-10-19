import QtQuick
import QtTest
import "../../shell/dock/DockModel.js" as DockModel

TestCase {
    name: "DockModel"

    readonly property var entries: ({
        "foot": {id: "foot", name: "Foot", icon: "foot"},
        "chromium": {id: "chromium", name: "Chromium", icon: "chromium"},
        "org.gnome.Nautilus": {id: "org.gnome.Nautilus", name: "Files", icon: "nautilus"}
    })

    function lookup(id) {
        // Case-insensitive like the heuristic lookup of desktop entries.
        for (const key in entries) {
            if (key.toLowerCase() === id.toLowerCase())
                return entries[key];
        }
        return null;
    }

    function test_pinnedKeepOrderAndSkipUnknown() {
        const list = DockModel.merge(["chromium", "ghost", "foot"], [], lookup);
        compare(list.map(i => i.key).join(","), "chromium,foot");
        verify(list.every(i => i.pinned && i.windows.length === 0));
    }

    function test_runningPinnedAppAttachesWindows() {
        const list = DockModel.merge(["foot"], [{appId: "foot", ref: "w1"}, {appId: "Foot", ref: "w2"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.join(","), "w1,w2");
        verify(list[0].pinned);
    }

    function test_runningUnpinnedAppsAppendedAfterPinned() {
        const list = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}, {appId: "mystery", ref: "m"}], lookup);
        compare(list.map(i => i.key).join(","), "foot,chromium,mystery");
        verify(!list[1].pinned);
        compare(list[2].name, "mystery");
        compare(list[2].entry, null);
    }

    function test_emptyAppIdIgnoredAndPinsDeduplicated() {
        const list = DockModel.merge(["foot", "FOOT", "foot"], [{appId: "", ref: "x"}], lookup);
        compare(list.length, 1);
        compare(list[0].windows.length, 0);
    }

    function test_tailIsSeparatorThenTrash() {
        const list = DockModel.withTail(DockModel.merge(["foot"], [], lookup));
        compare(list.map(i => i.kind).join(","), "app,separator,trash");
        compare(DockModel.withTail([]).map(i => i.kind).join(","), "separator,trash");
    }

    function test_pinUnpin() {
        compare(DockModel.pin(["a"], "b").join(","), "a,b");
        compare(DockModel.pin(["a"], "a").join(","), "a");
        compare(DockModel.pin(undefined, "a").join(","), "a");
        compare(DockModel.unpin(["a", "b"], "a").join(","), "b");
        // Pin written as an alias still unpins by resolved key.
        compare(DockModel.unpinKey(["FOOT", "chromium"], "foot", lookup).join(","), "chromium");
    }

    function test_badgeCounts() {
        const item = {kind: "app", key: "org.gnome.Nautilus", name: "Files"};
        const history = [{appName: "files"}, {appName: "Files"}, {appName: "org.gnome.nautilus"}, {appName: "Other"}];
        compare(DockModel.badgeCount(history, item), 3);
        compare(DockModel.badgeCount(history, {kind: "trash"}), 0);
        compare(DockModel.badgeCount(undefined, item), 0);
        compare(DockModel.badgeText(0), "");
        compare(DockModel.badgeText(7), "7");
        compare(DockModel.badgeText(120), "99+");
    }

    function test_recents() {
        compare(DockModel.pushRecent(["a", "b", "c"], "b", 3).join(","), "b,a,c");
        compare(DockModel.pushRecent(["a", "b", "c"], "d", 3).join(","), "d,a,b");
        const apps = DockModel.merge(["foot"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.withRecents(apps, ["foot", "chromium", "ghost", "org.gnome.Nautilus"], lookup, 3);
        // macOS: the recent applications are their own section, after a divider.
        compare(out.map(i => i.kind === "separator" ? "|" : i.key).join(","), "foot,chromium,|,org.gnome.Nautilus");
        verify(out[2].divider === true);
        verify(out[3].recent === true && !out[3].pinned && out[3].windows.length === 0);
        compare(DockModel.withRecents(apps, ["org.gnome.Nautilus"], lookup, 0).length, 2);
        // No recent to show: no divider either.
        compare(DockModel.withRecents(apps, ["foot", "chromium"], lookup, 3).length, 2);
        // NoDisplay / hidden entries are never shown as recents.
        const listed = e => e.id !== "org.gnome.Nautilus";
        compare(DockModel.withRecents(apps, ["org.gnome.Nautilus"], lookup, 3, listed).length, 2);
    }

    // A fake Dock: the same logic as Dock.qml rebuild() (running set -> recents update -> write only when it differs).
    function simulate(runningSets, pinned, max, start) {
        let stored = start ? start.slice() : [];
        let previous = null;
        let writes = 0;
        const shown = [];
        for (const running of runningSets) {
            // Rebuilds repeat until the stored list stops changing (as onDockRecentChanged re-runs rebuild()).
            for (let pass = 0; pass < 6; pass++) {
                const next = DockModel.recentsAfter(stored, previous, running, pinned, max);
                previous = running;
                if (next.join(",") === stored.join(","))
                    continue;
                stored = next;
                writes++;
            }
            shown.push(stored.join(","));
        }
        return {writes: writes, stored: stored, shown: shown};
    }

    function test_recentsStayStableWithManyUnpinnedRunning() {
        // 0..8 unpinned running apps, repeated rebuilds with the same set: never a write, whatever the cap.
        for (let n = 0; n <= 8; n++) {
            const running = [];
            for (let i = 0; i < n; i++)
                running.push("app" + i);
            const r = simulate([running, running, running, running, running, running], [], 3, []);
            compare(r.writes, 0, n + " unpinned running apps: no write while none quit");
        }
    }

    function test_recentsWriteOncePerRealChange() {
        const four = ["a", "b", "c", "d"];
        // all four run for a while, then they quit one after the other: one write per quit (the cap of 3 holds)
        const r = simulate([four, four, ["b", "c", "d"], ["b", "c", "d"], ["c", "d"], ["d"], []], [], 3, []);
        compare(r.writes, 4);
        compare(r.stored.join(","), "d,c,b");
        // a re-run of the same sets writes nothing more
        const again = simulate([four, ["b", "c", "d"], ["b", "c", "d"], ["b", "c", "d"]], [], 3, []);
        compare(again.writes, 1);
        compare(again.stored.join(","), "a");
        // an app that the cap evicted while it is still running is not re-added (it shows as a running tile)
        const full = simulate([four, four, four], [], 3, ["x", "y", "z"]);
        compare(full.writes, 0);
        compare(full.stored.join(","), "x,y,z");
    }

    function test_recentsIgnorePinnedAndHandleShellRestart() {
        // a pinned app that quits is not a recent; neither is one pinned meanwhile
        compare(DockModel.recentsAfter([], ["a", "b"], ["b"], ["a"], 3).join(","), "");
        // the first rebuild (previous = null) has nothing to compare: no change
        compare(DockModel.recentsAfter(["x"], null, ["a", "b"], [], 3).join(","), "x");
        // newest first, no duplicates, cap
        compare(DockModel.recentsAfter(["x", "y"], ["a", "x"], [], [], 3).join(","), "x,a,y");
    }

    // A hidden entry (OnlyShowIn / NotShowIn) looks listed until the hidden list loads, then not: it must not count as an
    // app that quit and take a recent slot. Nothing is evaluated before the entries and the hidden list are loaded.
    function test_recentsWaitForHiddenListAndEntries() {
        let stored = ["x"];
        let previous = null;
        const rebuild = (ready, running) => {
            const step = DockModel.recentsStep(ready, stored, previous, running, [], 3);
            previous = step.previous;
            stored = step.recent;
        };
        rebuild(false, ["hidden", "foot"]);   // startup: entries / hidden list not loaded, the hidden app looks listed
        compare(previous, null);
        rebuild(false, ["foot"]);
        compare(stored.join(","), "x");
        rebuild(true, ["foot"]);              // loaded: the hidden app is excluded, the first ready step only records
        compare(stored.join(","), "x");
        compare(previous.join(","), "foot");
        rebuild(true, []);                    // a real quit afterwards is remembered
        compare(stored.join(","), "foot,x");
        // without the gate the same sequence takes a slot for the hidden app
        let naive = DockModel.recentsAfter(["x"], ["hidden", "foot"], ["foot"], [], 3);
        compare(naive.join(","), "hidden,x");
    }

    function items3() {
        return DockModel.withTail(DockModel.merge(["foot", "chromium"], [{appId: "org.gnome.Nautilus", ref: "n"}], lookup));
    }

    function test_reorderPinned() {
        const r = DockModel.reorder(items3(), 0, 1);
        verify(r.changed);
        compare(r.pinned.join(","), "chromium,foot");
        verify(!DockModel.reorder(items3(), 1, 1).changed);
    }

    function test_reorderUnpinnedBecomesPinnedOnlyBeforePinned() {
        const a = DockModel.reorder(items3(), 2, 0);
        compare(a.pinned.join(","), "org.gnome.Nautilus,foot,chromium");
        verify(a.changed);
        const b = DockModel.reorder(items3(), 2, 2);
        verify(!b.changed);
        compare(DockModel.reorder(items3(), 9, 0).changed, false);
    }

    function test_dropSlotAndDragOut() {
        compare(DockModel.dropSlot([30, 90, 150, 220], [0, 1, 2], 100), 1);
        compare(DockModel.dropSlot([30, 90, 150, 220], [0, 1, 2], 400), 2);
        // the divider of the recent applications is not a slot: positions count app tiles only
        compare(DockModel.dropSlot([30, 90, 120, 150, 220], [0, 1, 3], 125), 2);
        compare(DockModel.appIndices([{kind: "app"}, {kind: "app"}, {kind: "separator", divider: true}, {kind: "app"}, {kind: "separator"}, {kind: "trash"}]).join(","), "0,1,3");
        verify(DockModel.draggedOut(-70, 60));
        verify(!DockModel.draggedOut(-20, 60));
    }

    function test_commandsForFiles() {
        // %F: one command with every file; %U: URIs
        compare(JSON.stringify(DockModel.commandsForFiles(["gimp", "%F"], ["/a", "/b c"])), JSON.stringify([["gimp", "/a", "/b c"]]));
        compare(JSON.stringify(DockModel.commandsForFiles(["gimp", "%U"], ["/a", "/b c"])), JSON.stringify([["gimp", "file:///a", "file:///b%20c"]]));
        // %f: one launch per file (Desktop Entry spec)
        compare(JSON.stringify(DockModel.commandsForFiles(["viewer", "%f"], ["/a", "/b"])), JSON.stringify([["viewer", "/a"], ["viewer", "/b"]]));
        // embedded and other codes
        compare(JSON.stringify(DockModel.commandsForFiles(["a", "%i", "--open=%f", "100%%"], ["/a"])), JSON.stringify([["a", "--open=/a", "100%"]]));
        // no file field code: nothing is ever appended (a file dropped on `foot` must not become `foot /path`)
        compare(DockModel.commandsForFiles(["foot", "--x"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["foot", "--x", "%i", "%c"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["foot", "100%%"], ["/a"]).length, 0);
        compare(DockModel.commandsForFiles(["viewer", "%f"], []).length, 0);
    }

    readonly property string mimeText: [
        "G\t50:text/plain:*.txt", "G\t50:text/x-python:*.py", "G\t50:image/png:*.png", "G\t50:application/x-compressed-tar:*.tar.gz",
        "G\t50:application/gzip:*.gz", "G\t50:text/x-makefile:Makefile", "G\t50:image/jpeg:*.jpg:cs", "G\t50:text/markdown:*.md",
        "S\ttext/x-python text/plain", "S\tapplication/x-compressed-tar application/gzip", "A\ttext/x-markdown text/markdown",
        "E\tedit\ttext/plain;", "E\tview\timage/*;", "E\tgz\tapplication/gzip;", "E\tmd\ttext/x-markdown;", "E\tbare\t"
    ].join("\n")

    function test_dropAcceptance() {
        const data = DockModel.parseMimeData(mimeText);
        verify(data.ready);
        const open = (id, cmd) => ({id: id, command: cmd});
        // MimeType matches the type, its parents and aliases
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt"], data));
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%f"]), ["/x/a.py"], data));
        verify(DockModel.acceptsFiles(open("edit", ["edit", "%u"]), ["/x/Makefile"], data));
        verify(DockModel.acceptsFiles(open("view", ["view", "%f"]), ["/x/a.PNG"], data));
        verify(DockModel.acceptsFiles(open("gz", ["gz", "%f"]), ["/x/a.tar.gz"], data));
        verify(DockModel.acceptsFiles(open("md", ["md", "%f"]), ["/x/a.md"], data));
        // wrong type, unknown type, every file must match
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.png"], data));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt", "/x/a.png"], data));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/noextension"], data));
        // no file field code in Exec: refused whatever the MimeType (foot)
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "--new"]), ["/x/a.txt"], data));
        // no MimeType (or an empty one): refused
        verify(!DockModel.acceptsFiles(open("foot", ["foot", "%F"]), ["/x/a.txt"], data));
        verify(!DockModel.acceptsFiles(open("bare", ["bare", "%F"]), ["/x/a.txt"], data));
        // no database yet / nothing dropped
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), ["/x/a.txt"], DockModel.parseMimeData("")));
        verify(!DockModel.acceptsFiles(open("edit", ["edit", "%F"]), [], data));
    }

    function test_bounceKeys() {
        const items = DockModel.merge(["foot", "chromium"], [{appId: "chromium", ref: "c"}], lookup);
        const out = DockModel.bounceKeys({foot: 1000, chromium: 1000, old: 0}, items, 5000, 10000);
        compare(Object.keys(out).join(","), "foot");
        compare(Object.keys(DockModel.bounceKeys({foot: 1000}, items, 20000, 10000)).length, 0);
    }
}
