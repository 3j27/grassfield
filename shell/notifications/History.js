.pragma library

// Notification history model (pure, unit-tested): ADR-0004 limits, persistence format, grouping.
//
// Entry: {key, nid, appName, appIcon, summary, body, time (ms), urgency (0 low, 1 normal, 2 critical),
//         transient, resident, actions: [{id, text}], restored}
// nid is the id of the live notification (-1 when restored from disk: not actionable).

const MAX_ENTRIES = 200;
const MAX_AGE_MS = 7 * 24 * 3600 * 1000;
const FORMAT_VERSION = 1;

// Transient hint, or low urgency without resident: never stored (ADR-0004).
function shouldPersist(entry) {
    if (entry.transient)
        return false;
    if (entry.urgency === 0 && !entry.resident)
        return false;
    return true;
}

// Newest first. Drops entries older than 7 days (relative to now) and anything beyond 200.
function prune(entries, now) {
    const kept = entries.filter(e => typeof e.time === "number" && now - e.time <= MAX_AGE_MS);
    kept.sort((a, b) => b.time - a.time);
    return kept.slice(0, MAX_ENTRIES);
}

// JSON for notifications.json: persistable entries only, actions as labels, no images.
function serialize(entries, now) {
    const stored = prune(entries.filter(shouldPersist), now).map(e => ({
        key: e.key,
        appName: e.appName,
        appIcon: e.appIcon,
        summary: e.summary,
        body: e.body,
        time: e.time,
        urgency: e.urgency,
        actions: (e.actions || []).map(a => a.text)
    }));
    return JSON.stringify({version: FORMAT_VERSION, notifications: stored}, null, 1) + "\n";
}

function str(value) {
    return typeof value === "string" ? value : "";
}

// Parses the file. Corrupt or foreign data yields []. Restored entries are non-actionable: their
// actions keep the label only (empty id) and nid is -1.
function parse(text, now) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!data || data.version !== FORMAT_VERSION || !Array.isArray(data.notifications))
        return [];
    const entries = [];
    for (const raw of data.notifications) {
        if (!raw || typeof raw.time !== "number")
            continue;
        entries.push({
            key: str(raw.key) !== "" ? str(raw.key) : "restored-" + entries.length,
            nid: -1,
            appName: str(raw.appName),
            appIcon: str(raw.appIcon),
            summary: str(raw.summary),
            body: str(raw.body),
            time: raw.time,
            urgency: raw.urgency === 0 || raw.urgency === 2 ? raw.urgency : 1,
            transient: false,
            resident: false,
            actions: Array.isArray(raw.actions) ? raw.actions.filter(a => typeof a === "string").map(a => ({id: "", text: a})) : [],
            restored: true
        });
    }
    return prune(entries, now);
}

function groupName(entry) {
    return entry.appName !== "" ? entry.appName : "Notification";
}

// Groups by app, newest group first, items newest first: [{appName, appIcon, latest, items}].
function group(entries) {
    const byApp = {};
    const order = [];
    const sorted = entries.slice().sort((a, b) => b.time - a.time);
    for (const e of sorted) {
        const name = groupName(e);
        if (!byApp[name]) {
            byApp[name] = {appName: name, appIcon: e.appIcon, latest: e.time, items: []};
            order.push(name);
        }
        byApp[name].items.push(e);
        if (byApp[name].appIcon === "" && e.appIcon !== "")
            byApp[name].appIcon = e.appIcon;
    }
    return order.map(n => byApp[n]);
}

function removeKey(entries, key) {
    return entries.filter(e => e.key !== key);
}

function removeApp(entries, appName) {
    return entries.filter(e => groupName(e) !== appName);
}

// "now", "5m ago", "3h ago", "2d ago".
function relativeTime(time, now) {
    const seconds = Math.max(0, Math.floor((now - time) / 1000));
    if (seconds < 60)
        return "now";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return minutes + "m ago";
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
        return hours + "h ago";
    return Math.floor(hours / 24) + "d ago";
}

// Banner timeout in ms (spec N2): critical never expires; expire_timeout 0 never; negative = default.
// expireSeconds is Quickshell's Notification.expireTimeout (seconds).
function bannerTimeout(urgency, expireSeconds, defaultMs) {
    if (urgency === 2)
        return 0;
    if (expireSeconds === 0)
        return 0;
    if (expireSeconds > 0)
        return Math.round(expireSeconds * 1000);
    return defaultMs;
}
