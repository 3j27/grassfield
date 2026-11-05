.pragma library

// Static registry of the first-party widgets (contract widgets/1, docs/specs/widgets.md).
// The manifests here mirror builtin/<id>/manifest.json (tests/unit/tst_widgets.qml keeps them equal).
// v1 never loads anything that is not listed here.

const CONTRACT = "widgets/1";
const SIZES = ["small", "medium", "large"];
// "weather": the Weather widget reads the shell's WeatherSampler (wttr.in's report for Omarchy's saved place, ADR-0045 OC-14):
// the one network read a widget gets, made by the shell on one fixed host, never by the widget.
const PERMISSIONS = ["media", "battery", "system", "weather"];

const MANIFESTS = [
    {id: "clock", name: "Clock", version: "1.0.0", sizes: ["small", "medium", "large"], contract: CONTRACT, permissions: []},
    {id: "calendar", name: "Calendar", version: "1.0.0", sizes: ["small", "medium", "large"], contract: CONTRACT, permissions: []},
    {id: "battery", name: "Battery", version: "1.0.0", sizes: ["small", "medium"], contract: CONTRACT, permissions: ["battery"]},
    {id: "nowplaying", name: "Now Playing", version: "1.0.0", sizes: ["small", "medium"], contract: CONTRACT, permissions: ["media"]},
    {id: "system", name: "System", version: "1.0.0", sizes: ["small", "medium"], contract: CONTRACT, permissions: ["system"]},
    {id: "weather", name: "Weather", version: "1.0.0", sizes: ["small", "medium"], contract: CONTRACT, permissions: ["weather"]}
];

// "" when the manifest is valid, otherwise the first problem found.
function validateManifest(m) {
    if (m === null || typeof m !== "object" || Array.isArray(m))
        return "manifest is not an object";
    if (typeof m.id !== "string" || !/^[a-z][a-z0-9]{0,31}$/.test(m.id))
        return "invalid id";
    if (typeof m.name !== "string" || m.name === "")
        return "invalid name";
    if (typeof m.version !== "string" || !/^\d+\.\d+\.\d+$/.test(m.version))
        return "invalid version";
    if (m.contract !== CONTRACT)
        return "unsupported contract";
    if (!Array.isArray(m.sizes) || m.sizes.length === 0)
        return "no sizes";
    for (let i = 0; i < m.sizes.length; i++) {
        if (SIZES.indexOf(m.sizes[i]) < 0)
            return "unknown size " + m.sizes[i];
        if (m.sizes.indexOf(m.sizes[i]) !== i)
            return "duplicate size " + m.sizes[i];
    }
    if (!Array.isArray(m.permissions))
        return "permissions is not a list";
    for (let i = 0; i < m.permissions.length; i++) {
        // "network" is deliberately not in PERMISSIONS: a widget of widgets/1 has no network access of its own ("weather"
        // reads what the shell fetched).
        if (PERMISSIONS.indexOf(m.permissions[i]) < 0)
            return "unknown permission " + m.permissions[i];
    }
    return "";
}

function find(id) {
    for (let i = 0; i < MANIFESTS.length; i++) {
        if (MANIFESTS[i].id === id)
            return MANIFESTS[i];
    }
    return null;
}

function ids() {
    return MANIFESTS.map(m => m.id);
}

// The whole registry is valid and ids are unique.
function validateAll() {
    const seen = {};
    for (let i = 0; i < MANIFESTS.length; i++) {
        const err = validateManifest(MANIFESTS[i]);
        if (err !== "")
            return MANIFESTS[i].id + ": " + err;
        if (seen[MANIFESTS[i].id])
            return "duplicate id " + MANIFESTS[i].id;
        seen[MANIFESTS[i].id] = true;
    }
    return "";
}
