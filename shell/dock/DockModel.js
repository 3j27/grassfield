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

// Recent apps that are neither pinned nor running, resolved through `lookup`, appended to the app list
// ({kind: "app", recent: true, windows: [], pinned: false}). `apps` is the result of merge().
function withRecents(apps, recent, lookup, max) {
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
        if (!entry || have[entry.id])
            continue;
        have[entry.id] = true;
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

// Slot a dragged tile would take: the index of the tile center nearest to x (centers of the app tiles only).
function dropSlot(centers, appCount, x) {
    let best = 0;
    let dist = Infinity;
    for (let i = 0; i < appCount && i < centers.length; i++) {
        const d = Math.abs(centers[i] - x);
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

// Open this app with dropped files: the entry command with Exec field codes replaced (%f %u: the first target; %F %U:
// all of them); when the command has no file field code the targets are appended. Targets are local paths or URIs.
function commandWithFiles(command, targets) {
    const files = Array.from(targets || []).map(String);
    const out = [];
    let used = false;
    for (const raw of Array.from(command || [])) {
        const a = String(raw);
        if (a === "%F" || a === "%U") {
            used = true;
            files.forEach(f => out.push(f));
        } else if (a === "%f" || a === "%u") {
            used = true;
            if (files.length > 0)
                out.push(files[0]);
        } else if (/^%[a-zA-Z]$/.test(a)) {
            continue;
        } else {
            out.push(a.replace(/%(.)/g, (m, c) => c === "%" ? "%" : ""));
        }
    }
    return used ? out : out.concat(files);
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
