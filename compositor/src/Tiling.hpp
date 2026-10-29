#pragma once

// Window tiling, Hyprland side (pure logic: core/Tiling.hpp; docs/specs/tiling.md TL1-TL21, ADR-0036). Every window stays
// floating: the plugin sets its box with CLayoutManager::setTargetGeom and keeps a tile record (core CTileBook) that
// follows Hyprland's events (full screen, Desktops, outputs, Hyprland's own resizes). Drags (TL16-TL20): the plugin's
// titlebar drag calls dragMotion() while it moves a window and tiles previewOf() at the release; Hyprland's own moves (an
// app's toolbar drag, Super+drag) are followed from the pointer listeners the same way and tiled once Hyprland ended them; a
// double-click on a window's resize border extends its sides. hl.plugin.grassfield.tile(address, place) calls
// tileRequest(), hl.plugin.grassfield.arrange(json) arrangeRequest(); `hyprctl grassfield-tiling` returns stateReply().
// Every change posts the bounded `tiling` notice (gfc/1). Compositor thread only, nothing blocks.

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
    // if any failed: stop() undoes what was registered and tiling-arrange is not advertised (tile() and the titlebar drag
    // still work, records are then only checked against the windows' boxes; Hyprland's moves and edge double-clicks do not
    // tile).
    bool start();

    // Unload: listeners, the scheduled callback and the preview timer removed (their code is in this library), the preview
    // gone, every record forgotten, the notice {"reason":"unavailable"} posted while the event throttle still runs. Windows
    // keep their boxes; a drag of Hyprland's in progress goes on as Hyprland's own. Safe more than once.
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

    // The place under the pointer for a drag of `w` with the pointer at `pointer`, honouring the drag options (state()) and
    // Alt (TL18); the frame is the one tile() gives at the release. Shown or not: see dragMotion().
    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer);

    // One drag at a time (one seat pointer): the plugin's titlebar drag or one of Hyprland's moves. The drag of `w` is at
    // `pointer`: the place under it shows once the pointer has rested on it for the preview delay, at once with Alt held
    // (TL17; a timer draws it when the pointer rests); the old and new preview frames are redrawn. Returns the place shown
    // now (a release tiles it).
    std::optional<Snap> dragMotion(const PHLWINDOW& w, const Vector2D& pointer);

    // The drag ended (released, cancelled, its window gone): no preview, no timer.
    void dragDone();

    // The place shown for a drag of `w` (its decoration draws the preview; a release tiles it); nullopt when none.
    std::optional<Snap> previewOf(const PHLWINDOW& w);

    // From the plugin's key listener: Alt may have changed; the drag's place is read again once Hyprland applied the key.
    void onKey();

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

    // The plugin may set `w`'s box (core movable: mapped, on a Desktop, its target in a layout space). A window that
    // closed or unmapped during a titlebar drag fails it: Hyprland would dereference null (gate C1).
    bool movable(const PHLWINDOW& w);

    // `w` can be tiled now (TL9): what the tiling popover greys when not (the tile-hover event's "tileable").
    bool tileable(const PHLWINDOW& w);

    // hl.plugin.grassfield.move_to(address, output) (TL23, TL26): `w` onto another output: a tiled window into the same place,
    // zone or sides there, any other at the same relative place (core moveToArea); it takes that output's Desktop. Untrusted:
    // the address and the output are compared with the live ones. Refused while locked (reason "locked") and for an
    // unknown output, the window's own output or a window that cannot move (reason "invalid").
    void moveToRequest(std::string_view address, std::string_view output);

    // hl.plugin.grassfield.group_front(address) (TL29): the members of the window's tile group on screen on its Desktop come
    // forward, in their stacking order (core groupRaiseOrder), above every other window, the window itself last when it is
    // on screen, zoomed or full screen included (the shell's activation may reach the compositor first, and changes nothing
    // for the focused window). A minimized or hidden window's restore raises it, before or after this request. Nothing for a
    // window without a group. Untrusted: the address is compared with the live
    // windows. Refused while locked (reason "locked") and for an unknown window (reason "invalid"); the tile records do not
    // change (no notice otherwise).
    void groupFrontRequest(std::string_view address);

    // hl.plugin.grassfield.split(address, side) (tiling.md TL33, ADR-0036 D41-D43): Full Screen › Left or Right of Screen. A new
    // Desktop with the next free id on the window's output, shown; the window in that half of the whole output (core
    // splitArea) and the suggestion of the other half from the Desktop it came from (always: the Split View asks for its
    // second window); nothing to suggest, it fills the Desktop alone. Untrusted: the address is compared with the live windows.
    // Refused while locked (reason "locked"); for a window that cannot be tiled now, one not on the Desktop its output shows,
    // one already in a Split View Desktop, a side other than left or right, or while Stages shows its strip (D47): "invalid".
    void splitRequest(std::string_view address, std::string_view side);

    // hl.plugin.grassfield.unsplit(address) (TL33, D44): Exit Full Screen of a window of a Split View Desktop. It goes back to
    // its home Desktop at its box from before, shown; the other window fills the Split View Desktop alone, and one left
    // without a window ends. Refused while locked (reason "locked") and for a window of no Split View Desktop ("invalid").
    void unsplitRequest(std::string_view address);

    // `w` is on a Split View Desktop: its titlebar drag does nothing (D46; step 6b swaps the two).
    bool inSplit(const PHLWINDOW& w);

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

    // "Suggest windows to fill the rest of a layout" turned off (TL32): the suggestion pending in the state reply ends; it
    // never comes back when the switch turns on again (integrator review of 1c08d6b).
    void suggestionsOff();

    // The reply of `hyprctl grassfield-tiling` (core stateJson). It moves no window: it only drops the records of closed
    // windows and of windows moved by other means.
    std::string stateReply();

    // From the plugin's pointer motion listener, before Hyprland applies the motion: one of Hyprland's resizes of a tiled
    // window began (Resizing); one of Hyprland's moves passed the drag threshold on a tiled window (TL16: Moving, its drag
    // ended and begun again from its size from before under the pointer) or goes on (dragMotion: the preview); no drag any
    // more ends a resize or a preview whose release was not seen. TL30: a drag of a shared edge's handle follows the
    // pointer; with no drag at all, the pointer resting on a handle shows its cursor.
    void beforePointerMotion();

    // From the plugin's first pointer button listener, after the top clamp's, before Hyprland handles the button: a press
    // records the grip; the release that ends one of Hyprland's moves tiles the place shown (TL16, the top clamp left out),
    // or makes a Moving window Free, once Hyprland ended the drag; the release that ends a resize ends Resizing then; two
    // left clicks on a window's resize border (Hyprland's border or the app's own, its resize begun and ended without
    // moving) extend its sides (TL20, with Alt the opposite ones) once Hyprland ended the second one. TL30: a plain left press
    // on a shared edge's handle (two windows of a tile group facing each other across the margin, the middle
    // tiling.handleLength of what they share; not under the lock, a foreign Exclusive layer or a layer) begins the plugin's
    // drag of that edge: every window along it is Resizing and follows the pointer, within every window's limits; the release
    // ends it (Tiled with the new boxes, one `resized` notice). True for that press and its release: the caller cancels them
    // on the bus (Hyprland's held-button state is left as it was, ADR-0015 P6), and no other listener acts on them.
    bool beforePointerButton(uint32_t button, bool pressed, uint32_t timeMs);

    // TL30: a drag of a shared edge's handle is in progress (DesktopFocus leaves its press alone).
    bool edgeOwnsPointer();

} // namespace gf::tiler
