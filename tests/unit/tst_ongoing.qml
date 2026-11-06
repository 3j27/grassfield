import QtQuick
import QtTest
import "../../shell/platform/MenuBridge.js" as Bridge
import "../../shell/platform/Ongoing.js" as Ongoing

// Ongoing activities, the shell's side (ADR-0052; shell/platform/Ongoing.js and the menu/1 lines of MenuBridge.js): what the
// bridge forwards is checked again, kept in a bounded state, ordered for the menu bar, redacted while locked, and shown as a
// compact time or percent. The menu bar items and the popover are NOT rendered here (no Quickshell runtime).
TestCase {
    name: "Ongoing"

    readonly property string keyA: "00000000000000a1"
    readonly property string keyB: "00000000000000b2"

    function line(fields) {
        return JSON.stringify(Object.assign({
            type: "ongoing",
            id: keyA,
            app: "org.grassfield.Files",
            kind: "transfer",
            title: "Copying 3 items to “Docs”",
            subtitle: "1 MB of 2 MB",
            progress: 0.5,
            started: null,
            ends: null,
            actions: [{id: "stop", label: "Stop"}],
            redacted: false
        }, fields));
    }

    function parsed(fields) {
        const msg = Bridge.parseBridgeLine(line(fields));
        return msg && msg.type === "ongoing" ? Ongoing.parse(msg.msg) : null;
    }

    function test_bridgeLines() {
        const msg = Bridge.parseBridgeLine(line({}));
        compare(msg.type, "ongoing");
        compare(Bridge.parseBridgeLine(JSON.stringify({type: "ongoing-end", id: keyA})), {type: "ongoing-end", id: keyA});
        compare(Bridge.parseBridgeLine(JSON.stringify({type: "ongoing-end", id: "zz"})), null);
    }

    function test_parse() {
        const it = parsed({});
        compare(it.id, keyA);
        compare(it.app, "org.grassfield.Files");
        compare(it.kind, "transfer");
        compare(it.title, "Copying 3 items to “Docs”");
        compare(it.progress, 0.5);
        compare(it.started, null);
        compare(it.actions, [{id: "stop", label: "Stop"}]);
        compare(it.redacted, false);
        // Refused: a bad key, an unknown kind, a progress out of range.
        compare(parsed({id: "x"}), null);
        compare(parsed({kind: "island"}), null);
        compare(parsed({progress: 1.5}), null);
        compare(parsed({progress: "50"}), null);
        // Cleaned: one plain line, capped; an app id that is not one is dropped.
        compare(parsed({title: "a\nb\u0007c"}).title, "a b c");
        compare(parsed({title: "x".repeat(200)}).title.length, Ongoing.limits.title);
        compare(parsed({app: "../etc"}).app, "");
        // Buttons: at most three, valid ids, no duplicates, labels capped.
        const many = [{id: "a", label: "A"}, {id: "a", label: "Again"}, {id: "Bad", label: "B"}, {id: "b", label: "B"}, {id: "c", label: "C"}, {id: "d", label: "D"}];
        compare(parsed({actions: many}).actions.map(a => a.id), ["a", "b", "c"]);
        compare(parsed({actions: [{id: "stop", label: "x".repeat(40)}]}).actions[0].label.length, Ongoing.limits.label);
        compare(parsed({actions: [{id: "stop", label: "  "}]}).actions, []);
        // Times: whole positive numbers only.
        compare(parsed({started: 1700000000000}).started, 1700000000000);
        compare(parsed({ends: -5}).ends, null);
        compare(parsed({ends: 1.5}).ends, null);
    }

    function test_redactedLinesCarryNothingTheAppWrote() {
        const it = parsed({redacted: true});
        compare(it.redacted, true);
        compare(it.app, "");
        compare(it.title, "");
        compare(it.subtitle, "");
        compare(it.actions, []);
        compare(it.progress, 0.5);
    }

    function test_stateOrderAndCap() {
        let s = Ongoing.empty();
        s = Ongoing.apply(s, parsed({}));
        s = Ongoing.apply(s, parsed({id: keyB, title: "Second"}));
        compare(Ongoing.ordered(s).map(i => i.id), [keyA, keyB]);
        // An update keeps the item's place.
        s = Ongoing.apply(s, parsed({title: "Moving"}));
        compare(Ongoing.ordered(s).map(i => i.id), [keyA, keyB]);
        compare(Ongoing.find(s, keyA).title, "Moving");
        // The bar shows the most recently started, in the order they started.
        for (let i = 0; i < 3; i++)
            s = Ongoing.apply(s, parsed({id: "00000000000000c" + i}));
        compare(Ongoing.barItems(s, 3).map(i => i.id), ["00000000000000c0", "00000000000000c1", "00000000000000c2"]);
        s = Ongoing.end(s, "00000000000000c2");
        compare(Ongoing.barItems(s, 3).map(i => i.id), [keyB, "00000000000000c0", "00000000000000c1"]);
        compare(Ongoing.end(s, "ffffffffffffffff"), s);
        // At most limits.activities.
        let full = Ongoing.empty();
        for (let i = 0; i < Ongoing.limits.activities + 4; i++)
            full = Ongoing.apply(full, parsed({id: ("0000000000000000" + (1000 + i).toString(16)).slice(-16)}));
        compare(Ongoing.ordered(full).length, Ongoing.limits.activities);
    }

    function test_lockRedaction() {
        const it = parsed({});
        const locked = Ongoing.view(it, true);
        compare(locked.redacted, true);
        compare(locked.title, "");
        compare(locked.subtitle, "");
        compare(locked.app, "");
        compare(locked.actions, []);
        compare(locked.kind, "transfer");
        compare(Ongoing.view(it, false), it);
        compare(it.title, "Copying 3 items to “Docs”"); // the original is not changed
        compare(Ongoing.view(null, true), null);
    }

    function test_compactText() {
        const now = 1700000000000;
        compare(Ongoing.duration(5), "0:05");
        compare(Ongoing.duration(245), "4:05");
        compare(Ongoing.duration(3723), "1:02:03");
        compare(Ongoing.duration(-3), "0:00");
        const timer = parsed({kind: "timer", progress: null, ends: now + 4500});
        compare(Ongoing.compact(timer, now), {kind: "time", text: "0:05"}); // a countdown rounds up
        compare(Ongoing.compact(timer, now + 60000), {kind: "time", text: "0:00"});
        const call = parsed({kind: "call", progress: null, started: now - 65000});
        compare(Ongoing.compact(call, now), {kind: "time", text: "1:05"});
        compare(Ongoing.compact(parsed({progress: 0.426}), now), {kind: "percent", value: 42});
        compare(Ongoing.compact(parsed({progress: null}), now), {kind: "none"});
        verify(Ongoing.ticking([timer]));
        verify(!Ongoing.ticking([parsed({})]));
        compare(Ongoing.symbolOf("recording"), "record");
        compare(Ongoing.symbolOf("nonsense"), "activity");
    }

    function test_shellLines() {
        compare(JSON.parse(Ongoing.lockLine(true)), {type: "lock", locked: true});
        compare(JSON.parse(Ongoing.lockLine(false)), {type: "lock", locked: false});
        compare(JSON.parse(Ongoing.lockLine("no")), {type: "lock", locked: false});
        compare(JSON.parse(Ongoing.actionLine(keyA, "stop")), {type: "ongoing-action", id: keyA, action: "stop"});
        compare(Ongoing.actionLine("x", "stop"), "");
        compare(Ongoing.actionLine(keyA, "Stop!"), "");
        verify(Ongoing.lockLine(true).endsWith("\n"));
    }
}
