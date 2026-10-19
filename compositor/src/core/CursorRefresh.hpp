#pragma once

// Cursor refresh (gfc/1 feature "cursor-refresh"; Settings > Accessibility > Pointer, ADR-0014; spec FR39-FR40).
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/CursorRefreshTest.cpp); the glue is
// src/CursorRefresh.cpp.
//
// Why: Hyprland 0.56.2's `setcursor <theme> <size>` (CCursorManager::changeTheme) loads the theme at the new size but
// leaves the image on screen as it is until a client sets a shape again, so a pointer that does not move keeps the old
// size. The shell sends `setcursor`, then hl.plugin.grassfield.cursor_refresh(); the plugin re-applies the image
// Hyprland shows now the way Hyprland itself does when it shows a hidden pointer again (IHyprRenderer::setCursorHidden
// (false), read from the 0.56.2 binary): the last named shape, forced. Same shape, same place, new size.

#include "EventThrottle.hpp"

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace gf::cursor {

    // What Hyprland holds for the pointer image: IHyprRenderer::shouldRenderCursor() and m_lastCursorData.
    struct SCursorState {
        bool             shown       = false; // shouldRenderCursor(): not hidden by Hyprland and an image is set
        bool             fromSurface = false; // m_lastCursorData.surf has a value: a client's own surface (or none: hidden)
        bool             outputs     = false; // at least one monitor
        std::string_view name;                // m_lastCursorData.name: the last named shape (cleared by a surface)
    };

    enum class Outcome : uint8_t {
        Redraw,        // re-apply `name` with force: the same shape, drawn from the theme at its current size
        Hidden,        // nothing is drawn now; Hyprland draws from the theme (new size) when it shows the pointer again
        ClientSurface, // the client draws its own image at its own size: the compositor has nothing to redraw
        NoShape,       // no named shape recorded: nothing to re-apply without guessing a shape
        NoOutput,      // no monitor: nothing to draw on
    };

    // The decision for the current state. Only Redraw changes anything; it never changes the shape (it re-applies the
    // name Hyprland recorded for the image it shows) and never moves the pointer.
    Outcome          decide(const SCursorState& state);

    // A stable word for logs: "redraw", "hidden", "client-surface", "no-shape", "no-output".
    std::string_view outcomeName(Outcome outcome);

    // A shape name as it may appear in a log line: up to 48 characters of [A-Za-z0-9_-] (or empty: no named shape);
    // anything else is "<other>".
    std::string      loggableName(std::string_view name);

    // Rate limit for refresh requests (the verb is reachable by any local client through the hyprctl socket). The first
    // request of a quiet period runs at once (no lag while a slider is dragged at the shell's own rate); requests that
    // follow within `minInterval` of the last run are folded into one trailing run when the interval ends, so the last
    // size is always drawn and a flood costs at most one run per interval.
    enum class GateAction : uint8_t {
        Now,  // refresh now (counted as run)
        Arm,  // refresh later: arm the timer for `delay`
        Fold, // a later refresh is already armed; this request is folded into it
    };

    struct SGateDecision {
        GateAction       action = GateAction::Now;
        events::Duration delay{};
    };

    class CRefreshGate {
      public:
        explicit CRefreshGate(events::Duration minInterval = kDefaultInterval);

        static constexpr events::Duration kDefaultInterval = std::chrono::milliseconds(25);

        // A request at `now`.
        SGateDecision request(events::TimePoint now);

        // The timer fired at `now`: true when the folded refresh must run now (counted as run).
        bool          fire(events::TimePoint now);

        // Forgets the waiting refresh and the last run (unload, or a new load of the plugin).
        void          reset();

        bool          waiting() const;
        uint64_t      runs() const;
        uint64_t      folded() const;

      private:
        events::Duration                 m_minInterval;
        std::optional<events::TimePoint> m_lastRun;
        bool                             m_waiting = false;
        uint64_t                         m_runs    = 0;
        uint64_t                         m_folded  = 0;
    };

} // namespace gf::cursor
