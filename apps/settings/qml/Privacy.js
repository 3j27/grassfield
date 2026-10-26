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

// A saved selection's restore token (systemguard.cpp isPortalToken).
function validToken(token) {
    return typeof token === "string" && /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/.test(token);
}

// The state as the panes use it: {location, background, camera: [{app, allowed}], remoteDesktop, screencast: [{app,
// tokens}]}, one entry per application (its saved selections together), anything malformed dropped; every key is there.
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
        const byApp = {};
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
    return out;
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

// The desktop entry an application id names (a Flatpak's id is its entry's name), "" for an id that is not valid.
function entryFile(app) {
    return validApp(app) ? app + ".desktop" : "";
}
