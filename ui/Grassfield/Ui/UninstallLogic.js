.pragma library

// Deleting an app from the launcher and from Files (ADR-0045; macOS: Launchpad's jiggle and its x, Finder's Move to Trash on
// an app in Applications): the decisions both share, pure (unit-tested by tests/unit/tst_uninstall.qml). The Store decides what
// may be removed and removes it (`grassfield-store --removable` answers, `grassfield-store --page=uninstall:<entry>` asks);
// nothing here runs a command or removes anything.

const MAX_TEXT = 4 * 1024 * 1024;
const ENTRY = /^[A-Za-z0-9][A-Za-z0-9._+@-]{0,200}$/;

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// An application entry's id as the Store keys it: without ".desktop"; "" for anything that is not one.
function entryKey(id) {
    const text = String(id || "");
    const key = text.endsWith(".desktop") ? text.slice(0, -8) : text;
    return ENTRY.test(key) ? key : "";
}

// The Store's answer ({version: 1, entries: {"<id>.desktop": {app, name, block}}}) as {key: {app, name, block}}. Anything that
// is not that answer is {}: no app is then offered for removal (fail closed).
function parse(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_TEXT)
        return {};
    let doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return {};
    }
    if (!isObject(doc) || doc.version !== 1 || !isObject(doc.entries))
        return {};
    const out = {};
    for (const id of Object.keys(doc.entries)) {
        const e = doc.entries[id];
        const key = entryKey(id);
        if (key === "" || !isObject(e) || typeof e.app !== "string" || typeof e.block !== "string")
            continue;
        out[key] = {app: e.app, name: typeof e.name === "string" ? e.name : "", block: e.block};
    }
    return out;
}

// Whether the entry shows the x and offers Delete / Move to Trash: the Store lists it and says "" (nothing blocks).
function removable(map, id) {
    const key = entryKey(id);
    const e = key === "" || !map ? null : map[key];
    return !!e && e.block === "";
}

// Why an app stays, in words (a tooltip or a dimmed item): the Store's reason.
function reason(map, id) {
    const key = entryKey(id);
    const e = key === "" || !map ? null : map[key];
    if (!e)
        return qsTr("The Store does not manage this app.");
    switch (e.block) {
    case "":
        return "";
    case "system":
        return qsTr("Part of the system.");
    case "omarchy":
        return qsTr("Part of Omarchy.");
    case "grassfield":
        return qsTr("Part of Grassfield.");
    case "dependency":
        return qsTr("Installed with another app.");
    case "notApp":
    case "notFromRepository":
    case "source":
        return qsTr("The Store can't remove this app.");
    case "dev":
    case "missing":
        return qsTr("Apps can't be removed in this session.");
    }
    return qsTr("The Store can't remove this app now.");
}

// The alert (macOS: "Delete “App”?" with Delete and Cancel; its text says what is kept, which is the truth for packages,
// Flatpaks and their data).
function alertTitle(name) {
    return qsTr("Delete “%1”?").arg(name);
}

function alertText() {
    return qsTr("The app is removed from this computer. Its documents and settings in your home folder are kept.");
}

function deleteLabel() {
    return qsTr("Delete");
}

function cancelLabel() {
    return qsTr("Cancel");
}

// The arguments of the Store that asks for the removal of an entry, null for an id that is not one.
function storeArguments(id) {
    const key = entryKey(id);
    return key === "" ? null : ["--page", "uninstall:" + key + ".desktop"];
}

// The icons' rocking, degrees at `ms` for the icon of position `index`: each rocks with its own phase so they never move
// together (macOS). 0 when `amplitude` or `periodMs` is 0.
function jiggleAngle(ms, index, amplitude, periodMs) {
    if (!(amplitude > 0) || !(periodMs > 0))
        return 0;
    const phase = ((index * 2654435761) % 1000) / 1000 * 2 * Math.PI;
    return amplitude * Math.sin(2 * Math.PI * ms / periodMs + phase);
}
