.pragma library

// Keyboard focus of the desktop icons surface, SAFE MODE (docs/specs/desktop.md, "Keyboard safe mode
// (2026-10-17)"): a pure state machine. The desktop surface never holds the keyboard on its own: its
// keyboard interactivity is None except while a rename field is active. The context menu has its own
// window, which holds the keyboard (Exclusive) while the menu is open. After either ends, nobody
// re-takes the keyboard: it is whatever Hyprland decides, as with a plain wallpaper.
//
// Modes:
//   "idle"   - nothing holds the keyboard (desktop None, menu window None and unmapped).
//   "menu"   - the menu window is mapped and Exclusive (arrows, Return, Esc).
//   "rename" - the desktop surface is Exclusive (inline rename field).
//
// Hand-off menu -> rename (`handoff`), so no keystroke can fall through to another window between the two:
//   "commit" - the desktop is Exclusive and committing, the menu window is still mapped and Exclusive
//              (it is the higher layer, so it keeps the keyboard until it lets go).
//   "map"    - the commit is out: the menu window is None but still mapped, so Hyprland has no reason to
//              refocus another window; it unmaps once the desktop has the keyboard (or has certainly had
//              the time to receive it).
//   ""       - no hand-off in progress.
//
// Events ({type, ...}):
//   menuOpened             the icon / desktop menu was shown
//   menuClosed             the menu went away (Esc, item, click outside, a failed New Folder)
//   renameOpened           a rename field became active (from the menu: hand-off; otherwise direct)
//   renameClosed           the rename ended (commit, cancel, click outside, focus lost)
//   committed              the desktop's Exclusive commit of the hand-off was sent
//   keys {hasKeys}         the desktop surface gained or lost the keyboard
//   settled                the hand-off's grace period is over (the menu window may unmap)
// A press on a click catcher (another output) ends the menu / rename through the same menuClosed /
// renameClosed events as a click outside on the hosting output.
// Anything else (pointer motion, hover, a pointer on another monitor, window events) changes nothing.
//
// next(state, event) -> state.

function initial() {
    return {
        mode: "idle",
        handoff: ""
    };
}

function make(mode, handoff) {
    return {
        mode: mode,
        handoff: handoff || ""
    };
}

// Layer-shell keyboard interactivity of the desktop surface: "none" | "exclusive".
function interactivity(state) {
    return state.mode === "rename" ? "exclusive" : "none";
}

// The menu window is mapped: while the menu is open and during the hand-off to the rename field.
function menuMapped(state) {
    return state.mode === "menu" || state.handoff !== "";
}

// The menu window holds the keyboard (Exclusive): while the menu is open and until the desktop's commit is out.
function menuHoldsKeys(state) {
    return state.mode === "menu" || state.handoff === "commit";
}

// Click catchers (transparent Overlay surfaces, keyboard Exclusive so that they receive the pointer of their
// output) are mapped on every screen that does not host the menu / rename for as long as either is active,
// so a press on another output cancels it (an Exclusive layer swallows pointer input elsewhere). Unmapped
// again when the state is idle.
function catchersMapped(state) {
    return state.mode !== "idle";
}

// The catchers that must exist, given the state and the release phase (the catchers unmap before the menu /
// rename surface lets go of the keyboard). This is the ONLY input of the catcher model.
function catchersShown(state, releasing) {
    return catchersMapped(state) && !releasing;
}

// End of the release phase: the snapshots {kb, releasing} the surface walks through, in order. The final
// keyboard state is applied BEFORE the releasing flag is cleared, so no snapshot has a mapped state with
// releasing false unless `pending` itself is mapped: a catcher can never come back (briefly) during release
// (it would take the keyboard, be destroyed, and leave Hyprland with no surface to refocus).
function releaseEnd(pending) {
    return [
        {
            kb: pending,
            releasing: true
        },
        {
            kb: pending,
            releasing: false
        }
    ];
}

function next(state, event) {
    const s = state;
    switch (event.type) {
    case "menuOpened":
        return make("menu");
    case "menuClosed":
        // Only the open menu: a menu handing over to a rename already left "menu".
        return s.mode === "menu" ? make("idle") : s;
    case "renameOpened":
        if (s.mode === "menu")
            return make("rename", "commit");
        return s.mode === "rename" ? s : make("rename");
    case "renameClosed":
        return s.mode === "rename" ? make("idle") : s;
    case "committed":
        return s.handoff === "commit" ? make(s.mode, "map") : s;
    case "keys":
        // The desktop has the keyboard: the menu window may unmap. (Losing it ends nothing here: the
        // rename field cancels itself when it loses its focus.)
        return event.hasKeys === true && s.handoff === "map" ? make(s.mode) : s;
    case "settled":
        return s.handoff === "map" ? make(s.mode) : s;
    default:
        return s;
    }
}
