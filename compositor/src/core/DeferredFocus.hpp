#pragma once

// Deferred focus (shared by Stages and the overview focus, docs/specs/stages.md ST10/ST23, docs/specs/overview.md
// "Close focus"): the decisions behind a focus the plugin cannot make yet because Hyprland 0.56.2 refuses every window
// focus while the session is locked or an Exclusive layer surface is mapped (CFocusState::rawWindowFocus: "Refusing a
// keyboard focus to a window because of a sessionlock / an exclusive ls"), and the decisions about which focus changes
// and presses are the user's. Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/); the
// Hyprland glue (DeferredFocus.*) reads Hyprland's state into these structs and schedules the attempts.

#include <cstdint>

namespace gf::deferredfocus {

    using WindowId = uint64_t; // Hyprland window address (compared, never dereferenced)

    // ---- Hyprland's refusal ----

    struct Refusal {
        bool locked      = false; // the session is locked
        bool exclusive   = false; // an Exclusive layer surface is mapped (Hyprland's Exclusive-layer list is not empty)
        bool holderKeeps = false; // the layer surface that held the keyboard when the focus was deferred still holds it (it
                                  // dropped its exclusivity and kept the keyboard: on_demand)
    };

    // A deferred focus waits while Hyprland refuses window focus (lock, Exclusive layer) or the layer surface that held the
    // keyboard keeps it. The plugin never works around the refusal (R13 counter-review #3 of e9ebc7f).
    bool mustWait(const Refusal& refusal);

    // ---- focus reasons ----

    // Hyprland 0.56.2's focus reasons (Desktop::eFocusReason), one to one; the glue maps them with an exhaustive switch.
    enum class FocusCause : uint8_t {
        Unknown,                // FOCUS_REASON_UNKNOWN (unused by Hyprland)
        PointerFollow,          // FFM: refocusLastWindow (an Exclusive layer released the keyboard), a popup grab ended,
                                // focus follows the pointer
        KeyBinding,             // KEYBIND: movefocus, focusmonitor, swap and similar dispatchers
        FocusDispatch,          // DISPATCH_FOCUSWINDOW: hl.dsp.focus({ window = … }) (Dock, Search, scripts)
        GroupDispatch,          // DISPATCH_MOVEWINDOWINTOGROUP
        Click,                  // CLICK: CInputManager::refocus, a refocus at the cursor: on a press (the hit test never picks
                                // a blocked window), group bar clicks, but also after an Exclusive layer unmapped with no
                                // active window, after the unlock, a popup grab ending, the last window of a Desktop closing
        Other,                  // OTHER: plugins (this one included) and the closing window's own notification
        Activation,             // DESKTOP_STATE_CHANGE: CWindow::activate (xdg-activation, foreign-toplevel activate from the
                                // shell's Dock), drags, layout and workspace swaps that refocus the current window
        SwitchSoft,             // SWITCH_TO_WINDOW_SOFT: cycle_next, focus { last }, focus { urgent_or_last }
        SwitchHard,             // SWITCH_TO_WINDOW_HARD: the same over a full-screen window
        GroupCurrentChange,     // GROUP_CURRENT_WINDOW_CHANGE: a group's current window changed under the focus
        WorkspaceChange,        // WORKSPACE_CHANGE: a Desktop switch focuses that Desktop's last focused window
        ToggleSpecialWorkspace, // TOGGLE_SPECIAL_WORKSPACE: a special workspace closed, its last window is refocused
        UnmapTiling,            // UNMAP_WINDOW_TILING: Hyprland's successor after a close
        UnmapFloating,          // UNMAP_WINDOW_FLOATING
        UnmapGrouped,           // UNMAP_GROUPED_WINDOW
        NewWindow,              // NEW_WINDOW: a window mapped (it takes focus, or the previous focus is restored)
        Ghosts,                 // GHOSTS (unused for focusing by Hyprland)
    };

    // Why Hyprland focused a window.
    enum class FocusOrigin : uint8_t {
        UserChoice,    // a key binding, a focus dispatch, an activation request (Dock, xdg-activation), a click (a real
                       // press): the user (or the app at the user's request) chose that window
        AfterClose,    // Hyprland's successor after a close or unmap (reasons UNMAP_*)
        Restore,       // Hyprland restoring a window it focused before: its last window (FFM: an Exclusive layer released
                       // the keyboard, a popup grab ended) or a Desktop's last focused window (WORKSPACE_CHANGE, special
                       // workspace closed)
        CursorRefocus, // Hyprland's refocus at the cursor without a press (CLICK): whatever lies under the pointer when an
                       // Exclusive layer unmapped with no active window, after the unlock, a grab ending, a Desktop emptied
        Automatic,     // Hyprland's own pick for another reason (a new window mapped, a group change, plugins, unknown)
    };

    // Hyprland 0.56.2 focuses a window of a Desktop that is not shown by switching to that Desktop first, which focuses
    // the Desktop's last focused window with WORKSPACE_CHANGE (CFocusState::rawWindowFocus sets it to the requested window
    // just before): a request for a window on another Desktop (Dock, activation) arrives as WORKSPACE_CHANGE. It is a
    // restore only when that window already was the last window Hyprland focused on that Desktop (`wasLastFocused`, tracked
    // by the glue from Hyprland's focus events); otherwise it is the redirected request, a user choice.
    // CLICK is a user choice only when a real press caused it (`pressed`, clickFromPress): Hyprland reports CLICK for every
    // refocus at the cursor (R13 counter-review #4 of 0.6.3-stages: when an Exclusive layer closed after a swap, the window
    // under the pointer took the keyboard from the swap's front window as if the user had clicked it).
    FocusOrigin focusOrigin(FocusCause cause, bool wasLastFocused, bool pressed);

    // ---- presses ----
    // Where a press (pointer button, touch down, tablet tip or button) goes, read when it arrives, before Hyprland handles
    // it. While an Exclusive layer surface is mapped Hyprland gives every press to it (CInputManager::mouseMoveUnified: the
    // exclusive layers come first, and one of them takes the press even when the cursor is outside it) and refuses window
    // focus; it refocuses at the cursor once the layer is gone.
    struct PressContext {
        bool     exclusive   = false; // an Exclusive layer surface is mapped
        bool     onExclusive = false; // the cursor is over one of them (its input region or one of its popups)
        WindowId under       = 0;     // the window Hyprland's hit test finds under the cursor (input-blocked windows skipped)
    };

    enum class PressScope : uint8_t {
        None,       // a press into an Exclusive layer (a dialog, Search): it chooses no window
        ThisPress,  // Hyprland refocuses at the cursor while it handles the press: a CLICK focus then is this press
        UntilFocus, // a press beside every Exclusive layer, on a window: the user clicked that window; Hyprland refocuses
                    // there only when the layer is gone, and that focus is the user's choice (macOS: a click outside a
                    // panel activates the window clicked)
    };

    struct PressRecord {
        PressScope scope  = PressScope::None;
        WindowId   target = 0; // UntilFocus: the window pressed
    };

    PressRecord recordPress(const PressContext& context);

    // Whether Hyprland's CLICK focus of `window` comes from the recorded press. ThisPress lasts while Hyprland handles the
    // press (the glue clears it from the event loop); UntilFocus until the next focus change, a deferred focus (a later
    // swap wins), or the refocus after the last Exclusive layer.
    bool clickFromPress(const PressRecord& press, WindowId window);

} // namespace gf::deferredfocus
