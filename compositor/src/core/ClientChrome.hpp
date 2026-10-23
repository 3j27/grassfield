#pragma once

// Windows that draw their own chrome (ADR-0015 "unified toolbar"; docs/specs/compositor.md "Plugin work item: client
// chrome"): Grassfield's apps draw their lights and toolbar themselves and tag their toplevel; the session rule
// gf-client-chrome (config/hypr/grassfield/windows.lua) turns that xdg tag into the Hyprland tag below, and the plugin
// steps aside for those windows. The rules here are pure (no Hyprland include): unit-tested in tests/ClientChromeTest.cpp.

#include "Theme.hpp"
#include "TitlebarLayout.hpp"

#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <string_view>

namespace gf::chrome {

    // The Hyprland tag of such windows. The shell's copy is shell/overview/ClientChrome.js (TAG): the plugin and the
    // shell's Overview decide by the same name (tests/shell/client_chrome_rules.sh checks the rule, the shell and the spec).
    inline constexpr std::string_view kTag = "grassfield-client-chrome";

    // P1: Hyprland's tags of a window (CTagKeeper::getTags) hold kTag. A dynamic tag, one a window rule set, is kept with a
    // trailing '*'; the name is what counts. Nothing else matches (no prefix, no case folding).
    bool hasClientChromeTag(const std::set<std::string>& tags);

    // The band the plugin reserves above a window's surface: its titlebar, none for a window that draws its own chrome
    // (P3: Stages thumbnails; also the tiling and restore frames, so that no empty strip is left above such a window).
    double band(bool clientChrome);

    // ---- P4: dragging a zoomed window by its own toolbar ----
    // The app starts Hyprland's interactive move (xdg_toplevel.move) from a press on its toolbar. macOS takes a window that
    // fills the screen out of that state at its previous size, under the pointer at the same place in its toolbar row.
    // The press is recorded before Hyprland handles it (the window is still zoomed then); the move request that follows
    // answers it when it comes for the same window while the button is still held, soon enough.
    inline constexpr uint64_t kMovePressMaxAgeMs = 3000;

    struct ZoomedPress {
        uint64_t       window = 0; // the window's address
        titlebar::Rect zoomed;     // its surface box while zoomed (layout px)
        double         x      = 0; // the press (layout px)
        double         y      = 0;
        uint64_t       timeMs = 0;
    };

    // The move request of `window` at `nowMs` answers `press`: same window, a button still held, at most
    // kMovePressMaxAgeMs after the press (a clock that went backwards answers nothing).
    bool moveAnswersPress(const std::optional<ZoomedPress>& press, uint64_t window, bool buttonHeld, uint64_t nowMs);

    // Where the window goes when such a move starts: its floating size back (restoredW x restoredH), the pointer at the
    // same horizontal fraction of the window and the same height below its top edge as at the press (titlebar::
    // unzoomedDragBox, the plugin titlebar's own rule).
    titlebar::Rect unzoomedBox(const ZoomedPress& press, double restoredW, double restoredH, double pointerX, double pointerY);

    // ---- P6: Option(Alt)+click on the zoom light ----
    // macOS: the green light zooms; with Option held it enters full screen (and the glyph shows the full-screen arrows).
    enum class ZoomAction : uint8_t {
        Zoom,             // maximize (FSMODE_MAXIMIZED)
        Unzoom,           // back from maximized
        EnterFullscreen,  // FSMODE_FULLSCREEN (the shell hides the menu bar as for any full screen)
        LeaveFullscreen,  // back from full screen
    };

    // What a press on the zoom light does, from the window's state and whether Alt is held. A window in full screen
    // leaves it whatever the modifier (macOS: the green light of a full-screen window exits it).
    ZoomAction zoomAction(bool maximized, bool fullscreen, bool altHeld);

    // The zoom glyph shows the full-screen arrows while Alt is held (over the group, where glyphs show at all).
    bool zoomGlyphIsArrows(bool altHeld);

} // namespace gf::chrome
