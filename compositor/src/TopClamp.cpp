#include "TopClamp.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Plugin.hpp"
#include "core/TopClamp.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace gf::topClamp {

    namespace {
        // A release that ended one of Hyprland's drags, waiting for Hyprland to end it.
        struct SPending {
            PHLWINDOWREF window;
            bool         resize = false;
        };

        struct SState {
            bool                    ready = false;
            std::optional<SPending> pending;
            deferredFocus::CLater   later; // its callback is code of this library: cancelled in stop()
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        topclamp::Rect toRect(const CBox& b) {
            return topclamp::Rect{b.x, b.y, b.w, b.h};
        }

        CBox toCBox(const topclamp::Rect& r) {
            return CBox{r.x, r.y, r.w, r.h};
        }

        // A floating window with its own frame: not full screen or zoomed (those cover the menu bar on purpose).
        bool holdable(const PHLWINDOW& w) {
            if (!w || !w->m_isMapped || !w->m_isFloating || !w->layoutTarget())
                return false;
            const auto& fs = Fullscreen::controller();
            return !fs || fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_NONE;
        }

        // Every output with the bottom of its menu bar strip (its top reserved area).
        std::vector<topclamp::Output> outputs() {
            std::vector<topclamp::Output> out;
            const auto&                   state = State::monitorState();
            if (!state)
                return out;
            for (const auto& m : state->monitors()) {
                if (!m)
                    continue;
                const CBox box = m->logicalBox();
                out.push_back(topclamp::Output{toRect(box), box.y + m->m_reservedArea.top()});
            }
            return out;
        }

        // The box of `w` held below the menu bar, or nothing when it already is (or is on no output).
        std::optional<CBox> held(const PHLWINDOW& w, const CBox& surface, const Vector2D& pointer, bool resize) {
            const double   band = gf::chrome::bandOf(w); // none above a window that draws its own chrome (ADR-0015)
            const auto     all  = outputs();
            const auto     box  = toRect(surface);
            const auto     at   = topclamp::outputFor(pointer.x, pointer.y, topclamp::Rect{box.x, box.y - band, box.w, box.h + band}, all);
            if (!at)
                return std::nullopt;
            const auto next = resize ? topclamp::afterResize(box, band, all[*at]) : topclamp::afterMove(box, band, all[*at]);
            if (!topclamp::changed(next, box))
                return std::nullopt;
            return toCBox(next);
        }

        // After Hyprland handled the release: its drag is over, the window keeps its titlebar below the menu bar.
        void afterHyprlandDrag() {
            auto&      s       = st();
            const auto pending = std::exchange(s.pending, std::nullopt);
            if (!pending || !s.ready || !g_layoutManager || !g_pInputManager)
                return;
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                return; // still dragging (the release was of another button)
            const auto w = pending->window.lock();
            if (!holdable(w))
                return;
            const auto target = w->layoutTarget();
            const auto box    = held(w, target->position(), g_pInputManager->getMouseCoordsInternal(), pending->resize);
            if (!box)
                return;
            g_layoutManager->setTargetGeom(*box, target);
            logRequest(Log::DEBUG, "top clamp {:x}: {} ended under the menu bar, now at {:.0f},{:.0f} {:.0f}x{:.0f}", reinterpret_cast<uintptr_t>(w.get()),
                       pending->resize ? "resize" : "move", box->x, box->y, box->w, box->h);
        }
    } // namespace

    bool start() {
        auto& s = st();
        s.later.clear(); // a previous stop() cancelled it (the library may have stayed mapped)
        s.pending.reset();
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.later.cancel();
        s.pending.reset();
    }

    CBox heldMove(const PHLWINDOW& w, const CBox& surface, const Vector2D& pointer) {
        if (!st().ready || !holdable(w))
            return surface;
        return held(w, surface, pointer, false).value_or(surface);
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (!s.ready || pressed || !g_layoutManager)
            return;
        const auto& drag = g_layoutManager->dragController();
        if (!drag)
            return;
        const auto mode = drag->mode();
        if (mode != MBIND_MOVE && mode != MBIND_RESIZE && mode != MBIND_RESIZE_BLOCK_RATIO && mode != MBIND_RESIZE_FORCE_RATIO)
            return;
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        if (!holdable(w))
            return;
        s.pending = SPending{.window = w, .resize = mode != MBIND_MOVE};
        s.later.schedule([] { gf::guarded("top clamp after a drag", [] { afterHyprlandDrag(); }); });
    }

} // namespace gf::topClamp
