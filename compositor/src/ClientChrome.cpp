#include "ClientChrome.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
#include "core/ClientChrome.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <optional>
#include <vector>

namespace gf::chrome {

    namespace {
        // The two listeners of one window's xdg toplevel. Destroying them disconnects them.
        struct SWatch {
            PHLWINDOWREF             window;
            WP<CXDGToplevelResource> toplevel;
            CHyprSignalListener      stateChanged;
            CHyprSignalListener      requestMove;
        };

        struct SState {
            std::vector<CHyprSignalListener> listeners; // window open / close
            std::vector<SWatch>              watches;
            std::optional<ZoomedPress>       press; // P4: the last press on a zoomed client-chrome window
            bool                             ready = false;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        uint64_t addressOf(const PHLWINDOW& w) {
            return reinterpret_cast<uintptr_t>(w.get());
        }

        uint64_t nowMs() {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
        }

        Fullscreen::eFullscreenMode modeOf(const PHLWINDOW& w) {
            const auto& fs = Fullscreen::controller();
            return fs ? fs->getFullscreenModes(w).internal : Fullscreen::FSMODE_NONE;
        }

        SP<CXDGToplevelResource> toplevelOf(const PHLWINDOW& w) {
            if (!w || w->m_isX11)
                return nullptr;
            const auto xdg = w->m_xdgSurface.lock();
            return xdg ? xdg->m_toplevel.lock() : nullptr;
        }

        // P5: the app asked to be minimized (xdg_toplevel.set_minimized; Hyprland does nothing with it on its own, spike
        // step 5): the minimize path of the titlebar's own light.
        void onStateChanged(const PHLWINDOWREF& ref, const WP<CXDGToplevelResource>& weakTop) {
            const auto w   = ref.lock();
            const auto top = weakTop.lock();
            if (!w || !top || !w->m_isMapped || !isClientChrome(w))
                return;
            if (!top->m_state.requestsMinimize.value_or(false))
                return;
            if (w->m_workspace && w->m_workspace->m_isSpecialWorkspace)
                return; // already parked (special:minimized or a scratchpad): nothing to do
            logRequest(Log::DEBUG, "client chrome: {:x} asks to be minimized", addressOf(w));
            ipc::postMinimizeRequest(addressOf(w));
        }

        // P4: the app started Hyprland's interactive move from its toolbar. On a zoomed window (the press recorded before
        // Hyprland handled it) the window leaves the zoom at its floating size, under the pointer at the same place in its
        // toolbar row (macOS), and the move restarts from there. Hyprland's own handler may already have left the zoom
        // (it centres the window on the pointer, spike step 3): the move it started is ended and begun again from the
        // place computed here, so the pointer keeps its grip on the row.
        void onRequestMove(const PHLWINDOWREF& ref) {
            auto&      s = st();
            const auto w = ref.lock();
            if (!w || !w->m_isMapped || !isClientChrome(w) || !g_pInputManager || !g_layoutManager)
                return;
            if (!s.press || !moveAnswersPress(s.press, addressOf(w), g_pInputManager->hasHeldButtons(), nowMs()))
                return;
            const ZoomedPress press = *s.press;
            s.press.reset();
            const auto target = w->layoutTarget();
            if (!target)
                return;
            if (modeOf(w) == Fullscreen::FSMODE_MAXIMIZED) {
                if (const auto& fs = Fullscreen::controller())
                    fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false);
            }
            if (modeOf(w) != Fullscreen::FSMODE_NONE)
                return; // still not floating normally: leave Hyprland's move alone
            const CBox     restored = target->position();
            const Vector2D pointer  = g_pInputManager->getMouseCoordsInternal();
            const auto     box      = unzoomedBox(press, restored.w, restored.h, pointer.x, pointer.y);
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                g_layoutManager->endDragTarget();
            g_layoutManager->setTargetGeom(CBox{box.x, box.y, box.w, box.h}, target);
            g_layoutManager->beginDragTarget(target, MBIND_MOVE);
            logRequest(Log::DEBUG, "client chrome: {:x} dragged out of its zoom: {:.0f}x{:.0f} at {:.0f},{:.0f}", addressOf(w), box.w, box.h, box.x, box.y);
        }

        void watch(const PHLWINDOW& w) {
            auto& s = st();
            std::erase_if(s.watches, [](const SWatch& e) { return e.window.expired() || e.toplevel.expired(); });
            const auto top = toplevelOf(w);
            if (!top || std::ranges::any_of(s.watches, [&w](const SWatch& e) { return e.window.lock() == w; }))
                return;
            SWatch      e;
            PHLWINDOWREF ref = w;
            WP<CXDGToplevelResource> weakTop = top;
            e.window       = ref;
            e.toplevel     = weakTop;
            e.stateChanged = top->m_events.stateChanged.listen([ref, weakTop] { guarded("client chrome stateChanged", [&] { onStateChanged(ref, weakTop); }); });
            e.requestMove  = top->m_events.requestMove.listen([ref](const SXDGToplevelMoveRequest& /*request*/) { guarded("client chrome requestMove", [&] { onRequestMove(ref); }); });
            s.watches.push_back(std::move(e));
        }

        void forget(const PHLWINDOW& w) {
            std::erase_if(st().watches, [&w](const SWatch& e) {
                const auto mine = e.window.lock();
                return !mine || mine == w || e.toplevel.expired();
            });
        }

        // The topmost mapped window on a visible workspace whose surface box contains `pos` (the stacking order Hyprland
        // keeps); null when the pointer is on no window.
        PHLWINDOW windowUnder(const Vector2D& pos) {
            if (!Desktop::windowState())
                return nullptr;
            const auto& windows = Desktop::windowState()->windows();
            for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
                const auto& w = *it;
                if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
                    continue;
                if (w->getWindowMainSurfaceBox().containsPoint(pos))
                    return w;
            }
            return nullptr;
        }
    } // namespace

    bool isClientChrome(const PHLWINDOW& w) {
        return w && w->m_ruleApplicator && hasClientChromeTag(w->m_ruleApplicator->m_tagKeeper.getTags());
    }

    double bandOf(const PHLWINDOW& w) {
        return band(isClientChrome(w));
    }

    bool start() {
        auto& s = st();
        if (s.ready)
            return true;
        auto& bus = Event::bus();
        if (!bus)
            return false;
        auto& ev = bus->m_events.window;
        s.listeners.push_back(ev.open.listen([](const PHLWINDOW& w) { guarded("client chrome window.open", [&] { watch(w); }); }));
        s.listeners.push_back(ev.close.listen([](const PHLWINDOW& w) { guarded("client chrome window.close", [&] { forget(w); }); }));
        if (Desktop::windowState()) {
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && w->m_isMapped)
                    watch(w);
            }
        }
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.watches.clear();
        s.listeners.clear();
        s.press.reset();
        s.ready = false;
    }

    bool ready() {
        return st().ready;
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (!s.ready)
            return;
        if (!pressed) {
            s.press.reset();
            return;
        }
        s.press.reset();
        if (!g_pInputManager)
            return;
        const Vector2D pos = g_pInputManager->getMouseCoordsInternal();
        const auto     w   = windowUnder(pos);
        if (!w || !isClientChrome(w) || modeOf(w) != Fullscreen::FSMODE_MAXIMIZED)
            return;
        const CBox zoomed = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        s.press           = ZoomedPress{.window = addressOf(w), .zoomed = titlebar::Rect{zoomed.x, zoomed.y, zoomed.w, zoomed.h}, .x = pos.x, .y = pos.y, .timeMs = nowMs()};
    }

} // namespace gf::chrome
