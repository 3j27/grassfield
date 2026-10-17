#pragma once

// Minimize / restore with an animation toward / from the Dock tile (master-prompt §5.6 feature 2,
// ADR-0002). Hyprland glue; geometry, timing and validation live in core/Minimize.*.
//
// Mechanism (Hyprland 0.56.2, see docs/specs/compositor.md "Minimize"):
// - Hidden state = the special workspace `special:minimized`, the same one the shell's fallback uses, so a
//   window stays minimized (and the shell rebuilds its Dock tiles) when the plugin is unloaded or absent.
// - The animation is purely visual: a snapshot of the window (IHyprRenderer::makeSnapshotFB, what Hyprland
//   uses for its close animation) is drawn with a CTexPassElement at interpolated boxes from the
//   render.stage RENDER_POST_WINDOWS event (under the menu bar and the Dock), ticked from render.preChecks
//   like Hyprland's own animations. The window itself is never resized: animating its m_realSize would
//   configure the client to every intermediate size (CWindow's size animation calls sendWindowSize).
// - Minimize: snapshot, move to special:minimized at once (state first, so nothing can act on a half-
//   minimized window), animate window box -> tile. Restore: move back to the focused monitor's workspace,
//   focus, snapshot, keep the window transparent (WINDOW_ALPHA_MOVE_FROM_WORKSPACE, the alpha Hyprland uses
//   to fade windows in on arrival) while the snapshot grows tile -> window box, then show it.

#include "core/Minimize.hpp"

#include <cstdint>
#include <optional>

namespace gf::minimizer {

    // Registers the render / monitor / window listeners. False if any failed (then minimize is not advertised).
    bool start();

    // Unload: completes every animation at once (a restoring window is made visible again; minimized windows
    // stay on special:minimized), drops the snapshots, removes the listeners and the watchdog timer.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // A target rectangle the shell sent, validated against the current monitor layout (core isValidTarget).
    std::optional<gf::minimize::Box> validTarget(const gf::minimize::Box& rect);

    // Entry points of hl.plugin.grassfield.minimize / restore, after argument validation. A missing target
    // means "no animation". Unknown or unmapped windows, and windows already in the requested state, are
    // ignored (logged).
    void minimize(uint64_t address, std::optional<gf::minimize::Box> target);
    void restore(uint64_t address, std::optional<gf::minimize::Box> target);

} // namespace gf::minimizer
