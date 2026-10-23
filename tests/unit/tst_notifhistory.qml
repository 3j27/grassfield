import QtQuick
import QtTest
import "../../shell/notifications/History.js" as History

TestCase {
    name: "NotificationHistory"

    readonly property real now: 1800000000000
    readonly property real day: 24 * 3600 * 1000

    function entry(key, app, time, extra) {
        const e = {key: key, nid: 1, appName: app, appIcon: "", summary: "s" + key, body: "b", time: time, urgency: 1,
            transient: false, resident: false, actions: []};
        return Object.assign(e, extra || {});
    }

    function test_pruneDropsOlderThanSevenDays() {
        const list = [entry("new", "a", now - day), entry("edge", "a", now - 7 * day), entry("old", "a", now - 7 * day - 1)];
        compare(History.prune(list, now).map(e => e.key).join(","), "new,edge");
    }

    // GF-113: retention, nothing at rest, no bodies for apps whose previews are Never.
    function test_serializeRetentionAndBodies() {
        const list = [entry("a", "Signal", now - 1000, {body: "secret"}), entry("b", "Mail", now - 2 * day, {body: "hello"})];
        const day1 = JSON.parse(History.serialize(list, now, {maxAgeMs: day}));
        compare(day1.notifications.map(e => e.key), ["a"]);
        const never = JSON.parse(History.serialize(list, now, {keep: false}));
        compare(never.notifications.length, 0);
        const noBody = JSON.parse(History.serialize(list, now, {bodyKept: app => app !== "Signal"}));
        compare(noBody.notifications[0].body, "");
        compare(noBody.notifications[1].body, "hello");
        compare(JSON.parse(History.serialize(list, now)).notifications[0].body, "secret");
    }

    function test_pruneCapsAt200NewestFirst() {
        const list = [];
        for (let i = 0; i < 250; i++)
            list.push(entry("k" + i, "a", now - i * 1000));
        const kept = History.prune(list, now);
        compare(kept.length, 200);
        compare(kept[0].key, "k0");
        compare(kept[199].key, "k199");
    }

    function test_pushNewestMatchesPrune() {
        let list = [];
        for (let i = 0; i < 200; i++)
            list.push(entry("k" + i, "a", now - (i + 1) * 1000));
        const next = entry("new", "a", now);
        const fast = History.pushNewest(list, next, now);
        compare(fast.map(e => e.key).join(","), History.prune([next].concat(list), now).map(e => e.key).join(","));
        compare(fast.length, 200);
        compare(fast[0].key, "new");
        // Older than the head: falls back to the full prune (sorted).
        const late = History.pushNewest(list, entry("late", "a", now - 5000), now);
        compare(late[4].key, "late");
        // Aged-out tail is dropped.
        const aged = History.pushNewest([entry("x", "a", now - 7 * day - 1)], next, now);
        compare(aged.map(e => e.key).join(","), "new");
    }

    function test_transientAndLowNotPersisted() {
        verify(!History.shouldPersist(entry("t", "a", now, {transient: true})));
        verify(!History.shouldPersist(entry("l", "a", now, {urgency: 0})));
        verify(History.shouldPersist(entry("lr", "a", now, {urgency: 0, resident: true})));
        verify(History.shouldPersist(entry("n", "a", now)));
        verify(History.shouldPersist(entry("c", "a", now, {urgency: 2})));
        const data = JSON.parse(History.serialize([entry("t", "a", now, {transient: true}), entry("n", "a", now)], now));
        compare(data.notifications.length, 1);
        compare(data.notifications[0].key, "n");
    }

    function test_roundTripRestoresNonActionable() {
        const live = entry("1", "mail", now - 1000, {actions: [{id: "reply", text: "Reply"}], nid: 42});
        const restored = History.parse(History.serialize([live], now), now);
        compare(restored.length, 1);
        compare(restored[0].nid, -1);
        compare(restored[0].restored, true);
        compare(restored[0].actions.length, 1);
        compare(restored[0].actions[0].text, "Reply");
        compare(restored[0].actions[0].id, "");
        compare(restored[0].summary, "s1");
    }

    function test_parseRejectsGarbage() {
        compare(History.parse("not json", now).length, 0);
        compare(History.parse("{\"version\": 2, \"notifications\": []}", now).length, 0);
        compare(History.parse("{\"version\": 1, \"notifications\": [1, {\"time\": \"x\"}, {\"time\": " + now + "}]}", now).length, 1);
    }

    function test_parsePrunesStoredOldEntries() {
        const text = JSON.stringify({version: 1, notifications: [{key: "o", time: now - 8 * day}, {key: "n", time: now}]});
        compare(History.parse(text, now).map(e => e.key).join(","), "n");
    }

    function test_groupByAppNewestFirst() {
        const list = [entry("1", "mail", now - 3000), entry("2", "chat", now - 1000), entry("3", "mail", now - 2000, {appIcon: "mail-icon"}),
            entry("4", "", now - 4000)];
        const groups = History.group(list);
        compare(groups.map(g => g.appName).join(","), "chat,mail,");
        compare(groups[1].items.map(e => e.key).join(","), "3,1");
        compare(groups[1].appIcon, "mail-icon");
        compare(groups[1].latest, now - 2000);
    }

    function test_removeKeyAndApp() {
        const list = [entry("1", "mail", now), entry("2", "chat", now), entry("3", "mail", now)];
        compare(History.removeKey(list, "2").length, 2);
        compare(History.removeApp(list, "mail").map(e => e.key).join(","), "2");
    }

    // Clear one (the x of a card): only that entry goes, order kept, unknown key changes nothing, input untouched.
    function test_clearOneKeepsTheRest() {
        const list = [entry("1", "mail", now), entry("2", "mail", now - 1000), entry("3", "chat", now - 2000)];
        const after = History.removeKey(list, "2");
        compare(after.map(e => e.key).join(","), "1,3");
        compare(list.length, 3);
        compare(History.removeKey(list, "nope").map(e => e.key).join(","), "1,2,3");
        compare(History.removeKey([], "1").length, 0);
        compare(History.group(after).map(g => g.appName + ":" + g.items.length).join(","), "mail:1,chat:1");
    }

    // Clear group (Clear All on a group header): every entry of the app, also the app without a name, nothing else.
    function test_clearGroupRemovesWholeApp() {
        const list = [entry("1", "mail", now), entry("2", "", now - 1000), entry("3", "mail", now - 2000), entry("4", "chat", now - 3000),
            entry("5", "", now - 4000)];
        compare(History.removeApp(list, "mail").map(e => e.key).join(","), "2,4,5");
        compare(History.removeApp(list, "").map(e => e.key).join(","), "1,3,4");
        compare(History.removeApp(list, "none").length, 5);
        compare(History.group(History.removeApp(list, "mail")).map(g => g.appName).join(","), ",chat");
    }

    // History state after clearing: what is written to disk no longer holds the cleared entries; clearing everything
    // writes an empty list that parses back to nothing (no "Clear All" is needed to reach that state).
    function test_clearedEntriesLeaveTheStoredHistory() {
        const list = [entry("1", "mail", now - 1000), entry("2", "mail", now - 2000), entry("3", "chat", now - 3000)];
        const stored = JSON.parse(History.serialize(History.removeApp(History.removeKey(list, "3"), "mail"), now));
        compare(stored.notifications.length, 0);
        const some = JSON.parse(History.serialize(History.removeKey(list, "1"), now));
        compare(some.notifications.map(e => e.key).join(","), "2,3");
        const restored = History.parse(History.serialize(History.removeKey(list, "2"), now), now);
        compare(restored.map(e => e.key).join(","), "1,3");
        compare(History.parse(History.serialize([], now), now).length, 0);
    }

    function test_relativeParts() {
        compare(History.relativeParts(now - 5000, now).unit, "now");
        compare(JSON.stringify(History.relativeParts(now - 120000, now)), "{\"unit\":\"m\",\"n\":2}");
        compare(JSON.stringify(History.relativeParts(now - 3 * 3600 * 1000, now)), "{\"unit\":\"h\",\"n\":3}");
        compare(JSON.stringify(History.relativeParts(now - 2 * day, now)), "{\"unit\":\"d\",\"n\":2}");
        compare(History.relativeParts(now + 5000, now).unit, "now");
    }

    // Quickshell's Notification.expireTimeout is in milliseconds.
    function test_bannerTimeout() {
        compare(History.bannerTimeout(2, 3000, 5000), 0);
        compare(History.bannerTimeout(1, 0, 5000), 0);
        compare(History.bannerTimeout(1, 2000, 5000), 2000);
        compare(History.bannerTimeout(1, -1, 5000), 5000);
        compare(History.bannerTimeout(0, -1, 5000), 5000);
    }

    function test_absoluteImage() {
        const u = "image://icon//usr/share/icons/hicolor/48x48/apps/btop.png";
        compare(History.absoluteImage(u), u);
        compare(History.absoluteImage("/tmp/a.png"), "/tmp/a.png");
        compare(History.absoluteImage("image://icon/firefox"), "");
        compare(History.absoluteImage("data:image/png;base64,AA"), "");
        compare(History.absoluteImage(""), "");
    }
}
