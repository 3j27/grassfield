// grassfield-compositor: Hyprland plugin entry points (master-prompt §5.6, R13).
//
// Load ONLY into the nested dev instance (scripts/dev/nested-up.sh). On a Hyprland/plugin ABI
// mismatch the plugin refuses to hook anything and notifies once; the shell then falls back to
// its degraded mode because no `grassfield` capabilities event is ever posted.

#include "AppmenuServer.hpp"
#include "ClientChrome.hpp"
#include "CursorRefresh.hpp"
#include "DesktopFocus.hpp"
#include "Ipc.hpp"
#include "LayerPointer.hpp"
#include "Minimize.hpp"
#include "Overview.hpp"
#include "OverviewFocus.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Tiling.hpp"
#include "Titlebar.hpp"

#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/Color.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/plugins/PluginSystem.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace gf {
    SPluginState& state() {
        static SPluginState s;
        return s;
    }

    void forgetRegisteredDecoration(IHyprWindowDecoration* deco) noexcept {
        guarded("forgetRegisteredDecoration", [deco] {
            if (!g_pPluginSystem || !state().handle)
                return;
            if (auto* plugin = g_pPluginSystem->getPluginByHandle(state().handle))
                std::erase(plugin->m_registeredDecorations, deco);
        });
    }
} // namespace gf

namespace {
    using gf::state;

    CGrassfieldTitlebar* titlebarFor(const PHLWINDOW& w) {
        if (!w)
            return nullptr;
        for (auto* deco : state().titlebars) {
            if (deco->window() == w)
                return deco;
        }
        return nullptr;
    }

    void decorate(const PHLWINDOW& w) {
        if (!w || !w->m_isMapped || titlebarFor(w))
            return;
        if (!HyprlandAPI::addWindowDecoration(state().handle, w, makeUnique<CGrassfieldTitlebar>(w)))
            gf::log(Log::WARN, "addWindowDecoration failed for window {:x}", reinterpret_cast<uintptr_t>(w.get()));
    }

    void refreshFor(const PHLWINDOW& w) {
        if (auto* deco = titlebarFor(w))
            deco->refresh();
    }

