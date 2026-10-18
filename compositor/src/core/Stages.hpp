#pragma once

// Stages (Grassfield's stage manager, master-prompt §5.6 feature 6, M5; UI name "Stages"): the stage model per workspace,
// request parsing and validation, thumbnail geometry and the event JSON. Plain C++ with no Hyprland includes, so it is
// unit-testable (compositor/tests/StagesTest.cpp). The Hyprland glue (Stages.cpp) keeps the windows of inactive stages
// mapped and live, draws them into the shell's strip tiles with a Render::IWindowTransformer and blocks their input.
// Spec and shell contract: docs/specs/stages.md; decision: docs/decisions/ADR-0013-stages.md.
//
// Coordinates are layout coordinates (Hyprland's global logical space, what `hyprctl clients` reports as at/size).

#include "Overview.hpp"

#include <cstddef>
#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::stages {

    using Box   = gf::minimize::Box;
    using Curve = gf::overview::Curve;

    using WindowId    = uint64_t; // Hyprland window address (compared, never dereferenced)
    using StageId     = uint32_t; // 0 = none; unique within one plugin load
    using WorkspaceId = int64_t;

    // Limits of hl.plugin.grassfield.stages(json) (untrusted input).
    inline constexpr size_t kMaxPayloadBytes = 8192;
    inline constexpr size_t kMaxStrips       = 8;  // one per monitor
    inline constexpr size_t kMaxTiles        = 8;  // per strip
    inline constexpr size_t kMaxMonitorName  = 64; // bytes
    inline constexpr double kMaxDurationMs   = 2000;
    inline constexpr double kMinTileSide     = 16;  // layout px
    inline constexpr double kMaxTileSide     = 800; // layout px

    // Windows managed per workspace; further windows are shown normally (never hidden).
    inline constexpr size_t kMaxWindowsPerWorkspace = 64;

    // Thumbnail stacking inside a tile: at most kStackDepth distinct positions, each one kStackStep px up-left of the one
    // in front of it; windows further back share the backmost position.
    inline constexpr size_t kStackDepth = 3;
    inline constexpr double kStackStep  = 8;
    // The plugin's titlebar above each window's surface box (logical px, scaled with the thumbnail).
    inline constexpr double kTitlebarHeight = 28;
    // How far left of its monitor a hidden strip's thumbnails are drawn (they are then not visible).
    inline constexpr double kHiddenMargin = 48;

    // ---- model ----

    struct WindowInfo {
        WindowId    id = 0;
        std::string app; // the window's class: windows of one app share a stage (macOS "all at once")
    };

    struct Stage {
        StageId               id = 0;
        std::vector<WindowId> windows; // back to front
    };

    // The stages of one workspace. Stages are kept in recency order: the first one is the active stage (its windows are
    // shown and usable at their real places), the others are the strip, most recent first. An emptied stage disappears;
    // when the active stage empties, the most recent inactive stage becomes active.
    class CWorkspaceStages {
      public:
        // Stages turned on with these windows (back to front, as stacked): one stage per app, the stage of `focused` (else
        // of the front window) active, the others ordered by their front-most window (most recent first). Windows beyond
        // kMaxWindowsPerWorkspace are ignored. `nextId` allocates stage ids.
        void reset(std::span<const WindowInfo> backToFront, std::optional<WindowId> focused, StageId& nextId);

        // A window mapped on (or moved to) this workspace: it joins the stage holding a window of the same app, which
        // becomes active; otherwise it opens a new stage, which becomes active. False when it is already known or the
        // workspace is full (then it stays unmanaged: shown normally).
        bool add(const WindowInfo& window, StageId& nextId);

        // A window closed, unmapped or left: false if unknown.
        bool remove(WindowId window);

        // The stage becomes active (the previous active stage goes to the front of the strip). False: unknown or active.
        bool activate(StageId stage);

        // The window moves into `to` (on top of its windows), or into a new stage at the front of the strip (nullopt).
        // False when the window or the stage is unknown, `to` is the window's own stage, or the window is alone in its
        // stage and would only be moved into a new stage.
        bool moveWindow(WindowId window, std::optional<StageId> to, StageId& nextId);

        // Every window of `stage` joins the active stage (on top). False: unknown or active.
        bool merge(StageId stage);

        // The window comes to the front of its stage (a focus inside the active stage). False if unknown or already there.
        bool raise(WindowId window);

        std::optional<StageId>    stageOf(WindowId window) const;
        StageId                   active() const; // 0 when there is no stage
        bool                      isActive(WindowId window) const;
        const std::vector<Stage>& stages() const; // recency order: [0] active, then the strip, most recent first
        size_t                    windowCount() const;
        bool                      contains(WindowId window) const;

      private:
        Stage*                  find(StageId stage);
        const std::string*      appOf(WindowId window) const;
        void                    pruneEmpty();
        std::vector<Stage>      m_stages;
        std::vector<WindowInfo> m_known; // every managed window with its app
    };

    // ---- requests ----

    struct Strip {
        std::string      monitor;   // output name
        std::vector<Box> tiles;     // slot 0 first (top); the shell draws its chrome around them
        bool             hidden = false; // thumbnails slid out to the left of the monitor
    };

    enum class Op : uint8_t {
        On,       // turn Stages on, or update the strips, timing and hidden flags while on
        Off,      // every window back to normal
        Activate, // a strip stage becomes active (a click on its tile)
        Move,     // a window moves into a stage, or into a new stage ("stage":"new")
        Merge,    // a strip stage joins the active stage (windows grouped)
    };

    struct Request {
        Op                     op         = Op::Off;
        double                 durationMs = 0;
        Curve                  curve;
        std::vector<Strip>     strips;  // On
        StageId                stage = 0; // Activate, Merge, Move (0 with newStage for Move)
        bool                   newStage = false;
        WindowId               window   = 0; // Move
    };

    // Parses and validates {"op":"on","durationMs":int,"curve":[x1,y1,x2,y2]?,"strips":[{"monitor":"…","hidden":bool?,
    // "tiles":[{"x","y","w","h"}…]}…]}, {"op":"off","durationMs":int?}, {"op":"activate","stage":N},
    // {"op":"merge","stage":N}, {"op":"move","address":"0x…","stage":N|"new"}. Strict: a JSON object of at most
    // kMaxPayloadBytes; `op` required; `durationMs` an integer 0..kMaxDurationMs (required for on); strips at most
    // kMaxStrips with distinct monitor names ([A-Za-z0-9._-], 1..kMaxMonitorName bytes), 1..kMaxTiles tiles each, finite
    // numbers, sides kMinTileSide..kMaxTileSide, tiles of one strip not overlapping; stage ids positive integers below
    // 2^32. Unknown keys are skipped (additive gfc/1 fields), a key given twice is an error. Whether monitors, stages and
    // windows exist and whether the strip surface covers the tiles is checked by the glue.
    std::expected<Request, std::string> parseRequest(std::string_view json);

    // ---- geometry ----

    // Where each window of a strip stage is drawn in its tile: one surface rect per window, same order as
    // `surfacesBackToFront` (the windows' current surface boxes). Each window is fitted (uniform scale, centred, never
    // distorted) with its titlebar band into its stack position; the front window takes the bottom-right position.
    std::vector<Box> thumbRects(const Box& tile, std::span<const Box> surfacesBackToFront);

    // How far a hidden strip slides left: the horizontal shift that puts the right edge of its tiles kHiddenMargin px left
    // of the monitor (its thumbnails are then not visible). Stages without a tile use the last tile, shifted the same way.
    double hiddenShift(std::span<const Box> tiles, const Box& monitor);

    // Every tile lies inside `surface` (the strip surface's box) and inside `monitor` (1 px tolerance).
    bool tilesCovered(std::span<const Box> tiles, const Box& surface, const Box& monitor);

    // The strip band of a monitor: the bounding box of its tiles, expanded by `margin` (overlap test of active windows).
    Box stripBand(std::span<const Box> tiles, double margin);

    // ---- events ----

    enum class Reason : uint8_t {
        None,
        Invalid,     // the request failed validation
        Disabled,    // the feature flag (config stagesEnabled) is off
        NoStrip,     // a strip's monitor is unknown, or the shell's strip surface is missing or does not cover the tiles
        Unknown,     // activate / move / merge named a stage or window that does not exist (any more)
        Unavailable, // the plugin is unloading
        Interrupted, // the shell's strip surface went away: that monitor's windows are shown normally
    };

    std::string_view reasonName(Reason reason);

    struct EventWindow {
        WindowId           id = 0;
        std::optional<Box> thumb; // where its surface box is drawn in its tile (strip stages with a tile only)
    };

    struct EventStage {
        StageId                  id   = 0;
        int                      slot = -1; // tile index, -1 for the active stage and for stages beyond the tiles
        std::vector<EventWindow> windows;   // back to front
    };

    struct EventMonitor {
        std::string             monitor;
        WorkspaceId             workspace = 0;
        StageId                 active    = 0;
        bool                    hidden    = false;
        bool                    overlap   = false; // an active-stage window overlaps the strip band
        std::vector<EventStage> stages;            // recency order, active first
    };

    // {"v":"gfc/1","type":"stages","on":bool,"monitors":[{"monitor":"…","workspace":N,"active":N,"hidden":bool,
    // "overlap":bool,"stages":[{"id":N,"slot":N,"windows":[{"address":"<hex, no 0x>","x":…,"y":…,"w":…,"h":…}]}]}]},
    // plus "reason":"…" when a request was refused (the state is the unchanged current one) or Stages ended without the
    // shell's request. Window rects are present only for windows drawn in a tile; numbers are rounded to 0.1 px.
    std::string eventJson(bool on, std::span<const EventMonitor> monitors, Reason reason = Reason::None);

    // ---- feature flag ----

    // hl.plugin.grassfield.config("stagesEnabled", "true" | "false").
    inline constexpr std::string_view kConfigStagesEnabled = "stagesEnabled";
    std::optional<bool>               parseStagesEnabled(std::string_view key, std::string_view value);

} // namespace gf::stages
