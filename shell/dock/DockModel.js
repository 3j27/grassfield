.pragma library

// Dock model (pure, unit-tested): merges pinned apps with running apps.
//
// pinned:   array of desktop entry ids (order is the user's order)
// running:  array of {appId, ref} (one per window; ref is the toplevel handle)
// lookup:   function(id) -> {id, name, icon, ...} or null (desktop entry resolution)
//
// Result items: {kind: "app", key, name, icon, entry, windows: [ref...], pinned}
//               {kind: "separator"} and {kind: "trash"} are appended by withTail().

function merge(pinned, running, lookup) {
    const list = [];
    const byKey = {};
    const pins = pinned ? pinned : [];
    for (let i = 0; i < pins.length; i++) {
        const entry = lookup(pins[i]);
        if (!entry || byKey[entry.id] !== undefined)
            continue;
        byKey[entry.id] = list.length;
        list.push({kind: "app", key: entry.id, name: entry.name, icon: entry.icon, entry: entry, windows: [], pinned: true});
    }
    for (let j = 0; j < running.length; j++) {
        const win = running[j];
        if (!win.appId)
            continue;
        const entry = lookup(win.appId);
        const key = entry ? entry.id : win.appId;
        if (byKey[key] === undefined) {
            byKey[key] = list.length;
            list.push({kind: "app", key: key, name: entry ? entry.name : win.appId, icon: entry ? entry.icon : win.appId,
                entry: entry, windows: [], pinned: false});
        }
        list[byKey[key]].windows.push(win.ref);
    }
    return list;
}

// Minimized windows as tiles: {kind: "minimized", key, name, icon, appId, toplevel}.
// records: [{toplevel, address, appId, title}] (platform/Minimized.js); lookup resolves desktop entries.
function minimizedItems(records, lookup) {
    return (records ? records : []).map(r => {
        const entry = lookup(r.appId);
        const app = entry ? entry.name : r.appId;
        return {
            kind: "minimized",
            key: "min:" + r.address,
            name: r.title ? r.title : app,
            appName: app,
            icon: entry ? entry.icon : r.appId,
            appId: r.appId,
            toplevel: r.toplevel
        };
    });
}

// Apps, a separator, minimized windows (right of the separator), then the trash.
function withTail(apps, minimized) {
    return apps.concat([{kind: "separator"}], minimized ? minimized : [], [{kind: "trash"}]);
}

function pin(pinned, id) {
    const list = (pinned ? pinned : []).slice();
    return list.indexOf(id) === -1 ? list.concat([id]) : list;
}

function unpin(pinned, id) {
    return (pinned ? pinned : []).filter(p => p !== id);
}

// Unpin by resolved key: drops every pinned id that resolves (via lookup) to the given key.
function unpinKey(pinned, key, lookup) {
    return (pinned ? pinned : []).filter(p => {
        const entry = lookup(p);
        return p !== key && (!entry || entry.id !== key);
    });
}

// Dock geometry, the single formula shared by the Dock and by whoever reserves its area (Overview).
// `t` = {iconSize, padding, indicatorSize, spacing, bottomMargin} (the dock tokens).
function shelfHeight(t) {
    return t.iconSize + 2 * t.padding + t.indicatorSize + t.spacing;
}

// Height the Dock takes from the bottom of the output when it is not auto-hidden (its exclusive zone).
function reservedHeight(t, autohide) {
    return autohide ? 0 : shelfHeight(t) + t.bottomMargin;
}

// ---- Dock fidelity pass ----

// Notification badge of an app tile: the number of notifications (Notifications.history entries, {appName}) whose app
// name is the tile's name or desktop entry id (case-insensitive). Read-only; 0 for tiles that are not apps.
function badgeCount(history, item) {
    if (!item || item.kind !== "app")
        return 0;
    const names = [String(item.name || "").toLowerCase(), String(item.key || "").toLowerCase()].filter(n => n !== "");
    let n = 0;
    for (const e of (history ? history : [])) {
        if (e && names.indexOf(String(e.appName || "").toLowerCase()) >= 0)
            n++;
    }
    return n;
}

