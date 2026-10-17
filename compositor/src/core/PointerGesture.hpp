#pragma once

// Pointer press ownership for titlebar gestures. Plain C++ with no Hyprland includes, so it is
// unit-testable (compositor/tests/). The Hyprland glue (Titlebar.cpp) feeds it the raw button and
// motion events; it answers which releases belong to a titlebar and when a gesture must end.
//
// Rules:
// - A release is kept from clients only when a titlebar consumed the matching press ("owned").
// - A new press of a button supersedes any older ownership of that button (its release was lost).
// - A press while a gesture (drag, armed titlebar button) is active cancels the gesture.
// - A motion while no button is held, or after a pointer device present at the press disappeared,
//   cancels the gesture and forgets its button: that release will never arrive.

#include <cstdint>
#include <optional>
#include <vector>

namespace gf::input {

    class CPointerGestureTracker {
      public:
        // Every press, before anything consumes it. Returns true when an active gesture was cancelled.
        bool onPress(uint32_t button);

        // A titlebar consumed the press of `button`. `startsGesture`: the press started a gesture that
        // ends on the release of the same button (drag, armed button); false for a press that acts at
        // once (double-click zoom).
        void claim(uint32_t button, bool startsGesture);

        struct SRelease {
            bool owned       = false; // a titlebar consumed the matching press: keep this release from clients
            bool endsGesture = false; // the release completes the active gesture
        };

        // Every release, before anything consumes it.
        SRelease onRelease(uint32_t button);

        // Every motion while a gesture is active. `buttonsHeld`: the compositor still sees a held button;
        // `devicesIntact`: every pointer device present at the press still exists. Returns true when the
        // gesture was cancelled.
        bool onMotion(bool buttonsHeld, bool devicesIntact);

        // The gesture's window/titlebar went away: forget the gesture but keep the press ownership, so
        // the release (which will still arrive) is kept from the client that never saw the press.
        void dropGesture();

        // An owned release that the compositor will route to a titlebar: the titlebar consumes it there.
        // The expectation lasts until the next button event.
        void expectTitlebarRelease(uint32_t button);

        // Called for every release routed to a titlebar. True when it is the expected one (consume it).
        bool takeTitlebarRelease(uint32_t button);

        bool                    owns(uint32_t button) const;
        std::optional<uint32_t> gestureButton() const;
        void                    reset();

      private:
        bool                    releaseOwnership(uint32_t button);

        std::vector<uint32_t>   m_owned; // buttons whose press a titlebar consumed (a handful at most)
        std::optional<uint32_t> m_gesture;
        std::optional<uint32_t> m_expectedRelease;
    };

} // namespace gf::input
