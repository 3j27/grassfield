#pragma once

// Window tiling, Hyprland side (pure logic: core/Tiling.hpp; docs/specs/tiling.md TL1-TL15, ADR-0036). Every window stays
// floating: the plugin sets its box with CLayoutManager::setTargetGeom and keeps a tile record (core CTileBook) that
// follows Hyprland's events (full screen, Desktops, outputs, Hyprland's own resizes). The titlebar drag asks snapFor()
// while it moves a window and tile() at the release; hl.plugin.grassfield.tile(address, place) calls tileRequest(),
// hl.plugin.grassfield.arrange(json) arrangeRequest(); `hyprctl grassfield-tiling` returns stateReply(). Every change posts
// the bounded `tiling` notice (gfc/1). Compositor thread only, nothing blocks.

#include "core/Tiling.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Vector2D.hpp>

#include <optional>
#include <string>
#include <string_view>

namespace gf::tiler {

    using Hyprutils::Math::CBox;
    using Hyprutils::Math::Vector2D;

    // Registers the listeners that keep the tile records (window close, full screen, Desktop moves, output removal). False
    // if any failed: stop() undoes what was registered and tiling-arrange is not advertised (tile() still works, records
    // are then only checked against the windows' boxes).
    bool start();

    // Unload: listeners and the scheduled callback removed (their code is in this library), every record forgotten, the
    // notice {"reason":"unavailable"} posted while the event throttle still runs. Windows keep their boxes. Safe more than once.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // A drag's pending place: where the window goes at the release, and the preview frame (titlebar included, layout
    // coordinates) on the monitor the pointer is on.
    struct Snap {
        tiling::Place place;
        CBox          frame;
        PHLMONITORREF monitor;
    };

    // The place for a titlebar drag of `w` with the pointer at `pointer`, honouring the drag options (state()); the frame is
    // the one tile() gives at the release.
    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer);

    // Tiles the floating window `w` into `place` on `monitor` (the output under its middle when null): the work area read
    // now (TL1), the grid (TL3), a half beside a tiled neighbour (TL7), the window's limits (TL8). The first time, its box
    // from before is kept for the drag-out and Return to Previous Size. False when the window cannot be tiled (TL9).
    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor = nullptr);

    // Whether `w` is in its tile (its record is Tiled and its box is the one the plugin gave it).
    bool isTiled(const PHLWINDOW& w);

    // The plugin moved the floating window `w` (its titlebar drag, a tile): it now belongs to the Desktop shown on the
    // output under its middle, as after Hyprland's own move (CDragStateController::mouseMove assigns the target to that
    // output's active special or regular workspace). Hyprland never sees the plugin's drag (R13): without this a window
    // dragged to another output kept the old output's Desktop and monitor. Its box is kept exactly (assigning a target to
    // another space lets the floating algorithm fit it in the new work area, DefaultFloatingAlgorithm::movedTarget).
    void followOutput(const PHLWINDOW& w);

    // The plugin's titlebar drag of a tiled window passed the threshold: Moving, with the box from before tiling (the
    // window takes that size under the pointer). nullopt when `w` is not tiled.
    std::optional<CBox> beginMove(const PHLWINDOW& w);

    // The titlebar drag ended without tiling (released elsewhere, cancelled): a Moving window becomes Free.
    void endMove(const PHLWINDOW& w);

    // The titlebar drag of a zoomed window takes it out of its zoom under the pointer: a tile record it kept while zoomed
    // ends (Free), so leaving the zoom does not put it back in its tile mid-drag.
    void leave(const PHLWINDOW& w);

    // hl.plugin.grassfield.tile(address, place): `place` is a core/Tiling.hpp name or "previous" (back to the box from
    // before tiling). Untrusted: the address is compared with the live windows, never dereferenced. Refused while locked.
    void tileRequest(std::string_view address, std::string_view place);

    // hl.plugin.grassfield.arrange(json) (core parseArrange): a layout of the catalogue filled with the given windows, then
    // with the next tileable windows in stacking order (TL6). Untrusted; a refused request posts reason "invalid" (or
    // "locked") and changes nothing.
    void arrangeRequest(std::string_view json);

    // The margins setting changed: every tiled window is placed again from its zone (TL2).
    void marginsChanged();

    // The reply of `hyprctl grassfield-tiling` (core stateJson).
    std::string stateReply();

    // From the plugin's pointer motion listener: one of Hyprland's resizes of a tiled window began (Resizing), or a move
    // (the record ends: the window is Free); no drag any more ends a resize whose release was not seen.
    void beforePointerMotion();

    // From the plugin's first pointer button listener, after the top clamp's: the release that ends Hyprland's resize of a
    // tiled window schedules the end of Resizing once Hyprland ended the drag (the box it has then is the new box).
    void beforePointerButton(bool pressed);

} // namespace gf::tiler
