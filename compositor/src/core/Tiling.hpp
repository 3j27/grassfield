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
    // Centre: the window keeps its size, at most this fraction of the free area (token tiling.centerMaxFraction).
    inline constexpr double kCenterMaxFraction = theme::tokens::kTilingCenterMaxFraction;

    struct DragOptions {
        bool edges   = true; // "Drag windows to left or right edge of screen to tile"
        bool menuBar = true; // "Drag windows to menu bar to fill screen"
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

    // Where a window was placed: a place, or zone `zone` of layout `layout`.
    struct Placement {
        std::optional<Place> place;
        std::string          layout;
        int                  zone = -1;

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
    // "output":"<name>"?}. windows[i] takes zone i (1 to the layout's zone count of them, distinct, not 0); with "fill" (default
    // true) the plugin fills the remaining zones with the next tileable windows in stacking order (TL6). With "zone", exactly
    // one window goes to that zone of the layout and nothing is filled. Untrusted: strictly validated, at most kMaxArrangeBytes.
    inline constexpr size_t kMaxArrangeBytes = 4096;
    inline constexpr size_t kMaxOutputName   = 64;
    struct ArrangeRequest {
        std::string           layout;
        std::vector<uint64_t> windows;
        bool                  fill = true;
        std::optional<int>    zone;
        std::string           output;
    };
    std::expected<ArrangeRequest, std::string> parseArrange(std::string_view json);

    // hl.plugin.grassfield.config keys (values "true" | "false").
    inline constexpr std::string_view kConfigEdges   = "tilingEdges";
    inline constexpr std::string_view kConfigMenuBar = "tilingMenuBar";
    inline constexpr std::string_view kConfigMargins = "tilingMargins";
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
    // The reply of `hyprctl grassfield-tiling`.
    std::string stateJson(uint64_t generation, std::span<const StateOutput> outputs);

} // namespace gf::tiling