// Badge text: "" for none, the number up to 99, then "99+".
function badgeText(count) {
    return count <= 0 ? "" : (count > 99 ? "99+" : String(count));
}

// Recently launched apps, newest first, without duplicates, at most `max`.
function pushRecent(recent, id, max) {
    const list = [id].concat((recent ? recent : []).filter(r => r !== id));
    return list.slice(0, max);
}

// Recent applications update (idempotent): the apps that were running (`previous`, keys) and are not any more (`now`,
// keys) and that are not kept in the Dock (`pinned`, keys) go to the front of `recent`, newest first, at most `max`.
// A function of the two running sets and the old list only: an app that is still running is never added (it shows as a
// running tile), so the cap evicting a key can not make it "new" again, and an unchanged running set returns `recent`.
function recentsAfter(recent, previous, now, pinned, max) {
    const nowSet = {};
    (now ? now : []).forEach(k => {
        nowSet[k] = true;
    });
    const kept = {};
    (pinned ? pinned : []).forEach(k => {
        kept[k] = true;
    });
    let list = (recent ? recent : []).slice(0, max);
    for (const key of (previous ? previous : [])) {
        if (nowSet[key] || kept[key])
            continue;
        list = pushRecent(list, key, max);
    }
    return list;
}

// One rebuild step of the recent list: until the desktop entries and the hidden-entry list (OnlyShowIn / NotShowIn) are
// loaded (`ready` false) nothing is evaluated, because an app that looks listed now may turn out hidden (or unresolved) a
// moment later and would then count as "quit". Returns {recent, previous}: the list to keep and the running set to
// remember (null while not ready: the first ready rebuild only records the running set, like a shell restart).
function recentsStep(ready, recent, previous, now, pinned, max) {
    if (!ready)
        return {recent: recent ? recent : [], previous: null};
    return {recent: recentsAfter(recent, previous, now, pinned, max), previous: now};
}

// Recent apps that are neither pinned nor running, resolved through `lookup`, appended to the app list
// ({kind: "app", recent: true, windows: [], pinned: false}). `apps` is the result of merge(). `listed` (optional) is a
// predicate on the desktop entry: NoDisplay / hidden entries are never shown as recents.
function withRecents(apps, recent, lookup, max, listed) {
    const have = {};
    apps.forEach(a => {
        have[a.key] = true;
    });
    const out = apps.slice();
    let added = 0;
    for (const id of (recent ? recent : [])) {
        if (added >= max)
            break;
        const entry = lookup(id);
        if (!entry || have[entry.id] || (listed && !listed(entry)))
            continue;
        have[entry.id] = true;
        // macOS: the recent applications are their own section, set off by a divider.
        if (added === 0)
            out.push({kind: "separator", divider: true});
        added++;
        out.push({kind: "app", key: entry.id, name: entry.name, icon: entry.icon, entry: entry, windows: [], pinned: false, recent: true});
    }
    return out;
}

// Drag to reorder: move the app tile `from` to slot `to` (indices in the app list, the first items of `items`).
// Returns {changed, pinned}: the new pinned key list. An unpinned app (running or recent) dropped before a pinned
// one becomes pinned there; dropped after every pinned app it stays as it is (its place follows the launch order).
function reorder(items, from, to) {
    const apps = items.filter(it => it.kind === "app");
    if (from < 0 || from >= apps.length)
        return {changed: false, pinned: apps.filter(a => a.pinned).map(a => a.key)};
    const dest = Math.max(0, Math.min(apps.length - 1, to));
    const moved = apps[from];
    const order = apps.slice();
    order.splice(from, 1);
    order.splice(dest, 0, moved);
    const pinnedBefore = apps.filter(a => a.pinned).map(a => a.key);
    let becomesPinned = moved.pinned;
    if (!moved.pinned) {
        for (let i = dest + 1; i < order.length; i++) {
            if (order[i].pinned)
                becomesPinned = true;
        }
    }
    const pinned = order.filter(a => a.key === moved.key ? becomesPinned : a.pinned).map(a => a.key);
    return {changed: pinned.join("\n") !== pinnedBefore.join("\n"), pinned: pinned};
}

