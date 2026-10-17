// grassfield-compositor: Hyprland plugin entry points (master-prompt §5.6, R13).
//
// Load ONLY into the nested dev instance (scripts/dev/nested-up.sh). On a Hyprland/plugin ABI
// mismatch the plugin refuses to hook anything and notifies once; the shell then falls back to
// its degraded mode because no `grassfield` capabilities event is ever posted.

#include "Ipc.hpp"
#include "Minimize.hpp"
#include "Plugin.hpp"
#include "Titlebar.hpp"

#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
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
        l.push_back(ev.window.title.listen([](const PHLWINDOW& w) {
            gf::guarded("window.title", [&] {
                if (auto* deco = titlebarFor(w))
                    deco->onTitleChanged();
            });
        }));
        l.push_back(ev.input.mouse.move.listen([](Vector2D /*pos*/, Event::SCallbackInfo& /*info*/) { CGrassfieldTitlebar::onGlobalMouseMove(); }));
        // Button events are observed, never cancelled (FR13): Hyprland must process every release to keep
        // its held-button state, which pins pointer focus while a button is down.
        l.push_back(ev.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& /*info*/) { CGrassfieldTitlebar::onGlobalMouseButton(e); }));
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
        step("minimizer", [] { gf::minimizer::stop(); }); // before the Lua entry points go: animations complete, snapshots dropped
        step("ipc", [] { gf::ipc::unregisterAll(); });
        step("titlebars", [] { removeAllTitlebars(); });
        s.active = false;
    }

    void notify(const std::string& text, const CHyprColor& color) {
        if (state().handle)
            HyprlandAPI::addNotification(state().handle, text, color, 8000);
    }
} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    auto& s  = state();
    s.handle = handle;

    PLUGIN_DESCRIPTION_INFO info{.name = gf::kPluginName, .description = "Grassfield titlebars and shell IPC (gfc/1)", .author = "Grassfield", .version = gf::kPluginVersion};

    const std::string serverHash = __hyprland_api_get_hash();
    const std::string clientHash = __hyprland_api_get_client_hash();
    if (serverHash != clientHash) {
        // Refuse cleanly: nothing is hooked, so the session keeps Hyprland's defaults (C2).
        gf::log(Log::ERR, "ABI mismatch: Hyprland {} vs plugin built for {}; plugin inactive", serverHash, clientHash);
        notify("[Grassfield] Compositor plugin built for another Hyprland version: titlebars disabled.", CHyprColor{1.F, 0.35F, 0.3F, 1.F});
        info.description += " [inactive: Hyprland version mismatch]";
        return info;
    }

    const bool ok = gf::guarded("PLUGIN_INIT", [&] {
        registerListeners();
        if (!gf::minimizer::start())
            gf::log(Log::WARN, "minimize render hooks failed to register; minimize not advertised");
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
