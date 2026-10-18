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
//     on_demand after the press (the shell switches None -> OnDemand on that press), without any pointer motion;
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

    // The desktop surface that a press armed (AwaitOnDemand), until it commits on_demand, another press arrives, the
    // surface goes away or kGrantWindow elapses. Surfaces are opaque ids (compared, never dereferenced).
    class CPendingGrant {
      public:
        void arm(uint64_t surface, TimePoint now);
        void cancel();

        // A commit of `surface` with `interactivity` at `now`: true when the keyboard must be given to it now (the grant
        // is consumed). A commit of another surface, or one still without on_demand, keeps the grant waiting; an
        // expired grant is dropped.
        bool onCommit(uint64_t surface, Interactivity interactivity, TimePoint now);

        // Armed and not expired at `now`.
        bool armed(TimePoint now) const;

        // The armed surface (even if expired), for cleanup when that surface goes away.
        std::optional<uint64_t> surface() const;

      private:
        std::optional<uint64_t> m_surface;
        TimePoint               m_deadline{};
    };

} // namespace gf::desktopfocus
