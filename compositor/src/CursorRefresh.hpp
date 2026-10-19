#pragma once

// Pointer redraw after a size change (gfc/1 feature "cursor-refresh", spec FR39-FR40, ADR-0014). Hyprland glue; the
// decision and the rate limit live in core/CursorRefresh.*.
//
// Mechanism (Hyprland 0.56.2, read from the installed headers and the binary): `setcursor <theme> <size>` reloads the
// theme at the new size (CCursorManager::changeTheme) and leaves the image on screen alone. The refresh calls
// IHyprRenderer::setCursorFromName(m_lastCursorData.name, true), which is what IHyprRenderer::setCursorHidden(false)
// does to show the pointer again: the same name, the same shape index (no shape-switch timer reset), the image loaded
// again from the theme at its current size and handed to the pointer manager. Never while Hyprland hides the pointer
// (that call bypasses the hidden state when forced), never for a client's own cursor surface; the pointer position is
// not touched.

namespace gf::cursorRefresh {

    // Nothing to hook: true when Hyprland's renderer exists (then cursor-refresh may be advertised).
    bool start();

    // Unload: removes the trailing-refresh timer (its callback is code of this library) and forgets the gate state.
    // Safe to call more than once.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // Entry point of hl.plugin.grassfield.cursor_refresh(): refresh now, or once at the end of the rate-limit interval.
    void request();

} // namespace gf::cursorRefresh
