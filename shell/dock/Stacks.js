.pragma library

// Dock folder stacks (macOS: a folder kept in the right section of the Dock, e.g. Downloads, opens as a Fan, a Grid or a
// List). Pure functions, tested in tests/unit/tst_dockstacks.qml. Spec: docs/specs/dock.md requirement 25.
//
// Settings: `dock.folders` (paths, "~/" allowed), `dock.stackOptions` ({path: {sort, view, display}}).

var SORTS = ["name", "dateAdded", "dateModified", "dateCreated", "kind"];
var VIEWS = ["automatic", "fan", "grid", "list"];
var DISPLAYS = ["stack", "folder"];

var DEFAULTS = {sort: "dateAdded", view: "automatic", display: "stack"};

function pick(value, allowed, fallback) {
    return typeof value === "string" && allowed.indexOf(value) >= 0 ? value : fallback;
}

function normalizeSort(value) {
    return pick(value, SORTS, DEFAULTS.sort);
}

function normalizeView(value) {
    return pick(value, VIEWS, DEFAULTS.view);
}

function normalizeDisplay(value) {
    return pick(value, DISPLAYS, DEFAULTS.display);
}

// "~" and "~/x" read against `home`; anything else is returned as it is.
function expandHome(path, home) {
    const p = String(path);
    if (p === "~")
        return home;
    return p.startsWith("~/") ? home + p.substring(1) : p;
}

// "/a/b/" and "/a//b" read as "/a/b"; the root stays "/".
function cleanPath(path) {
    const parts = String(path).split("/").filter(s => s !== "" && s !== ".");
    return "/" + parts.join("/");
}

// The folders of the Dock as absolute, clean, distinct paths in their order (a stored value is untrusted): non-strings,
// relative paths and "..", and the root itself are dropped; at most `max`.
function folderList(list, home, max) {
    const out = [];
    const n = list && typeof list.length === "number" ? list.length : 0;
    for (let i = 0; i < n; i++) {
        if (typeof list[i] !== "string" || list[i] === "")
            continue;
        const full = expandHome(list[i], home);
        if (!full.startsWith("/") || full.split("/").indexOf("..") >= 0)
            continue;
        const clean = cleanPath(full);
        if (clean === "/" || out.indexOf(clean) >= 0)
            continue;
        out.push(clean);
        if (out.length >= max)
            break;
    }
    return out;
}

// Options of one folder: its stored entry, each field validated, the macOS defaults for what is missing.
function optionsFor(all, path) {
    const o = all && typeof all === "object" && all[path] && typeof all[path] === "object" ? all[path] : {};
    return {sort: normalizeSort(o.sort), view: normalizeView(o.view), display: normalizeDisplay(o.display)};
}

// The stored options after one field of one folder changed. Entries of unknown fields and values are dropped; a folder whose
// options all equal the defaults has no entry.
function withOption(all, path, key, value) {
    const next = {};
    const source = all && typeof all === "object" ? all : {};
    for (const p of Object.keys(source)) {
        if (typeof p === "string" && p.startsWith("/") && p !== path)
            next[p] = optionsFor(source, p);
    }
    const o = optionsFor(source, path);
    if (key === "sort")
        o.sort = normalizeSort(value);
    else if (key === "view")
        o.view = normalizeView(value);
    else if (key === "display")
        o.display = normalizeDisplay(value);
    next[path] = o;
    for (const p of Object.keys(next)) {
        const v = next[p];
        if (v.sort === DEFAULTS.sort && v.view === DEFAULTS.view && v.display === DEFAULTS.display)
            delete next[p];
    }
    return next;
}

function baseName(path) {
    const parts = String(path).split("/").filter(s => s !== "");
    return parts.length > 0 ? parts[parts.length - 1] : "/";
}

// Icon theme name of a folder tile: the places icons of the XDG user folders, "folder" for the rest.
function folderIconName(path, home) {
    const rel = String(path).startsWith(home + "/") ? String(path).substring(home.length + 1) : "";
    const names = {
        "Downloads": "folder-download",
        "Documents": "folder-documents",
        "Pictures": "folder-pictures",
        "Music": "folder-music",
        "Videos": "folder-videos",
        "Desktop": "user-desktop"
    };
    return names[rel] ? names[rel] : "folder";
}

// ---- Listing ----

// Output of dock/list-folder.sh: records ended by RS (0x1e), fields by US (0x1f): birth, modified and changed time (seconds,
// birth is empty or 0 where the file system has none), type letter (d folder, f file, ...), name. Hidden names never come
// (the script drops them). [{name, path, isDir, created, modified, added}], times in seconds.
function parseListing(text, dir) {
    const out = [];
    const base = String(dir).replace(/\/+$/, "");
    for (const record of String(text || "").split("\x1e")) {
        if (record === "")
            continue;
        const f = record.split("\x1f");
        if (f.length < 5)
            continue;
        const name = f.slice(4).join("\x1f").replace(/^\n+/, "");
        if (name === "" || name.indexOf("/") >= 0 || name.startsWith("."))
            continue;
        const modified = parseFloat(f[1]) || 0;
        const changed = parseFloat(f[2]) || 0;
        const born = parseFloat(f[0]) || 0;
        out.push({
            name: name,
            path: base + "/" + name,
            isDir: f[3] === "d",
            created: born > 0 ? born : modified,
            modified: modified,
            // Linux has no "date added": the last change of the inode (a download finishing, a file moved in) is the closest.
            added: Math.max(changed, born)
        });
    }
    return out;
}

