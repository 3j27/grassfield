.pragma library

// Search ranking (pure, unit-tested). Applications: prefix/word/substring/fuzzy match on the name, keyword, generic name
// and comment matching, and a persisted usage boost. Files (the Documents group, docs/specs/search.md "File ranking"): the same
// text match on the name, then penalties for junk names, generated folders, depth and paths outside the home, a bonus for the
// user's XDG folders, and the usage boost of the files opened from Search. Inspired by Project Luma's luma-search ranking
// (Apache-2.0): the mechanism only, no code copied.
//
// App record: {id, name, genericName, comment, keywords: [string]}.
// Usage map (null prototype): id -> {count, last (ms), weight}. Files use the id "file:" + path.
// `weight` is a frecency: each pick adds 1 to the weight decayed since the last pick (half-life USAGE_HALF_LIFE_DAYS), so an
// app picked a hundred times last year no longer outranks the one picked three times this week.

// Version 1 was {count, last}; version 2 adds the decayed weight (parseUsage migrates 1 to 2: weight = count, capped).
const USAGE_VERSION = 2;
// Apps and files are capped apart, so the files opened from Search never push the apps' history out.
const MAX_USAGE_ENTRIES = 500;
const MAX_FILE_USAGE_ENTRIES = 200;
const FILE_USAGE_PREFIX = "file:";

function isFileUsage(id) {
    return id.startsWith(FILE_USAGE_PREFIX);
}

// The ids to keep, most recent first: at most MAX_USAGE_ENTRIES apps and MAX_FILE_USAGE_ENTRIES files.
function keptIds(ids, lastOf) {
    const sorted = ids.slice().sort((a, b) => lastOf(b) - lastOf(a));
    const apps = sorted.filter(id => !isFileUsage(id)).slice(0, MAX_USAGE_ENTRIES);
    const files = sorted.filter(isFileUsage).slice(0, MAX_FILE_USAGE_ENTRIES);
    return apps.concat(files).sort((a, b) => lastOf(b) - lastOf(a));
}
const USAGE_HALF_LIFE_DAYS = 14;
const USAGE_WEIGHT_CAP = 50;
// The usage boost lifts equal matches apart and a recent favourite over a slightly better match; it never lifts a fuzzy hit
// (<= 25) over a prefix match (80).
const USAGE_BOOST_CAP = 20;
const DAY_MS = 86400000;

// Folded form used for every comparison (GF-104, like Spotlight): NFD with the combining marks dropped, then
// lower case, so "reglages" finds "Réglages" whether the stored name is NFC or NFD. Plain ASCII skips the work.
const COMBINING = /[\u0300-\u036f]/g;
const NON_ASCII = /[^\u0000-\u007f]/;
function norm(s) {
    if (typeof s !== "string")
        return "";
    const low = s.toLowerCase();
    return NON_ASCII.test(low) ? low.normalize("NFD").replace(COMBINING, "").normalize("NFC") : low;
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

// Below this a decayed weight counts as nothing (about 13 half-lives for the capped weight): an old pick no longer even breaks
// ties.
const USAGE_FORGET_WEIGHT = 0.01;

// The weight of an entry at `now`, decayed with a half-life of USAGE_HALF_LIFE_DAYS since its last pick (a clock that went
// back does not inflate it).
function decayedWeight(entry, now) {
    if (!entry || !(entry.weight > 0))
        return 0;
    const age = now - entry.last;
    if (!(age > 0))
        return entry.weight;
    const w = entry.weight * Math.pow(0.5, age / (USAGE_HALF_LIFE_DAYS * DAY_MS));
    return w < USAGE_FORGET_WEIGHT ? 0 : w;
}

// 5 for one pick today, 10 for three, the cap (20) from fifteen; the weight halves every half-life without a pick.
// `now` defaults to the current time.
function usageBoost(entry, now) {
    const w = decayedWeight(entry, now === undefined ? Date.now() : now);
    if (!(w > 0))
        return 0;
    return Math.min(USAGE_BOOST_CAP, Math.log2(1 + w) * 5);
}

function usageFor(usage, id) {
    return usage && id in usage ? usage[id] : null;
}

// 32-bit set of the (hashed) characters of the strings: every query character must occur in a field
// for any match kind (prefix, substring, fuzzy, comment), so a query whose set is not contained in
// the app's set cannot match. Hash collisions only let more apps through to the exact scoring.
function charMask(strings) {
    let m = 0;
    for (const t of strings) {
        for (let i = 0; i < t.length; i++)
            m |= 1 << (t.charCodeAt(i) & 31);
    }
    return m;
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
            comment: norm(app.comment),
            mask: 0
        };
        p.mask = charMask([p.name, p.generic, p.comment].concat(p.keywords));
        prepared.set(key, p);
    }
    return p;
}