// Item indices of the app tiles (the recent applications divider sits between app tiles).
function appIndices(items) {
    const out = [];
    items.forEach((it, i) => {
        if (it.kind === "app")
            out.push(i);
    });
    return out;
}

// Slot a dragged tile would take: the position in the app list (items at `indices`) whose tile center is nearest to x.
function dropSlot(centers, indices, x) {
    let best = 0;
    let dist = Infinity;
    for (let i = 0; i < indices.length && indices[i] < centers.length; i++) {
        const d = Math.abs(centers[indices[i]] - x);
        if (d < dist) {
            dist = d;
            best = i;
        }
    }
    return best;
}

// A dragged tile that left the shelf by more than `threshold` px (above its top edge) is dropped out of the Dock.
function draggedOut(y, threshold) {
    return y < -threshold;
}

// ---- Files dropped on an app tile ----
// macOS model: a tile accepts a drop only when the app can open that kind of document. Here: the Exec line has a file field
// code (%f %F %u %U, Desktop Entry spec) AND the entry's MimeType matches the type of every dropped file (an entry without
// MimeType accepts nothing).

// Parsed output of dock/mime-data.sh: {entries: {id: [mime]}, suffix: {".ext": [mime]}, names: {"name": [mime]},
// parents: {mime: [mime]}, aliases: {alias: mime}, ready}.
function parseMimeData(text) {
    const out = {entries: {}, suffix: {}, names: {}, parents: {}, aliases: {}, ready: false};
    for (const raw of String(text || "").split("\n")) {
        const f = raw.replace(/\r$/, "").split("\t");
        if (f[0] === "E" && f.length >= 3) {
            out.entries[f[1]] = f[2].split(";").filter(m => m !== "");
        } else if (f[0] === "G" && f.length >= 2) {
            const g = f[1].split(":");
            if (g.length < 3 || g.indexOf("cs", 3) >= 0)
                continue;
            const glob = g[2];
            if (glob.startsWith("*.") && !/[*?\[]/.test(glob.substring(1))) {
                const k = glob.substring(1).toLowerCase();
                (out.suffix[k] = out.suffix[k] || []).push(g[1]);
            } else if (!/[*?\[]/.test(glob)) {
                const k = glob.toLowerCase();
                (out.names[k] = out.names[k] || []).push(g[1]);
            }
        } else if (f[0] === "S" && f.length >= 2) {
            const p = f[1].split(/\s+/);
            if (p.length === 2)
                (out.parents[p[0]] = out.parents[p[0]] || []).push(p[1]);
        } else if (f[0] === "A" && f.length >= 2) {
            const p = f[1].split(/\s+/);
            if (p.length === 2) {
                out.aliases[p[0]] = p[1];
                (out.aliases["<" + p[1]] = out.aliases["<" + p[1]] || []).push(p[0]);
            }
        }
    }
    out.ready = Object.keys(out.suffix).length > 0;
    return out;
}

// MIME types of a file name (by name only, longest matching extension first): the matched types, their parents
// (subclasses; text/* is a subclass of text/plain) and aliases. [] when the name matches no pattern.
function mimeTypesOf(path, data, resolved) {
    const name = String(path).replace(/\/+$/, "").replace(/^.*\//, "").toLowerCase();
    let found = data.names[name] ? data.names[name] : [];
    for (let i = 1; found.length === 0 && i < name.length; i++) {
        if (name[i] === "." && data.suffix[name.substring(i)])
            found = data.suffix[name.substring(i)];
    }
    // The real type found at drop time (folders, extensionless files, magic) wins over the name.
    if (resolved && typeof resolved[path] === "string" && resolved[path] !== "" && resolved[path] !== "-")
        found = [resolved[path]];
    const all = {};
    const queue = found.slice();
    while (queue.length > 0) {
        const m = queue.shift();
        if (all[m])
            continue;
        all[m] = true;
        (data.parents[m] ? data.parents[m] : []).forEach(x => queue.push(x));
        if (m.startsWith("text/") && m !== "text/plain")
            queue.push("text/plain");
        // Alias -> canonical name, and canonical -> its aliases ("<name" keys).
        if (typeof data.aliases[m] === "string")
            queue.push(data.aliases[m]);
        (data.aliases["<" + m] ? data.aliases["<" + m] : []).forEach(x => queue.push(x));
    }
    return Object.keys(all);
}

function hasFileCode(command) {
    return Array.from(command || []).some(a => /%[fFuU]/.test(String(a).replace(/%%/g, "")));
}

// The tile of `entry` ({id, command}) accepts the dropped `paths`: file field code in Exec and, for every file, a MimeType
// of the entry that equals one of the file's types (or matches "type/*").
// `resolved` (optional) maps a path to its real type (dock/file-types.sh). `lenient` (hovering): a path whose type the name
// does not tell (folder, extensionless file) is let through, the drop resolves it and decides.
function acceptsFiles(entry, paths, data, resolved, lenient) {
    if (!entry || !data || !data.ready || !paths || paths.length === 0 || !hasFileCode(entry.command))
        return false;
    const declared = data.entries[entry.id];
    if (!declared || declared.length === 0)
        return false;
    return paths.every(p => {
        const types = mimeTypesOf(p, data, resolved);
        if (lenient && types.length === 0)
            return true;
        return types.some(t => declared.some(d => d === t || (d.endsWith("/*") && t.startsWith(d.substring(0, d.length - 1)))));
    });
}

// Paths whose type the file name does not tell (no glob matches: folders, extensionless files): their real type is
// resolved at drop time. [] when the name decides every path.
function unresolvedPaths(paths, data) {
    return Array.from(paths || []).filter(p => data && mimeTypesOf(p, data).length === 0);
}

// {path: type} from the lines printed by dock/file-types.sh for `paths` (same order).
function parseResolved(paths, text) {
    const lines = String(text || "").split("\n");
    const out = {};
    Array.from(paths || []).forEach((p, i) => {
        out[p] = (lines[i] || "-").trim();
    });
    return out;
}

// file:// URI of a local path (%u %U get URIs, %f %F paths).
function fileUri(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
}

// Commands that open `files` (local paths) with an entry command, field codes substituted per the Desktop Entry spec:
// %F %U expand to all files in one command; %f %u (single) give one command per file; other codes are dropped and "%%" is a
// literal percent. [] when the command has no file field code (nothing is ever appended to the command line).
function commandsForFiles(command, files) {
    const list = Array.from(files || []).map(String);
    const args = Array.from(command || []).map(String);
    if (list.length === 0 || !hasFileCode(args))
        return [];
    const build = group => {
        const out = [];
        for (const a of args) {
            if (a === "%F" || a === "%U") {
                group.forEach(f => out.push(a === "%U" ? fileUri(f) : f));
            } else if (/^%[a-zA-Z]$/.test(a) && "fFuU".indexOf(a[1]) < 0) {
                continue;
            } else {
                out.push(a.replace(/%(.)/g, (m, c) => c === "%" ? "%" : (c === "f" || c === "F" ? group[0] : (c === "u" || c === "U" ? fileUri(group[0]) : ""))));
            }
        }
        return out;
    };
    const multi = args.some(a => a === "%F" || a === "%U");
    return multi ? [build(list)] : list.map(f => build([f]));
}

// Launch bounce: tiles that were launched and have no window yet. `launching` maps key -> start (ms); entries older
// than `timeoutMs` or whose app now has a window are dropped.
function bounceKeys(launching, items, now, timeoutMs) {
    const out = {};
    for (const key of Object.keys(launching ? launching : {})) {
        if (now - launching[key] > timeoutMs)
            continue;
        const item = items.find(it => it.kind === "app" && it.key === key);
        if (!item || item.windows.length > 0)
            continue;
        out[key] = launching[key];
    }
    return out;
}
