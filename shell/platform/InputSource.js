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

// Next state and whether to show the HUD. state: {last: {keyboard: layout}}. Show when the keyboard had a different layout.
function step(state, event) {
    const last = Object.assign({}, state && state.last ? state.last : {});
    const known = last[event.keyboard];
    last[event.keyboard] = event.layout;
    return {state: {last: last}, show: known !== undefined && known !== event.layout};
}
