.pragma library

// Keyboard focus of the desktop icons surface (docs/specs/desktop.md, "Keyboard focus"): a pure
// state machine. The host (DesktopIcons.qml) maps the mode to the layer-shell keyboard
// interactivity (interactivity()) and dispatches `focus` (a validated window address) when set.
//
// Modes:
//   "none" - None (default). The desktop never has the keyboard; hovering it changes nothing.
//   "hold" - OnDemand. The user pressed the desktop surface (icon or empty space): it holds the keyboard.
//   "take" - Exclusive, briefly. Hyprland 0.56 gives an OnDemand layer the keyboard only on pointer
//            motion, so a click without motion (and the return from Glance) takes it explicitly with
//            one Exclusive commit; the host reports "keys" (keyboard arrived) or "committed" (the
//            commit went out) and the mode becomes "hold".
//   "menu" - None while the icon / desktop menu is open: the MENU window holds the keyboard
//            (Exclusive) and the pointer. Hyprland routes the pointer only to an Exclusive layer, so an
//            Exclusive desktop would swallow every hover and click meant for the menu.
//            Closing: the desktop takes the keyboard back first ("take" with `menu` set, the menu
//            window stays mapped and keyboard-less meanwhile) and the menu unmaps only once the desktop
//            has it, so no moment exists in which Hyprland falls back to another window.
//
// State fields besides the mode:
//   away      - the pointer is off the desktop surface and no rename, menu or drag keeps it there.
//               Hyprland does not move the keyboard when the user clicks the window it still counts
//               as focused (processMouseDownNormal refocuses only a different window), so the desktop
//               lets go of the keyboard as soon as the pointer leaves it: Hyprland then gives it back
//               to that window, which is what the click would have done.
//   lent      - address of a window that returns the keyboard when it closes (Glance opened from the
//               desktop), "" if none.
//   lendNext  - Glance is being opened: the desktop let go of the keyboard first, so Hyprland focuses
//               the new window itself (an explicit focus request would also warp the pointer into it);
//               the next window that maps on the focused workspace with returnsFocus becomes `lent`.
//   active    - address of the window Hyprland counts as active (last activewindowv2), "" if unknown. The
//               desktop holding the keyboard does not change it. When that window closes by itself,
//               Hyprland's fallback focus would take the keyboard from the desktop: it is re-taken.
//   menu      - "take" was started by the menu closing: the menu window stays mapped (menuLingers()).
//   reclaim   - "take" was started because the lent window closed: the activation Hyprland reports
//               for its own fallback window meanwhile is ignored.
//
// Events ({type, ...}):
//   press                                     pointer press on the desktop surface
//   release {hasKeys}                         pointer release on the desktop surface
//   pointer {away}                            the pointer left / came back (see `away`)
//   keys {hasKeys}                            the surface gained or lost the keyboard
//   committed                                 the Exclusive commit of "take" was sent
//   menuOpened / menuClosed                   icon or desktop menu shown / hidden
//   renameOpened                              the user opened a rename field
//   itemOpened                                an item was opened (double click, Return, menu Open)
//   previewOpened                             Glance is being opened for the selection (Space)
//   escape {hasSelection, renaming}           Esc reached the desktop
//   hover                                     pointer motion (never changes anything)
//   openWindow {address, workspace, focusedWorkspace, returnsFocus}   Hyprland openwindow
//   activeWindow {address}                    Hyprland activewindowv2 ("" = no window)
//   closeWindow {address}                     Hyprland closewindow
//   workspace                                 the focused workspace changed
//   seedActive {address}                      the window Hyprland counts as active, from its state (at
//                                             startup, when `activewindowv2` was missed); only fills `active` when it is unknown
//
// next(state, event) -> {state, focus}: `focus` is "" or a validated lowercase hex address to focus.

function initial() {
    return make("none", {
        away: true
    });
}

