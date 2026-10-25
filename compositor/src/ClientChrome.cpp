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
#include <hyprland/src/protocols/core/Compositor.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace gf::chrome {

    namespace {
        // The two listeners of one window's xdg toplevel. Destroying them disconnects them. `minimizeTold`: the window was
        // told the minimize capability (P8); unload tells it Hyprland's own capabilities again.
        struct SWatch {
            PHLWINDOWREF             window;
            WP<CXDGToplevelResource> toplevel;
            CHyprSignalListener      stateChanged;
            CHyprSignalListener      requestMove;
            bool                     minimizeTold = false;
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

        // P8: the xdg_toplevel wl_resource of `top`: Hyprland keeps it private, so it is found among its client's resources
        // (libwayland's own list) by its interface and CXDGToplevelResource::fromResource.
        wl_resource* toplevelResource(const SP<CXDGToplevelResource>& top) {
            const auto xdg     = top ? top->m_owner.lock() : nullptr;
            const auto surface = xdg ? xdg->m_surface.lock() : nullptr;
            wl_client* client  = surface ? surface->client() : nullptr;
            if (!client)
                return nullptr;
            struct SFind {
                CXDGToplevelResource* wanted = nullptr;
                wl_resource*          found  = nullptr;
            } find{.wanted = top.get()};
            wl_client_for_each_resource(
                client,
                [](wl_resource* resource, void* data) -> wl_iterator_result {
                    auto*       f   = static_cast<SFind*>(data);
                    const char* cls = resource ? wl_resource_get_class(resource) : nullptr;
                    if (!cls || std::string_view{cls} != "xdg_toplevel")
                        return WL_ITERATOR_CONTINUE;
                    if (CXDGToplevelResource::fromResource(resource).get() != f->wanted)
                        return WL_ITERATOR_CONTINUE;
                    f->found = resource;
                    return WL_ITERATOR_STOP;
                },
                &find);
            return find.found;
        }

        // P8: tells the window its capabilities again (core wmCapabilities) when they change, then a configure, as
        // xdg-shell asks ("when the capabilities change, compositors must send this event again and then send an
        // xdg_surface.configure event"). Nothing for a client older than xdg_toplevel v5 (it never had the event).
        // The configure is Hyprland's own full one (setSize with the size it already asked for: an xdg_toplevel.configure
        // with its current states, then the xdg_surface.configure; read from the 0.56.2 binary, no early return): a bare
        // xdg_surface.configure made GTK4 apply an empty state set (no longer activated or tiled: it drew its shadow
        // margins and looked inactive).
        void tellCapabilities(SWatch& e, bool clientChrome, bool bridged) {
            const bool withMinimize = clientChrome && bridged;
            if (withMinimize == e.minimizeTold)
                return;
            const auto   top = e.toplevel.lock();
            wl_resource* res = toplevelResource(top);
            const auto   xdg = top ? top->m_owner.lock() : nullptr;
            if (!res || !xdg || wl_resource_get_version(res) < static_cast<int>(kWmCapabilitiesSince))
                return;
            const auto caps = wmCapabilities(clientChrome, bridged);
            wl_array   array;
            wl_array_init(&array);
            for (const uint32_t cap : caps) {
                auto* slot = static_cast<uint32_t*>(wl_array_add(&array, sizeof(uint32_t)));
                if (!slot) {
                    wl_array_release(&array);
                    return;
                }
                *slot = cap;
            }
            wl_resource_post_event(res, 3 /* xdg_toplevel.wm_capabilities */, &array);
            wl_array_release(&array);
            top->setSize(top->m_pendingApply.size);
            e.minimizeTold = withMinimize;
            logRequest(Log::DEBUG, "client chrome: {:x} told {} capabilities{}", addressOf(e.window.lock()), caps.size(), withMinimize ? " (minimize)" : "");
        }

        // The capabilities of a watched window after an open or a rule change (the tag may come or go).
        void syncCapabilities(const PHLWINDOW& w) {
            for (auto& e : st().watches) {
                if (e.window.lock() == w)
                    tellCapabilities(e, isClientChrome(w), st().ready);
            }
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
            tellCapabilities(s.watches.back(), isClientChrome(w), true);
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
        // The tag is a dynamic effect of the session rules: a rule change can make a window client chrome or not (P8).
        s.listeners.push_back(ev.updateRules.listen([](const PHLWINDOW& w) { guarded("client chrome window.updateRules", [&] { syncCapabilities(w); }); }));
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
        // P8: every window told minimize is told Hyprland's own capabilities again before the bridge goes (C2: without the
        // plugin a client sees what Hyprland offers, and its minimize button greys again).
        for (auto& e : s.watches) {
            if (e.minimizeTold)
                guarded("client chrome capabilities on stop", [&] { tellCapabilities(e, false, false); });
        }
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
