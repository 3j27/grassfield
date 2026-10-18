.pragma library

// Keyboard focus of the desktop icons surface, macOS model (docs/decisions/ADR-0012-desktop-focus-model.md,
// docs/specs/desktop.md "Keyboard focus"): a pure state machine. Hyprland decides who holds the keyboard;
// this only decides what the surface ASKS for (keyboard interactivity) and when its own actions may run.
//
// Modes:
//   "idle"  - keyboard interactivity None. Hover never takes the keyboard.
//   "armed" - a press asked for OnDemand; waiting for Hyprland to grant the keyboard (a transient 1x1 surface
//             "kicks" Hyprland so no pointer motion is needed). Gives up after a timeout (pointer over a window).
//   "held"  - the surface has the keyboard: the desktop keyboard actions (arrows, Return, ...) are active.
//   "menu"  - the context menu (a PopupWindow with a grab) holds the keyboard; the surface stays OnDemand so
//             that the keyboard is back on it when the menu closes.
//
// Events ({type, ...}):
//   press                 a left press on the desktop surface
//   keys {hasKeys}        the surface gained / lost the keyboard (activeFocus)
//   pointerLeft           the pointer left the surface (onto a window, another output, the Dock)
//   armTimeout            the keyboard was not granted in time
//   menuOpened            the context menu was opened
//   menuClosed {how}      how: "esc" | "item" (closed by the user: the keyboard is back on the surface)
//                         or "outside" (dismissed by a click elsewhere: swallowed by the compositor)
// Anything else changes nothing.

function initial() {
    return {
        mode: "idle"
    };
}

function make(mode) {
    return {
        mode: mode
    };
}

// Layer-shell keyboard interactivity of the surface: "none" | "ondemand".
function interactivity(state) {
    return state.mode === "idle" ? "none" : "ondemand";
}

// The transient kicker surface is mapped.
function kicking(state) {
    return state.mode === "armed";
}

// The desktop keyboard actions may run.
function keysActive(state) {
    return state.mode === "held";
}

// After an outside dismissal the surface drops to None and arms again: the keyboard comes back to the desktop
// only when Hyprland finds the pointer on the bare desktop, not when it is on a window.
function rearmAfter(event) {
    return event.type === "menuClosed" && event.how === "outside";
}

function next(state, event) {
    const m = state.mode;
    switch (event.type) {
    case "press":
        return m === "idle" ? make("armed") : state;
    case "keys":
        if (event.hasKeys === true)
            return m === "armed" ? make("held") : state;
        return m === "held" ? make("idle") : state;
    case "pointerLeft":
        return m === "held" || m === "armed" ? make("idle") : state;
    case "armTimeout":
        return m === "armed" ? make("idle") : state;
    case "menuOpened":
        return make("menu");
    case "menuClosed":
        if (m !== "menu")
            return state;
        return event.how === "outside" ? make("idle") : make("held");
    default:
        return state;
    }
}