// Fills the normalized-field cache for every app and runs the scoring path once, so that the first keystroke
// does not pay for the preparation (idle time or panel opening; the result is discarded).
function warm(apps) {
    for (const app of apps)
        prep(app);
    rank(apps, "a", newUsage(), 1);
}

// Score for an already normalized, trimmed, non-empty query.
function scoreNormalized(app, query, usage, queryMask, now) {
    const p = prep(app);
    if (queryMask !== undefined && (queryMask & ~p.mask) !== 0)
        return 0;
    let s = textScore(p.name, query);
    if (s >= 50)
        // Keywords, generic name and comment score at most 45, 40 and 15.
        return s + usageBoost(usageFor(usage, app.id), now);
    let kw = 0;
    for (const k of p.keywords)
        kw = Math.max(kw, textScore(k, query) * 0.45);
    s = Math.max(s, kw);
    s = Math.max(s, textScore(p.generic, query) * 0.4);
    if (p.comment.length > 0 && query.length >= 3 && p.comment.indexOf(query) >= 0)
        s = Math.max(s, 15);
    if (s <= 0)
        return 0;
    return s + usageBoost(usageFor(usage, app.id), now);
}

// Score of one app for a (trimmed) query; 0 = no match. The usage boost only applies to matches.
function score(app, rawQuery, usage, now) {
    const query = norm(rawQuery).trim();
    if (query === "")
        return 0;
    return scoreNormalized(app, query, usage, undefined, now === undefined ? Date.now() : now);
}

// Sorted matches [{app, score}], best first; ties by name. `limit` caps the list. `now` (ms, default the current time) is the
// time the usage boost decays to.
function rank(apps, query, usage, limit, now) {
    const out = [];
    const q = norm(query).trim();
    if (q === "")
        return out;
    const qm = charMask([q]);
    const t = now === undefined ? Date.now() : now;
    for (const app of apps) {
        const s = scoreNormalized(app, q, usage, qm, t);
        if (s > 0)
            out.push({app: app, score: s, name: prep(app).name});
    }
    // Ties by folded name in code unit order, then by the locale collator for names that fold equal
    // (localeCompare costs several ms per sort, so it only runs on exact ties).
    out.sort((a, b) => b.score - a.score || (a.name < b.name ? -1 : (a.name > b.name ? 1 : (a.app.name || "").localeCompare(b.app.name || ""))));
    return limit > 0 ? out.slice(0, limit) : out;
}

function newUsage() {
    return Object.create(null);
}

// Delete Search History (Settings > Search, search.historyResetAt): the results picked before `at` (milliseconds since the
// epoch) are forgotten, the ones picked later stay. A time that is not a positive number forgets nothing.
function forgetUsageBefore(usage, at) {
    if (typeof at !== "number" || !isFinite(at) || at <= 0)
        return usage;
    const kept = newUsage();
    for (const id of Object.keys(usage)) {
        if (usage[id].last >= at)
            kept[id] = usage[id];
    }
    return kept;
}

// One pick of `id` at `now`: the count goes up by one and the weight becomes the decayed weight plus one (at most
// USAGE_WEIGHT_CAP).
function bumpUsage(usage, id, now) {
    if (typeof id !== "string" || id === "")
        return usage;
    const prev = usageFor(usage, id);
    const weight = Math.min(USAGE_WEIGHT_CAP, decayedWeight(prev, now) + 1);
    usage[id] = {count: (prev ? prev.count : 0) + 1, last: prev && prev.last > now ? prev.last : now, weight: weight};
    return usage;
}

