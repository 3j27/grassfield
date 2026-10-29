.pragma library

// What the Open and Save panels decide (FilePanel.qml; ADR-0035 D-4, docs/specs/system-dialogs.md section 1), pure for the
// tests (tests/unit/tst_filepanel.qml). A request is grassfield-portal's chooser::toQml map: {kind: "open"|"save"|"saveFiles",
// multiple, directory, filters: [{name, globs, mimeTypes}], currentFilter, choices, currentName, files, currentFolder, ...}.

// The panel chooses folders, not files: a folder Open panel and SaveFiles (a folder for several files).
function choosesFolders(request) {
    return request.kind === "saveFiles" || (request.kind === "open" && request.directory === true);
}

// FolderModel.chooser for the listings: the filter shown in the Format pop-up (none: every file), folders only, and one
// item at most unless the application takes several.
function filterFor(request, filterIndex) {
    const filters = request.filters || [];
    const f = filterIndex >= 0 && filterIndex < filters.length ? filters[filterIndex] : null;
    return {
        globs: f ? f.globs : [],
        mimeTypes: f ? f.mimeTypes : [],
        foldersOnly: choosesFolders(request),
        single: !(request.kind === "open" && request.multiple === true)
    };
}

function isLocal(url) {
    return String(url).startsWith("file:///");
}

// A file URL inside `folder` (a file URL) for `name`.
function childUrl(folder, name) {
    const base = String(folder);
    return (base.endsWith("/") ? base : base + "/") + encodeURIComponent(name);
}

// The URL of the folder holding `url`.
function parentUrl(url) {
    const s = String(url).replace(/\/+$/, "");
    const at = s.lastIndexOf("/");
    return at > "file://".length ? s.substring(0, at) : "file:///";
}

// What the Open panel's default button does with the selection (`selected`: [{url, isDir}] in view order; the listing never
// selects a file the panel cannot take) in the folder `current`:
//   {action: "choose", uris}  the answer;
//   {action: "enter", url}    a folder selected in a file panel opens in the panel (macOS);
//   {action: "none"}          nothing to choose.
function openAction(request, selected, current) {
    if (request.directory === true) {
        const dirs = selected.filter(s => s.isDir);
        if (dirs.length === 0)
            return {action: "choose", uris: [String(current)]};
        return {action: "choose", uris: request.multiple === true ? dirs.map(s => String(s.url)) : [String(dirs[0].url)]};
    }
    const files = selected.filter(s => !s.isDir);
    if (files.length > 0)
        return {action: "choose", uris: request.multiple === true ? files.map(s => String(s.url)) : [String(files[0].url)]};
    if (selected.length > 0 && selected[0].isDir)
        return {action: "enter", url: String(selected[0].url)};
    return {action: "none"};
}

// Whether the Open panel's default button is enabled: a folder panel always (the shown folder), a file panel with a selection.
function openEnabled(request, selectedCount) {
    return request.directory === true || selectedCount > 0;
}

// The extension a filter names by a plain "*.ext" glob (the first one), "" when none.
function extensionOf(globs) {
    for (let i = 0; globs && i < globs.length; i++) {
        const m = /^\*\.([A-Za-z0-9][A-Za-z0-9_.+-]*)$/.exec(globs[i]);
        if (m)
            return m[1];
    }
    return "";
}

// The Save As name after the Format pop-up changed to a filter of `globs` (macOS: the extension follows the format). A
// name without an extension gets none; a filter without a plain extension changes nothing.
function nameForFormat(name, globs) {
    const ext = extensionOf(globs);
    const dot = name.lastIndexOf(".");
    if (ext === "" || dot <= 0)
        return name;
    return name.substring(0, dot) + "." + ext;
}

// The folder a panel opens in: the application's own suggestion, else the folder the panel was left in for that
// application, else Documents, else the home folder (`isFolder(url)`: an existing local folder).
function startFolder(request, memory, places, isFolder) {
    const candidates = [request.currentFolder, memory ? memory.folder : "", places.documents, places.home];
    for (let i = 0; i < candidates.length; i++) {
        const c = candidates[i];
        if (c && isFolder(c))
            return String(c);
    }
    return String(places.home);
}

// The choices' answer: [{id, value}] in the request's order, from `values` (id -> value).
function choicesAnswer(request, values) {
    return (request.choices || []).map(c => ({id: c.id, value: values[c.id] !== undefined ? String(values[c.id]) : c.initial}));
}

// The names of SaveFiles that exist in the chosen folder (`kind(url)`: 0 none, 1 file, 2 folder).
function clashes(names, folder, kind) {
    const out = [];
    for (let i = 0; i < names.length; i++) {
        const k = kind(childUrl(folder, names[i]));
        if (k !== 0)
            out.push({name: names[i], folder: k === 2});
    }
    return out;
}
