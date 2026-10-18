#include "DesktopFocus.hpp"

#include "Plugin.hpp"
#include "Surfaces.hpp"
#include "Titlebar.hpp"
#include "core/DesktopFocus.hpp"

#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>

#include <linux/input-event-codes.h>

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace df = gf::desktopfocus;

namespace {
    struct SDesktopLayer {
        PHLLSREF            layer;
        uint64_t            id = 0; // the layer surface's address: compared, never dereferenced
        CHyprSignalListener commit; // on its CLayerShellResource (interactivity changes arrive in commits)
    };

    struct SDesktopFocusState {
        bool                             ready = false;
        std::vector<CHyprSignalListener> listeners;
        std::vector<SDesktopLayer>       desktops;
        df::CPendingGrant                pending;
    };

    // Constructed on first use inside a guarded call (R13). Emptied by stop() before dlclose.
    SDesktopFocusState& st() {
        static SDesktopFocusState s;
        return s;
    }

    uint64_t idOf(const PHLLS& ls) {
        return reinterpret_cast<uintptr_t>(ls.get());
    }

    std::string monitorName(const PHLLS& ls) {
        const auto mon = ls ? ls->m_monitor.lock() : nullptr;
        return mon ? mon->m_name : std::string{"?"};
    }

    // What a wl_surface is for the policy, with the window or layer surface it belongs to.
    struct SResolved {
        df::SurfaceKind kind = df::SurfaceKind::None;
        PHLWINDOW       window;
        PHLLS           layer;
    };

    SResolved resolve(const SP<CWLSurfaceResource>& surface) {
        if (!surface)
            return {};
        const auto owner = gf::surfaces::ownerOf(surface);
        if (owner.layer)
            return {.kind = df::classifyLayer(owner.layer->m_namespace, owner.popup), .window = nullptr, .layer = owner.layer};
        if (owner.window) {
            if (owner.popup)
                return {.kind = df::SurfaceKind::WindowPopup, .window = owner.window, .layer = nullptr};
            return {.kind = df::SurfaceKind::Window, .window = owner.window, .layer = nullptr};
        }
        return {.kind = df::SurfaceKind::Other, .window = nullptr, .layer = nullptr};
    }

    SP<CWLSurfaceResource> keyboardSurface() {
        return gf::surfaces::keyboardFocus();
    }

    df::Seat seatNow(const SResolved& keyboard) {
        df::Seat seat;
        seat.keyboard     = keyboard.kind;
        seat.keyboardGrab = g_pSeatManager && g_pSeatManager->m_seatGrab && g_pSeatManager->m_seatGrab->m_keyboard;
        seat.exclusiveLayer =
            g_pInputManager && std::ranges::any_of(g_pInputManager->m_exclusiveLSes, [](const PHLLSREF& ls) { return ls && ls->m_mapped; });
        seat.locked = g_pSessionLockManager && g_pSessionLockManager->isSessionLocked();
        return seat;
    }

    df::Interactivity interactivityOf(const PHLLS& ls) {
        return df::interactivityFromProtocol(gf::surfaces::interactivity(ls));
    }

    bool windowFocusable(const PHLWINDOW& w) {
        return w && w->m_isMapped && !w->isHidden() && !w->m_X11ShouldntFocus;
    }

