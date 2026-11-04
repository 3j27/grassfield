.pragma library
.import "../platform/Minimized.js" as Minimized

// Emoji & Symbols (ADR-0045 OC-3, docs/specs/clipboard.md "Emoji & Symbols"): the panel's decisions. Pure functions, unit-tested
// (tests/unit/tst_emoji.qml); shell/services/Emoji.qml and shell/overlay/EmojiPanel.qml run them.
//
// The data is Omarchy's own list, $OMARCHY_PATH/shell/plugins/emojis/emojis.json (MIT; read at run time, never copied): an
// array of {e: the emoji, k: its English keywords} in Unicode's order. It names no groups, so the categories come from the
// first emoji of each CLDR group (GROUPS); a file whose first emoji are not where they belong gets one "All" group, nothing
// guessed.

// The first emoji of each CLDR group in Unicode's order, and the panel category it belongs to (Smileys & Emotion and People &
// Body are macOS's one Smileys & People). Checked on Omarchy v4.0.6's file: indices 0, 166, 529, 681, 814, 1032, 1117, 1378,
// 1601 of 1870.
const GROUPS = [
    {group: "Smileys & Emotion", first: String.fromCodePoint(0x1F600), category: "smileys"},     // grinning face
    {group: "People & Body", first: String.fromCodePoint(0x1F44B), category: "smileys"},         // waving hand
    {group: "Animals & Nature", first: String.fromCodePoint(0x1F435), category: "animals"},      // monkey face
    {group: "Food & Drink", first: String.fromCodePoint(0x1F347), category: "food"},             // grapes
    {group: "Travel & Places", first: String.fromCodePoint(0x1F30D), category: "travel"},        // globe showing Europe-Africa
    {group: "Activities", first: String.fromCodePoint(0x1F383), category: "activity"},           // jack-o-lantern
    {group: "Objects", first: String.fromCodePoint(0x1F453), category: "objects"},               // glasses
    {group: "Symbols", first: String.fromCodePoint(0x1F3E7), category: "symbols"},               // ATM sign
    {group: "Flags", first: String.fromCodePoint(0x1F3C1), category: "flags"}                    // chequered flag
];

// The sections in macOS's order (its category bar): Recently Used first, Activity before Travel & Places (Unicode has them the
// other way round); "all" stands for the whole list when the groups are unknown.
const ORDER = ["recents", "smileys", "animals", "food", "activity", "travel", "objects", "symbols", "flags", "all"];

// The glyph of each section in the category bar (branding/icons/symbolic).
const ICONS = {
    recents: "clock",
    smileys: "face-smiling",
    animals: "paw",
    food: "cup",
    activity: "ball",
    travel: "car",
    objects: "lightbulb",
    symbols: "number-sign",
    flags: "flag",
    all: "grid"
};

// Recently Used holds this many, newest first (ADR-0045 OC-3).
const RECENTS_MAX = 30;
// Bounds on what the data file may hold: an entry's glyph (the longest of Omarchy's, a subdivision flag, is 14 UTF-16 units; a
// family of four with a skin tone each, 19), its keywords (Omarchy's longest has 90 characters), and the number of entries
// (Omarchy's has 1870).
const GLYPH_MAX = 48;
const KEYWORDS_MAX = 512;
const ENTRIES_MAX = 8000;
// The insertion waits for the window that was active when the panel opened to be active again (FocusReturn gives it the
// keyboard back), checking every INSERT_POLL_MS, for at most INSERT_WAIT_MS (as a clipboard paste does, ADR-0034 §4).
const INSERT_WAIT_MS = 1000;
const INSERT_POLL_MS = 50;

// A glyph the panel may show and insert: a non-empty string of at most GLYPH_MAX UTF-16 units, without a control, a line or
// paragraph separator or a bidi control (the joiner, the variation selectors, the keycap mark and the tag characters of the
// subdivision flags are part of emoji and allowed). It is drawn as plain text and handed to the insertion as one argument.
function isGlyph(s) {
    if (typeof s !== "string" || s.length === 0 || s.length > GLYPH_MAX)
        return false;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 0x20 || (c >= 0x7f && c <= 0x9f) || c === 0x061c || c === 0x200e || c === 0x200f || (c >= 0x2028 && c <= 0x202e)
                || (c >= 0x2066 && c <= 0x2069))
            return false;
    }
    return true;
}

