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
