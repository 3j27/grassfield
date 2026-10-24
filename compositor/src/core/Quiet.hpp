#pragma once

// Key paths log nothing (review of part B, 2026-10-24: a DEBUG line per key while the session was locked gave a password's
// length and typing rhythm away in hyprland.log). Every listener of a key event runs inside a CKeyPath scope (gf::keyPath in
// Plugin.hpp); gf::log and gf::logRequest write nothing while one is open, and do not count what they drop (the request
// budget's "held back" count would count keys). compositor/tests/QuietTest.cpp checks the scope and that every key listener
// of the plugin's sources opens one. Pure (no Hyprland include).

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

} // namespace gf::quiet
