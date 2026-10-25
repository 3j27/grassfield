#pragma once

// The run mode (ADR-0019): the one rule every Grassfield component uses. A development run is GRASSFIELD_DEV == "1"
// while GRASSFIELD_SESSION != "1"; only the exact string "1" counts for either. The plugin has no Qt, so it keeps its
// own read of the environment (Ipc.cpp, Hyprland's process environment) and decides here. A GRASSFIELD_DEV=1 that
// leaked into a Grassfield session opens no development hook: session.lua sets GRASSFIELD_SESSION=1 with hl.env, which
// calls setenv in Hyprland's own process (read from the 0.56.2 binary), so the plugin sees it. Pure (no Hyprland
// include): tests/RunModeTest.cpp checks it against the shared vectors (tests/fixtures/run-mode-vectors.json), the ones
// the shell's RunMode.js and the apps are held to.

namespace gf::runmode {

    // `devValue`, `sessionValue`: the raw values of GRASSFIELD_DEV and GRASSFIELD_SESSION (null: unset).
    bool dev(const char* devValue, const char* sessionValue);

    // A Grassfield session: GRASSFIELD_SESSION == "1".
    bool session(const char* sessionValue);

} // namespace gf::runmode
