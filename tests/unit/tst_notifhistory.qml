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

    function test_pruneCapsAt200NewestFirst() {
        const list = [];
        for (let i = 0; i < 250; i++)
            list.push(entry("k" + i, "a", now - i * 1000));
        const kept = History.prune(list, now);
        compare(kept.length, 200);
        compare(kept[0].key, "k0");
        compare(kept[199].key, "k199");
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
}
