.pragma library

// Application ranking (pure, unit-tested): prefix/word/substring/fuzzy match on the name,
// keyword, generic name and comment matching, and a persisted usage boost.
//
// App record: {id, name, genericName, comment, keywords: [string]}.
// Usage map (null prototype): id -> {count, last (ms)}.

const USAGE_VERSION = 1;
const MAX_USAGE_ENTRIES = 500;

function norm(s) {
    return typeof s === "string" ? s.toLowerCase() : "";
}

// Subsequence match: every query char appears in order. Returns 0 when not a subsequence,
// otherwise 1..25 (tighter and earlier matches score higher).
function fuzzy(text, query) {
    let ti = 0;
    let first = -1;
    let last = -1;
    for (let qi = 0; qi < query.length; qi++) {
        const idx = text.indexOf(query[qi], ti);
        if (idx < 0)
            return 0;
        if (first < 0)
            first = idx;
        last = idx;
        ti = idx + 1;
    }
    const span = last - first + 1;
    const gaps = span - query.length;
    return Math.max(1, 25 - gaps * 2 - first);
}

function wordStart(text, query) {
    const words = text.split(/[\s\-_.]+/);
    for (const w of words) {
        if (w.length > 0 && w.startsWith(query))
            return true;
    }
    return false;
}

// Text match score: 100 exact, 80 prefix, 65 word prefix, 50 substring, <=25 fuzzy, 0 none.
function textScore(text, query) {
    if (text === "" || query === "")
        return 0;
    if (text === query)
        return 100;
    if (text.startsWith(query))
        return 80;
    if (wordStart(text, query))
        return 65;
    if (text.indexOf(query) >= 0)
        return 50;
    return query.length >= 2 ? fuzzy(text, query) : 0;
}

function usageBoost(entry) {
    if (!entry || !(entry.count > 0))
        return 0;
    return Math.min(20, Math.log2(1 + entry.count) * 5);
}

function usageFor(usage, id) {
    return usage && id in usage ? usage[id] : null;
}

// Score of one app for a (trimmed) query; 0 = no match. The usage boost only applies to matches.
function score(app, rawQuery, usage) {
    const query = norm(rawQuery).trim();
    if (query === "")
        return 0;
    let s = textScore(norm(app.name), query);
    let kw = 0;
    for (const k of app.keywords || [])
        kw = Math.max(kw, textScore(norm(k), query) * 0.45);
    s = Math.max(s, kw);
    s = Math.max(s, textScore(norm(app.genericName), query) * 0.4);
    const c = norm(app.comment);
    if (c.length > 0 && query.length >= 3 && c.indexOf(query) >= 0)
        s = Math.max(s, 15);
    if (s <= 0)
        return 0;
    return s + usageBoost(usageFor(usage, app.id));
}

// Sorted matches [{app, score}], best first; ties by name. `limit` caps the list.
function rank(apps, query, usage, limit) {
    const out = [];
    for (const app of apps) {
        const s = score(app, query, usage);
        if (s > 0)
            out.push({app: app, score: s});
    }
    out.sort((a, b) => b.score - a.score || norm(a.app.name).localeCompare(norm(b.app.name)));
    return limit > 0 ? out.slice(0, limit) : out;
}

function newUsage() {
    return Object.create(null);
}

function bumpUsage(usage, id, now) {
    if (typeof id !== "string" || id === "")
        return usage;
    const prev = usageFor(usage, id);
    usage[id] = {count: (prev ? prev.count : 0) + 1, last: now};
    return usage;
}

// Most recently used first, capped at 500.
function serializeUsage(usage) {
    const ids = Object.keys(usage).sort((a, b) => usage[b].last - usage[a].last).slice(0, MAX_USAGE_ENTRIES);
    const stored = {};
    for (const id of ids)
        stored[id] = {count: usage[id].count, last: usage[id].last};
    return JSON.stringify({version: USAGE_VERSION, usage: stored}, null, 1) + "\n";
}

// Corrupt or foreign data yields an empty map.
function parseUsage(text) {
    const usage = newUsage();
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return usage;
    }
    if (!data || data.version !== USAGE_VERSION || typeof data.usage !== "object" || data.usage === null)
        return usage;
    for (const id of Object.keys(data.usage).slice(0, MAX_USAGE_ENTRIES)) {
        const e = data.usage[id];
        if (e && typeof e.count === "number" && e.count > 0 && typeof e.last === "number")
            usage[id] = {count: Math.min(e.count, 1000000), last: e.last};
    }
    return usage;
}
