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
    };

    // One refresh owed per burst of events: the first one schedules an attempt from the event loop (after Hyprland's own
    // handling has run, including the pointer focus it sets); more events before it runs join it.
    class CRefreshState {
      public:
        // A layer surface with namespace `ns` mapped, or the seat's keyboard went to one. True when an attempt must be
        // scheduled now (a Grassfield layer and none scheduled yet).
        bool     onLayerEvent(std::string_view ns);

        // The scheduled attempt runs (or could not be scheduled: no event loop). Refresh (and nothing owed any more) when
        // a pointer device exists and no button is held; Wait otherwise; None when nothing is owed.
        Step     onAttempt(bool pointerDevice, bool buttonsHeld);

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
        bool     m_scheduled = false; // an event-loop attempt is scheduled
        bool     m_owed      = false; // a Grassfield layer mapped or took the keyboard since the last refresh
        uint64_t m_refreshes = 0;
    };

} // namespace gf::layerpointer
