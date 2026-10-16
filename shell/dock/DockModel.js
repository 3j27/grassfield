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

// Apps, then a separator, then the trash.
function withTail(apps) {
    return apps.concat([{kind: "separator"}, {kind: "trash"}]);
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
