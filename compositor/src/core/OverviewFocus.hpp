#pragma once

// Overview close focus (feature "overview-focus", owner decision 2026-10-19 batch 5; docs/specs/overview.md "Close
// focus"): when the Overview starts closing, the shell names what gets the keyboard (the window or the Desktop the user
// chose, or the window remembered at open); the plugin makes that focus at the moment Hyprland accepts window focus again
// (no Exclusive layer surface left: every output's chrome released, no dialog; the session not locked), checked again
// then, through Hyprland's own focus path. Hyprland 0.56.2 refuses every window focus while an Exclusive layer is mapped
// and does not retry when the last one goes ("refocusLastWindow: ignoring, exclusive LS present"), and the protocol
// activate does nothing for the window it still counts focused: with two outputs the keyboard was lost after a close.
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/OverviewFocusTest.cpp); the Hyprland glue
// is OverviewFocus.* on top of the deferred focus shared with Stages (DeferredFocus.*, core/DeferredFocus.*).

#include "DeferredFocus.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::overviewfocus {

    using WindowId    = uint64_t; // Hyprland window address (compared, never dereferenced)
    using WorkspaceId = int64_t;  // regular workspaces only (positive ids)

    // Limits of hl.plugin.grassfield.overview_focus(json) (untrusted input).
    inline constexpr size_t      kMaxPayloadBytes = 512;
    inline constexpr size_t      kMaxStringBytes  = 64;
    inline constexpr int         kMaxDepth        = 4;
    inline constexpr WorkspaceId kMaxWorkspaceId  = 2147483647;
    inline constexpr uint64_t    kMaxRequestId    = 4294967295;

    // How long a request waits for Hyprland to accept window focus again; then it ends with outcome "timeout" (nothing is
    // focused by the plugin: Hyprland's own refocus stands).
    inline constexpr std::chrono::milliseconds kBound{1000};

    // ---- requests ----

    enum class Target : uint8_t {
        Window,     // the user chose a window
        Workspace,  // the user chose a Desktop (also the Desktop created with "+" while open)
        Remembered, // no choice: the window that had the keyboard when the Overview opened, and its Desktop
        None,       // no choice and nothing remembered (the desktop or nothing had the keyboard at open)
        Press,      // never requested: a press beside every Exclusive layer, on a window, after the request (it wins)
    };

    // "window", "workspace", "remembered", "none", "press".
    std::string_view targetName(Target target);

    struct Request {
        Target      target    = Target::None;
        WindowId    window    = 0; // Window, Remembered (and Press)
        WorkspaceId workspace = 0; // Workspace (required), Remembered (optional: 0 when not given)
        uint32_t    id        = 0; // the shell's request id, echoed in the events (0 when not given)
    };

    // Parses and validates {"target":"window","address":"0x…"}, {"target":"workspace","workspace":N},
    // {"target":"remembered","address":"0x…","workspace":N?}, {"target":"none"}, each with an optional "id":N. Strict: a JSON
    // object of at most kMaxPayloadBytes; `target` required; an address "0x" (optional) + 1-16 hex digits, not 0; workspace an integer
    // 1..kMaxWorkspaceId; id an integer 0..kMaxRequestId; a field the target does not use (an address for a Desktop, a
    // Desktop for a chosen window, anything for none) is an error; unknown keys are skipped (additive gfc/1 fields); a key
    // given twice is an error. Whether the window or the Desktop exists is checked by the glue when the focus is made.
    std::expected<Request, std::string> parseRequest(std::string_view json);

    // ---- when ----

    struct Gate {
        bool locked    = false; // the session is locked
        bool exclusive = false; // an Exclusive layer surface is mapped (Hyprland's Exclusive-layer list is not empty)
        bool expired   = false; // kBound has passed since the request
    };

    enum class Step : uint8_t {
        Wait,    // Hyprland refuses window focus (an Exclusive layer): try again on the next layer change, key or the bound
        Apply,   // Hyprland accepts window focus: make the focus now
        Refuse,  // the session is locked: nothing is focused (Hyprland refocuses itself after the unlock)
        Timeout, // an Exclusive layer stayed past the bound (a dialog opened during the close): nothing is focused
    };

    Step step(const Gate& gate);

    // ---- what ----

    // The named window (Window, Remembered, Press) when Hyprland accepts window focus again.
    struct WindowFacts {
        bool exists    = false; // a mapped window with that address
        bool hidden    = false; // Hyprland hides it (CWindow::isHidden)
        bool minimized = false; // on a special workspace (Grassfield minimizes to special:minimized)
        bool shown     = false; // its workspace is the one shown on its monitor
    };

    enum class WindowVerdict : uint8_t { Eligible, Gone, Hidden, Minimized, NotShown };

    WindowVerdict judgeWindow(const WindowFacts& facts);

    // The named Desktop (Workspace).
    struct WorkspaceFacts {
        bool exists = false; // a regular workspace with that id
        bool shown  = false; // shown on its monitor
    };

    enum class Plan : uint8_t {
        FocusWindow,     // the named window
        Front,           // the named Desktop is shown: its front window, else no window
        SwitchThenFront, // the named Desktop is not shown: switch to it (Hyprland's own path), then its front window, else
                         // no window
        Fallback,        // the target is gone, minimized, hidden or not shown, or none was named: the front window of the
                         // fallback Desktop (fallbackSpace), else no window (the desktop)
    };

    struct PlanResult {
        Plan             plan = Plan::Fallback;
        std::string_view why; // Fallback: "gone", "hidden", "minimized", "not-shown", "no-workspace", "none"
    };

    PlanResult plan(Target target, WindowVerdict window, const WorkspaceFacts& workspace);

    // The Desktop whose front window a fallback picks: the remembered Desktop when it is still shown (macOS: leaving
    // Mission Control returns to the Desktop you were on), else the Desktop shown on the focused monitor.
    enum class FallbackSpace : uint8_t { Remembered, FocusedMonitor };

    FallbackSpace fallbackSpace(Target target, bool rememberedShown);

    // A window of Hyprland's stacking order, as a candidate for a Desktop's front window.
    struct Candidate {
        WindowId id          = 0;
        bool     onWorkspace = false; // on the Desktop asked for
        bool     mapped      = false;
        bool     hidden      = false; // CWindow::isHidden
        bool     takesInput  = false; // CWindow::acceptsInput (a Stages strip window or an inactive group member does not)
        bool     focusable   = false; // not an X11 window that refuses focus
        uint64_t focusSeq    = 0;     // when it last took focus (higher: more recent; 0: not since the plugin loaded)
    };

    // The windows to try, in order, for a Desktop's front window (macOS: the front-most window is the one activated last):
    // the eligible windows by their last focus (most recent first), then the eligible windows not focused since the load
    // from the top of the stack down. Hyprland does not raise a floating window on every focus, so the stack alone is not
    // the activation order, and its CWorkspace::m_lastFocusedWindow is not either: CFocusState::rawWindowFocus sets it to the
    // window it was asked for before it refuses the focus (an Exclusive layer), e.g. its successor of a window closed under
    // the Overview chrome (measured: tests/compositor/overview_focus.sh case 8). Eligible: on that Desktop, mapped, not
    // hidden, taking input, focusable. Hyprland may still refuse one (a no_focus rule): the glue tries the next.
    std::vector<WindowId> frontOrder(std::span<const Candidate> bottomToTop);

    // ---- the user's input while a request waits ----

    enum class PressEffect : uint8_t {
        None,      // a press into an Exclusive layer (the chrome, a dialog): it chooses nothing
        Supersede, // a press while Hyprland accepts window focus: Hyprland's click handling decides; the request ends
        Retarget,  // a press beside every Exclusive layer, on a window: that window takes the focus once the layers are gone
    };

    PressEffect pressEffect(const gf::deferredfocus::PressRecord& press);

    // Hyprland focused a window while a request waits: a user choice (a key binding, a dispatch, an activation, a real
    // click) of another window ends the request; Hyprland's own picks (its refocus after a layer, a restore) do not.
    bool supersedes(gf::deferredfocus::FocusOrigin origin, bool isTarget);

    // ---- events ----

    enum class Outcome : uint8_t {
        Pending,     // the request waits for Hyprland to accept window focus
        Focused,     // the named target holds the keyboard (a Desktop target: its front window, or no window)
        Fallback,    // the target was gone, minimized, hidden or not shown (or none was named, or Hyprland refused it): the
                     // fallback's front window holds the keyboard, or no window (the desktop)
        Timeout,     // an Exclusive layer stayed past kBound: nothing focused by the plugin
        Refused,     // the session is locked: nothing focused
        Superseded,  // the user chose something else first (a press, a key binding, a dispatch), or a newer request came
        Unavailable, // the plugin is unloading
        Invalid,     // the request failed validation: nothing changes (a waiting request keeps waiting)
    };

    // "pending", "focused", "fallback", "timeout", "refused", "superseded", "unavailable", "invalid".
    std::string_view outcomeName(Outcome outcome);

    struct Event {
        Outcome                    outcome = Outcome::Pending;
        Target                     target  = Target::None;
        uint32_t                   id      = 0;
        std::optional<WindowId>    window;    // the window that holds the keyboard (focused, fallback); absent: none
        std::optional<WorkspaceId> workspace; // the Desktop of that window, or the Desktop shown without a window
        std::string_view           reason;    // why (fallback, refused, timeout, superseded); empty: none
    };

    // {"v":"gfc/1","type":"overview-focus","outcome":"…","target":"…","id":N}, plus "address":"<hex, no 0x>" when a window
    // holds the keyboard, "workspace":N and "reason":"…" when known.
    std::string eventJson(const Event& event);

} // namespace gf::overviewfocus
