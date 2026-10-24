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

    // The zoom glyph shows the full-screen arrows while Alt is held (over the group, where glyphs show at all), and always
    // on the titlebar of a full-screen window (its light leaves full screen).
    bool zoomGlyphIsArrows(bool altHeld, bool fullscreen);

    // ---- P6: the titlebar of a full-screen window (macOS) ----
    // In full screen the titlebar is away. The pointer at the top edge of the window's monitor brings it back, below the
    // menu bar and over the window's content; it goes when the pointer leaves it, or with the full screen. Its zoom light
    // leaves full screen (the pointer's way out); its minimize light is unavailable (greyed and inert, as on macOS).
    inline constexpr double kRevealEdge  = 2.0; // the pointer this close to the monitor's top edge (layout px) reveals it
    inline constexpr double kRevealSlack = 8.0; // it stays until the pointer is this far below it (layout px)

    struct RevealInput {
        bool   fullscreen = false; // the window is in full screen on a visible workspace and has a plugin titlebar
        bool   onMonitor  = false; // the pointer is on the window's monitor
        double pointerY   = 0.0;   // the pointer below the monitor's top edge (layout px)
        double barTop     = 0.0;   // where the bar starts below the top edge (the menu bar's height, or 0)
        bool   pressing   = false; // a press on the revealed bar is not released yet
    };

    // Whether the titlebar is revealed after a pointer motion (or a change of the window), from whether it was.
    bool nextRevealed(bool revealed, const RevealInput& in);

    // Whether a light of a full-screen window's titlebar can be used (minimize cannot).
    bool lightAvailableInFullscreen(titlebar::Button button);

    // The presses on a revealed titlebar are the plugin's alone: they are cancelled on Hyprland's event bus with their
    // releases. Hyprland 0.56.2 returns from CInputManager::onMouseButton right after the bus when an event is cancelled,
    // before it records the button as held or released (read from the binary), so a cancelled press and its cancelled
    // release leave its held-button state as it was. This tracks the releases owed, per button: the bus event names no
    // device, so the caller takes a press on the bar only while no button is held anywhere (no other device's release of
    // the same button can then be mistaken for the bar's).
    class CRevealPresses {
      public:
        // A press, on the revealed bar or not. A release still owed for the same button was lost (its device went away):
        // forgotten, so that the release of this press, which Hyprland records, is never cancelled.
        void onPress(uint32_t button, bool onBar);
        // A release: true when it belongs to a press on the bar (cancel it too); the debt is paid.
        bool takeRelease(uint32_t button);
        // A press on the bar is not released yet (the bar stays while it is).
        bool pressing() const;
        void reset();

      private:
        std::set<uint32_t> m_owed;
    };

} // namespace gf::chrome