// The entries of emojis.json, [{e, k, f, w}], in its order: entries that are not objects, glyphs refused by isGlyph and repeated
// glyphs are dropped, keywords are cut at KEYWORDS_MAX, at most ENTRIES_MAX entries; `f` and `w` are the keywords folded and their
// words, computed once for search(). [] for anything that is not a JSON array.
function parse(text) {
    let data;
    try {
        data = JSON.parse(String(text));
    } catch (e) {
        return [];
    }
    if (!Array.isArray(data))
        return [];
    const out = [];
    const seen = new Set();
    for (const item of data) {
        if (out.length >= ENTRIES_MAX)
            break;
        if (!item || typeof item !== "object" || !isGlyph(item.e) || seen.has(item.e))
            continue;
        seen.add(item.e);
        const k = typeof item.k === "string" ? item.k.slice(0, KEYWORDS_MAX) : "";
        const f = fold(k);
        out.push({e: item.e, k: k, f: f, w: words(f)});
    }
    return out;
}

// The glyph without its emoji presentation selector (U+FE0F): a file that writes it or not still finds its group's first emoji.
function bare(s) {
    return String(s).replace(/\uFE0F/g, "");
}

// The categories of `list` (parse's entries): [{id, start, end}] in the list's order, `end` excluded; Smileys & Emotion and People
// & Body are one "smileys" category. One {id: "all"} when a group's first emoji is missing, the first ones are out of order, or
// the list does not begin with the first group's; [] for an empty list.
function categories(list) {
    const n = (list || []).length;
    if (n === 0)
        return [];
    const index = new Map();
    list.forEach((item, i) => {
        const key = bare(item.e);
        if (!index.has(key))
            index.set(key, i);
    });
    const starts = GROUPS.map(g => index.get(bare(g.first)));
    const ordered = starts[0] === 0 && starts.every((s, i) => s !== undefined && (i === 0 || s > starts[i - 1]));
    if (!ordered)
        return [{id: "all", start: 0, end: n}];
    const out = [];
    GROUPS.forEach((g, i) => {
        const end = i + 1 < GROUPS.length ? starts[i + 1] : n;
        const last = out.length > 0 ? out[out.length - 1] : null;
        if (last && last.id === g.category)
            last.end = end;
        else
            out.push({id: g.category, start: starts[i], end: end});
    });
    return out;
}

// The sections the panel shows with an empty search, in macOS's order: Recently Used (the recents that are still in the list,
// none when there is none), then each category. `titles` maps a section id to its (translated) title.
// [{id, title, items: [glyph]}]
function sections(list, cats, recents, titles) {
    const out = [];
    const known = new Set((list || []).map(item => item.e));
    const recent = (recents || []).filter(e => known.has(e));
    const names = titles || {};
    if (recent.length > 0)
        out.push({id: "recents", title: names.recents || "", items: recent});
    const ordered = (cats || []).slice().sort((a, b) => ORDER.indexOf(a.id) - ORDER.indexOf(b.id));
    for (const c of ordered)
        out.push({id: c.id, title: names[c.id] || "", items: list.slice(c.start, c.end).map(item => item.e)});
    return out;
}

// The folded form every comparison uses (as Search's Ranking.norm, GF-104): lower case, the accents dropped, so "activites"
// finds "Activités".
function fold(s) {
    const low = String(s === undefined || s === null ? "" : s).toLowerCase();
    return /[^\u0000-\u007f]/.test(low) ? low.normalize("NFD").replace(/[\u0300-\u036f]/g, "").normalize("NFC") : low;
}

