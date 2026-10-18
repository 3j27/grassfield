#pragma once

// Which window or layer surface a wl_surface belongs to (Hyprland 0.56.2 views), shared by the desktop focus policy and
// the overview's chrome checks.

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>

class CWLSurfaceResource;

namespace gf::surfaces {

    struct SOwner {
        PHLWINDOW window;        // the window (main surface, subsurface or one of its popups)
        PHLLS     layer;         // the layer surface (itself, a subsurface or one of its popups)
        bool      popup   = false; // the surface is (in) an xdg_popup of that window or layer surface
        bool      known   = false; // false: no surface, or a surface without a window or layer (lock screen, cursor...)
        bool      visible = false; // its view (window, layer surface or popup) is alive and visible (IView::aliveAndVisible)
    };

    // Subsurfaces are climbed to their top-level parent (at most 16 levels), popups to their window or layer owner.
    SOwner ownerOf(const SP<CWLSurfaceResource>& surface);

    // The seat's keyboard focus (nullptr when none).
    SP<CWLSurfaceResource> keyboardFocus();

    // The layer surface's keyboard interactivity as the protocol value (0 none, 1 exclusive, 2 on_demand); 0 without a
    // layer shell resource.
    uint32_t interactivity(const PHLLS& layer);

} // namespace gf::surfaces
