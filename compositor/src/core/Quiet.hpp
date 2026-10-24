#pragma once

// Key paths log nothing (review of part B, 2026-10-24: a DEBUG line per key while the session was locked gave a password's
// length and typing rhythm away in hyprland.log). Every listener of a key event runs inside a CKeyPath scope (gf::keyPath in
// Plugin.hpp); gf::log and gf::logRequest write nothing while one is open, and do not count what they drop (the request
// budget's "held back" count would count keys). compositor/tests/QuietTest.cpp checks the scope and that every key listener
// of the plugin's sources opens one. Pure (no Hyprland include).

#include <utility>

namespace gf::quiet {

    class CKeyPath {
      public:
        CKeyPath() noexcept;
        ~CKeyPath();

        CKeyPath(const CKeyPath&)            = delete;
        CKeyPath& operator=(const CKeyPath&) = delete;
        CKeyPath(CKeyPath&&)                 = delete;
        CKeyPath& operator=(CKeyPath&&)      = delete;
    };

    // A key path is running on this thread (Hyprland's: the compositor is single-threaded).
    bool inKeyPath() noexcept;

    // A key listener's body inside a CKeyPath scope (gf::keyPath, Plugin.hpp), given the listener's own event and callback
    // info (the event by const reference: never changed here; the info as the listener got it, untouched here). The body
    // runs once and all it does stands. An exception it throws stays here (false): nothing may escape into Hyprland, and
    // nothing is logged from a key path.
    template <typename Fn, typename Event, typename Info>
    bool runKeyPath(Fn&& fn, const Event& event, Info& info) noexcept {
        const CKeyPath scope;
        try {
            std::forward<Fn>(fn)(event, info);
            return true;
        } catch (...) { // NOLINT(bugprone-empty-catch): a key path logs nothing; it must not throw into Hyprland
            return false;
        }
    }

} // namespace gf::quiet
