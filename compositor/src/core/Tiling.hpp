#pragma once

// Window tiling (macOS 15+ model with the Windows 11 layouts the owner took; docs/specs/compositor.md FR47-FR50,
// docs/specs/tiling.md TL1-TL15, ADR-0036). A window dragged by its titlebar so that the pointer touches a free left or
// right edge of an output fills that half; near a corner of that edge, that quarter; the pointer on the menu bar fills the
// free area. hl.plugin.grassfield.tile(address, place) places one window (Window > Move & Resize);
// hl.plugin.grassfield.arrange(json) fills a layout of the catalogue with several windows (macOS Arrange, the Layouts
// section). Every window stays a floating window: the plugin only sets its box and keeps a tile record (CTileBook).
// Pure logic, no Hyprland includes: unit-tested in tests/TilingTest.cpp.

#include "ThemeTokens.hpp"

#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::tiling {

    // Box in global logical (layout) coordinates.
    struct Rect {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;

        bool   operator==(const Rect&) const = default;
    };

    enum class Place : uint8_t {
        Left,
        Right,
        Top,
        Bottom,
        TopLeft,
        TopRight,
        BottomLeft,
        BottomRight,
        Fill,
        Center,
        LeftThird,
        MiddleThird,
        RightThird,
        LeftTwoThirds,
        RightTwoThirds,
    };

    // Drag geometry (tokens tiling.edge, tiling.cornerBand). The pointer is on an edge when it is within kEdge px of it
    // (the pointer stops at an outer edge); on a corner of a side edge when it is also within kCorner px of the output's
    // top or bottom.
    inline constexpr double kEdge   = theme::tokens::kTilingEdge;
    inline constexpr double kCorner = theme::tokens::kTilingCornerBand;
    // Gap around and between tiled windows when margins are on (token tiling.margin; macOS "Tiled windows have margins").
    inline constexpr double kMargin = theme::tokens::kTilingMargin;
    // The shared-edge handle (TL30): the middle of a shared stretch where a drag moves the whole edge, and its least width
    // across the edge (tokens tiling.handleLength, tiling.handleBand).
    inline constexpr double kHandleLength = theme::tokens::kTilingHandleLength;
    inline constexpr double kHandleBand   = theme::tokens::kTilingHandleBand;
    // Centre: the window keeps its size, at most this fraction of the free area (token tiling.centerMaxFraction).
    inline constexpr double kCenterMaxFraction = theme::tokens::kTilingCenterMaxFraction;

    struct DragOptions {
        bool edges   = true; // "Drag windows to left or right edge of screen to tile"
        bool menuBar = true; // "Drag windows to menu bar to fill screen"
        bool altDrag = true; // "Hold Alt key while dragging windows to tile" (TL18)
    };

    // The output the pointer is on: its full box, the bottom of the menu bar strip (the output's top reserved area), and
    // whether its left / right edges are free (no other output there: a shared edge is a way to the next output).
    struct Output {
        Rect   box;
        double menuBarBottom = 0;
        bool   leftFree      = true;
        bool   rightFree     = true;
    };

    // The place a drag would tile into with the pointer at (x, y), or none.
    std::optional<Place> placeForPointer(double x, double y, const Output& output, const DragOptions& options);

    // TL18: with Alt held, the nearest half, quarter or fill from the pointer's position in the work area `area`, split in
    // thirds across and down: the corner cells give the quarters, the side cells of the middle row the halves, the
    // top-middle cell Fill, the centre and bottom-middle cells the half on the pointer's side. A pointer outside the area
    // (on the menu bar, over the Dock) counts in the nearest cell.
    Place placeForAltPointer(double x, double y, const Rect& area);

    // The place of a drag with the pointer at (x, y) on `output` (nullopt: off it): with Alt held and the Alt drag on,
    // placeForAltPointer in the work area `area`, whatever the edge and menu-bar settings; else placeForPointer.
    std::optional<Place> dragPlace(double x, double y, const Output& output, const Rect& area, const DragOptions& options, bool alt);

    // TL17: a drag's place shows (its preview is drawn, a release tiles it) once the pointer has rested on that place of
    // the same output for kPreviewDelay ms (token tiling.previewDelay), at once with Alt held; another place, another
    // output or none starts over and hides the preview at once.
    inline constexpr uint64_t kPreviewDelay = theme::tokens::kTilingPreviewDelay;
    class CDwell {
      public:
        // The pointer is on `place` of output `output` (nullopt: none) at `nowMs`; `immediate`: Alt is held. True when
        // the place shows now.
        bool update(std::optional<Place> place, std::string_view output, uint64_t nowMs, bool immediate);
        // Milliseconds until the place shows if the pointer stays on it (the timer that draws it then); nullopt when it
        // shows already or there is no place.
        std::optional<uint64_t> remaining(uint64_t nowMs) const;
        bool                    shown() const;
        void                    reset();

      private:
        std::optional<Place> m_place;
        std::string          m_output;
        uint64_t             m_since = 0;
        bool                 m_shown = false;
    };

    // TL22: the pointer resting on a window's zoom light for kHoverDelay ms (token tiling.hoverDelay) is a hover: `enter`,
    // and `leave` once the pointer is off that light. One light at a time. A press while the pointer is on the light (its
    // click zooms the window) ends the hover and holds it off until the pointer has left that light.
    inline constexpr uint64_t kHoverDelay = theme::tokens::kTilingHoverDelay;
    struct HoverChange {
        std::optional<uint64_t> leave; // the window whose hover ended (post leave)
        std::optional<uint64_t> enter; // the window whose hover began (post enter)
    };
    class CHoverDwell {
      public:
        // The pointer is over the zoom light of window `window` (nullopt: over none) at `nowMs`.
        HoverChange             update(std::optional<uint64_t> window, uint64_t nowMs);
        // A press (or a drag) begins: a hover that began ends, and the light waits until the pointer has left it.
        HoverChange             press();
        // Milliseconds until the light under the pointer is a hover if the pointer stays (the timer that posts enter then);
        // nullopt when there is nothing to wait for.
        std::optional<uint64_t> remaining(uint64_t nowMs) const;
        std::optional<uint64_t> entered() const;
        void                    reset();

      private:
        std::optional<uint64_t> m_window;
        uint64_t                m_since   = 0;
        bool                    m_entered = false;
        bool                    m_held    = false; // pressed: no hover on this light until the pointer leaves it
    };

    // The shell's popup layer (shell/overlay/Overlay.qml): mapped Exclusive while a shell popup is open, the tiling popover
    // included, on the output of that popup only.
    inline constexpr std::string_view kShellPopupNamespace = "grassfield-overlay";
    // What hides every zoom light from the hover now (TL22, TL34; integrator review of 4ead6fb): the session is locked; an
    // Exclusive layer other than the shell's popup layer is mapped anywhere (the polkit sheet, Search, Apps, the Overview, the
    // switcher, the Notification Center, the Dock's keyboard mode, a third-party one); or a Top or Overlay layer, or a layer
    // popup, is under the pointer (the light is covered, the shell's own popup layer too).
    struct HoverCover {
        bool                     locked = false;
        std::vector<std::string> exclusiveNamespaces; // of the mapped Exclusive layers
        bool                     layerUnderPointer = false;
    };
    // What a cover does to the hover (D24; integrator nested rerun of 25e757c). Away: the lock or a foreign Exclusive layer
    // took the desktop; the hover ends and starts over once it is back (CHoverDwell::update with no light), so a pointer that
    // rested on a light through the lock gives a hover after the delay. Over: a layer covers the light (the shell's open
    // popover included); as a press, the light waits until the pointer has left it, so a popover closed over the light does not
    // come back by itself. The lock and a foreign Exclusive layer come first.
    enum class HoverCoverEffect : uint8_t {
        None,
        Away,
        Over,
    };
    HoverCoverEffect hoverCoverEffect(const HoverCover& cover);

    // The `tile-hover` event (gfc/1). enter: the pointer rested on the window's zoom light (TL22); leave: it left that light;
    // open: hl.plugin.grassfield.tile_popover asked for the popover with the keyboard (Super+Ctrl+L, TL26). enter and open
    // carry the light's box (layout coordinates) and whether the window can be tiled (TL9: the shell greys the glyphs):
    // {"v":"gfc/1","type":"tile-hover","address":"<hex>","state":"enter","x":…,"y":…,"w":…,"h":…,"tileable":true}. Bounded.
    enum class HoverState : uint8_t {
        Enter,
        Leave,
        Open,
    };
    std::string_view hoverStateName(HoverState state); // its "state" in the event
    std::string tileHoverJson(uint64_t address, HoverState state, const Rect& light = {}, bool tileable = false);

    // The output a window belongs to after the plugin moved it (its titlebar drag, a tile): the one under the middle of
    // its box, as Hyprland's own move decides (CDragStateController::mouseMove); nullopt off every output (it keeps its
    // Desktop). `outputs`: the outputs' logical boxes.
    std::optional<size_t> outputUnder(const Rect& box, std::span<const Rect> outputs);

    // What the plugin knows of a window before it moves it.
    struct WindowFacts {
        bool mapped    = false; // CWindow::m_isMapped
        bool onDesktop = false; // CWindow::m_workspace is set (unmapping clears it, Window.cpp:750)
        bool inSpace   = false; // its layout target is in a layout space (unmapping takes it out, Window.cpp:2639)
        bool floating  = false;
    };

    // The plugin may set the window's box: CLayoutManager::setTargetGeom reaches the target's space and
    // CWindow::moveToWorkspace reads its old Desktop, both without a null check. A window that closed or unmapped during a
    // titlebar drag fails it (integrator re-review of 439e1f2, gate C1).
    bool movable(const WindowFacts& w);

    // followOutput: give the window the Desktop of the output under its middle (`output`, outputUnder) when it is movable
    // and floating, there is such an output, and that Desktop's space is not already the window's (`sameSpace`).
    bool shouldFollow(const WindowFacts& w, std::optional<size_t> output, bool sameSpace);

    // ---- geometry (TL1-TL8) ----

    // A zone of the work area on a 12 x 12 grid: halves, thirds and quarters are exact twelfths.
    inline constexpr int kZoneGrid = 12;
    struct Zone {
        int  x = 0;
        int  y = 0;
        int  w = kZoneGrid;
        int  h = kZoneGrid;

        bool operator==(const Zone&) const = default;
    };

    // The zone of a single place; nullopt for Center (it keeps the window's size).
    std::optional<Zone> zoneOf(Place place);

    // TL3: Hyprland keeps an output's scale on steps of 1/120 with an integer logical size (output/Monitor.cpp:996-1048), so
    // `120 / gcd(round(scale x 120), 120)` logical px is a whole number of device px too. That step when it is at most
    // kMaxGridStep, else 1 (whole logical px only; the device position is then Hyprland's rounding).
    inline constexpr int kMaxGridStep = 4;
    int gridStep(double scale);

    // Edges are snapped to multiples of `step` logical px from the output's logical origin.
    struct Grid {
        double originX = 0;
        double originY = 0;
        int    step    = 1;
    };

    // Where tiles go: the work area (the output minus its reserved area and the Stages strip column, TL1), the margin
    // (0 when "Tiled windows have margins" is off) and the output's grid.
    struct Area {
        Rect   box;
        double margin = 0;
        Grid   grid;
    };

    // The frame (titlebar band included) of `zone` in `area`: the area shrunk by the margin, the zone's twelfths of it, half
    // a margin taken on each side of an edge between two zones; every edge a whole logical px on the grid (TL3: an edge
    // between zones is rounded to the nearest grid line, an outer edge to the nearest one inside the work area). Two zones
    // that share an edge without margins share one value. Never smaller than 1 x 1.
    Rect zoneFrame(const Zone& zone, const Area& area);

    // What a window allows (logical px). min*/max* are its surface's limits (TL8: for an xdg window the larger of a
    // min_size rule and its protocol minimum; maxW/maxH 0 = none); inc*/base* its X11 resize increments (0 = none);
    // `band` the titlebar band above its surface (32 for the plugin's titlebar, 0 for client chrome, ADR-0015).
    struct Constraints {
        double minW  = 1;
        double minH  = 1;
        double maxW  = 0;
        double maxH  = 0;
        double incW  = 0;
        double incH  = 0;
        double baseW = 0;
        double baseH = 0;
        double band  = 0;
    };

    // TL8: frames[i] (zone zones[i]) made to fit constraints[i]. A frame smaller than the window's minimum first takes room
    // from the zones on the other side of its inner edges as far as their own minimum allows (the shared edge moves for
    // them too), then grows alone (from its edge on the work area's border, or both ways) and overlaps; never beyond the
    // work area unless the minimum is larger than it. A frame larger than the maximum shrinks to it, centred in its zone.
    // X11 increments round a surface down, top-left kept. Moves are whole grid steps where the minimum allows.
    std::vector<Rect> fitFrames(std::span<const Zone> zones, std::span<const Rect> frames, std::span<const Constraints> constraints, const Area& area);

    // TL7: a half (Left, Right, Top, Bottom) next to a tiled neighbour that already holds the other side: the frame from the
    // work area's edge to that neighbour, one margin before it. A neighbour holds the other side when its frame touches
    // the opposite inner edge and both perpendicular inner edges (within one grid step) and leaves at least a quarter of
    // the work area; the nearest such neighbour wins. nullopt: an exact half.
    std::optional<Rect> halfBesideNeighbour(Place place, const Area& area, std::span<const Rect> neighbourFrames);

    // Center: the window keeps its size (at most kCenterMaxFraction of the work area), in the middle, snapped.
    Rect centerFrame(const Rect& currentSurface, double band, const Area& area);

    // TL20: the sides of a window a double-click on its resize border extends, as a mask.
    inline constexpr uint8_t kSideLeft   = 1;
    inline constexpr uint8_t kSideRight  = 2;
    inline constexpr uint8_t kSideTop    = 4;
    inline constexpr uint8_t kSideBottom = 8;
    inline constexpr uint8_t kAllSides   = kSideLeft | kSideRight | kSideTop | kSideBottom;

    // The sides a press at (x, y) on a window's resize border grips. `surface`: the box Hyprland's border grab surrounds
    // (the window's geometric box, InputManager processMouseDownNormal). Left of it: left; right of it: right; above or
    // below likewise (both near a corner); inside it (a press in a rounded corner, which Hyprland also takes as the
    // border): the corner of the quadrant the press is in.
    uint8_t sidesAt(double x, double y, const Rect& surface);

    // The sides a double-click on `sides` extends: with Alt, the opposite side of each too (a corner then gives all four:
    // the window fills the work area).
    uint8_t extendedSides(uint8_t sides, bool alt);

    // TL20: the frame `frame` (titlebar band included) with each side in `sides` moved to the work area's edge, inside the
    // margin and on the grid (the edges of the whole-area frame, zoneFrame); the other sides stay. The window's limits
    // (`constraints`, band included): never larger than its maximum nor smaller than its minimum, X11 increments round its
    // surface down; the side that did not move stays, and when both sides of an axis moved a maximum centres the window.
    Rect extendFrame(const Rect& frame, uint8_t sides, const Constraints& constraints, const Area& area);

    // "top", "bottom", "left", "right" joined by "-" in that order ("top-left", "left-right"); "" for none.
    std::string sidesName(uint8_t sides);

    // Move to <display> of a window that is not tiled (TL23): its frame `frame` in the work area `from` goes to the work area
    // `to` at the same relative place (the free space left and above it keeps its share on each axis), its size kept, at
    // most `to`'s; whole logical px.
    Rect moveToArea(const Rect& frame, const Rect& from, const Rect& to);

    // The frame (titlebar included) of a surface box: what the preview draws; and back.
    Rect frameOf(const Rect& surface, double titlebar);
    Rect surfaceOf(const Rect& frame, double titlebar);

    // The window's surface box for `place` in the free area `area` at scale 1 with the area's own origin as grid origin:
    // the helper the drag preview and the single-window requests share (zoneFrame, centerFrame).
    Rect surfaceFor(Place place, const Rect& area, double titlebar, bool margins, const Rect& current);

    // ---- outputs and the layout catalogue (TL5, owner decision T1f) ----

    enum class OutputClass : uint8_t {
        Small,     // under kLargeWidth logical px wide
        Large,     // kLargeWidth or wider
        UltraWide, // aspect kUltraWideAspect or wider
        Portrait,  // taller than wide
    };
    inline constexpr double kLargeWidth      = 1920.0;
    inline constexpr double kUltraWideAspect = 21.0 / 9.0;
    OutputClass      classify(double logicalWidth, double logicalHeight);
    std::string_view nameOf(OutputClass outputClass);

    // A layout of the catalogue (tokens tiling.layout*): zones in zone order, the first for the window that asks.
    inline constexpr size_t kMaxZones = 4;
    struct Layout {
        std::string_view  id;
        std::vector<Zone> zones;
    };
    std::span<const Layout>           catalogue();
    const Layout*                     layoutById(std::string_view id);
    std::span<const std::string_view> layoutsFor(OutputClass outputClass); // the Layouts section of that class (tokens tiling.class*)

    // ---- the tile record (TL10) ----

    enum class TileState : uint8_t {
        Tiled,     // in its tile
        Moving,    // a drag that began tiled: it took its box from before under the pointer
        Resizing,  // a resize by the user (Hyprland's drag): the record and the group stay
        Suspended, // full screen, zoomed, minimized or hidden: back to its tile when it returns
    };
    std::string_view nameOf(TileState state);

    // Where a window was placed: a place, zone `zone` of layout `layout`, or the sides an edge double-click extended (TL20).
    struct Placement {
        std::optional<Place> place;
        std::string          layout;
        int                  zone  = -1;
        uint8_t              sides = 0;

        bool                 operator==(const Placement&) const = default;
    };

    struct TileRecord {
        uint64_t    id    = 0;
        TileState   state = TileState::Tiled;
        Placement   where;
        Rect        box;    // the surface box the plugin gave it, or that it took through a user resize
        Rect        before; // its floating surface box before the first tiling
        double      band = 0;
        uint64_t    group = 0; // 0: none
        std::string output;
        int64_t     workspace = 0;
        bool        relayout  = false; // placed again from its zone when it comes back (margins changed, output gone)
        bool        deferred  = false; // placed again from its zone once it can be (TL2: the margins changed while it could not
                                       // be placed, e.g. in an inactive stage); its box is still the plugin's, so it is checked
    };

    // The tile records of every window (TL10). A group lives while two of its members are Tiled, Resizing or Suspended.
    // `generation()` grows with every change (the tiling notice).
    class CTileBook {
      public:
        // Free, Tiled or Moving -> Tiled. `current`: the window's surface box now; it becomes `before` unless the window
        // already has a record (a later tiling keeps the box from before the first one). `group` 0: none; joining another
        // group leaves the old one, which dissolves when one member is left. Returns the record.
        const TileRecord& placed(uint64_t id, const Rect& current, const Rect& box, double band, Placement where, std::string output, int64_t workspace,
                                 uint64_t group);
        // Tiled -> Moving: the box from before (the window takes its size under the pointer); it leaves its group. nullopt
        // when the window is not Tiled.
        std::optional<Rect> beginMove(uint64_t id);
        // Moving -> Free (a release elsewhere, a cancelled drag). A release that tiles calls placed() instead.
        void endMove(uint64_t id);
        // Tiled -> Resizing. False when the window is not Tiled.
        bool beginResize(uint64_t id);
        // Resizing -> Tiled with the new box; `before` and the group stay.
        void endResize(uint64_t id, const Rect& box);
        // Tiled or Resizing -> Suspended.
        bool suspend(uint64_t id);
        // Suspended -> Tiled (the glue checks zoneFree first and calls forget() otherwise). nullptr when not Suspended.
        const TileRecord* resume(uint64_t id);
        // Tiled: its box differs from the record by more than 1 px (something the plugin does not observe moved or
        // resized it) -> Free; false then, and for a window without a record. Moving, Resizing, Suspended and a record
        // waiting to be placed again (markRelayout: its output went away and Hyprland moved it): true.
        bool check(uint64_t id, const Rect& current);
        // Return to Previous Size: the box from before, the window Free.
        std::optional<Rect> takeBefore(uint64_t id);
        // The window closed, unmapped or was placed by other means.
        void forget(uint64_t id);
        void clear();
        // Changes the box of a Tiled window (a re-placement after a margins change or an output removal).
        void setBox(uint64_t id, const Rect& box, std::string output);
        // Marks a record to be placed again from its zone when it comes back (Suspended) or now (Tiled).
        void markRelayout(uint64_t id, bool on);
        // Marks a Tiled record to be placed again once its window can be (see TileRecord::deferred). Unlike markRelayout
        // the record is still checked against the window's box: a window the user moves meanwhile becomes Free.
        void markDeferred(uint64_t id, bool on);
        // Move to Desktop: the record keeps its state and box on the window's new Desktop.
        void setWorkspace(uint64_t id, int64_t workspace);

        const TileRecord*           find(uint64_t id) const;
        std::span<const TileRecord> records() const;
        uint64_t                    newGroup();
        uint64_t                    generation() const;
        // A suggestion's window joins the window that asked (TL28): that window's group, a new one it joins first when it has
        // none. 0 when it has no record.
        uint64_t joinGroup(uint64_t asker);

        // TL10: no other window that is Tiled or Resizing on `output` and `workspace` has a frame overlapping `frame` by
        // more than 1 px on both axes. `ignore`: windows that do not count either (an inactive stage's, drawn in the strip).
        bool zoneFree(const Rect& frame, std::string_view output, int64_t workspace, uint64_t except, std::span<const uint64_t> ignore = {}) const;

      private:
        TileRecord* get(uint64_t id);
        void        changed();
        void        leaveGroup(TileRecord& r);
        void        dissolveIfSingle(uint64_t group);

        std::vector<TileRecord> m_records;
        uint64_t                m_nextGroup  = 1;
        uint64_t                m_generation = 0;
    };

    // ---- requests ----

    // "left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center",
    // "left-third", "middle-third", "right-third", "left-two-thirds", "right-two-thirds".
    std::optional<Place> parsePlace(std::string_view name);
    std::string_view    nameOf(Place place);

    // hl.plugin.grassfield.arrange(json): {"layout":"<catalogue id>","windows":["0x<hex>",…],"fill":bool?,"zone":int?,
    // "with":"0x<hex>"?,"output":"<name>"?}. windows[i] takes zone i (1 to the layout's zone count of them, distinct, not 0);
    // with "fill" (default true) the plugin fills the remaining zones with the next tileable windows in stacking order (TL6).
    // With "zone", exactly one window goes to that zone of the layout and nothing is filled (a zone of the Layouts section,
    // TL27). "with" (only with "zone"; feature tiling-layouts) names the window whose layout the zone belongs to: a pick of
    // the suggestions (TL28); the window joins that window's group. Untrusted: strictly validated, at most kMaxArrangeBytes.
    inline constexpr size_t kMaxArrangeBytes = 4096;
    inline constexpr size_t kMaxOutputName   = 64;
    // An output name a request may carry: 1 to kMaxOutputName characters of [A-Za-z0-9._-].
    bool outputNameOk(std::string_view name);
    struct ArrangeRequest {
        std::string           layout;
        std::vector<uint64_t> windows;
        bool                  fill = true;
        std::optional<int>      zone;
        std::optional<uint64_t> with;
        std::string             output;
    };
    std::expected<ArrangeRequest, std::string> parseArrange(std::string_view json);

    // ---- tile groups (TL29) ----

    // The members of the group of `chosen` that come forward with it (a window brought forward from the Dock, the app
    // switcher or the Overview), in the order to raise them: the stacking order, bottom first (`stack`: the windows on
    // screen, bottom to top: none on a special workspace). Members Tiled or Resizing on the Desktop of `chosen`; a suspended
    // one (minimized, full screen, zoomed, hidden) stays where it is. `chosen` comes last whenever it is in `stack`, whatever
    // its state (zoomed or full screen it is Suspended but on screen; integrator review of cd74af2): the shell's activation
    // also raises it but may reach the compositor first, and changes nothing for the focused window. A minimized or hidden
    // `chosen` is not in `stack`: its restore raises it, before or after this request. Empty when no member comes forward
    // (`chosen` has no group, or none on screen beside it).
    std::vector<uint64_t> groupRaiseOrder(std::span<const TileRecord> records, uint64_t chosen, std::span<const uint64_t> stack);

    // ---- shared edge (TL30) ----

    // A Tiled member of a group on one output's Desktop as the shared edge sees it: its frame (titlebar band included) and
    // its limits (its surface's minimum and maximum, `band` the titlebar band; X11 increments are not applied during a drag,
    // as Hyprland's own floating resize does not apply them).
    struct EdgeWindow {
        uint64_t    id    = 0;
        uint64_t    group = 0;
        Rect        frame;
        Constraints limits;
    };

    // An edge the windows of one group share. Vertical (side by side): the windows `before` it (left) have their right side
    // on `at`, those `after` it (right) their left side `gap` further (the margin between them, 0 without margins);
    // horizontal (stacked) likewise with the bottom and top sides. Only windows that face one across the edge are in it, and
    // every such window of the group along that line is. `handles`: one per pair of facing windows, the middle
    // `handleLength` of the stretch they share (all of it when shorter), at least `band` across (the gap, widened equally
    // into both windows when narrower: without margins the windows touch).
    struct SharedEdge {
        bool                  vertical = true;
        uint64_t              group    = 0;
        double                at       = 0;
        double                gap      = 0;
        std::vector<uint64_t> before;
        std::vector<uint64_t> after;
        std::vector<Rect>     handles;
    };

    // The shared edges of `windows` (the Tiled group members of one output's Desktop). Two windows face each other when
    // they are in the same group (never group 0), the gap between their facing sides is from -1 to `maxGap` + 1 logical px
    // (the margin; frames sit on the grid) and they overlap along the edge by more than 1 px; an edge gathers the pairs of
    // one group on the same line (`at` and `gap` within 1 px).
    std::vector<SharedEdge> sharedEdges(std::span<const EdgeWindow> windows, double maxGap, double handleLength, double band);

    // The edge one of whose handles holds the point (x, y) (the first in `edges`), or nullopt.
    std::optional<SharedEdge> edgeAt(std::span<const SharedEdge> edges, double x, double y);

    // Whether a handle under the pointer may take it (TL30, TL34): the frontmost window under the point always gets the
    // click (macOS). `topmost`: the window Hyprland's pointer focus finds there (its hit test with the reserved and input
    // extents and floating windows: a titlebar, a border grab area, a popup, a full-screen window, from the top of the
    // stack), 0 when none; `popup`: an xdg popup of it holds the point. Clear when no window is there or it is one of the
    // edge's own windows by its body or border, never by a popup.
    bool handleClear(const SharedEdge& edge, uint64_t topmost, bool popup);

    // A drag of `edge` by `delta` logical px along its axis (x for a vertical edge) from the frames at the press
    // (`windows`, which hold every window of the edge): the before windows' far side and the after windows' near side move
    // together and the gap stays; the edge lands on the grid line nearest the pointer; it never takes a window under its
    // minimum or over its maximum (heights count the titlebar band), stopping on the last grid line that keeps every window
    // within them, and does not move when no line does. Returns the new frames, the before windows then the after ones in
    // the edge's order (a window `windows` lacks is left out).
    std::vector<std::pair<uint64_t, Rect>> dragEdge(const SharedEdge& edge, std::span<const EdgeWindow> windows, double delta, const Grid& grid);

    // ---- suggestions (TL28) ----

    // The zones of the layout instance of `asker` that a window holds: its own and those of the members of its group placed
    // in the same layout on the same output and Desktop (Tiled, Resizing or Suspended: a suspended member comes back to its
    // zone), in zone order, each once.
    std::vector<int> zonesHeld(std::span<const TileRecord> records, const TileRecord& asker);
    // The zones of `layout` that are not in `held`, in zone order.
    std::vector<int> emptyZones(const Layout& layout, std::span<const int> held);

    // What the shell offers to fill the rest of a layout (TL28) after an arrangement or a zone of the Layouts section left
    // zones empty: kept by the plugin, published in the state reply while the tile records are still those of `generation`
    // (any later change ends it) and the window that asked still holds its zone.
    inline constexpr size_t kMaxSuggested = 12;
    struct Suggestion {
        uint64_t              generation = 0;
        uint64_t              asker      = 0; // the window whose layout it fills
        std::string           layout;
        std::string           output;
        std::vector<int>      zones;   // the empty zones, zone order: the shell offers the first
        std::vector<Rect>     frames;  // their frames (layout coordinates), same order
        std::vector<uint64_t> windows; // the windows that can fill them, at most kMaxSuggested (D26)
    };

    // hl.plugin.grassfield.config keys (values "true" | "false").
    inline constexpr std::string_view kConfigEdges   = "tilingEdges";
    inline constexpr std::string_view kConfigMenuBar = "tilingMenuBar";
    inline constexpr std::string_view kConfigMargins = "tilingMargins";
    inline constexpr std::string_view kConfigAltDrag = "tilingOptionDrag"; // Settings windows.tilingOptionDrag (TL18)
    std::optional<bool> parseBool(std::string_view value);

    // ---- the tiling notice and state (gfc/1, ADR-0007) ----

    enum class Reason : uint8_t {
        None,
        Placed,      // a window took a tile (tile, arrange, a release in a drag zone)
        Moved,       // a tiled window was dragged away
        Resized,     // a user resize of a tiled window ended
        Suspended,   // full screen, zoom, minimize or hide
        Restored,    // back from Suspended
        Forgotten,   // a record ended (Free, closed, Return to Previous Size)
        Relaid,      // windows placed again (margins changed, an output went away)
        Invalid,     // a refused request (nothing changed)
        Locked,      // a request refused while the session is locked (tiling.md TL34; nothing changed)
        Unavailable, // the plugin unloads
    };
    std::string_view reasonName(Reason reason);

    // The `tiling` event, a change notice: {"v":"gfc/1","type":"tiling","gen":N} plus "reason":"…". Bounded (ADR-0007: no
    // event grows with the windows); the state is the reply of `hyprctl grassfield-tiling`.
    std::string noticeJson(uint64_t generation, Reason reason);

    struct StateOutput {
        std::string                    name;
        Rect                           area; // the work area a placement would use now
        OutputClass                    outputClass = OutputClass::Small;
        int                            grid        = 1;
        std::vector<const TileRecord*> windows;
    };
    // The reply of `hyprctl grassfield-tiling`: "suggestion" is null without one.
    std::string stateJson(uint64_t generation, std::span<const StateOutput> outputs, const Suggestion* suggestion = nullptr);

} // namespace gf::tiling