// The words of a folded text: Omarchy's keywords join words with spaces, underscores, hyphens and colons ("sweat_smile",
// "jack-o-lantern", "flag: wales").
function words(folded) {
    return folded.split(/[\s_\-:;,.()'"!?&/]+/).filter(w => w !== "");
}

// How a query word `q` (folded) matches a text (its folded form and its words): 3 a whole word, 2 the beginning of a word, 1
// anywhere inside, 0 not at all.
function level(q, folded, list) {
    if (list.indexOf(q) >= 0)
        return 3;
    if (list.some(w => w.startsWith(q)))
        return 2;
    return folded.indexOf(q) >= 0 ? 1 : 0;
}

// The glyphs that match `query`, best first (ties keep the list's order): every word of the query must match the entry's English
// keywords or the (translated) title of its category, as a whole word, the beginning of a word or anywhere inside. A keyword
// match counts more than a category match: in French "animaux" finds Animals & Nature, "chat" only what Omarchy's English
// keywords hold. `cats` are categories()'s, in the list's order. [] for an empty query.
function search(list, cats, query, titles) {
    const terms = words(fold(query));
    if (terms.length === 0)
        return [];
    const names = titles || {};
    // How each query word matches each category's title, once per search, not once per entry.
    const catLevels = (cats || []).map(c => {
        const folded = fold(names[c.id] || "");
        const titleWords = words(folded);
        return {start: c.start, end: c.end, levels: terms.map(q => level(q, folded, titleWords))};
    });
    const hits = [];
    const entries = list || [];
    let ci = 0;
    for (let i = 0; i < entries.length; i++) {
        const item = entries[i];
        while (ci < catLevels.length && i >= catLevels[ci].end)
            ci++;
        const cat = ci < catLevels.length && i >= catLevels[ci].start ? catLevels[ci] : null;
        const folded = item.f !== undefined ? item.f : fold(item.k);
        const kw = item.w !== undefined ? item.w : words(folded);
        let score = 0;
        for (let t = 0; t < terms.length; t++) {
            const k = level(terms[t], folded, kw);
            const s = k > 0 ? k + 1 : (cat ? cat.levels[t] : 0) / 2;
            if (s === 0) {
                score = 0;
                break;
            }
            score += s;
        }
        if (score > 0)
            hits.push({e: item.e, score: score, index: i});
    }
    hits.sort((a, b) => b.score - a.score || a.index - b.index);
    return hits.map(h => h.e);
}

// ---- Recently Used: ~/.local/state/grassfield/emoji-recents.json, {"v": 1, "recents": [glyph, ...]} -----------------------

function parseRecents(text) {
    let data;
    try {
        data = JSON.parse(String(text));
    } catch (e) {
        return [];
    }
    if (!data || typeof data !== "object" || !Array.isArray(data.recents))
        return [];
    const out = [];
    for (const e of data.recents) {
        if (out.length >= RECENTS_MAX)
            break;
        if (isGlyph(e) && out.indexOf(e) < 0)
            out.push(e);
    }
    return out;
}

function serializeRecents(recents) {
    return JSON.stringify({v: 1, recents: (recents || []).slice(0, RECENTS_MAX)});
}

// `emoji` chosen: it goes first, once, and the list keeps RECENTS_MAX at most. A glyph refused by isGlyph changes nothing.
function addRecent(recents, emoji) {
    const list = recents || [];
    if (!isGlyph(emoji))
        return list;
    return [emoji].concat(list.filter(e => e !== emoji)).slice(0, RECENTS_MAX);
}

// ---- The grid -----------------------------------------------------------------------------------------------------------------

// The rows of the grid view: a header row before each section (with `headers`: an empty search shows the section titles, the
// results of a search are one untitled section), then its glyphs `columns` to a row. Each glyph has its index in the whole
// grid (`start` + its column). [{kind: "header", section, title, start} | {kind: "cells", section, start, items}]
function rows(sections, columns, headers) {
    const out = [];
    const step = Math.max(1, columns);
    let flat = 0;
    (sections || []).forEach((sec, s) => {
        if (headers)
            out.push({kind: "header", section: s, title: sec.title, start: flat});
        for (let i = 0; i < sec.items.length; i += step)
            out.push({kind: "cells", section: s, start: flat + i, items: sec.items.slice(i, i + step)});
        flat += sec.items.length;
    });
    return out;
}

// The row of `rows` that holds the glyph `index`, -1 for none.
function rowOf(rowList, index) {
    for (let r = 0; r < rowList.length; r++) {
        const row = rowList[r];
        if (row.kind === "cells" && index >= row.start && index < row.start + row.items.length)
            return r;
    }
    return -1;
}

// The header row of section `section`, else its first row; -1 for none (the category bar scrolls the grid there).
function sectionRow(rowList, section) {
    return rowList.findIndex(row => row.section === section);
}

// The section a row belongs to (its index in `sections`), -1 for none.
function sectionOfRow(rowList, r) {
    return r >= 0 && r < rowList.length ? rowList[r].section : -1;
}

// Where the glyph `index` lies: {section, offset} among sections of `lengths` glyphs; null when outside.
function locate(lengths, index) {
    let base = 0;
    for (let s = 0; s < lengths.length; s++) {
        if (index >= base && index < base + lengths[s])
            return {section: s, offset: index - base, base: base};
        base += lengths[s];
    }
    return null;
}

function baseOf(lengths, section) {
    let base = 0;
    for (let s = 0; s < section; s++)
        base += lengths[s];
    return base;
}

// The next section from `section` in `direction` (+1, -1) that holds glyphs, -1 for none.
function nonEmpty(lengths, section, direction) {
    for (let s = section + direction; s >= 0 && s < lengths.length; s += direction) {
        if (lengths[s] > 0)
            return s;
    }
    return -1;
}

function stepDown(lengths, columns, at) {
    const len = lengths[at.section];
    const column = at.offset % columns;
    const next = at.offset - column + columns;
    if (next < len)
        return at.base + Math.min(next + column, len - 1);
    const s = nonEmpty(lengths, at.section, 1);
    if (s < 0)
        return at.base + at.offset;
    return baseOf(lengths, s) + Math.min(column, Math.min(columns, lengths[s]) - 1);
}

function stepUp(lengths, columns, at) {
    const column = at.offset % columns;
    const rowStart = at.offset - column;
    if (rowStart > 0)
        return at.base + rowStart - columns + column;
    const s = nonEmpty(lengths, at.section, -1);
    if (s < 0)
        return at.base + at.offset;
    const len = lengths[s];
    const lastRow = Math.floor((len - 1) / columns) * columns;
    return baseOf(lengths, s) + Math.min(lastRow + column, len - 1);
}

// The glyph a key moves the keyboard selection to, in a grid of sections of `lengths` glyphs laid `columns` to a row (each
// section starts a row): "left" and "right" go through the glyphs in reading order, "up" and "down" to the same column in the
// row above or below (the last glyph of a shorter row; across sections), "pageUp" and "pageDown" `pageRows` rows, "home" and
// "end" the first and the last glyph, "next" and "previous" (Tab, Shift-Tab) the first glyph of the next or the previous
// section. With no selection (-1) any key selects the first glyph ("end" the last). -1 when the grid is empty.
function move(lengths, columns, current, key, pageRows) {
    const total = lengths.reduce((a, b) => a + b, 0);
    if (total === 0)
        return -1;
    const cols = Math.max(1, columns);
    const at = current >= 0 ? locate(lengths, current) : null;
    if (!at)
        return key === "end" ? total - 1 : 0;
    switch (key) {
    case "left":
        return Math.max(0, current - 1);
    case "right":
        return Math.min(total - 1, current + 1);
    case "down":
        return stepDown(lengths, cols, at);
    case "up":
        return stepUp(lengths, cols, at);
    case "pageDown":
    case "pageUp": {
        let i = current;
        for (let n = 0; n < Math.max(1, pageRows); n++) {
            const here = locate(lengths, i);
            const next = key === "pageDown" ? stepDown(lengths, cols, here) : stepUp(lengths, cols, here);
            if (next === i)
                break;
            i = next;
        }
        return i;
    }
    case "home":
        return 0;
    case "end":
        return total - 1;
    case "next": {
        const s = nonEmpty(lengths, at.section, 1);
        return s < 0 ? current : baseOf(lengths, s);
    }
    case "previous": {
        if (at.offset > 0)
            return at.base;
        const s = nonEmpty(lengths, at.section, -1);
        return s < 0 ? current : baseOf(lengths, s);
    }
    }
    return current;
}

// Qt.Key_* values (a .pragma library sees no QML enums).
const KEY = {
    tab: 0x01000001,
    backtab: 0x01000002,
    left: 0x01000012,
    up: 0x01000013,
    right: 0x01000014,
    down: 0x01000015,
    pageUp: 0x01000016,
    pageDown: 0x01000017
};

// The key name move() takes for a Qt key (`shift`: Shift is held; some injectors deliver Shift+Tab as Tab with Shift), "" for a
// key the grid does not use.
function keyName(key, shift) {
    switch (key) {
    case KEY.left:
        return "left";
    case KEY.right:
        return "right";
    case KEY.up:
        return "up";
    case KEY.down:
        return "down";
    case KEY.pageUp:
        return "pageUp";
    case KEY.pageDown:
        return "pageDown";
    case KEY.tab:
        return shift ? "previous" : "next";
    case KEY.backtab:
        return "previous";
    }
    return "";
}

// ---- Where the panel opens --------------------------------------------------------------------------------------------------

// {x, y} of `hyprctl cursorpos -j` (the pointer in layout coordinates), null for anything else.
function cursorPosition(text) {
    let v = null;
    try {
        v = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    return v && Number.isFinite(v.x) && Number.isFinite(v.y) ? {x: v.x, y: v.y} : null;
}

// The output under the pointer and the pointer in that output's coordinates, {name, x, y}; null when no output of `screens`
// ({name, x, y, width, height} in layout coordinates) holds it.
function pointerOn(screens, x, y) {
    for (const s of screens || []) {
        if (s && x >= s.x && y >= s.y && x < s.x + s.width && y < s.y + s.height)
            return {name: s.name, x: x - s.x, y: y - s.y};
    }
    return null;
}

// ---- Insertion --------------------------------------------------------------------------------------------------------------

// The window address as the service keeps it: lower-case hex without 0x, "" when invalid.
function addressHex(address) {
    return Minimized.normalizeAddress(address || "");
}

// One check of an insertion waiting for its window (every INSERT_POLL_MS once the panel closed, and at the deadline): "send",
// "wait", or why it is dropped. s: {locked, rememberedAddress, activeAddress, closedSinceOpen, otherSurfaceOpen, expired}.
// The panel has closed and released the keyboard, so a full-attention surface open at a check opened after the choice.
function insertStep(s) {
    if (!s || s.locked !== false)
        return "locked";
    const want = addressHex(s.rememberedAddress);
    if (want === "")
        return "no window";
    if (s.closedSinceOpen !== false)
        return "the window closed";
    if (s.otherSurfaceOpen !== false)
        return "another surface opened";
    if (addressHex(s.activeAddress) === want)
        return "send";
    return s.expired !== false ? "the window did not come back" : "wait";
}

// The insertion as an argument vector: `script` (shell/services/emoji-insert.sh) runs Omarchy's omarchy-menu-emoji-insert (found
// in PATH, else at `insert`, $OMARCHY_PATH/bin's), which copies the glyph with `wl-copy --sensitive` (the clipboard history does
// not record it, docs/specs/clipboard.md PV-1) and sends Shift+Insert; without it wtype when it is installed; without either it
// says "missing" (the service writes the journal line). The glyph is an argument, never part of a command line. [] for a glyph
// isGlyph refuses or a glyph that would read as an option.
function insertCommand(emoji, insert, script) {
    if (!isGlyph(emoji) || emoji.startsWith("-"))
        return [];
    return ["sh", String(script), emoji, String(insert || "")];
}

// Omarchy's folder: OMARCHY_PATH when it is an absolute path, else /usr/share/omarchy (its default, config/hypr/grassfield/
// omarchy.lua).
function omarchyPath(env) {
    const p = String(env || "");
    return p.startsWith("/") && p.indexOf("\n") < 0 ? p.replace(/\/+$/, "") || "/" : "/usr/share/omarchy";
}
