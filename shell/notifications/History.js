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
function prune(entries, now, maxAgeMs) {
    const maxAge = maxAgeMs > 0 ? maxAgeMs : MAX_AGE_MS;
    const kept = entries.filter(e => typeof e.time === "number" && now - e.time <= maxAge);
    kept.sort((a, b) => b.time - a.time);
    return kept.slice(0, MAX_ENTRIES);
}

// `entries` (newest first, already pruned) with `entry` on top, pruned like prune() but in
// O(dropped): only the tail can fall out. Falls back to prune() when `entry` is not the newest.
function pushNewest(entries, entry, now) {
    if (typeof entry.time !== "number" || (entries.length > 0 && entry.time < entries[0].time))
        return prune([entry].concat(entries), now);
    const list = [entry].concat(entries);
    while (list.length > MAX_ENTRIES || (list.length > 0 && now - list[list.length - 1].time > MAX_AGE_MS))
        list.pop();
    return list;
}

// JSON for notifications.json: persistable entries only, actions as labels, no images.
// `opts` (GF-113, all optional): maxAgeMs, how long entries stay on disk (absent: 7 days); keep: false writes no
// entry at all; textKept(appName) returning false drops the title, the body and the action labels of that app's entries
// (previews are Never for it: the text is never shown, so it is not kept at rest either; app name, icon and time stay).
function serialize(entries, now, opts) {
    const o = opts || {};
    const textKept = typeof o.textKept === "function" ? o.textKept : () => true;
    const stored = (o.keep === false ? [] : prune(entries.filter(shouldPersist), now, o.maxAgeMs)).map(e => ({
        key: e.key,
        appName: e.appName,
        appIcon: e.appIcon,
        summary: textKept(e.appName) ? e.summary : "",
        body: textKept(e.appName) ? e.body : "",
        time: e.time,
        urgency: e.urgency,
        actions: textKept(e.appName) ? (e.actions || []).map(a => a.text) : []
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

// Group key: the app name ("" for senders without one; the UI shows a translated label).
function groupName(entry) {
    return entry.appName;
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

// Age as {unit: "now"|"m"|"h"|"d", n}; the UI turns it into translated text.
function relativeParts(time, now) {
    const seconds = Math.max(0, Math.floor((now - time) / 1000));
    if (seconds < 60)
        return {unit: "now", n: 0};
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return {unit: "m", n: minutes};
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
        return {unit: "h", n: hours};
    return {unit: "d", n: Math.floor(hours / 24)};
}

// Banner timeout in ms (spec N2): critical never expires; expire_timeout 0 never; negative = default.
// expireMs is Quickshell's Notification.expireTimeout, which is in MILLISECONDS (the D-Bus
// expire_timeout unit; verified with `notify-send -t 2000`).
function bannerTimeout(urgency, expireMs, defaultMs) {
    if (urgency === 2)
        return 0;
    if (expireMs === 0)
        return 0;
    if (expireMs > 0)
        return Math.round(expireMs);
    return defaultMs;
}

// An image that is an absolute local file (a plain path, or Quickshell's image://icon//abs/path
// for an app_icon path): returned as given; "" for anything else (themed names, other URLs).
function absoluteImage(image) {
    if (typeof image !== "string")
        return "";
    return image.startsWith("/") || image.startsWith("image://icon//") ? image : "";
}
