.pragma library

// Keyboard layout changes (macOS input source HUD). Pure functions, tested in tests/unit/tst_inputsource.qml.
//
// Hyprland sends `activelayout>>keyboard,layout` when a keyboard's active layout changes, and also when a keyboard
// appears. Nothing says how many layouts are configured, so the HUD is shown only for a CHANGE: the first layout seen on
// a keyboard is remembered without a HUD (a session with one layout never has a second one, so it never shows anything).

// Splits the event data. The keyboard is up to the first comma, the layout name is the rest (names can have commas).
// null for anything that does not look like it.
function parse(data) {
    const text = String(data === undefined || data === null ? "" : data);
    const i = text.indexOf(",");
    if (i <= 0 || i >= text.length - 1)
        return null;
    const keyboard = text.substring(0, i).trim();
    const layout = text.substring(i + 1).trim();
    if (keyboard === "" || layout === "" || layout.length > 128)
        return null;
    return {keyboard: keyboard, layout: layout};
}

// A layout name a person can read. A virtual keyboard that brings its own keymap (wtype, a remapper, a remote desktop) has no
// layout names in it: Hyprland reports xkb's failure word, "error", for it. That keyboard is not an input source (macOS: the
// input source is the system's, one per user setting, a virtual keyboard never changes it), so its events are ignored
// and "error" is never shown.
function named(layout) {
    const text = String(layout === undefined || layout === null ? "" : layout).trim();
    return text !== "" && !/^(error|unknown|none|\(unknown\))$/i.test(text);
}

// English needs no lookup (the names are English already); so does an empty language.
function needsLookup(language) {
    const text = String(language === undefined || language === null ? "" : language).trim();
    return text !== "" && !/^en([_.@-]|$)/i.test(text);
}

// The helper's answer for one name: its first line, the English name when there is none (the helper prints one line per name).
function lookupResult(output, english) {
    const line = String(output === undefined || output === null ? "" : output).split("\n")[0].trim();
    return line === "" || line.length > 128 ? english : line;
}

// Next state and whether to show the HUD. state: {last: {keyboard: layout}}. Show when the keyboard had a different layout.
// An event without a readable layout name changes nothing and shows nothing.
function step(state, event) {
    if (!named(event.layout))
        return {state: {last: Object.assign({}, state && state.last ? state.last : {})}, show: false};
    const last = Object.assign({}, state && state.last ? state.last : {});
    const known = last[event.keyboard];
    last[event.keyboard] = event.layout;
    return {state: {last: last}, show: known !== undefined && known !== event.layout};
}

// The input sources (macOS: the Input menu in the menu bar, Keyboard > Input Sources). Hyprland's `kb_layout` and `kb_variant`
// (comma lists, one field per layout, the order xkb numbers the groups in) are the sources; `j/devices` on the request socket
// gives them, and `activelayout` names the one in use (its xkb name, "French"), not its position.

var MAX_SOURCES = 4;

// Keyboards that are not typed on (Hyprland lists them with the seat's layouts all the same): a virtual keyboard, a button.
var UNTYPED = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)/;

function validCode(s) {
    return typeof s === "string" && /^[a-z][a-z0-9_-]*$/.test(s) && s.length <= 16;
}

function validVariantCode(s) {
    return s === "" || (typeof s === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(s) && s.length <= 32);
}

// The sources of a layout list and its variants: [{layout, variant}], the names that are not xkb codes dropped, at most four.
function sources(layout, variant) {
    const layouts = String(layout === undefined || layout === null ? "" : layout).split(",");
    const variants = String(variant === undefined || variant === null ? "" : variant).split(",");
    const out = [];
    for (let i = 0; i < layouts.length && out.length < MAX_SOURCES; i++) {
        const v = variants[i] === undefined ? "" : variants[i];
        if (validCode(layouts[i]))
            out.push({layout: layouts[i], variant: validVariantCode(v) ? v : ""});
    }
    return out;
}

