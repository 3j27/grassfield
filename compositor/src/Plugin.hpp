#pragma once

// Shared plugin state and safety helpers (R13: no exception may escape into Hyprland).

#include "core/EventThrottle.hpp"
#include "core/Protocol.hpp"
#include "core/Quiet.hpp"
#include "core/Theme.hpp"
#include "core/Tiling.hpp"

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

#include <chrono>
#include <exception>
#include <format>
#include <utility>
#include <string>
#include <string_view>
#include <vector>

class CGrassfieldTitlebar;
class IHyprWindowDecoration;

#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // only a build without the VERSION file's definition
#endif

namespace gf {

    inline constexpr const char* kPluginName    = "grassfield-compositor";
    // From the VERSION file (cmake/GrassfieldVersion.cmake, build-direct.sh); "unknown" only when built without it.
    inline constexpr const char* kPluginVersion = GRASSFIELD_VERSION;

    struct SPluginState {
        HANDLE                             handle = nullptr;
        bool                               active = false; // true once hooks are registered (not on a hash mismatch)

        std::vector<CHyprSignalListener>   listeners;
        SP<SHyprCtlCommand>                hyprctlCommand;
        SP<SHyprCtlCommand>                hyprctlFramesCommand; // `hyprctl grassfield-frames` (FrameProbe, feature frame-times)
        SP<SHyprCtlCommand>                hyprctlFramesStartCommand; // `hyprctl grassfield-frames-start` (records for 60 s)
        SP<SHyprCtlCommand>                hyprctlStagesCommand; // `hyprctl grassfield-stages` (the Stages state; stages-available needs it)
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
        // The appearance the chrome follows (config "appearance", audit UX-06); dark until the shell says otherwise.
        theme::Appearance appearance = theme::kDefaultAppearance;

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

    // Nothing is written from a key path (core/Quiet.hpp): not a line, not a count.
    template <typename... Args>
    void log(Hyprutils::CLI::eLogLevel level, std::format_string<Args...> fmt, Args&&... args) {
        if (quiet::inKeyPath())
            return;
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
        if (quiet::inKeyPath())
            return; // before the budget: a dropped line would be counted in the next "held back" (a count of keys)
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

    // A key listener's body (Event::bus()->m_events.input.keyboard.key): guarded, and with every log line off while it runs,
    // whatever it calls (core/Quiet.hpp; compositor/tests/QuietTest.cpp fails on a key listener without it).
    template <typename Fn, typename Event, typename Info>
    void keyPath(std::string_view /*where*/, Fn&& fn, const Event& event, Info& info) noexcept {
        quiet::runKeyPath(std::forward<Fn>(fn), event, info);
    }

} // namespace gf
