.pragma library
.import "Registry.js" as Registry

// Widget placements (pure logic): the persisted state, grid snapping and collision handling.
// State: {version: 1, center: [{uid, id, size}], desktop: [{uid, id, size, screen, col, row}]}.
// Every function returns a new state; the input is never modified.

const VERSION = 1;

function empty() {
    return {version: VERSION, center: [], desktop: []};
}

function clone(state) {
    return JSON.parse(JSON.stringify(state));
}

// Footprint in grid cells.
function cells(size) {
    switch (size) {
    case "medium":
        return {w: 2, h: 1};
    case "large":
        return {w: 2, h: 2};
    }
    return {w: 1, h: 1};
}

// Footprint in px for a cell edge and gap.
function px(size, cell, gap) {
    const c = cells(size);
    return {w: c.w * cell + (c.w - 1) * gap, h: c.h * cell + (c.h - 1) * gap};
}

function validSize(id, size) {
    const m = Registry.find(id);
    return m !== null && m.sizes.indexOf(size) >= 0;
}

function isUid(value) {
    return typeof value === "string" && /^[a-z0-9]+-[0-9]+$/.test(value);
}

function nextUid(state, id) {
    const used = {};
    state.center.concat(state.desktop).forEach(e => used[e.uid] = true);
    let n = 1;
    while (used[id + "-" + n])
        n++;
    return id + "-" + n;
}

function toInt(value, fallback) {
    const n = Number(value);
    return isFinite(n) ? Math.max(0, Math.min(1000, Math.round(n))) : fallback;
}

// Limits against a hostile or corrupt widgets.json (mirrored by Tokens.widgetMaxEntries and
// Tokens.widgetMaxFileBytes, which the callers may override).
const MAX_ENTRIES = 64;
const MAX_BYTES = 262144;

// Text of widgets.json to a valid state. Unknown ids, sizes the widget does not offer and
// malformed entries are dropped; at most `maxEntries` entries are kept per list (the rest is
// ignored); a text that is larger than `maxBytes` or not a version 1 object gives
// {state: empty, ok: false}. Linear in the number of entries kept.
function parse(text, maxEntries, maxBytes) {
    const cap = maxEntries > 0 ? maxEntries : MAX_ENTRIES;
    if (typeof text !== "string" || text.length > (maxBytes > 0 ? maxBytes : MAX_BYTES))
        return {state: empty(), ok: false};
    let raw;
    try {
        raw = text.trim() === "" ? null : JSON.parse(text);
    } catch (e) {
        return {state: empty(), ok: false};
    }
    if (raw === null)
        return {state: empty(), ok: true};
    if (typeof raw !== "object" || Array.isArray(raw) || raw.version !== VERSION)
        return {state: empty(), ok: false};
    const state = empty();
    const used = {};
    const counters = {};
    const accept = (entry, target) => {
        if (entry === null || typeof entry !== "object" || typeof entry.id !== "string" || !validSize(entry.id, entry.size))
            return null;
        const e = {uid: isUid(entry.uid) && !used[entry.uid] ? entry.uid : "", id: entry.id, size: entry.size};
        if (e.uid === "") {
            let n = counters[e.id] || 1;
            while (used[e.id + "-" + n])
                n++;
            counters[e.id] = n + 1;
            e.uid = e.id + "-" + n;
        }
        used[e.uid] = true;
        target.push(e);
        return e;
    };
    const center = Array.isArray(raw.center) ? raw.center : [];
    for (let i = 0; i < center.length && state.center.length < cap; i++)
        accept(center[i], state.center);
    const desktop = Array.isArray(raw.desktop) ? raw.desktop : [];
    for (let i = 0; i < desktop.length && state.desktop.length < cap; i++) {
        const entry = desktop[i];
        if (entry === null || typeof entry !== "object" || typeof entry.screen !== "string" || entry.screen === "")
            continue;
        const e = accept(entry, state.desktop);
        if (e) {
            e.screen = entry.screen;
            e.col = toInt(entry.col, 0);
            e.row = toInt(entry.row, 0);
        }
    }
    return {state: state, ok: true};
}

function serialize(state) {
    return JSON.stringify(state, null, 2) + "\n";
}

function addCenter(state, id, size) {
    const s = clone(state);
    if (!validSize(id, size) || s.center.length >= MAX_ENTRIES)
        return s;
    s.center.push({uid: nextUid(s, id), id: id, size: size});
    return s;
}

function remove(state, uid) {
    const s = clone(state);
    s.center = s.center.filter(e => e.uid !== uid);
    s.desktop = s.desktop.filter(e => e.uid !== uid);
    return s;
}

// Resizing a desktop widget re-checks collisions through `grid` ({cols, rows}); null skips that.
function setSize(state, uid, size, grid) {
    const s = clone(state);
    const e = s.center.concat(s.desktop).find(x => x.uid === uid);
    if (!e || !validSize(e.id, size))
        return s;
    e.size = size;
    if (e.screen !== undefined && grid) {
        const others = s.desktop.filter(x => x.screen === e.screen && x.uid !== uid);
        const spot = nearestFree(others, size, {col: e.col, row: e.row}, grid.cols, grid.rows);
        if (spot) {
            e.col = spot.col;
            e.row = spot.row;
        }
    }
    return s;
}

