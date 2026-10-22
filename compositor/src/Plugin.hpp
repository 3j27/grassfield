#pragma once

// Shared plugin state and safety helpers (R13: no exception may escape into Hyprland).

#include "core/EventThrottle.hpp"
#include "core/Protocol.hpp"
#include "core/Tiling.hpp"

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

#include <chrono>
#include <exception>
#include <format>
#include <string>
#include <string_view>
#include <vector>

class CGrassfieldTitlebar;
class IHyprWindowDecoration;

namespace gf {

    inline constexpr const char* kPluginName    = "grassfield-compositor";
    inline constexpr const char* kPluginVersion = "0.11.0-tiling";

    struct SPluginState {
        HANDLE                             handle = nullptr;
        bool                               active = false; // true once hooks are registered (not on a hash mismatch)

        std::vector<CHyprSignalListener>   listeners;
        SP<SHyprCtlCommand>                hyprctlCommand;
        bool                               luaHelloRegistered    = false;
        bool                               luaMinimizeRegistered = false;
        bool                               luaRestoreRegistered  = false;
        bool                               luaConfigRegistered   = false;
        bool                               luaAppmenuRegistered  = false;
        bool                               luaOverviewRegistered = false;
        bool                               luaStagesRegistered   = false;
        bool                               luaCursorRefreshRegistered = false;
        bool                               luaOverviewFocusRegistered = false;
        bool                               luaTileRegistered          = false;

        // Settings pushed by the shell (hl.plugin.grassfield.config).
        gfc::DoubleClickAction doubleClickAction = gfc::DoubleClickAction::Zoom;
        // Window tiling (core/Tiling.hpp, Settings windows.tilingEdges / tilingMenuBar / tilingMargins): macOS defaults, all on.
        tiling::DragOptions tilingDrag;
        bool                tilingMargins = true;

        // Live titlebars. Owned by their windows; each removes itself in its destructor.
        std::vector<CGrassfieldTitlebar*> titlebars;

        // Log lines that requests trigger (see logRequest).
        events::CLogLimiter requestLog{20, std::chrono::seconds(1)};
    };

    SPluginState& state();

    // Removes a decoration that is being destroyed from this plugin's CPlugin::m_registeredDecorations.
    // Hyprland 0.56.2 never prunes that list, and after PLUGIN_EXIT CPluginSystem::unloadPlugin calls
    // removeWindowDecoration() on every pointer still in it: a stale pointer whose address was reused by
    // another window's decoration would remove that decoration.
    void forgetRegisteredDecoration(IHyprWindowDecoration* deco) noexcept;

    template <typename... Args>
    void log(Hyprutils::CLI::eLogLevel level, std::format_string<Args...> fmt, Args&&... args) {
        try {
            Log::logger->log(level, std::string{"[grassfield] "} + std::format(fmt, std::forward<Args>(args)...));
        } catch (...) { // NOLINT(bugprone-empty-catch): nothing to report to, and nothing may escape
            // logging must never throw into Hyprland
        }
    }

    // For log lines that requests can trigger at will (Wayland clients, Lua verbs over the hyprctl socket): at most 20
    // at once, then one per second, one budget for all of them (spec FR24). The next written line says how many were
    // held back.
    template <typename... Args>
    void logRequest(Hyprutils::CLI::eLogLevel level, std::format_string<Args...> fmt, Args&&... args) {
        try {
            const auto held = state().requestLog.admit(events::Clock::now());
            if (!held)
                return;
            std::string line = std::string{"[grassfield] "} + std::format(fmt, std::forward<Args>(args)...);
            if (*held > 0)
                line += std::format(" ({} similar line(s) held back)", *held);
            Log::logger->log(level, line);
        } catch (...) { // NOLINT(bugprone-empty-catch): nothing to report to, and nothing may escape
            // logging must never throw into Hyprland
        }
    }

    // Runs fn and swallows any exception (logged). Returns false when fn threw.
    template <typename Fn>
    bool guarded(std::string_view where, Fn&& fn) noexcept {
        try {
            fn();
            return true;
        } catch (const std::exception& e) {
            log(Log::ERR, "exception in {}: {}", where, e.what());
        } catch (...) {
            log(Log::ERR, "unknown exception in {}", where);
        }
        return false;
    }

} // namespace gf
