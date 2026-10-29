.pragma library

// Which output a shell surface opens on when nobody named one (SUPER+N, IPC, keyboard): macOS opens Notification
// Center, Spotlight, Mission Control... on the active display. One rule for every such surface
// (`Compositor.activeScreenName`): the requested output when it exists, else the output with the keyboard or pointer
// focus, else the first output as a last resort, else "".

// `requested`: an output name or ""; `focused`: the compositor's focused output or ""; `names`: the outputs that exist.
function pick(requested, focused, names) {
    if (requested !== "" && names.indexOf(requested) >= 0)
        return requested;
    if (focused !== "" && names.indexOf(focused) >= 0)
        return focused;
    return names.length > 0 ? names[0] : "";
}

// Where a centred popup (confirm, notice) opens: on the output of the popup that is open right now (a menu on display B
// asks "Restart?" on B), else on the active display. A popup that was closed leaves no screen behind.
// `requested` (optional): the display of the panel that asked (Search's panel), which wins over both.
function centered(popupOpen, popupScreen, activeScreen, requested) {
    if (typeof requested === "string" && requested !== "")
        return requested;
    return popupOpen && popupScreen !== "" ? popupScreen : activeScreen;
}

// True when `name` is non-empty and no existing output has it any more (an output unplugged while something was open on it):
// the owner of that state moves it to `Compositor.activeScreenName`.
function gone(name, names) {
    return typeof name === "string" && name !== "" && (Array.isArray(names) ? names : []).indexOf(name) < 0;
}

// A popup of kind `kind` belongs to something on its own output (a window's tiling popover under its zoom light, the
// suggestions in a layout's empty zone: docs/specs/tiling.md TL22, TL28): it closes when that output goes, instead of
// moving to another output that does not show what it offers (integrator merge note on #48). Every other popup moves.
function closesWithScreen(kind) {
    return kind === "tiling" || kind === "tilingSuggest";
}

// The output a piece of state moves to when its own output (`current`) went away: the output with the focus if it still exists,
// else the first one; `current` itself when it is still there (nothing to move) or empty. Everything is read from the arguments:
// a handler of "the outputs changed" gets the live names and the focus at that moment, never `Compositor.activeScreenName`
// (a binding of the same change, which Qt may not have re-evaluated yet: the handler saw the removed output's name).
function replacement(current, focused, names) {
    if (!gone(current, names))
        return current;
    return pick("", typeof focused === "string" ? focused : "", Array.isArray(names) ? names : []);
}