// The sources the typed keyboards of `hyprctl devices -j` carry: the main one's, else the first one's (every keyboard has the
// same list unless one was given its own). [] for anything that is not that reply.
function chosenKeyboard(text) {
    let json;
    try {
        json = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    const keyboards = json && Array.isArray(json.keyboards) ? json.keyboards.filter(k => k && typeof k.name === "string" && !UNTYPED.test(k.name) && typeof k.layout === "string") : [];
    return keyboards.find(k => k.main === true) || keyboards[0] || null;
}

function parseDevices(text) {
    const chosen = chosenKeyboard(text);
    return chosen ? sources(chosen.layout, chosen.variant) : [];
}

// The name of the layout that keyboard has in use now ("French", xkb's name), "" for none: after the configuration was read
// again no `activelayout` event says it.
function parseActive(text) {
    const chosen = chosenKeyboard(text);
    return chosen && typeof chosen.active_keymap === "string" && named(chosen.active_keymap) ? chosen.active_keymap : "";
}

// xkb's base.lst: {"fr": "French", "fr:bepo": "French (Bepo)"}, the English names of the layouts and variants.
function parseNames(text) {
    const names = {};
    let section = "";
    for (const line of String(text === undefined || text === null ? "" : text).split("\n")) {
        const head = /^!\s*(\w+)/.exec(line);
        if (head) {
            section = head[1];
            continue;
        }
        if (section === "layout") {
            const m = /^\s+(\S+)\s+(.+?)\s*$/.exec(line);
            if (m)
                names[m[1]] = m[2];
        } else if (section === "variant") {
            const m = /^\s+(\S+)\s+([a-z][a-z0-9_-]*):\s+(.+?)\s*$/.exec(line);
            if (m)
                names[m[2] + ":" + m[1]] = m[3];
        }
    }
    return names;
}

// The name of a source in the menu: xkb's description, else its codes.
function sourceName(source, names) {
    const key = source.variant ? source.layout + ":" + source.variant : source.layout;
    return (names && names[key]) || key;
}

// The key of a source in the translated names: "fr" or "fr:bepo".
function sourceKey(source) {
    return source.variant ? source.layout + ":" + source.variant : source.layout;
}

// The helper's answer for several names at once (layout-names.py prints one line per name, in the order given): {key: translated}
// for the sources, the English name for a line that is missing or unreadable. Only the names the helper was asked for are taken.
function parseTranslations(output, sourcesList, names) {
    const lines = String(output === undefined || output === null ? "" : output).split("\n");
    const out = {};
    sourcesList.forEach((s, i) => {
        const line = (lines[i] || "").trim();
        out[sourceKey(s)] = line === "" || line.length > 128 ? sourceName(s, names) : line;
    });
    return out;
}

// The short label the menu bar shows (macOS shows the source's flag or abbreviation): the layout's code in capitals, "FR", "US";
// a variant of a layout another source also uses adds its own ("FR bepo"), so two sources never show the same label.
function label(source, all) {
    const code = source.layout.toUpperCase();
    const twin = (all || []).some(s => s !== source && s.layout === source.layout);
    return twin && source.variant ? code + " " + source.variant : code;
}

// The position of the source the compositor named. `previous` is the position known before (-1 for none). The name is xkb's
// own: it equals the description of base.lst for a layout, and often not for a variant, so a name that matches none exactly
// is matched on the words before its first parenthesis; when several still fit, the first other than `previous`.
function activeIndex(all, names, name, previous) {
    const wanted = String(name === undefined || name === null ? "" : name).trim();
    const known = previous >= 0 && previous < all.length ? previous : 0;
    if (wanted === "" || all.length === 0)
        return known;
    const exact = [];
    const loose = [];
    const base = s => s.replace(/\s*\(.*$/, "");
    all.forEach((s, i) => {
        const described = sourceName(s, names);
        if (described === wanted)
            exact.push(i);
        else if (base(described) === base(wanted))
            loose.push(i);
    });
    const fit = exact.length > 0 ? exact : loose;
    if (fit.length === 0)
        return known;
    if (fit.length === 1)
        return fit[0];
    return fit.find(i => i !== previous) ?? fit[0];
}

// The position `by` steps from `index` (-1 previous, 1 next), around the list.
function stepIndex(index, count, by) {
    if (count <= 0)
        return 0;
    return ((index + by) % count + count) % count;
}

// The request that makes the source at `index` the one in use on every keyboard ("all": a keyboard plugged in later has the
// same list, a switch that named one keyboard would leave the others behind). null for a position that is not one.
function switchRequest(index, count) {
    if (!Number.isInteger(index) || index < 0 || index >= count)
        return null;
    return "switchxkblayout all " + index;
}

// Whether the Input menu is shown: two sources or more (macOS: on by default as soon as there are two).
function menuShown(count, enabled) {
    return enabled !== false && count >= 2;
}