function moveCenter(state, uid, toIndex) {
    const s = clone(state);
    const from = s.center.findIndex(e => e.uid === uid);
    if (from < 0)
        return s;
    const item = s.center.splice(from, 1)[0];
    s.center.splice(Math.max(0, Math.min(s.center.length, toIndex)), 0, item);
    return s;
}

// ---- grid -------------------------------------------------------------------------------------

// Column/row count of the grid on a screen of the given size.
function gridSize(width, height, cell, gap, margin) {
    const pitch = cell + gap;
    return {
        cols: Math.max(1, Math.floor((width - 2 * margin + gap) / pitch)),
        rows: Math.max(1, Math.floor((height - 2 * margin + gap) / pitch))
    };
}

// Grid of a screen: the usable area is the screen minus the menu bar on top and the Dock's
// reserved height at the bottom, then `margin` on every side. Returns {cols, rows, x0, y0}
// (origin in screen px).
function gridFor(width, height, cell, gap, margin, top, bottom) {
    const g = gridSize(width, height - top - bottom, cell, gap, margin);
    return {cols: g.cols, rows: g.rows, x0: margin, y0: top + margin};
}

// Nearest grid cell for a top-left position in px relative to the grid origin; clamped so that
// a widget of `size` stays inside cols x rows.
function snap(x, y, size, cell, gap, cols, rows) {
    const pitch = cell + gap;
    const c = cells(size);
    return {
        col: Math.max(0, Math.min(cols - c.w, Math.round(x / pitch))),
        row: Math.max(0, Math.min(rows - c.h, Math.round(y / pitch)))
    };
}

function overlaps(a, sizeA, b, sizeB) {
    const ca = cells(sizeA);
    const cb = cells(sizeB);
    return a.col < b.col + cb.w && b.col < a.col + ca.w && a.row < b.row + cb.h && b.row < a.row + ca.h;
}

function isFree(others, size, spot, cols, rows) {
    const c = cells(size);
    if (spot.col < 0 || spot.row < 0 || spot.col + c.w > cols || spot.row + c.h > rows)
        return false;
    return !others.some(o => overlaps(spot, size, o, o.size));
}

// The free cell closest to `want` (Euclidean in cells; ties go to the top row), or null.
function nearestFree(others, size, want, cols, rows) {
    let best = null;
    let bestD = Infinity;
    for (let row = 0; row < rows; row++) {
        for (let col = 0; col < cols; col++) {
            const spot = {col: col, row: row};
            if (!isFree(others, size, spot, cols, rows))
                continue;
            const d = (col - want.col) * (col - want.col) + (row - want.row) * (row - want.row);
            if (d < bestD) {
                bestD = d;
                best = spot;
            }
        }
    }
    return best;
}

// Add to the desktop of `screen` at the first free cell, scanning columns from the left edge, each from the
// top (widgets start top-left, the desktop icons take the right column: F1 gap 16). Without room the widget
// is not added.
function addDesktop(state, id, size, screen, cols, rows) {
    const s = clone(state);
    if (!validSize(id, size) || screen === "" || s.desktop.length >= MAX_ENTRIES)
        return s;
    const others = s.desktop.filter(e => e.screen === screen);
    const c = cells(size);
    for (let col = 0; col <= cols - c.w; col++) {
        for (let row = 0; row <= rows - c.h; row++) {
            if (isFree(others, size, {col: col, row: row}, cols, rows)) {
                s.desktop.push({uid: nextUid(s, id), id: id, size: size, screen: screen, col: col, row: row});
                return s;
            }
        }
    }
    return s;
}

// Move to the snapped cell, or the nearest free one when it is taken.
function moveDesktop(state, uid, spot, cols, rows) {
    const s = clone(state);
    const e = s.desktop.find(x => x.uid === uid);
    if (!e)
        return s;
    const others = s.desktop.filter(x => x.screen === e.screen && x.uid !== uid);
    const target = nearestFree(others, e.size, spot, cols, rows);
    if (target) {
        e.col = target.col;
        e.row = target.row;
    }
    return s;
}

// Re-places the desktop entries of one screen into a cols x rows grid: an entry keeps its cell
// when it fits and is free, else it moves to the nearest free cell (clamped first); an entry that
// finds no room is dropped. Entries of other screens are untouched. Returns {state, changed}.
function fitScreen(state, screen, cols, rows) {
    const s = clone(state);
    const placed = [];
    let changed = false;
    const keep = [];
    s.desktop.forEach(e => {
        if (e.screen !== screen) {
            keep.push(e);
            return;
        }
        const c = cells(e.size);
        const want = {col: Math.min(e.col, Math.max(0, cols - c.w)), row: Math.min(e.row, Math.max(0, rows - c.h))};
        const spot = isFree(placed, e.size, want, cols, rows) ? want : nearestFree(placed, e.size, want, cols, rows);
        if (!spot) {
            changed = true;
            return;
        }
        if (spot.col !== e.col || spot.row !== e.row)
            changed = true;
        e.col = spot.col;
        e.row = spot.row;
        placed.push(e);
        keep.push(e);
    });
    s.desktop = keep;
    return {state: s, changed: changed};
}

// True when a single window {x, y, w, h} contains the whole rectangle {x, y, w, h} (a widget tile
// under it is invisible, so the widget can stop).
function coveredBy(rect, windows) {
    return windows.some(w => w.x <= rect.x && w.y <= rect.y && w.x + w.w >= rect.x + rect.w && w.y + w.h >= rect.y + rect.h);
}
