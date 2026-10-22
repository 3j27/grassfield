#pragma once

// Window tiling, Hyprland side (pure logic: core/Tiling.hpp; spec FR47-FR50). The titlebar drag asks snapFor() while it
// moves a window and tile() at the release; hl.plugin.grassfield.tile(address, place) calls tileRequest().

#include "core/Tiling.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Vector2D.hpp>

#include <optional>
#include <string_view>

namespace gf::tiler {

    using Hyprutils::Math::CBox;
    using Hyprutils::Math::Vector2D;

    // A drag's pending place: where the window goes at the release, and the preview frame (titlebar included, layout
    // coordinates) on the monitor the pointer is on.
    struct Snap {
        tiling::Place place;
        CBox          frame;
        PHLMONITORREF monitor;
    };

    // The place for a titlebar drag of `w` with the pointer at `pointer`, honouring the drag options (state()).
    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer);

    // Tiles the floating window `w` into `place` on `monitor` (its own monitor when null). The first time, its box from
    // before is remembered for the drag-out and Return to Previous Size. False when the window cannot be placed.
    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor = nullptr);

    // Whether `w` is tiled (its box from before is known).
    bool isTiled(const PHLWINDOW& w);

    // The box from before tiling, forgotten (the window leaves its tile).
    std::optional<CBox> takePrevious(const PHLWINDOW& w);

    // hl.plugin.grassfield.tile(address, place): `place` is a core/Tiling.hpp name or "previous" (back to the box from
    // before tiling). Untrusted: the address is compared with the live windows, never dereferenced.
    void tileRequest(std::string_view address, std::string_view place);

    // Unload: forgets every tiled window.
    void forgetAll();

} // namespace gf::tiler
