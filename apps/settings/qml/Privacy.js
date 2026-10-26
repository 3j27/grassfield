.pragma library

// Privacy & Security (ADR-0030, the portal permission store): what the Backend's "privacy.state" answers, checked again here,
// and the two actions. Pure; the Backend refuses a malformed action again (systemguard.cpp, systembus.cpp validAction).

// The grants with a switch (an application allowed or not) and the saved selections (a screen or window chosen once, which
// the application may use again without asking): the keys of the state, in the order of the hub's rows.
var SWITCHES = ["location", "background", "camera"];
var SAVED = ["remoteDesktop", "screencast"];

// An application id as the portal keeps it (systemguard.cpp isPortalAppId): a Flatpak id or another name of the same
// characters, never a path.
function validApp(id) {
    return typeof id === "string" && /^[A-Za-z0-9_][A-Za-z0-9_.+-]{0,254}$/.test(id) && id.indexOf("..") < 0;
}

// A saved selection's restore token as the portal makes and accepts it (systemguard.cpp isPortalToken): [A-Za-z0-9_] (some
// begin with _), or a legacy UUID.
function validToken(token) {
    return typeof token === "string" && /^(?:[A-Za-z0-9_]{1,128}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$/.test(token);
}

// The state as the panes use it: {location, background, camera: [{app, allowed}], remoteDesktop, screencast: [{app,
// tokens}], portals: {background, remoteDesktop}}, one entry per application (its saved selections together), anything
// malformed dropped; every key is there (a portal true or false only when the Backend knows).
function parse(text) {
    let v = null;
    try {
        v = JSON.parse(text);
    } catch (e) {
        v = null;
    }
    const listOf = key => v !== null && typeof v === "object" && Array.isArray(v[key]) ? v[key] : [];
    const out = {};
    for (const key of SWITCHES)
        out[key] = listOf(key).filter(e => e && validApp(e.app) && typeof e.allowed === "boolean").map(e => ({app: e.app, allowed: e.allowed}));
    for (const key of SAVED) {
        const byApp = Object.create(null);
        out[key] = [];
        for (const e of listOf(key)) {
            if (!e || !validApp(e.app) || !validToken(e.token))
                continue;
            if (byApp[e.app] === undefined) {
                byApp[e.app] = {app: e.app, tokens: []};
                out[key].push(byApp[e.app]);
            }
            if (byApp[e.app].tokens.indexOf(e.token) < 0)
                byApp[e.app].tokens.push(e.token);
        }
    }
    out.portals = {};
    const portals = v !== null && typeof v === "object" && v.portals !== null && typeof v.portals === "object" ? v.portals : {};
    for (const key of ["background", "remoteDesktop"]) {
        if (typeof portals[key] === "boolean")
            out.portals[key] = portals[key];
    }
    return out;
}

// The desktop portal this category's grant is for is known to be missing: no app can ask for it, and its settings change
// nothing on this system (ADR-0030: Omarchy's portal backends may implement neither Background nor RemoteDesktop).
function portalMissing(state, key) {
    return !!state && !!state.portals && state.portals[key] === false;
}

// How many applications a row counts: those allowed (a switch), those with a saved selection.
function count(state, key) {
    const list = state && Array.isArray(state[key]) ? state[key] : [];
    return SWITCHES.indexOf(key) >= 0 ? list.filter(e => e.allowed).length : list.length;
}

// The Backend's action that allows (on) or refuses one application, null when a value is not valid.
function allow(key, app, on) {
    if (SWITCHES.indexOf(key) < 0 || !validApp(app) || typeof on !== "boolean")
        return null;
    return {op: "privacy.allow", category: key, app: app, on: on};
}

// The Backend's action that forgets one saved selection, null when a value is not valid.
function forget(key, token) {
    if (SAVED.indexOf(key) < 0 || !validToken(token))
        return null;
    return {op: "privacy.forget", kind: key, token: token};
}

// Whether the portal takes an application for one of the host's (not sandboxed). `entries`: every applications folder that
// has its desktop entry, [{dir, hidden}]. Not when any of them is a Flatpak export (a user's override or hidden copy of a
// Flatpak's entry elsewhere does not make it the host's), not for a Snap, and only with an entry the user sees: when in
// doubt the switch stays. The portal allows the host's applications their location and the background without reading the
// store (location.c, background.c), so a switch would do nothing for them.
function hostApp(app, entries) {
    if (String(app).indexOf("snap.") === 0 || !Array.isArray(entries))
        return false;
    if (entries.some(e => e && /\/exports\/share\/applications\/?$/.test(String(e.dir))))
        return false;
    return entries.some(e => e && typeof e.dir === "string" && e.hidden !== true);
}

// The tag of a category's actions: its failure shows under its own list only.
function actTag(key) {
    return "privacy." + key + ".act";
}

// The categories whose grant the portal reads for the host's applications too (camera.c).
var HOST_READ = ["camera"];

// The desktop entry an application id names (a Flatpak's id is its entry's name), "" for an id that is not valid.
function entryFile(app) {
    return validApp(app) ? app + ".desktop" : "";
}
