#pragma once

// Pointer focus on a Grassfield layer surface that maps or takes the keyboard under a resting pointer (gfc/1 feature
// "layer-pointer", spec FR51-FR52). Plain C++ with no Hyprland includes, so it is unit-testable
// (compositor/tests/LayerPointerTest.cpp); the glue is src/LayerPointer.cpp.
//
// Why (Hyprland 0.56.2, measured in the nested session and read from the binary): when a layer surface takes the keyboard
// (CLayerSurface::onMap for a layer mapped Exclusive or OnDemand, CLayerSurface::onCommit when a mapped layer becomes
// Exclusive or OnDemand) Hyprland gives it the pointer focus at once, with the surface-local position
// cursor - (layer geometry + monitor position). The layer geometry is already in layout coordinates, so on a monitor that
// is not at the layout origin the monitor offset is counted twice: the shell's menu overlay on GF-REF (x = 1440 in the
// nested session) was told the pointer at x - 1440. Hyprland corrects it only on the next motion that changes the
// cursor's whole-pixel position (CInputManager::mouseMoveUnified skips the rest otherwise), so a click without motion (a
// trackpad tap, a still mouse) was delivered outside the overlay and reached nothing the shell could see. A layer that
// maps without taking the keyboard gets no pointer focus at map (the surface below keeps it until the pointer moves).
// The plugin re-runs Hyprland's own pointer focus logic at the cursor afterwards (CInputManager::simulateMouseMovement,
// what Hyprland itself does when a layer unmaps): the surface under the cursor gets the pointer at the right position, as
// after one pixel of motion. Only for the shell's own namespaces ("grassfield-*"); nothing else changes.

#include <cstdint>
#include <string_view>

namespace gf::layerpointer {

    inline constexpr std::string_view kNamespacePrefix = "grassfield-";

    // A layer namespace of the Grassfield shell ("grassfield-overlay", "grassfield-menubar", ...): a non-empty name after
    // the prefix. Other clients' layers (and a bare "grassfield-") are left to Hyprland.
    bool isGrassfieldNamespace(std::string_view ns);

    enum class Step : uint8_t {
        None,     // nothing to do now
        Refresh,  // re-run Hyprland's pointer focus logic at the cursor now
        Wait,     // owed, but not now: no pointer device (Hyprland refuses any pointer focus change then) or a button is held
                  // (Hyprland keeps the pressed surface): done after the release or before the next press
        Schedule, // schedule an attempt from the event loop (after Hyprland has handled the event being delivered)
        Defer,    // owed, but over kMaxRefreshesPerSecond: the attempt runs again in budgetWaitMs() (still owed, still scheduled)
    };

    // At most this many refreshes from the event loop a second (a backstop: a loop this class does not foresee stays bounded
    // and the compositor keeps answering). Over it the refresh stays owed and is tried again when the second is over
    // (deferred, never dropped: a press would otherwise land at a stale position, FR51). A refresh before a press is the
    // user's and never waits.
    inline constexpr uint32_t kMaxRefreshesPerSecond = 20;

    // One refresh owed per burst of events: the first one schedules an attempt from the event loop (after Hyprland's own
    // handling has run, including the pointer focus it sets); more events before it runs join it.
    class CRefreshState {
      public:
        // A layer surface with namespace `ns` mapped. True when an attempt must be scheduled now (a Grassfield layer, none
        // scheduled yet, and not an effect of the refresh running now).
        bool     onLayerEvent(std::string_view ns);

        // The seat's keyboard went to `surface` (an opaque identity; 0 for none). `layerNs`: the namespace of the layer
        // surface it went to, empty for anything else (a window, a popup, nothing). Only a keyboard that MOVES to a
        // Grassfield layer owes a refresh: Hyprland sets the keyboard focus again on the surface that already has it on every
        // pointer focus refresh over an on-demand layer (the desktop icons), and counting that owed the next refresh, for
        // ever (stages.sh on 2026-10-23: 10 million refreshes, the compositor stopped answering). Returns as onLayerEvent.
        bool     onKeyboardFocus(uint64_t surface, std::string_view layerNs);

        // Around a refresh (Hyprland's pointer focus logic running now): what it causes is its own, not a new layer event.
        void     beginRefresh();
        void     endRefresh();

        // An event-loop attempt may refresh at `nowMs` (kMaxRefreshesPerSecond per one-second window); 0 when it may, else
        // the milliseconds until the window is over (the attempt is then tried again, the refresh still owed). Read only.
        uint64_t budgetWaitMs(uint64_t nowMs) const;
        // A refresh ran at `nowMs` (counted in its window, whatever started it).
        void     spend(uint64_t nowMs);
        // Event-loop attempts that had to wait for the next window.
        uint64_t deferred() const;


        // The scheduled attempt runs (or could not be scheduled: no event loop). Refresh (and nothing owed any more) when
        // a pointer device exists and no button is held; Wait otherwise; None when nothing is owed.
        Step     onAttempt(bool pointerDevice, bool buttonsHeld);
        // The event loop's attempt at `nowMs`: onAttempt, except Defer when it would refresh over the budget. Then the
        // refresh stays owed and the attempt stays scheduled (the caller runs it again in budgetWaitMs(nowMs); meanwhile a
        // new layer event schedules nothing more, and a press still refreshes at once: beforeButton has no budget).
        Step     attemptAt(bool pointerDevice, bool buttonsHeld, uint64_t nowMs);

        // A pointer button event, before Hyprland handles it. A press while a refresh is owed: Refresh now (the press is
        // then delivered at the right place) when a device exists and no other button is held, else None. A release while
        // a refresh is owed: Schedule (an attempt after Hyprland handled the release) unless one is scheduled already.
        Step     beforeButton(bool pressed, bool pointerDevice, bool buttonsHeld);

        // Forgets everything (unload, or a new load of the plugin).
        void     reset();

        bool     scheduled() const;
        bool     owed() const;
        uint64_t refreshes() const;

      private:
        bool     m_scheduled       = false; // an event-loop attempt is scheduled
        bool     m_owed            = false; // a Grassfield layer mapped or took the keyboard since the last refresh
        uint64_t m_refreshes       = 0;
        uint64_t m_keyboardSurface = 0;     // where the seat's keyboard was last seen going
        bool     m_inRefresh       = false;
        uint64_t m_windowStartMs   = 0; // the budget's one-second window
        uint32_t m_inWindow        = 0;
        uint64_t m_deferred        = 0;
    };

} // namespace gf::layerpointer
