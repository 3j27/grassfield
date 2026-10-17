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
    if (span > 2 * query.length + 2)
        return 0;
    const gaps = span - query.length;
    return Math.max(1, 25 - gaps * 2 - first);
}

// True when `query` starts a word of `text`; words are split at whitespace, "-", "_" and ".".
function wordStart(text, query) {
    let i = text.indexOf(query);
    while (i >= 0) {
        if (i === 0)
            return true;
        const c = text.charCodeAt(i - 1);
        if (c === 45 || c === 46 || c === 95 || c === 32 || (c >= 9 && c <= 13) || c === 160)
            return true;
        i = text.indexOf(query, i + 1);
    }
    return false;
}

// Text match score: 100 exact, 80 prefix, 65 word prefix, 50 substring, <=25 fuzzy, 0 none.
function textScore(text, query) {
    if (text === "" || query === "")
        return 0;
    if (text === query)
        return 100;
    const at = text.indexOf(query);
    if (at === 0)
        return 80;
    if (at > 0)
        return wordStart(text, query) ? 65 : 50;
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

// Normalized fields of an app, cached by content (a keystroke ranks every app). Keyed by a string, not by the
// app object: a WeakMap keyed by QObject wrappers (DesktopEntry) crashed the QML engine (V4 sameValueZero,
// review 2026-10-17). The cache is bounded and rebuilt when it grows past MAX_PREPARED.
const MAX_PREPARED = 4000;
let prepared = new Map();

function prepKey(app) {
    // id + name: cheap and changes when a desktop entry is replaced by an updated one.
    return (app.id || "") + "\u0000" + (app.name || "");
}

function prep(app) {
    const key = prepKey(app);
    let p = prepared.get(key);
    if (p === undefined) {
        if (prepared.size >= MAX_PREPARED)
            prepared = new Map();
        p = {
            name: norm(app.name),
            keywords: (app.keywords || []).map(norm),
            generic: norm(app.genericName),
            comment: norm(app.comment)
        };
        prepared.set(key, p);
    }
    return p;
}

// Score for an already normalized, trimmed, non-empty query.
function scoreNormalized(app, query, usage) {
    const p = prep(app);
    let s = textScore(p.name, query);
    let kw = 0;
    for (const k of p.keywords)
        kw = Math.max(kw, textScore(k, query) * 0.45);
    s = Math.max(s, kw);
    s = Math.max(s, textScore(p.generic, query) * 0.4);
    if (p.comment.length > 0 && query.length >= 3 && p.comment.indexOf(query) >= 0)
        s = Math.max(s, 15);
    if (s <= 0)
        return 0;
    return s + usageBoost(usageFor(usage, app.id));
}

// Score of one app for a (trimmed) query; 0 = no match. The usage boost only applies to matches.
function score(app, rawQuery, usage) {
    const query = norm(rawQuery).trim();
    if (query === "")
        return 0;
    return scoreNormalized(app, query, usage);
}

// Sorted matches [{app, score}], best first; ties by name. `limit` caps the list.
function rank(apps, query, usage, limit) {
    const out = [];
    const q = norm(query).trim();
    if (q === "")
        return out;
    for (const app of apps) {
        const s = scoreNormalized(app, q, usage);
        if (s > 0)
            out.push({app: app, score: s, name: prep(app).name});
    }
    // Ties by normalized name in code unit order (localeCompare costs several ms per sort).
    out.sort((a, b) => b.score - a.score || (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)));
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