// Most recently used first, at most 500 apps and 200 files.
function serializeUsage(usage) {
    const ids = keptIds(Object.keys(usage), id => usage[id].last);
    const stored = {};
    for (const id of ids)
        stored[id] = {count: usage[id].count, last: usage[id].last, weight: Math.round(usage[id].weight * 10000) / 10000};
    return JSON.stringify({version: USAGE_VERSION, usage: stored}, null, 1) + "\n";
}

// Corrupt or foreign data yields an empty map. Version 1 ({count, last}) is migrated: its weight is its count (capped), which
// then decays from its last pick like any other, so a favourite of version 1 that has not been picked for months weighs
// nothing. A version newer than this one is foreign (read as empty; the next pick writes this version).
function parseUsage(text) {
    const usage = newUsage();
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return usage;
    }
    if (!data || (data.version !== 1 && data.version !== USAGE_VERSION) || typeof data.usage !== "object" || data.usage === null)
        return usage;
    // The file is written most recent first: the first entries of each kind are kept, within its cap.
    let apps = 0;
    let files = 0;
    for (const id of Object.keys(data.usage)) {
        if (apps >= MAX_USAGE_ENTRIES && files >= MAX_FILE_USAGE_ENTRIES)
            break;
        const e = data.usage[id];
        if (!e || typeof e.count !== "number" || !(e.count > 0) || typeof e.last !== "number" || !isFinite(e.last))
            continue;
        if (isFileUsage(id) ? files++ >= MAX_FILE_USAGE_ENTRIES : apps++ >= MAX_USAGE_ENTRIES)
            continue;
        const count = Math.min(e.count, 1000000);
        const w = data.version === USAGE_VERSION && typeof e.weight === "number" && isFinite(e.weight) && e.weight >= 0 ? e.weight : count;
        usage[id] = {count: count, last: e.last, weight: Math.min(USAGE_WEIGHT_CAP, w)};
    }
    return usage;
}

// ---- File ranking (docs/specs/search.md "File ranking") ---------------------------------------------------------------
// One scale with the app scores (100 exact, 80 prefix, 65 word prefix, 50 substring, <=25 fuzzy). Inspired by Project Luma's
// luma-search ranking (Apache-2.0); the weights are Grassfield's own, about a tenth of Luma's scale.

// How many candidates the providers return before the ranking keeps Tokens.searchMaxFiles of them.
const FILE_CANDIDATES = 60;
// A file the provider found by its content (localsearch) whose name does not match the query.
const FILE_CONTENT_SCORE = 10;
const FILE_XDG_SELF = 20;       // the result is one of the user's XDG folders (Documents, Downloads...)
const FILE_XDG_INSIDE = 8;      // the result lies in one of them
const FILE_DEPTH_STEP = 3;      // per folder level below the first one under the home
const FILE_DEPTH_CAP = 18;
const FILE_OUTSIDE_HOME = 12;
const FILE_GENERATED_PATH = 45; // a folder on the way is generated, a cache or hidden (node_modules, build, .git...)
const FILE_JUNK_CAP = 40;

// Folder names (folded) that hold generated files, caches or dependencies. A hidden folder (".x") counts as one too.
const GENERATED_DIRS = new Set(["node_modules", "__pycache__", "cache", "build", "builddir", "_build", "dist", "target", "obj",
    "venv", "site-packages", "vendor", "deps", "cmakefiles", "rpmbuild", "buildroot", "tmp", "temp", "bower_components",
    "__macosx"]);

