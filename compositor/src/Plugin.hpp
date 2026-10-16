#pragma once

// Shared plugin state and safety helpers (R13: no exception may escape into Hyprland).

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

#include <exception>
#include <format>
#include <string_view>
#include <vector>

class CGrassfieldTitlebar;

namespace gf {

    inline constexpr const char* kPluginName    = "grassfield-compositor";
    inline constexpr const char* kPluginVersion = "0.1.0-s2";

    struct SPluginState {
        HANDLE                             handle = nullptr;
        bool                               active = false; // true once hooks are registered (not on a hash mismatch)

        std::vector<CHyprSignalListener>   listeners;
        SP<SHyprCtlCommand>                hyprctlCommand;
        bool                               luaHelloRegistered = false;

        // Live titlebars. Owned by their windows; each removes itself in its destructor.
        std::vector<CGrassfieldTitlebar*> titlebars;
    };

    SPluginState& state();

    template <typename... Args>
    void log(Hyprutils::CLI::eLogLevel level, std::format_string<Args...> fmt, Args&&... args) {
        try {
            Log::logger->log(level, std::string{"[grassfield] "} + std::format(fmt, std::forward<Args>(args)...));
        } catch (...) {
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
