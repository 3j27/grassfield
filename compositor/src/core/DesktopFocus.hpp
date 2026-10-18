#pragma once

// Desktop focus policy (feature "desktop-focus", ADR-0012 amendment, docs/specs/desktop.md "Compositor focus policy"):
// the macOS model for the shell's desktop surface, enforced on pointer presses. Plain C++ with no Hyprland includes, so
// it is unit-testable (compositor/tests/DesktopFocusTest.cpp); the glue (DesktopFocus.cpp) classifies Hyprland's
// surfaces into the kinds below and carries out the action.
//
// Rules (only on button presses; hover never moves the keyboard):
//   - a press on a normal window while the desktop holds the keyboard gives that window the keyboard, also when Hyprland
//     still counts it as its focused window (Hyprland 0.56.2 then ignores the click and the desktop kept the keys);
//   - a left press on the desktop surface gives it the keyboard at once when it is on_demand, or as soon as it commits
//     on_demand after the press (the shell switches None -> OnDemand on that press), without any pointer motion; that
//     pending grant is dropped when anything else moves the keyboard first (a key binding, a new window, a workspace
//     switch, Hyprland's own refocus), so a late commit never takes the keyboard back;
//   - the window's grant goes through Hyprland's own click focus only: when Hyprland refuses it (no_focus window rule, a
//     modal child, ...), the keyboard stays where it is;
//   - presses on other Grassfield layers (Dock, menu bar, widgets), on popups (the desktop's context menu included) and
//     anything while a keyboard grab, an Exclusive layer or the session lock is active change nothing.

#include <chrono>
#include <cstdint>
#include <optional>
#include <string_view>

namespace gf::desktopfocus {

    using Clock     = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    // Layer namespace of the shell's desktop surface (shell/desktop/DesktopIcons.qml), on any output.
    inline constexpr std::string_view kDesktopNamespace = "grassfield-desktop-icons";
    // Every Grassfield shell layer surface starts with this.
    inline constexpr std::string_view kShellNamespacePrefix = "grassfield-";
    // How long after a press on a not yet on_demand desktop its on_demand commit still gets the keyboard.
    inline constexpr std::chrono::milliseconds kGrantWindow{1000};

    // What a surface is for the policy.
    enum class SurfaceKind : uint8_t {
        None,         // no surface (nothing focused, pointer over nothing)
        Desktop,      // the desktop layer surface (kDesktopNamespace)
        DesktopPopup, // an xdg_popup of the desktop layer surface (its context menu)
        Window,       // a normal window: main surface, subsurface or its Grassfield titlebar
        WindowPopup,  // an xdg_popup of a window
        ShellLayer,   // another Grassfield layer surface (Dock, menu bar, widgets, overview...) or one of its popups
        OtherLayer,   // a layer surface of another client, or one of its popups
        Other,        // lock screen surface, cursor, unknown
    };

    // zwlr_layer_surface_v1 keyboard interactivity.
    enum class Interactivity : uint8_t {
        None,
        Exclusive,
        OnDemand,
    };

    // Seat state when a press arrives (or when a pending grant would be carried out).
    struct Seat {
        SurfaceKind keyboard       = SurfaceKind::None; // what holds the keyboard
        bool        keyboardGrab   = false;             // a keyboard grab is active (xdg_popup grab)
        bool        exclusiveLayer = false;             // a layer surface holds the keyboard with Exclusive interactivity
        bool        locked         = false;             // the session is locked
    };

    struct Press {
        SurfaceKind   target            = SurfaceKind::None; // what the press lands on
        Interactivity interactivity     = Interactivity::None; // of the target layer surface (Desktop only)
        bool          primary           = false;               // left button
        bool          targetHasKeyboard = false;               // the target surface already holds the keyboard
        bool          windowFocusable   = false;               // Window target: mapped, visible, may take focus
    };

    enum class Action : uint8_t {
        None,          // Hyprland's own handling only
        FocusWindow,   // give the keyboard to the pressed window
        FocusDesktop,  // give the keyboard to the pressed desktop surface now
        AwaitOnDemand, // give it to the pressed desktop surface when it commits on_demand (within kGrantWindow)
    };

    // The policy for one button press.
    Action onPress(const Seat& seat, const Press& press);

    // What the seat's pointer focus says when a press arrives.
    enum class PointerFocus : uint8_t {
        Live,  // a mapped, visible surface of a window or layer surface (a window that takes input)
        None,  // no pointer focus (nothing under the pointer, or its surface was destroyed: the weak reference expired)
        Stale, // a surface that is unmapped, invisible, no longer part of any window or layer (a closed popup), or of a
               // window whose input is blocked (a Stages strip window: Hyprland's hit test skips it)
    };