// Words (folded) that mark a copy, a backup or a leftover, in English and French. A word the query itself touches is not junk
// (a search for "backup" wants the backups).
const JUNK_WORDS = {
    backup: 22, backups: 22, bak: 22, bck: 22, bkp: 22, copy: 22, old: 20, orig: 18, tmp: 22, temp: 20, autosave: 22,
    conflicted: 20, stale: 16, archived: 12, obsolete: 16,
    sauvegarde: 22, sauvegardes: 22, copie: 22, ancien: 18, ancienne: 18, anciens: 18, anciennes: 18, vieux: 16, vieille: 16,
    temporaire: 20, temporaires: 20, conflit: 20, perime: 16
};
const JUNK_EXTENSIONS = new Set(["bak", "old", "orig", "tmp", "swp", "swo", "part", "crdownload", "rej"]);
const EDITOR_BACKUP = 26;
const BACKUP_EXTENSION = 26;
const DUPLICATE_MARK = 20;
// "Report (2)", "Report copy", "Report copy 3", "Report - Copy", "Rapport (copie)", "Rapport - copie 2".
const DUPLICATE_RE = /(\(\d{1,3}\)|[\s_-]\(?(copy|copie)(\s*\d+)?\)?)\s*$/i;
// ASCII whitespace and punctuation separate words (non-ASCII letters stay in their word).
const WORD_SPLIT = /[\s!-\/:-@\[-`{-~]+/;

// The stem and the extension of a file name ("a.tar.gz" -> "a.tar", "gz"; ".x" and "x." have none; an "extension" longer
// than 10 characters is part of the name).
function splitExtension(name) {
    const dot = name.lastIndexOf(".");
    if (dot <= 0 || dot === name.length - 1 || name.length - dot > 11)
        return {stem: name, ext: ""};
    return {stem: name.slice(0, dot), ext: name.slice(dot + 1)};
}

// The folded words of a name: camelCase and letter/digit boundaries split too ("oldReport2" -> old, report, 2).
function nameWords(name) {
    const spaced = name.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/([A-Za-z])(\d)/g, "$1 $2").replace(/(\d)([A-Za-z])/g, "$1 $2");
    return norm(spaced).split(WORD_SPLIT).filter(w => w !== "");
}

function touches(word, terms) {
    for (const t of terms) {
        if (word.startsWith(t) || t.startsWith(word) || (t.length >= 3 && word.indexOf(t) >= 0))
            return true;
    }
    return false;
}

// Penalty (0..FILE_JUNK_CAP) and its reasons for a junk-looking file name; `terms` are the folded query words.
function junkPenalty(name, terms) {
    const parts = splitExtension(name);
    const reasons = [];
    let p = 0;
    if (name.endsWith("~") || /^#.*#$/.test(name)) {
        p += EDITOR_BACKUP;
        reasons.push("editor-backup");
    }
    const ext = norm(parts.ext);
    if (ext !== "" && JUNK_EXTENSIONS.has(ext) && !touches(ext, terms)) {
        p += BACKUP_EXTENSION;
        reasons.push("backup-extension");
    }
    if (DUPLICATE_RE.test(parts.stem)) {
        p += DUPLICATE_MARK;
        reasons.push("duplicate");
    }
    for (const w of nameWords(parts.stem)) {
        if (Object.prototype.hasOwnProperty.call(JUNK_WORDS, w) && !touches(w, terms)) {
            p += JUNK_WORDS[w];
            reasons.push("word:" + w);
            break;
        }
    }
    return {penalty: Math.min(p, FILE_JUNK_CAP), reasons: reasons};
}

function pathParts(path) {
    return typeof path === "string" ? path.split("/").filter(s => s !== "") : [];
}

// Location adjustment (<= 0) and its reasons: depth below the home, a path outside the home, a generated or hidden folder on
// the way.
function locationAdjustment(path, home) {
    const parts = pathParts(path);
    const homeParts = pathParts(home);
    let inHome = homeParts.length > 0 && parts.length > homeParts.length;
    for (let i = 0; inHome && i < homeParts.length; i++)
        inHome = parts[i] === homeParts[i];
    const rel = inHome ? parts.slice(homeParts.length) : parts;
    const reasons = [];
    let adj = 0;
    if (inHome) {
        // ~/Documents/a.txt (2 levels) is free; every level below costs FILE_DEPTH_STEP.
        const d = Math.min(FILE_DEPTH_CAP, FILE_DEPTH_STEP * Math.max(0, rel.length - 2));
        if (d > 0) {
            adj -= d;
            reasons.push("depth:" + rel.length);
        }
    } else {
        adj -= FILE_OUTSIDE_HOME;
        reasons.push("outside-home");
    }
    // The folders on the way only: the result itself is what was asked for (a folder named "build" answers "build").
    for (let i = 0; i < rel.length - 1; i++) {
        if (rel[i].startsWith(".") || GENERATED_DIRS.has(norm(rel[i]))) {
            adj -= FILE_GENERATED_PATH;
            reasons.push("generated-path");
            break;
        }
    }
    return {adjustment: adj, reasons: reasons};
}

// Bonus for the user's XDG folders (`xdgDirs`: canonical absolute paths, Files.parseUserDirs).
function xdgBonus(path, xdgDirs) {
    let best = 0;
    for (const d of xdgDirs || []) {
        if (path === d)
            return FILE_XDG_SELF;
        if (path.startsWith(d + "/"))
            best = FILE_XDG_INSIDE;
    }
    return best;
}

// Text score of a file name for the folded query `q` (its words `terms`): the best of the whole name and the name without
// its extension; a query of several words matches when every word does (0.8 of the weakest word); FILE_CONTENT_SCORE when
// the name does not match at all (the provider found the file by its content).
function fileTextScore(name, q, terms) {
    const folded = norm(name);
    const stem = norm(splitExtension(name).stem);
    let s = Math.max(textScore(folded, q), textScore(stem, q));
    if (s === 0 && terms.length > 1) {
        let weakest = 100;
        for (const t of terms)
            weakest = Math.min(weakest, textScore(folded, t));
        s = weakest * 0.8;
    }
    return s > 0 ? s : FILE_CONTENT_SCORE;
}

function queryTerms(q) {
    return q.split(/\s+/).filter(t => t !== "");
}

// Score of one path: {score, reasons}. `q` is the folded, trimmed query; `ctx` {home, xdgDirs, usage, now}.
function scoreFileNormalized(path, q, terms, ctx) {
    const slash = path.lastIndexOf("/");
    const name = slash >= 0 ? path.slice(slash + 1) : path;
    const text = fileTextScore(name, q, terms);
    const loc = locationAdjustment(path, ctx.home);
    const junk = junkPenalty(name, terms);
    const xdg = xdgBonus(path, ctx.xdgDirs);
    const usage = usageBoost(usageFor(ctx.usage, "file:" + path), ctx.now);
    const reasons = ["text:" + text].concat(loc.reasons, junk.reasons);
    if (xdg > 0)
        reasons.push("xdg:" + xdg);
    if (usage > 0)
        reasons.push("usage:" + Math.round(usage));
    return {score: text + loc.adjustment - junk.penalty + xdg + usage, reasons: reasons};
}

function scoreFile(path, rawQuery, ctx) {
    const q = norm(rawQuery).trim();
    const c = Object.assign({home: "", xdgDirs: [], usage: null, now: Date.now()}, ctx || {});
    return scoreFileNormalized(path, q, queryTerms(q), c);
}

// The paths, best first (ties: the shorter path, then code unit order), repeats dropped, at most `limit` (all when 0).
// `ctx`: {home, xdgDirs: [path], usage, now (ms)}.
function rankFiles(paths, rawQuery, ctx, limit) {
    const q = norm(rawQuery).trim();
    const terms = queryTerms(q);
    const c = Object.assign({home: "", xdgDirs: [], usage: null, now: Date.now()}, ctx || {});
    const seen = new Set();
    const scored = [];
    for (const p of paths || []) {
        if (typeof p !== "string" || p === "" || seen.has(p))
            continue;
        seen.add(p);
        scored.push({path: p, score: scoreFileNormalized(p, q, terms, c).score});
    }
    scored.sort((a, b) => b.score - a.score || a.path.length - b.path.length || (a.path < b.path ? -1 : (a.path > b.path ? 1 : 0)));
    const out = scored.map(s => s.path);
    return limit > 0 ? out.slice(0, limit) : out;
}
