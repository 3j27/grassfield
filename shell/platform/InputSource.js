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
