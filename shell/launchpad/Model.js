.pragma library

// Apps layout model and paging math (pure, unit-tested).
//
// Layout items (top level, in display order):
//   {t: "app", id}                        one desktop entry
//   {t: "folder", key, name, apps: [id]}  a folder (key is session-local, never persisted)
// Persisted form (apps-layout.json): {version: 1, items: ["app.desktop", {folder, apps}]}.
// All edit functions return a new array and never mutate their input.

const VERSION = 1;

function clone(items) {
    return items.map(it => it.t === "folder" ? {t: "folder", key: it.key, name: it.name, apps: it.apps.slice()} : {t: "app", id: it.id});
}

function nextKey(items) {
    let n = 0;
    for (const it of items) {
        if (it.t === "folder" && /^f\d+$/.test(it.key))
            n = Math.max(n, parseInt(it.key.slice(1), 10));
    }
    return "f" + (n + 1);
}

function serialize(items) {
    const out = items.map(it => it.t === "folder" ? {folder: it.name, apps: it.apps.slice()} : it.id);
    return JSON.stringify({version: VERSION, items: out}, null, 1) + "\n";
}

// Corrupt or foreign data yields an empty layout (every app is then appended by name).
function parse(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!data || data.version !== VERSION || !Array.isArray(data.items))
        return [];
    const items = [];
    let k = 0;
    for (const raw of data.items.slice(0, 5000)) {
        if (typeof raw === "string" && raw !== "") {
            items.push({t: "app", id: raw});
        } else if (raw && typeof raw === "object" && typeof raw.folder === "string" && Array.isArray(raw.apps)) {
            const apps = raw.apps.filter(a => typeof a === "string" && a !== "").slice(0, 500);
            items.push({t: "folder", key: "f" + (++k), name: raw.folder.slice(0, 120), apps: apps});
        }
    }
    return items;
}

// Prune apps that are not installed (or duplicated), drop empty folders, append new apps by name.
// `installed`: [{id, name}].
function reconcile(items, installed) {
    const known = {};
    for (const a of installed)
        known[a.id] = true;
    const seen = {};
    const out = [];
    for (const it of items) {
        if (it.t === "app") {
            if (known[it.id] === true && seen[it.id] !== true) {
                seen[it.id] = true;
                out.push({t: "app", id: it.id});
            }
        } else {
            const apps = [];
            for (const id of it.apps) {
                if (known[id] === true && seen[id] !== true) {
                    seen[id] = true;
                    apps.push(id);
                }
            }
            if (apps.length > 0)
                out.push({t: "folder", key: it.key, name: it.name, apps: apps});
        }
    }
    const fresh = installed.filter(a => seen[a.id] !== true);
    fresh.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()) || (a.id < b.id ? -1 : 1));
    for (const a of fresh)
        out.push({t: "app", id: a.id});
    return out;
}

// Move the item at `from` so that it ends up at index `to` of the result.
function moveTo(items, from, to) {
    if (from < 0 || from >= items.length || to < 0 || to >= items.length || from === to)
        return clone(items);
    const out = clone(items);
    const [it] = out.splice(from, 1);
    out.splice(to, 0, it);
    return out;
}

// Drop app `src` onto app `dst`: a folder replaces `dst` and holds [dst, src].
function createFolder(items, src, dst, name) {
    if (src === dst || src < 0 || dst < 0 || src >= items.length || dst >= items.length)
        return clone(items);
    if (items[src].t !== "app" || items[dst].t !== "app")
        return clone(items);
    const out = clone(items);
    const folder = {t: "folder", key: nextKey(out), name: name, apps: [out[dst].id, out[src].id]};
    out[dst] = folder;
    out.splice(src, 1);
    return out;
}

// Drop app `src` onto folder `dst`.
function addToFolder(items, src, dst) {
    if (src === dst || src < 0 || dst < 0 || src >= items.length || dst >= items.length)
        return clone(items);
    if (items[src].t !== "app" || items[dst].t !== "folder")
        return clone(items);
    const out = clone(items);
    out[dst].apps.push(out[src].id);
    out.splice(src, 1);
    return out;
}