    void registerListeners() {
        auto& bus = Event::bus();
        if (!bus)
            throw std::runtime_error("event bus unavailable");

        auto& ev = bus->m_events;
        auto& l  = state().listeners;

        l.push_back(ev.window.open.listen([](const PHLWINDOW& w) { gf::guarded("window.open", [&] { decorate(w); }); }));
        l.push_back(ev.window.floating.listen([](const PHLWINDOW& w) { gf::guarded("window.floating", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("window.fullscreen", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.updateRules.listen([](const PHLWINDOW& w) { gf::guarded("window.updateRules", [&] { refreshFor(w); }); }));
        l.push_back(ev.window.active.listen([](const PHLWINDOW& w, Desktop::eFocusReason /*reason*/) { CGrassfieldTitlebar::onActiveWindowChanged(w); }));
        l.push_back(ev.window.title.listen([](const PHLWINDOW& w) {
            gf::guarded("window.title", [&] {
                if (auto* deco = titlebarFor(w))
                    deco->onTitleChanged();
            });
        }));
        l.push_back(ev.input.mouse.move.listen([](Vector2D /*pos*/, Event::SCallbackInfo& /*info*/) { CGrassfieldTitlebar::onGlobalMouseMove(); }));
        // Button events are observed, never cancelled (FR13): Hyprland must process every release to keep
        // its held-button state, which pins pointer focus while a button is down. Stages first: a pointer focus
        // left on a strip window (input blocked, no motion since) moves to the surface under the cursor before
        // anything else sees the press (R13 review of 46b3e9b).
        l.push_back(ev.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& /*info*/) {
            // A shell layer mapped or took the keyboard under the resting pointer and its pointer focus is not refreshed yet
            // (a button was held, no pointer device, or the press came in the same event loop pass): a press is delivered
            // at the right place, a release schedules the refresh after Hyprland handled it (FR51).
            gf::guarded("layer pointer press", [&] { gf::layerPointer::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            gf::guarded("stages pointer guard", [&] { gf::stager::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // A press after an overview focus request wins over the target the shell named (recorded only).
            gf::guarded("overview focus press", [&] { gf::overviewFocus::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            // A press on a zoomed window that draws its own chrome, recorded while it is still zoomed: the app's move request
            // that may follow takes it out of the zoom under the pointer (ADR-0015 P4).
            gf::guarded("client chrome press", [&] { gf::chrome::beforePointerButton(e.state == WL_POINTER_BUTTON_STATE_PRESSED); });
            CGrassfieldTitlebar::onGlobalMouseButton(e);
        }));
        // Keys are observed, never cancelled: Alt changes the zoom glyph of the hovered lights (ADR-0015 P6).
        l.push_back(ev.input.keyboard.key.listen([](IKeyboard::SKeyEvent /*e*/, Event::SCallbackInfo& /*info*/) { CGrassfieldTitlebar::onKey(); }));
    }

    // The window whose m_windowDecorations owns `deco` (normally deco->window(); scanned as a fallback).
    PHLWINDOW ownerOf(const CGrassfieldTitlebar* deco) {
        const auto owns = [deco](const PHLWINDOW& w) {
            return w && std::ranges::any_of(w->m_windowDecorations, [deco](const UP<IHyprWindowDecoration>& d) { return d.get() == deco; });
        };
        if (const auto w = deco->window(); owns(w))
            return w;
        for (const auto& w : Desktop::windowState()->windows()) {
            if (owns(w))
                return w;
        }
        return nullptr;
    }

    // Destroys a titlebar now, whatever its window's state. HyprlandAPI::removeWindowDecoration only queues
    // the removal (CWindow::m_decosToRemove) and runs CWindow::updateWindowDecos(), which in 0.56.2 returns
    // at once for an unmapped or hidden window (it tests m_isMapped, then isHidden(); read from the binary):
    // such a titlebar would survive dlclose. This does what updateWindowDecos does for a queued removal
    // (uncache it from the positioner, erase it from m_windowDecorations) without that early return.
    bool destroyNow(CGrassfieldTitlebar* deco) {
        const auto w = ownerOf(deco);
        if (!w)
            return false;
        auto&      decos = w->m_windowDecorations;
        const auto it    = std::ranges::find_if(decos, [deco](const UP<IHyprWindowDecoration>& d) { return d.get() == deco; });
        if (it == decos.end())
            return false;
        std::erase(w->m_decosToRemove, deco);
        if (g_pDecorationPositioner)
            g_pDecorationPositioner->uncacheDecoration(deco); // pointer comparison only; deco still alive
        UP<IHyprWindowDecoration> owned = std::move(*it);
        decos.erase(it);
        owned.reset(); // ~CGrassfieldTitlebar runs here, while this library is still loaded
        if (g_pDecorationPositioner)
            g_pDecorationPositioner->forceRecalcFor(w);
        return true;
    }

    void removeAllTitlebars() {
        CGrassfieldTitlebar::cancelPointerGrab();
        gf::tiler::forgetAll();

        // Visible windows: Hyprland's own removal path, which also lays the window out again without the
        // titlebar. It destroys the decoration synchronously for a mapped, visible window.
        for (auto* deco : std::vector(state().titlebars)) { // copy: removal destroys entries
            const auto w = deco->window();
            if (w && w->m_isMapped && !w->isHidden())
                HyprlandAPI::removeWindowDecoration(state().handle, deco);
        }

        // Everything left (unmapped or hidden windows): destroy directly, so that no object of this library
        // outlives dlclose.
        size_t direct = 0;
        for (auto* deco : std::vector(state().titlebars)) {
            if (destroyNow(deco))
                ++direct;
            else
                gf::log(Log::ERR, "titlebar {:x} has no owning window; cannot destroy it before unload", reinterpret_cast<uintptr_t>(deco));
        }
        if (direct > 0)
            gf::log(Log::INFO, "destroyed {} titlebar(s) of unmapped or hidden windows directly", direct);
    }

    void teardown() {
        auto& s = state();
        // Each step on its own: a failure in one must not skip the others (a Lua function registered
        // after unload would point into the unloaded library).
        const auto step = [](const char* what, auto&& fn) {
            try {
                fn();
            } catch (const std::exception& e) {
                gf::log(Log::ERR, "teardown: {} failed: {}", what, e.what());
            } catch (...) {
                gf::log(Log::ERR, "teardown: {} failed with an unknown exception", what);
            }
        };
        step("listeners", [&] { s.listeners.clear(); });
        step("client chrome", [] { gf::chrome::stop(); });   // per-window toplevel listeners removed
        step("desktop focus", [] { gf::desktopFocus::stop(); }); // no press or commit may reach the policy any more
        step("minimizer", [] { gf::minimizer::stop(); }); // before the Lua entry points go: animations complete, snapshots dropped
        step("overview", [] { gf::overviewer::stop(); });   // every window back to normal rendering, transformers detached
        step("stages", [] { gf::stager::stop(); });          // strip windows shown normally, input unblocked, transformers detached
        step("overview focus", [] { gf::overviewFocus::stop(); }); // a waiting request ends "unavailable"; watches and timer removed
        step("cursor refresh", [] { gf::cursorRefresh::stop(); }); // trailing-refresh timer removed (its callback is in this library)
        step("layer pointer", [] { gf::layerPointer::stop(); });   // layer listener and event-loop callback removed
        step("appmenu", [] { gf::appmenuServer::stop(); }); // no wl_resource may point into this library after dlclose
        step("events", [] { gf::ipc::stopEvents(); });      // after the appmenu clears: waiting events posted, timer removed
        step("ipc", [] { gf::ipc::unregisterAll(); });
        step("titlebars", [] { removeAllTitlebars(); });
        step("withdraw", [] { gf::ipc::postWithdrawn(); }); // last: the shell drops every feature and uses its fallbacks
        s.active = false;
    }

    void notify(const std::string& text, const CHyprColor& color, float timeMs = 8000.F) {
        if (state().handle)
            HyprlandAPI::addNotification(state().handle, text, color, timeMs);
    }
} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    auto& s  = state();
    s.handle = handle;

    PLUGIN_DESCRIPTION_INFO info{.name = gf::kPluginName, .description = "Grassfield titlebars, minimize, appmenu, overview, overview focus, desktop focus, Stages, cursor refresh, layer pointer focus and shell IPC (gfc/1)", .author = "Grassfield", .version = gf::kPluginVersion};

    const std::string serverHash = __hyprland_api_get_hash();
    const std::string clientHash = __hyprland_api_get_client_hash();
    if (serverHash != clientHash) {
        // Refuse cleanly: nothing is hooked, so the session keeps Hyprland's defaults (C2).
        gf::log(Log::ERR, "ABI mismatch: Hyprland {} vs plugin built for {}; plugin inactive", serverHash, clientHash);
        // The degraded-mode notice (audit GF-033): what is off and how to get it back. The session normally never loads a
        // build stamped for another Hyprland (ADR-0009 "Amendment 2026-10-23", config/hypr/grassfield/compositor.lua);
        // this shows when one is loaded anyway (by hand, or a stamp that lies).
        notify("[Grassfield] The compositor extension was built for another Hyprland: titlebars, minimize and global menus are off. "
               "Run grassfield-compositor-rebuild in a terminal, then log out and back in.",
               CHyprColor{1.F, 0.35F, 0.3F, 1.F}, 30000.F);
        info.description += " [inactive: Hyprland version mismatch]";
        return info;
    }

    const bool ok = gf::guarded("PLUGIN_INIT", [&] {
        gf::ipc::startEvents(); // before anything can post (spec FR24)
        registerListeners();
        if (!gf::minimizer::start())
            gf::log(Log::WARN, "minimize render hooks failed to register; minimize not advertised");
        // Optional feature: a failure here only drops overview from the capabilities (the shell keeps thumbnails).
        bool overviewOk = false;
        gf::guarded("overview start", [&] { overviewOk = gf::overviewer::start(); });
        if (!overviewOk) {
            gf::guarded("overview rollback", [] { gf::overviewer::stop(); });
            gf::log(Log::WARN, "overview hooks failed to register; overview not advertised");
        }
        // Optional feature: a failure here only drops appmenu from the capabilities (the shell keeps T0 menus).
        bool appmenuOk = false;
        gf::guarded("appmenu start", [&] { appmenuOk = gf::appmenuServer::start(); });
        if (!appmenuOk) {
            gf::guarded("appmenu rollback", [] { gf::appmenuServer::stop(); });
            gf::log(Log::WARN, "appmenu global failed to start; appmenu not advertised");
        }
        // Optional feature: without it the shell keeps its own desktop focus workarounds and no file-changing desktop keys.
        bool desktopFocusOk = false;
        gf::guarded("desktop focus start", [&] { desktopFocusOk = gf::desktopFocus::start(); });
        if (!desktopFocusOk) {
            gf::guarded("desktop focus rollback", [] { gf::desktopFocus::stop(); });
            gf::log(Log::WARN, "desktop focus listeners failed to register; desktop-focus not advertised");
        }
        // Optional feature behind a flag (off at load; the shell pushes Settings windows.stages): without it the shell sends
        // no Stages flag and no Stages operation.
        bool stagesOk = false;
        gf::guarded("stages start", [&] { stagesOk = gf::stager::start(); });
        if (!stagesOk) {
            gf::guarded("stages rollback", [] { gf::stager::stop(); });
            gf::log(Log::WARN, "stages listeners failed to register; stages-available not advertised");
        }
        // Optional feature: without it the shell restores the focus after the Overview itself (checks and retries).
        bool overviewFocusOk = false;
        gf::guarded("overview focus start", [&] { overviewFocusOk = gf::overviewFocus::start(); });
        if (!overviewFocusOk) {
            gf::guarded("overview focus rollback", [] { gf::overviewFocus::stop(); });
            gf::log(Log::WARN, "overview focus listeners failed to register; overview-focus not advertised");
        }
        // Optional feature: without it the shell sends no refresh and a new pointer size shows at the next shape change.
        bool cursorRefreshOk = false;
        gf::guarded("cursor refresh start", [&] { cursorRefreshOk = gf::cursorRefresh::start(); });
        if (!cursorRefreshOk) {
            gf::guarded("cursor refresh rollback", [] { gf::cursorRefresh::stop(); });
            gf::log(Log::WARN, "no renderer for the cursor refresh; cursor-refresh not advertised");
        }
        // Optional feature: without it a click without motion after a shell layer mapped may miss it (Hyprland 0.56.2, FR51).
        bool layerPointerOk = false;
        gf::guarded("layer pointer start", [&] { layerPointerOk = gf::layerPointer::start(); });
        if (!layerPointerOk) {
            gf::guarded("layer pointer rollback", [] { gf::layerPointer::stop(); });
            gf::log(Log::WARN, "layer pointer listener failed to register; layer-pointer not advertised");
        }
        // Optional feature: without it windows that draw their own chrome still get no titlebar (P1 needs no listener), but
        // their minimize light and zoomed drag are not bridged and client-chrome is not advertised (the shell's Overview
        // then keeps the titlebar band above them).
        bool clientChromeOk = false;
        gf::guarded("client chrome start", [&] { clientChromeOk = gf::chrome::start(); });
        if (!clientChromeOk) {
            gf::guarded("client chrome rollback", [] { gf::chrome::stop(); });
            gf::log(Log::WARN, "client chrome listeners failed to register; client-chrome not advertised");
        }
        if (!gf::ipc::registerAll())
            gf::log(Log::WARN, "some IPC entry points failed to register");

        for (const auto& w : Desktop::windowState()->windows())
            decorate(w);

        s.active = true;

        const auto version = HyprlandAPI::getHyprlandVersion(handle);
        gf::log(Log::INFO, "{} {} initialised on Hyprland {} (commit {}), ABI hash match", gf::kPluginName, gf::kPluginVersion, version.tag, version.hash);

        gf::ipc::postCapabilities();
    });

    if (!ok) {
        gf::guarded("PLUGIN_INIT rollback", [] { teardown(); });
        notify("[Grassfield] Compositor plugin failed to start: titlebars disabled.", CHyprColor{1.F, 0.35F, 0.3F, 1.F});
        info.description += " [inactive: init failed]";
    }

    return info;
}

APICALL EXPORT void PLUGIN_EXIT() {
    gf::guarded("PLUGIN_EXIT", [] {
        if (state().active)
            teardown();
        gf::log(Log::INFO, "{} unloaded", gf::kPluginName);
    });
}