    // The surface the press lands on: Hyprland's pointer focus (it follows the pointer with follow_mouse 2). Over a
    // Grassfield titlebar there is no pointer focus (decorations are not surfaces): the window whose shown titlebar
    // contains the pointer then.
    SResolved pressTarget() {
        const auto pointer = g_pSeatManager ? g_pSeatManager->m_state.pointerFocus.lock() : nullptr;
        if (pointer)
            return resolve(pointer);
        if (!g_pInputManager || !Desktop::viewState())
            return {};
        const Vector2D pos = g_pInputManager->getMouseCoordsInternal();
        constexpr auto props = static_cast<uint16_t>(Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
        const auto     w     = Desktop::viewState()->hitTest().windowAt(pos, props);
        if (!w)
            return {};
        const bool onBar = std::ranges::any_of(gf::state().titlebars, [&](const CGrassfieldTitlebar* deco) { return deco->window() == w && deco->barContains(pos); });
        return onBar ? SResolved{.kind = df::SurfaceKind::Window, .window = w, .layer = nullptr} : SResolved{};
    }

    bool keyboardOnWindow(const PHLWINDOW& w) {
        const auto k = resolve(keyboardSurface());
        return k.kind == df::SurfaceKind::Window && k.window == w;
    }

    bool keyboardOnLayer(const PHLLS& ls) {
        const auto k = keyboardSurface();
        return k && ls && k == ls->resource();
    }

    void focusWindow(const PHLWINDOW& w) {
        const auto focus = Desktop::focusState();
        if (!focus)
            return;
        // Hyprland's click focus. While a layer surface holds the keyboard Hyprland may still count `w` as its focused
        // window, and then refocusing it changes nothing (Hyprland 0.56.2, ADR-0012 spike row 2): the keyboard is given
        // to the window's surface directly in that case.
        focus->fullWindowFocus(w, Desktop::FOCUS_REASON_CLICK);
        bool direct = false;
        if (!keyboardOnWindow(w)) {
            focus->rawSurfaceFocus(w->resource(), w);
            direct = true;
        }
        gf::logRequest(Log::DEBUG, "desktop-focus: press on window {:x}: keyboard to the window{} ({})", reinterpret_cast<uintptr_t>(w.get()),
                       direct ? " (direct surface focus)" : "", keyboardOnWindow(w) ? "granted" : "NOT granted");
    }

    void focusDesktop(const PHLLS& ls, const char* when) {
        const auto focus = Desktop::focusState();
        if (!focus || !ls || !ls->m_mapped)
            return;
        focus->rawSurfaceFocus(ls->resource(), nullptr);
        gf::logRequest(Log::DEBUG, "desktop-focus: desktop {:x} ({}): keyboard to the desktop {} ({})", idOf(ls), monitorName(ls),
                       when, keyboardOnLayer(ls) ? "granted" : "NOT granted");
    }

    void onPress(const IPointer::SButtonEvent& e) {
        if (e.state != WL_POINTER_BUTTON_STATE_PRESSED)
            return;
        auto& s = st();
        s.pending.cancel(); // any press decides afresh

        const auto     keyboard = resolve(keyboardSurface());
        const auto     target   = pressTarget();
        const df::Seat seat     = seatNow(keyboard);
        df::Press      press;
        press.target  = target.kind;
        press.primary = e.button == BTN_LEFT;
        if (target.kind == df::SurfaceKind::Window) {
            press.windowFocusable   = windowFocusable(target.window);
            press.targetHasKeyboard = keyboard.kind == df::SurfaceKind::Window && keyboard.window == target.window;
        } else if (target.kind == df::SurfaceKind::Desktop) {
            press.interactivity     = interactivityOf(target.layer);
            press.targetHasKeyboard = keyboard.kind == df::SurfaceKind::Desktop && keyboard.layer == target.layer;
        }

        const auto action = df::onPress(seat, press);
        if (action != df::Action::None || keyboard.kind == df::SurfaceKind::Desktop)
            gf::logRequest(Log::DEBUG, "desktop-focus: press (button {:#x}) on {} while the keyboard is on {} -> {}", e.button, df::kindName(target.kind),
                           df::kindName(keyboard.kind), df::actionName(action));
        switch (action) {
            case df::Action::None: break;
            case df::Action::FocusWindow: focusWindow(target.window); break;
            case df::Action::FocusDesktop: focusDesktop(target.layer, "at the press"); break;
            case df::Action::AwaitOnDemand: s.pending.arm(idOf(target.layer), df::Clock::now()); break;
        }
    }

    // A commit of a desktop layer surface: if a press armed it and it is on_demand now, it gets the keyboard (the shell
    // switched None -> OnDemand on that press; Hyprland itself would wait for the next pointer motion).
    void onDesktopCommit(const PHLLS& ls) {
        auto& s = st();
        if (!ls || !s.pending.surface() || *s.pending.surface() != idOf(ls))
            return;
        if (!s.pending.onCommit(idOf(ls), interactivityOf(ls), df::Clock::now()))
            return;
        const auto keyboard = resolve(keyboardSurface());
        if (!ls->m_mapped || !df::mayGrantDesktop(seatNow(keyboard), keyboardOnLayer(ls)))
            return;
        focusDesktop(ls, "after its on_demand commit");
    }

    void attach(const PHLLS& ls) {
        auto& s = st();
        std::erase_if(s.desktops, [](const SDesktopLayer& d) { return !d.layer; }); // gone surfaces
        if (!ls || ls->m_namespace != df::kDesktopNamespace)
            return;
        if (std::ranges::any_of(s.desktops, [&ls](const SDesktopLayer& d) { return d.layer.lock() == ls; }))
            return;
        const auto resource = ls->m_layerSurface.lock();
        if (!resource)
            return;
        SDesktopLayer d;
        d.layer  = ls;
        d.id     = idOf(ls);
        d.commit = resource->m_events.commit.listen([ref = PHLLSREF(ls)] { gf::guarded("desktop-focus commit", [&ref] { onDesktopCommit(ref.lock()); }); });
        s.desktops.push_back(std::move(d));
        gf::logRequest(Log::INFO, "desktop-focus: desktop surface {:x} on {} tracked", idOf(ls), monitorName(ls));
    }

    void detach(const PHLLS& ls) {
        auto& s = st();
        if (!ls)
            return;
        const uint64_t id = idOf(ls);
        if (s.pending.surface() == id)
            s.pending.cancel();
        std::erase_if(s.desktops, [id](const SDesktopLayer& d) { return !d.layer || d.id == id; });
    }
} // namespace

namespace gf::desktopFocus {

    bool start() {
        auto& bus = Event::bus();
        if (!bus || !g_pSeatManager || !g_pInputManager || !Desktop::layerState())
            return false;
        auto& ev = bus->m_events;
        auto& l  = st().listeners;
        // Observed, never cancelled (FR13).
        l.push_back(ev.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& /*info*/) { gf::guarded("desktop-focus press", [&] { onPress(e); }); }));
        l.push_back(ev.layer.opened.listen([](const PHLLS& ls) { gf::guarded("desktop-focus layer.opened", [&] { attach(ls); }); }));
        l.push_back(ev.layer.closed.listen([](const PHLLS& ls) { gf::guarded("desktop-focus layer.closed", [&] { detach(ls); }); }));
        for (const auto& ls : Desktop::layerState()->layers()) {
            if (ls && ls->m_mapped)
                attach(ls);
        }
        st().ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.ready = false;
        s.pending.cancel();
        s.listeners.clear();
        s.desktops.clear(); // drops the commit listeners (their callbacks are code of this library)
    }

    bool ready() {
        return st().ready;
    }

} // namespace gf::desktopFocus