// Take an app out of a folder and place it right after the folder; an empty folder disappears.
function removeFromFolder(items, key, id) {
    const out = clone(items);
    const fi = out.findIndex(it => it.t === "folder" && it.key === key);
    if (fi < 0)
        return out;
    const f = out[fi];
    const ai = f.apps.indexOf(id);
    if (ai < 0)
        return out;
    f.apps.splice(ai, 1);
    out.splice(fi + 1, 0, {t: "app", id: id});
    if (f.apps.length === 0)
        out.splice(fi, 1);
    return out;
}

function renameFolder(items, key, name) {
    const out = clone(items);
    for (const it of out) {
        if (it.t === "folder" && it.key === key)
            it.name = name.trim().slice(0, 120);
    }
    return out;
}

// ---- paging math ---------------------------------------------------------------------

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// Grid for a screen. o: {iconSize (at 1080p), widthFraction, heightFraction, cellWidthScale,
// cellHeightScale, minCols, maxCols, minRows, maxRows}. Returns {cols, rows, perPage, cellW, cellH,
// gridW, gridH, icon}.
function grid(width, height, o) {
    const icon = Math.round(o.iconSize * clamp(height / 1080, 0.7, 1.6));
    const gridW = width * o.widthFraction;
    const gridH = height * o.heightFraction;
    const cols = clamp(Math.floor(gridW / (icon * o.cellWidthScale)), o.minCols, o.maxCols);
    const rows = clamp(Math.floor(gridH / (icon * o.cellHeightScale)), o.minRows, o.maxRows);
    return {cols: cols, rows: rows, perPage: cols * rows, cellW: gridW / cols, cellH: gridH / rows, gridW: gridW, gridH: gridH, icon: icon};
}

function pageCount(n, perPage) {
    return Math.max(1, Math.ceil(n / Math.max(1, perPage)));
}

function pageOf(index, perPage) {
    return index < 0 ? 0 : Math.floor(index / Math.max(1, perPage));
}

function clampPage(page, n, perPage) {
    return clamp(page, 0, pageCount(n, perPage) - 1);
}

// Global item index under a point of the grid area on `page`, or -1 outside the grid or past the
// last item. `center` reports whether the point is inside the central `mergeFraction` of the cell.
function cellAt(x, y, g, page, n, mergeFraction) {
    if (x < 0 || y < 0 || x >= g.gridW || y >= g.gridH)
        return {index: -1, center: false};
    const c = Math.floor(x / g.cellW);
    const r = Math.floor(y / g.cellH);
    const index = page * g.perPage + r * g.cols + c;
    if (index >= n)
        return {index: -1, center: false};
    const fx = (x - c * g.cellW) / g.cellW;
    const fy = (y - r * g.cellH) / g.cellH;
    const m = (1 - mergeFraction) / 2;
    return {index: index, center: fx >= m && fx <= 1 - m && fy >= m && fy <= 1 - m};
}

// Keyboard selection. Left/Right walk the reading order across page edges; Up/Down stay in the
// column (no-op at the first/last row of the page); Home/End jump. Returns the new index.
function step(sel, key, cols, perPage, n) {
    if (n <= 0)
        return -1;
    if (sel < 0)
        return 0;
    const pos = sel % perPage;
    switch (key) {
    case "left":
        return Math.max(0, sel - 1);
    case "right":
        return Math.min(n - 1, sel + 1);
    case "up":
        return pos >= cols ? sel - cols : sel;
    case "down":
        if (pos + cols >= perPage)
            return sel;
        return Math.min(n - 1, sel + cols);
    case "home":
        return 0;
    case "end":
        return n - 1;
    }
    return sel;
}

// Set of hidden desktop entry ids from the output of hidden-entries.sh. Ids are normalized like
// Quickshell's DesktopEntry.id (no ".desktop" suffix, no CR) so a lookup by entry id matches.
function parseHidden(text) {
    const set = {};
    for (const line of String(text).split("\n")) {
        const id = line.replace(/\r$/, "").replace(/\.desktop$/, "");
        if (id !== "")
            set[id] = true;
    }
    return set;
}

function isHidden(set, id) {
    return set[String(id).replace(/\.desktop$/, "")] === true;
}
