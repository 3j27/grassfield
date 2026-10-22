#include "LayerPointer.hpp"

#include "DeferredFocus.hpp"
#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "core/EventThrottle.hpp"
#include "core/LayerPointer.hpp"

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace gf::layerPointer {

    namespace lp = gf::layerpointer;

    namespace {
        struct SState {
            std::vector<CHyprSignalListener> listeners;
            lp::CRefreshState                refresh;
            deferredFocus::CLater            attempt;       // its callback is code of this library: cancelled in stop()
            std::string                      lastNamespace; // the layer that made the refresh owed (log only)
            bool                             ready = false;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        // Hyprland 0.56.2 changes the seat's pointer focus only while a pointer device exists (CSeatManager::setPointerFocus
        // returns otherwise; virtual pointers come and go). Same test as Stages (FR38).
        bool pointerDevice() {
            return g_pInputManager && g_pSeatManager && !g_pSeatManager->m_mouse.expired();
        }

        bool buttonsHeld() {
            return g_pInputManager && g_pInputManager->hasHeldButtons();
        }

        // Hyprland's pointer focus logic at the cursor, as after a pointer motion (CInputManager::simulateMouseMovement:
        // it moves its "last floored position" by one pixel so that CInputManager::mouseMoveUnified does not skip the
        // update, then runs it): the surface under the cursor gets wl_pointer.enter or motion at its right surface-local
        // position, with its own wl_pointer.frame (as CInputManager::onMouseMoved sends one), so a button delivered next
        // arrives in a later frame. Hyprland's own rules apply (constraints, the lock, follow_mouse, Stages' blocked
        // windows); it is what one pixel of motion does.
        void refreshNow(std::string_view when) {
            g_pInputManager->simulateMouseMovement();
            g_pSeatManager->sendPointerFrame();
            const auto n = st().refresh.refreshes();
            if (events::isLogMilestone(n))
                logRequest(Log::DEBUG, "layer pointer: pointer focus refreshed at the cursor {} ({}; {} refresh(es))", when, st().lastNamespace, n);
        }

        void attempt() {
            auto& s = st();
            if (!s.ready)
                return;
            if (s.refresh.onAttempt(pointerDevice(), buttonsHeld()) == lp::Step::Refresh)
                refreshNow("after a Grassfield layer mapped or took the keyboard");
            // Wait: the release of the held button schedules the next attempt; without a pointer device the next press does.
        }

        void scheduleAttempt() {
            auto& s = st();
            if (!s.attempt.schedule([] { gf::guarded("layer pointer attempt", [] { attempt(); }); }))
                s.refresh.onAttempt(false, true); // no event loop: nothing scheduled, the refresh waits for a button
        }

        // From CLayerSurface::onMap (layer.opened) or the seat's keyboard focus (input.keyboard.focus, also from
        // CLayerSurface::onMap / onCommit when a layer takes the keyboard): both come before Hyprland sets that layer's
        // pointer focus with the miscomputed position, so the refresh runs from the event loop, after it.
        void onLayerEvent(const PHLLS& ls) {
            auto& s = st();
            if (!s.ready || !ls)
                return;
            if (lp::isGrassfieldNamespace(ls->m_namespace))
                s.lastNamespace = ls->m_namespace;
            if (s.refresh.onLayerEvent(ls->m_namespace))
                scheduleAttempt();
        }

        void onKeyboardFocus(const SP<CWLSurfaceResource>& surface) {
            if (!st().ready || !surface)
                return;
            const auto owner = surfaces::ownerOf(surface);
            if (owner.layer && !owner.popup)
                onLayerEvent(owner.layer);
        }
    } // namespace

    bool start() {
        auto& s = st();
        s.listeners.clear();
        s.refresh.reset();
        s.attempt.clear(); // a previous stop() cancelled it (the library may have stayed mapped, FR23)
        s.lastNamespace.clear();
        s.ready   = false;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events;
        s.listeners.push_back(ev.layer.opened.listen([](const PHLLS& ls) { gf::guarded("layer pointer layer.opened", [&] { onLayerEvent(ls); }); }));
        s.listeners.push_back(ev.input.keyboard.focus.listen([](const SP<CWLSurfaceResource>& surface) {
            gf::guarded("layer pointer keyboard.focus", [&] { onKeyboardFocus(surface); });
        }));
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.listeners.clear();
        s.attempt.cancel();
        s.refresh.reset();
        s.lastNamespace.clear();
    }

    bool ready() {
        return st().ready;
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (!s.ready)
            return;
        switch (s.refresh.beforeButton(pressed, pointerDevice(), buttonsHeld())) {
            case lp::Step::Refresh: refreshNow("before a press"); break;
            case lp::Step::Schedule: scheduleAttempt(); break;
            case lp::Step::Wait:
            case lp::Step::None: break;
        }
    }

} // namespace gf::layerPointer