function compareNames(a, b) {
    const x = a.name.toLowerCase();
    const y = b.name.toLowerCase();
    return x < y ? -1 : x > y ? 1 : (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
}

// File kind used for the "Kind" order: folders first, then by extension, then by name.
function kindOf(entry) {
    if (entry.isDir)
        return "";
    const i = entry.name.lastIndexOf(".");
    return i > 0 ? entry.name.substring(i + 1).toLowerCase() : "~";
}

// A copy of `entries` in the order of `sort`: Name (A to Z), the three dates newest first (macOS), Kind. Ties by name.
function sortEntries(entries, sort) {
    const by = {
        name: compareNames,
        dateAdded: (a, b) => b.added - a.added,
        dateModified: (a, b) => b.modified - a.modified,
        dateCreated: (a, b) => b.created - a.created,
        kind: (a, b) => {
            const x = kindOf(a);
            const y = kindOf(b);
            return x < y ? -1 : x > y ? 1 : 0;
        }
    };
    const cmp = by[normalizeSort(sort)];
    return Array.from(entries || []).sort((a, b) => cmp(a, b) || compareNames(a, b));
}

// ---- Views ----

// The view an "Automatic" stack shows (macOS): a Fan while the items fit in it, a Grid beyond that. The others are as chosen.
function resolveView(view, count, fanMax) {
    const v = normalizeView(view);
    if (v !== "automatic")
        return v;
    return count <= fanMax ? "fan" : "grid";
}

// Items a Fan shows (the rest are reached through "Open in Files").
function fanItems(count, fanMax) {
    return Math.max(0, Math.min(count, fanMax));
}

// Where the n icons of a Fan sit. `step` is the distance between two icons along the line away from the Dock and `bend`
// how far the last one has moved sideways; the sideways offset grows with the square of the position (a curve like
// macOS'). Item 0 is the one nearest the Dock. Returns [{out, side}] in px: `out` is the distance from the tile (>= 0),
// `side` the offset along the Dock.
function fanLayout(n, step, bend) {
    const out = [];
    const last = Math.max(1, n - 1);
    for (let i = 0; i < n; i++)
        out.push({out: i * step, side: bend * (i / last) * (i / last)});
    return out;
}

// Columns of a Grid: a square-ish grid, at most `maxColumns`, at least 1.
function gridColumns(count, maxColumns) {
    return Math.max(1, Math.min(maxColumns, Math.ceil(Math.sqrt(Math.max(1, count)))));
}

// Index reached from `index` by a key in a list or grid of `count` items in `columns` columns (columns 1: a list). Up/Down
// move a row, Left/Right an item; Home/End the ends. No wrap. -1 (nothing current) enters at the first item.
function step(index, count, columns, key) {
    if (count <= 0)
        return -1;
    if (index < 0)
        return 0;
    const last = count - 1;
    switch (key) {
    case "left":
        return columns > 1 ? Math.max(0, index - 1) : index;
    case "right":
        return columns > 1 ? Math.min(last, index + 1) : index;
    case "up":
        return index - columns >= 0 ? index - columns : index;
    case "down":
        return index + columns <= last ? index + columns : index;
    case "home":
        return 0;
    case "end":
        return last;
    }
    return index;
}

// Icon theme names to try for an entry, most specific first: the MIME type as an icon name ("image/png" is "image-png"),
// then its generic family ("image-x-generic"), then a plain file. Folders: "folder".
function iconCandidates(mime, isDir) {
    if (isDir)
        return ["folder"];
    const out = [];
    const m = String(mime || "");
    if (m.indexOf("/") > 0) {
        out.push(m.replace("/", "-"));
        const family = m.substring(0, m.indexOf("/"));
        if (["audio", "image", "video", "text", "font"].indexOf(family) >= 0)
            out.push(family + "-x-generic");
        if (m.indexOf("zip") >= 0 || m.indexOf("tar") >= 0 || m.indexOf("compress") >= 0)
            out.push("package-x-generic");
    }
    out.push("text-x-generic");
    out.push("application-x-generic");
    return out;
}

// Image types that have a real preview (drawn from the file itself, like macOS' thumbnails in a stack).
function hasPreview(mime) {
    return ["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/svg+xml"].indexOf(String(mime)) >= 0;
}

// file:// URL of a local path for an Image source.
function fileUrl(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
}