// Validated lowercase hex of a Hyprland window address ("0x" prefix optional), "" if invalid.
function normalizeAddress(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// Hyprland `openwindow` data "<address>,<workspace name>,<class>,<title>" (the title may contain
// commas): {address (validated), workspace, appClass}, or null.
function parseOpenWindow(data) {
    const parts = String(data).split(",");
    if (parts.length < 3)
        return null;
    const address = normalizeAddress(parts[0]);
    if (address === "" || parts[1] === "")
        return null;
    return {
        address: address,
        workspace: parts[1],
        appClass: parts[2]
    };
}

// Layer-shell keyboard interactivity for a state: "none" | "onDemand" | "exclusive".
function interactivity(state) {
    switch (state.mode) {
    case "hold":
        return "onDemand";
    case "take":
        return "exclusive";
    default:
        return "none";
    }
}

// True while the desktop owns (or is taking) the keyboard: only then does it move focus to its key sink.
// (In "menu" the menu window owns the keyboard, but the desktop is where it returns to.)
function holdsKeys(state) {
    return state.mode !== "none";
}

// The menu window is mapped (besides while the menu is open) until the desktop has the keyboard back.
function menuLingers(state) {
    return state.mode === "take" && state.menu === true;
}

// A state with `mode`; the other fields default to "nothing pending", `away` is kept from `from`.
function make(mode, fields, from) {
    return Object.assign({
        mode: mode,
        away: from ? from.away : true,
        lent: "",
        lendNext: false,
        reclaim: false,
        menu: false,
        active: from ? from.active : ""
    }, fields || {});
}

// Back to "hold" after taking the keyboard or closing the menu, or straight to "none" when the
// pointer has meanwhile left the desktop.
// After the menu closed, the pointer is reported as away only because the (still mapped) menu window
// covers the desktop: the desktop holds the keyboard whatever `away` says, and `away` restarts from
// "here" (the desktop's pointer events correct it once the menu window has unmapped).
function held(s, fields) {
    if (s.menu === true)
        return make("hold", Object.assign({
            away: false
        }, fields), s);
    return make(s.away ? "none" : "hold", fields, s);
}

function to(state, focus) {
    return {
        state: state,
        focus: focus || ""
    };
}

function next(state, event) {
    const s = state;
    switch (event.type) {
    case "press":
        // The opening right press of a menu, or a press while the keyboard is being taken: unchanged.
        return to(make(s.mode === "menu" || s.mode === "take" ? s.mode : "hold", {
            away: false,
            menu: s.menu
        }, s));
    case "release":
        // A click without pointer motion: the OnDemand surface has not received the keyboard.
        if (s.mode === "hold" && !event.hasKeys)
            return to(make("take", {
                lent: s.lent
            }, s));
        return to(s);
    case "pointer":
        {
            const away = event.away === true;
            if (away && s.mode === "hold")
                return to(make("none", {
                    away: true,
                    lent: s.lent
                }, s));
            return to(Object.assign({}, s, {
                away: away
            }));
        }
    case "keys":
        if (event.hasKeys && s.mode === "take")
            return to(held(s, {
                lent: s.lent
            }));
        // Another surface took the keyboard (a launcher, a popup): OnDemand must not stay armed,
        // or the next pointer motion over the desktop would take the keyboard back.
        if (!event.hasKeys && s.mode === "hold")
            return to(make("none", {
                lent: s.lent
            }, s));
        return to(s);
    case "committed":
        if (s.mode === "take")
            return to(held(s, {
                lent: s.lent
            }));
        return to(s);
    case "menuOpened":
        return to(make("menu", {}, s));
    case "menuClosed":
        // The desktop takes the keyboard back before the menu window unmaps (even if the pointer has
        // left it: Hyprland would otherwise fall back to the last window when the menu unmaps).
        if (s.mode === "menu")
            return to(make("take", {
                menu: true
            }, s));
        return to(s);
    case "renameOpened":
        if (s.mode === "none")
            return to(make("take", {
                lent: s.lent
            }, s));
        return to(s);
    case "itemOpened":
        // Released before the opened window maps, so Hyprland focuses it itself.
        return to(make("none", {}, s));
    case "previewOpened":
        return to(make("none", {
            lendNext: true
        }, s));
    case "escape":
        if (!event.hasSelection && !event.renaming && s.mode !== "menu")
            return to(make("none", {}, s));
        return to(s);
    case "openWindow":
        {
            // A window mapping while the desktop holds the keyboard gets no focus from Hyprland
            // (a focused OnDemand layer suppresses the initial focus), and releasing alone would make
            // Hyprland fall back to the previously focused window: focus the new one explicitly, but
            // only on the focused workspace (never switch workspaces or override a silent rule).
            const address = normalizeAddress(event.address);
            const onScreen = address !== "" && event.workspace !== "" && event.workspace === event.focusedWorkspace;
            const target = s.mode !== "none" && onScreen ? address : "";
            const lends = event.returnsFocus === true && (target !== "" || (s.lendNext && onScreen));
            return to(make("none", {
                lent: lends ? address : ""
            }, s), target);
        }
    case "activeWindow":
        {
            const address = normalizeAddress(event.address);
            if (address === "") {
                // No window is active any more (the last one closed).
                return to(event.address === "" ? Object.assign({}, s, {
                    active: ""
                }) : s);
            }
            // The menu window is taking the keyboard from the desktop (or the desktop from the menu window):
            // Hyprland reports the window it falls back to meanwhile. It is only remembered, or the
            // desktop would never take the keyboard back when the menu closes.
            if (s.mode === "menu" || menuLingers(s))
                return to(Object.assign({}, s, {
                    active: address
                }));
            // Hyprland's own fallback focus while the keyboard comes back from the lent / closed window.
            if (s.mode === "take" && s.reclaim)
                return to(Object.assign({}, s, {
                    active: address
                }));
            // Hyprland's fallback focus right after the release for Glance keeps lendNext.
            return to(make("none", {
                lent: address === s.lent ? s.lent : "",
                lendNext: s.lendNext,
                active: address
            }, s));
        }
    case "closeWindow":
        {
            const address = normalizeAddress(event.address);
            // The lent window closed: the keyboard comes back to the desktop, unless the pointer has
            // left it (then Hyprland's choice stands).
            if (address !== "" && address === s.lent)
                return to(s.away ? make("none", {}, s) : make("take", {
                    reclaim: true
                }, s));
            // The window Hyprland counts as active closed while the desktop holds the keyboard (a click
            // on the desktop does not change that): Hyprland's fallback focus would hand the keyboard
            // to another window, so the desktop takes it again once the fallback is reported.
            if (address !== "" && address === s.active && !s.away && (s.mode === "hold" || s.mode === "take"))
                return to(make("take", {
                    reclaim: true,
                    active: ""
                }, s));
            // Any other window: Hyprland moves the keyboard itself when the closed window had it and
            // reports it with activewindowv2. Releasing here would make Hyprland hand the keyboard of
            // the desktop to the previously focused window (refocusLastWindow).
            return to(s);
        }
    case "workspace":
        return to(make("none", {}, s));
    case "seedActive":
        // Only fills a gap: Quickshell updates its toplevel before the raw events of the same change
        // arrive, so a seed must never override what the events say.
        return to(s.active === "" ? Object.assign({}, s, {
            active: normalizeAddress(event.address)
        }) : s);
    default:
        return to(s);
    }
}