    // Classifies the seat's pointer focus: `present` a surface is focused; `known` it belongs to a window or layer surface;
    // `visible` that view is alive and visible; `takesInput` it is not a window whose input is blocked (always true for
    // layer surfaces).
    PointerFocus classifyPointerFocus(bool present, bool known, bool visible, bool takesInput);

    // Hyprland 0.56.2 updates pointer focus on pointer motion only: after a popup closes, a press without any motion still
    // finds the popup's (destroyed or unmapped) surface, or nothing, as pointer focus. The press target is then what lies
    // under the cursor (looked up by the glue in Hyprland's pointer focus order) instead.
    enum class TargetSource : uint8_t {
        PointerFocus, // the seat's pointer focus (where Hyprland delivers the press)
        UnderCursor,  // the window or layer surface under the cursor position
    };
    TargetSource pressTargetSource(PointerFocus focus);

    // The kind of the press target: `focusKind` (the seat's pointer focus, classified) when it is live, otherwise
    // `cursorKind` (the surface under the cursor, classified).
    SurfaceKind pressTargetKind(PointerFocus focus, SurfaceKind focusKind, SurfaceKind cursorKind);

    // A pending desktop grant may be carried out now (no lock, grab or Exclusive layer; the desktop does not hold the
    // keyboard already).
    bool mayGrantDesktop(const Seat& seat, bool desktopHasKeyboard);

    // "grassfield-desktop-icons" -> Desktop (DesktopPopup for one of its popups); "grassfield-..." -> ShellLayer;
    // anything else -> OtherLayer.
    SurfaceKind classifyLayer(std::string_view layerNamespace, bool popup);

    // Values of zwlr_layer_surface_v1.keyboard_interactivity (0 none, 1 exclusive, 2 on_demand); unknown -> None.
    Interactivity interactivityFromProtocol(uint32_t value);

    std::string_view actionName(Action action);
    std::string_view kindName(SurfaceKind kind);

    // Something other than the pending grant moved the keyboard, or changed what the user expects to type into, while a
    // grant waits for its on_demand commit (the glue maps Hyprland's event bus onto these).
    enum class FocusEvent : uint8_t {
        KeyboardFocus,    // the seat keyboard moved (to another surface, to nothing, or to the armed desktop itself)
        WindowActivated,  // Hyprland focused a window or cleared its window focus, for any reason (key binding, dispatch,
                          // activation request, a closing window's successor)
        WindowOpened,     // a window mapped
        WorkspaceChanged, // a workspace became active on a monitor
    };

    // What a FocusEvent did to the pending grant.
    enum class GrantUpdate : uint8_t {
        NotArmed,  // nothing was waiting (an expired grant is dropped silently)
        Fulfilled, // the keyboard reached the armed desktop by another path: nothing is left to do
        Cancelled, // the keyboard went elsewhere, or a window or workspace change superseded the press
    };

    std::string_view focusEventName(FocusEvent event);
    std::string_view grantUpdateName(GrantUpdate update);

    // The desktop surface that a press armed (AwaitOnDemand), until it commits on_demand, another press arrives, the
    // keyboard focus changes by any other path, the surface goes away or kGrantWindow elapses. Surfaces are opaque ids
    // (compared, never dereferenced).
    class CPendingGrant {
      public:
        void arm(uint64_t surface, TimePoint now);
        void cancel();

        // A commit of `surface` with `interactivity` at `now`: true when the keyboard must be given to it now (the grant
        // is consumed). A commit of another surface, or one still without on_demand, keeps the grant waiting; an
        // expired grant is dropped.
        bool onCommit(uint64_t surface, Interactivity interactivity, TimePoint now);

        // `event` happened at `now`; `keyboardLayer`: for KeyboardFocus, the id of the layer surface that holds the
        // keyboard now (nullopt: a window, nothing, or anything that is not a layer surface). Any focus change drops a
        // waiting grant: it is Fulfilled when the keyboard moved to the armed surface itself, otherwise Cancelled, so the
        // desktop's late on_demand commit can never take the keyboard from what a key binding, a new window or a
        // workspace switch chose.
        GrantUpdate onFocusEvent(FocusEvent event, std::optional<uint64_t> keyboardLayer, TimePoint now);

        // Armed and not expired at `now`.
        bool armed(TimePoint now) const;

        // The armed surface (even if expired), for cleanup when that surface goes away.
        std::optional<uint64_t> surface() const;

      private:
        std::optional<uint64_t> m_surface;
        TimePoint               m_deadline{};
    };

} // namespace gf::desktopfocus
