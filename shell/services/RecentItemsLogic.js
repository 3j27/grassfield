.pragma library

// Recent Items of the Grassfield menu (macOS Apple menu > Recent Items): pure logic, unit-tested in
// tests/unit/tst_recentitems.qml. State: {apps: [{id, at}], clearedAt}: the applications the shell launched, newest
// first, with the time of their last launch (ms), and when the menu was last cleared (ms, 0: never).

// The state after `id` was launched at `at`: moved to the front, the list cut to `keep`. Invalid ids leave it as it is.
function withLaunch(state, id, at, keep) {
    const s = normalize(state);
    if (typeof id !== "string" || id === "" || id.length > 255)
        return s;
    const apps = [{id: id, at: at}].concat(s.apps.filter(a => a.id !== id)).slice(0, keep);
    return {apps: apps, clearedAt: s.clearedAt};
}

// The state after Clear Menu at `at`: no applications, and documents used before `at` are hidden.
function cleared(state, at) {
    return {apps: [], clearedAt: at};
}

// A state read from disk (untrusted JSON): unknown or invalid parts dropped.
function normalize(state) {
    const s = state && typeof state === "object" ? state : {};
    const apps = Array.isArray(s.apps) ? s.apps.filter(a => a && typeof a.id === "string" && a.id !== "" && a.id.length <= 255 && Number.isFinite(a.at)) : [];
    const clearedAt = Number.isFinite(s.clearedAt) && s.clearedAt > 0 ? s.clearedAt : 0;
    return {apps: apps, clearedAt: clearedAt};
}

// At most `max` applications that still resolve (`lookup(id)` -> a desktop entry or null): [{id, name}].
function applications(state, max, lookup) {
    const out = [];
    for (const a of normalize(state).apps) {
        const entry = lookup(a.id);
        if (!entry)
            continue;
        out.push({id: a.id, name: entry.name ? String(entry.name) : a.id});
        if (out.length >= max)
            break;
    }
    return out;
}

// At most `max` documents ([{path, modified}], newest first, from the recently-used list) used after the menu was cleared.
function documents(list, state, max) {
    const clearedAt = normalize(state).clearedAt;
    return (Array.isArray(list) ? list : []).filter(d => d && typeof d.path === "string" && d.path !== "" && d.modified > clearedAt).slice(0, max);
}

// The submenu rows: a header and the items of each section (macOS shows both headers, also when a section is empty),
// then Clear Menu (disabled when there is nothing to clear). `t` holds the translated texts.
function menu(apps, docs, t) {
    const rows = [{id: "recentHeader", text: t.applications, enabled: false}];
    for (const a of apps)
        rows.push({id: "recentApp", appId: a.id, text: a.name});
    rows.push({separator: true});
    rows.push({id: "recentHeader", text: t.documents, enabled: false});
    for (const d of docs)
        rows.push({id: "recentDocument", path: d.path, text: baseName(d.path)});
    rows.push({separator: true});
    rows.push({id: "recentClear", text: t.clear, enabled: apps.length + docs.length > 0});
    return rows;
}

function baseName(path) {
    const parts = String(path).split("/");
    return parts[parts.length - 1] !== "" ? parts[parts.length - 1] : String(path);
}
