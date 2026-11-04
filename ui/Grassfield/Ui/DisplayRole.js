.pragma library

// The main display (ADR-0044): which of the connected displays holds the Dock, the desktop icons and the notification banners
// (macOS: Displays > "Use as" > Main display). Pure functions, no I/O, shared by the Settings app (what it writes), the shell
// (what it reads) and the tests. Untrusted input: the stored value goes through normalize(); a bad entry is dropped.
//
// Stored in grassfield.json as `displays.main`: a list of remembered choices, newest first, at most MAX_ENTRIES:
//   [{set: [<display key>, ...sorted], main: <display key in set>}]
// One entry per SET of connected displays (a laptop alone, the laptop with the desk monitor, ...), so that the choice
// comes back when the same displays are connected again. A display is keyed by its identity (identity()), never by its
// connector name alone: the connector can change between ports and boots.

const MAX_ENTRIES = 16;
const MAX_SET = 16;
const MAX_KEY_CHARS = 160;

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// A list as a real array, or null (the JSON adapter's QVariantList is not an Array: see WallpaperConfig.asArray).
function asArray(v, cap) {
    if (Array.isArray(v))
        return v.slice(0, cap);
    if (v === null || typeof v !== "object" || Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null)
        return null;
    if (typeof v.length !== "number" || v.length < 0 || Math.floor(v.length) !== v.length)
        return null;
    const out = [];
    const n = Math.min(v.length, cap);
    for (let i = 0; i < n; i++)
        out.push(v[i]);
    out.realLength = v.length;
    return out;
}

// The identity of a display `d` ({name, model, serial}: the compositor's output name, the EDID model and serial). The model
// and the serial when it has one (the same panel on any port); else the model with its connector (two identical monitors
// without a serial stay apart); else the connector name alone, only for an output with no EDID at all (a virtual one).
function identity(d) {
    const name = d && typeof d.name === "string" ? d.name : "";
    const model = d && typeof d.model === "string" ? d.model : "";
    const serial = d && typeof d.serial === "string" ? d.serial : "";
    if (model !== "" && serial !== "")
        return "s:" + model + "|" + serial;
    if (model !== "")
        return "m:" + model + "|" + name;
    return "n:" + name;
}

// The sorted keys of the displays: the identity of a set of connected displays.
function setOf(displays) {
    const keys = displays.map(identity);
    keys.sort();
    return keys;
}

function sameSet(a, b) {
    if (a.length !== b.length)
        return false;
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i])
            return false;
    }
    return true;
}

// A built-in panel (a laptop's own display): its connector is eDP-n, LVDS-n or DSI-n.
function isBuiltin(d) {
    return !!d && typeof d.name === "string" && /^(eDP|LVDS|DSI)/i.test(d.name);
}

// Reason ("" when valid) for one stored entry.
function entryProblem(e) {
    if (!isPlainObject(e))
        return "not-an-object";
    for (const k of Object.keys(e)) {
        if (k !== "set" && k !== "main")
            return "unknown key " + k;
    }
    const set = asArray(e.set, MAX_SET + 1);
    if (set === null || set.length < 1 || set.length > MAX_SET || (set.realLength || 0) > MAX_SET)
        return "set";
    let last = "";
    for (let i = 0; i < set.length; i++) {
        const k = set[i];
        if (typeof k !== "string" || k.length < 3 || k.length > MAX_KEY_CHARS || /[\u0000-\u001f\u007f-\u009f]/.test(k))
            return "set";
        // Sorted and without repeats: the set is compared as it is stored.
        if (i > 0 && !(last < k))
            return "set-order";
        last = k;
    }
    if (typeof e.main !== "string" || set.indexOf(e.main) < 0)
        return "main";
    return "";
}

// "" when `raw` is a valid list (at most MAX_ENTRIES valid entries, no set twice), else the reason.
function problem(raw) {
    const list = asArray(raw, MAX_ENTRIES + 1);
    if (list === null)
        return "not-an-array";
    if (list.length > MAX_ENTRIES || (list.realLength || 0) > MAX_ENTRIES)
        return "too-many";
    for (let i = 0; i < list.length; i++) {
        const why = entryProblem(list[i]);
        if (why !== "")
            return "entry " + i + ": " + why;
        for (let j = 0; j < i; j++) {
            if (sameSet(asArray(list[j].set, MAX_SET), asArray(list[i].set, MAX_SET)))
                return "entry " + i + ": set repeated";
        }
    }
    return "";
}

// The good entries of a stored value, copied (the stored object is never handed on as it is): a bad or repeated entry is
// dropped, a value that is not a list reads as no choice at all.
function normalize(raw) {
    const list = asArray(raw, MAX_ENTRIES);
    if (list === null)
        return [];
    const out = [];
    for (const e of list) {
        if (entryProblem(e) !== "")
            continue;
        const set = asArray(e.set, MAX_SET);
        if (out.some(o => sameSet(o.set, set)))
            continue;
        out.push({set: set, main: e.main});
    }
    return out;
}

// The main display among the connected `displays` ([{name, model, serial}], the compositor's order), given the stored
// `entries`. Returns {name, key, why}; `why` says how it was found:
//   "chosen"     the choice made for exactly this set of displays;
//   "remembered" no choice for this set: the newest choice, for another set, whose display is connected (a display plugged
//                in or out does not move the main role while the main display is still there);
//   "builtin"    the main display is gone (or never chosen): the built-in panel;
//   "first"      no built-in panel: the first display;
//   "none"       no display.
function resolve(entries, displays) {
    const list = Array.isArray(displays) ? displays : [];
    if (list.length === 0)
        return {name: "", key: "", why: "none"};
    const stored = normalize(entries);
    const keys = list.map(identity);
    const set = setOf(list);
    const find = key => {
        const i = keys.indexOf(key);
        return i < 0 ? null : {name: list[i].name, key: key};
    };
    const exact = stored.find(e => sameSet(e.set, set));
    if (exact) {
        const hit = find(exact.main);
        if (hit)
            return {name: hit.name, key: hit.key, why: "chosen"};
    }
    for (const e of stored) {
        const hit = find(e.main);
        if (hit)
            return {name: hit.name, key: hit.key, why: "remembered"};
    }
    const builtin = list.find(isBuiltin);
    if (builtin)
        return {name: builtin.name, key: identity(builtin), why: "builtin"};
    return {name: list[0].name, key: keys[0], why: "first"};
}

// The stored list with `mainKey` as the main display of the current set of `displays`: that set's entry is replaced and put
// first, the oldest entry past MAX_ENTRIES goes. The list unchanged when `mainKey` is not one of the displays.
function withMain(entries, displays, mainKey) {
    const list = Array.isArray(displays) ? displays : [];
    const set = setOf(list);
    if (set.indexOf(mainKey) < 0)
        return normalize(entries);
    const rest = normalize(entries).filter(e => !sameSet(e.set, set));
    return [{set: set, main: mainKey}].concat(rest).slice(0, MAX_ENTRIES);
}
