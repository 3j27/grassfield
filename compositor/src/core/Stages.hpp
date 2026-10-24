#pragma once

// Stages (Grassfield's stage manager, master-prompt §5.6 feature 6, M5; UI name "Stages"): the stage model per workspace,
// request parsing and validation, thumbnail geometry and the event JSON. Plain C++ with no Hyprland includes, so it is
// unit-testable (compositor/tests/StagesTest.cpp). The Hyprland glue (Stages.cpp) keeps the windows of inactive stages
// mapped and live, draws them into the shell's strip tiles with a Render::IWindowTransformer and blocks their input.
// Spec and shell contract: docs/specs/stages.md; decision: docs/decisions/ADR-0013-stages.md.
//
// Coordinates are layout coordinates (Hyprland's global logical space, what `hyprctl clients` reports as at/size).

#include "DeferredFocus.hpp"
#include "Overview.hpp"
#include "Theme.hpp"

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
    inline constexpr double kMaxTileCoord    = 1.0e6; // |x|, |y| of a tile (layout px): far beyond any monitor layout, never inf

    // Windows managed per workspace; further windows are shown normally (never hidden).
    inline constexpr size_t kMaxWindowsPerWorkspace = 64;

    // Thumbnail stacking inside a tile: at most kStackDepth distinct positions, each one kStackStep px up-left of the one
    // in front of it; windows further back share the backmost position.
    inline constexpr size_t kStackDepth = 3;
    inline constexpr double kStackStep  = 8;
    // The plugin's titlebar above each window's surface box (logical px, scaled with the thumbnail). A window that draws
    // its own chrome has none (ADR-0015 P3, core/ClientChrome.hpp band): the glue passes the band of each window.
    inline constexpr double kTitlebarHeight = gf::theme::kTitlebarHeight;
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
    // numbers, sides kMinTileSide..kMaxTileSide, |x| and |y| at most kMaxTileCoord, tiles of one strip not overlapping; stage
    // ids positive integers below 2^32. Unknown keys are skipped (additive gfc/1 fields), a key given twice is an error.
    // Whether monitors, stages and
    // windows exist and whether the strip surface covers the tiles is checked by the glue.
    std::expected<Request, std::string> parseRequest(std::string_view json);

    // ---- geometry ----

    // Where each window of a strip stage is drawn in its tile: one surface rect per window, same order as
    // `surfacesBackToFront` (the windows' current surface boxes). Each window is fitted (uniform scale, centred, never
    // distorted) with its titlebar band into its stack position; the front window takes the bottom-right position.
    // `bands`: the band above each window (same order; kTitlebarHeight, 0 for a window that draws its own chrome); empty,
    // shorter, or a value that is not finite and >= 0: kTitlebarHeight.
    std::vector<Box> thumbRects(const Box& tile, std::span<const Box> surfacesBackToFront, std::span<const double> bands = {});

    // How far a hidden strip slides left: the horizontal shift that puts the right edge of its tiles kHiddenMargin px left
    // of the monitor (its thumbnails are then not visible). Stages without a tile use the last tile, shifted the same way.
    double hiddenShift(std::span<const Box> tiles, const Box& monitor);

    // Every tile lies inside `surface` (the strip surface's box) and inside `monitor` (1 px tolerance).
    bool tilesCovered(std::span<const Box> tiles, const Box& surface, const Box& monitor);

    // The strip band of a monitor: the bounding box of its tiles, expanded by `margin` (overlap test of active windows).
    Box stripBand(std::span<const Box> tiles, double margin);

    // Where the windows of the strip stage in `slot` (0 = the first tile) are drawn: one entry per window, same order as
    // `surfacesBackToFront`. In tile `slot` when the strip has one (shifted off the monitor while the strip is hidden or the
    // monitor shows a full-screen window); beyond the tiles beside the last tile, off the monitor (the shell has no tile for
    // it). `thumb`: its place in its tile when the strip is shown (events), absent beyond the tiles. A change of the tiles
    // (count, places) only changes these targets: each window is then animated from where it is drawn now (the glue's
    // retarget), so the strip updates smoothly (stages.md, Shell side work item 3).
    struct StripTarget {
        Box                to;
        std::optional<Box> thumb;
    };
    std::vector<StripTarget> stripTargets(size_t slot, std::span<const Box> tiles, bool hidden, bool fullscreen, const Box& monitor,
                                          std::span<const Box> surfacesBackToFront, std::span<const double> bands = {});

    // Every tile lies inside `monitor` (1 px tolerance; finite and bounded). False without tiles.
    bool tilesInMonitor(std::span<const Box> tiles, const Box& monitor);

    // ST17, the shell's strip for op:on: its tiles inside their monitor (always: they are the shown places the hidden shift,
    // the thumbnails and the drop zone are computed from), its surface on the Top or Overlay layer, and while the strip is
    // shown the surface's box and input region over every tile (input over a thumbnail must reach the strip, never the
    // window drawn there). A hidden strip (hidden:true) draws its thumbnails off the monitor: its input region may shrink
    // to its reveal zone at the edge (stages.md, Shell side work item 2). A reveal (hidden:false) is checked again.
    bool stripAccepted(bool hidden, bool layerOk, bool tilesInside, bool boxCovers, bool inputCovers);

    // ---- a window dragged to the strip (macOS: a window dragged onto the strip becomes a stage of its own) ----

    // How far right of the strip's tiles a titlebar drag release still counts as on the strip (logical px).
    inline constexpr double kStripDropMargin = 16.0;

    // The release point (layout) lies on `monitor`, left of the right edge of its strip's tiles plus kStripDropMargin
    // (the whole height of the monitor: the strip is the left side of the screen). False without tiles.
    bool inDropZone(double x, double y, std::span<const Box> tiles, const Box& monitor);

    struct DropFacts {
        bool on       = false; // Stages is on (the shell sent op:on)
        bool hasStrip = false; // the release monitor has the shell's strip
        bool hidden   = false; // that strip is hidden (slid out): no drop zone (macOS: the drop target is the visible strip; the
                               // shell reveals it, hidden:false, while the pointer rests at the edge)
        bool inZone   = false; // inDropZone
        bool managed  = false; // the dragged window is in a stage of the Desktop shown there
        bool active   = false; // ... of its active stage (strip windows cannot be dragged: their input is blocked)
        bool alone    = false; // it is the only window of that stage (it is a stage of its own already)
        bool tiling   = false; // the release tiles the window (window tiling at a screen edge wins)
    };

    enum class DropAction : uint8_t {
        None,     // a normal drag: the window stays where it was dropped
        NewStage, // the window goes to the strip as a stage of its own (op move "new"), back at its place from before the
                  // drag, and the active stage's front window keeps the keyboard
    };

    DropAction dropAction(const DropFacts& facts);

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

    // The front window of the active stage of the Desktop shown on a monitor: the app the menu bar names (macOS keeps naming
    // the frontmost app). It is the window that holds, or takes once a layer surface lets go, the keyboard; while an
    // Exclusive layer holds the keyboard after a swap Hyprland has no active window at all (ST24), so the shell cannot learn
    // it from Hyprland.
    struct EventFront {
        WindowId    id = 0;
        std::string app; // the window's class (what stages group by), as received from the client: sanitized by eventJson
    };

    struct EventMonitor {
        std::string               monitor;
        WorkspaceId               workspace = 0;
        StageId                   active    = 0;
        bool                      hidden    = false;
        bool                      overlap   = false; // an active-stage window overlaps the strip band
        std::optional<EventFront> front;             // absent when the Desktop has no stage
        std::vector<EventStage>   stages;            // recency order, active first
    };

    // Longest app name in an event (bytes); a client's class can be any length.
    inline constexpr size_t kMaxAppBytes = 256;

    // Client text made safe for the event: valid UTF-8 kept, every invalid byte replaced by U+FFFD, cut at a character
    // boundary to at most `maxBytes` bytes (JSON escaping is done by the caller).
    std::string sanitizedText(std::string_view in, size_t maxBytes);

    // {"v":"gfc/1","type":"stages","on":bool,"monitors":[{"monitor":"…","workspace":N,"active":N,"hidden":bool,
    // "overlap":bool,"front":{"address":"<hex, no 0x>","app":"…"},"stages":[{"id":N,"slot":N,"windows":[{"address":"<hex,
    // no 0x>","x":…,"y":…,"w":…,"h":…}]}]}]}, plus "reason":"…" when a request was refused (the state is the unchanged
    // current one) or Stages ended without the shell's request. Window rects are present only for windows drawn in a tile;
    // numbers are rounded to 0.1 px; "front" is absent when the Desktop has no stage.
    std::string eventJson(bool on, std::span<const EventMonitor> monitors, Reason reason = Reason::None);

    // ---- input on strip windows ----
    // A strip window keeps its real place and is input-blocked; Hyprland 0.56.2 updates pointer focus on pointer motion
    // only and does not check the block when it delivers keys, buttons or scrolls to the current focus. These decisions
    // keep every event away from a blocked window (R13 review of 46b3e9b).

    // Focus reasons and presses: the deferred-focus decisions shared with the overview focus (core/DeferredFocus.*).
    using FocusCause   = gf::deferredfocus::FocusCause;
    using FocusOrigin  = gf::deferredfocus::FocusOrigin;
    using PressContext = gf::deferredfocus::PressContext;
    using PressScope   = gf::deferredfocus::PressScope;
    using PressRecord  = gf::deferredfocus::PressRecord;
    using gf::deferredfocus::clickFromPress;
    using gf::deferredfocus::focusOrigin;
    using gf::deferredfocus::recordPress;

    // Only a user choice brings a strip window's stage forward (ST10); otherwise the active stage keeps the keyboard.
    bool stripFocusBringsStage(FocusOrigin origin);

    // Hyprland's focused window when the keyboard is checked again (the focused window left its workspace's active stage:
    // closed, unmapped, minimized, moved away; or Hyprland focused a strip window without a user choice).
    struct KeyboardHolder {
        bool present  = false; // Hyprland has a focused window
        bool eligible = false; // mapped, not hidden, on a workspace shown on a monitor, takes input (or is about to:
                               // its stage is the active one)
    };

    enum class KeyboardTarget : uint8_t {
        Keep,          // Hyprland's choice stands
        FrontOfActive, // the front window of the workspace's active stage takes the keyboard
        Nothing,       // no window keeps it (keyboard focus cleared; the desktop policy decides on the next press)
    };

    // The keyboard never stays on a minimized, hidden or strip window: an eligible holder keeps it, otherwise the active
    // stage's front window takes it (`hasFront`), otherwise nothing holds it.
    KeyboardTarget keyboardAfterLeave(const KeyboardHolder& holder, bool hasFront);

    // Before every key (keepKeyboardFocus in Stages.cpp; integrator decision 2026-10-24, by the macOS model: a modal system
    // prompt always gets the keyboard, and there is always a key window). wlr-layer-shell: a Top or Overlay surface with
    // Exclusive keyboard interactivity gets every key; on Bottom and Background ones the compositor's normal focus stays.
    // Hyprland drops a keyboard focus change while the session has no keyboard device (CSeatManager::setKeyboardFocus:
    // "BUG THIS: setKeyboardFocus without a valid keyboard set") and gives a keyboard device that appears only its own
    // focus surface (CInputManager::setupKeyboard), both read from the 0.56.2 binary. In a session whose keyboards come and
    // go (a keyboard plugged in, a Bluetooth keyboard reconnecting, an on-screen keyboard) the seat's keyboard could stay
    // off a dialog, or on nothing after it, and every key was lost (stages.sh 8c, 8f, 8g, 8h, 8i(e): the three nested runs
    // without a keyboard device of their own lost them all, the thirteen with one lost none).
    enum class KeyFocusAction : uint8_t {
        None,     // the seat's keyboard focus stands
        ToLayer,  // the frontmost Exclusive Top or Overlay layer gets the keyboard
        ToWindow, // Hyprland's active window gets the keyboard back
    };
    inline constexpr uint32_t kLayerTop = 2; // zwlr_layer_shell_v1 layers: 0 background, 1 bottom, 2 top, 3 overlay

    struct KeyFocusFacts {
        bool     locked            = true;  // the session is locked, or that is not known (failures stay locked)
        bool     inputMethodGrab   = false; // an input method grabs the keyboard: its keys and surfaces are left alone
        bool     exclusive         = false; // a mapped layer surface has Exclusive keyboard interactivity (any layer)
        uint32_t frontmostLevel    = 0;     // the frontmost such layer's level (replacesFrontmost)
        bool     seatOnFrontmost   = false; // the seat's keyboard is on it (or one of its popups)
        bool     grabRejectsLayer  = false; // a seat grab is set and does not accept it
        bool     seatFocusNone     = false; // the seat's keyboard is on no surface
        bool     activeWindow      = false; // Hyprland has an active window that may take the keyboard (mapped, shown, takes input)
        bool     grabRejectsWindow = false; // a seat grab is set and does not accept that window's surface
        bool     keyArriving       = true;  // checked before a key; false: from the event loop after a focus change, a layer
                                            // mapped or unmapped, or a keyboard device that appeared
    };

    // ToLayer: an Exclusive layer is up, the frontmost is on Top or Overlay and the seat's keyboard is not on it. ToWindow:
    // no Exclusive layer, the seat's keyboard on nothing, an active window that may take it, and a key arriving (from the
    // event loop the plugin's other focus rules and Hyprland's refocus may still give the keyboard elsewhere: the overview's
    // "no window is key", a deferred focus). Never while locked, under an input method's keyboard grab, or against a seat
    // grab that rejects the surface. While an Exclusive layer is up no window gets the keyboard (Hyprland refuses every
    // window focus then).
    KeyFocusAction keyFocusAction(const KeyFocusFacts& facts);

    // Walking Hyprland's Exclusive-layer list in order: a layer on `level` replaces the frontmost found so far (on
    // `bestLevel`, if any) unless its level is lower (the latest to become Exclusive wins among equals).
    bool replacesFrontmost(uint32_t level, std::optional<uint32_t> bestLevel);

    // Hyprland's active window (CFocusState::window()) is what window key bindings (close, full screen, floating), window
    // dispatchers without an explicit window and the shell's menu bar (foreign-toplevel "activated") act on. It can differ
    // from the keyboard holder: while a layer surface holds the keyboard (an Exclusive one: Search, the overview chrome,
    // Quick Settings, the polkit dialog; or an on_demand one: the desktop) it stays the last focused window, and Hyprland
    // refuses every window focus while an Exclusive layer is mapped or the session is locked. It must never be a strip
    // window (R13 counter-review of 17208af). The plugin never works around Hyprland's refusal (R13 counter-review #3 of
    // e9ebc7f: setting Hyprland's Exclusive-layer list aside let the keyboard leave an Exclusive layer through Hyprland's
    // side paths: a special workspace closing, a Desktop switch).
    struct ActiveWindowState {
        bool hidden        = false; // Hyprland's active window is a strip window (or is about to be blocked as one)
        bool locked        = false; // the session is locked (nothing is focused until the unlock; the lock is not touched)
        bool layerKeyboard = false; // a layer surface (or one of its popups) holds the keyboard
        bool exclusive     = false; // an Exclusive layer surface is mapped (Hyprland refuses window focus)
        bool hasFront      = false; // the active stage of that window's workspace has a front window that may be focused
    };

    enum class ActiveWindowAction : uint8_t {
        None,       // nothing to do (not a strip window, or the session is locked)
        FocusFront, // Hyprland accepts a window focus (no Exclusive layer): the front window takes focus and the keyboard,
                    // as after a swap (an on_demand layer such as the desktop loses it, as on any window focus)
        Clear,      // Hyprland refuses window focus (an Exclusive layer is mapped), or no window may replace it while a layer
                    // surface holds the keyboard: no active window, the keyboard holder untouched
                    // (CFocusState::resetWindowFocus, what Hyprland does when its focused window unmaps); the front window,
                    // if any, takes the focus once the Exclusive layer released the keyboard (PendingFocusState)
        Unfocus,    // no window may replace it otherwise: no active window and no keyboard focus (what Hyprland itself
                    // does when the input of its focused window gets blocked)
    };

    // What the glue does so that Hyprland's active window is never a strip window. After a FocusFront that Hyprland refused
    // (a no_focus rule, a modal child), the glue asks again with hasFront = false.
    ActiveWindowAction activeWindowAction(const ActiveWindowState& state);

    // A focus the plugin could not make because Hyprland refuses window focus (an Exclusive layer is mapped, the session is
    // locked): the window (a swap's incoming front window, the keyboard rule's front window) and its Desktop are remembered;
    // once the refusal is over the front window of that Desktop's active stage takes the focus, checked again then: the
    // remembered window, or, when it closed, was minimized or moved away or another stage came forward meanwhile, the window
    // in front now (macOS: the frontmost app's key window gets the keyboard back). Tried after a layer surface unmaps, after
    // a keyboard focus change (an Exclusive layer dropping its keyboard interactivity), after the unlock and before a key.
    struct PendingFocusState {
        bool remembered  = false; // the remembered window is mapped, not hidden and still the front window of its Desktop's
                                  // active stage
        bool hasFront    = false; // that Desktop's active stage has a front window (the remembered one or the one now in front)
        bool shown       = false; // the target's Desktop is shown on its monitor and not covered by a special workspace
        bool locked      = false; // the session is locked
        bool exclusive   = false; // an Exclusive layer surface is mapped
        bool holderKeeps = false; // the layer surface that held the keyboard when the focus was deferred still holds it
                                  // (it dropped its exclusivity and kept the keyboard: on_demand)
        bool focused     = false; // the target already is Hyprland's active window and holds the keyboard
    };

    enum class PendingFocusAction : uint8_t {
        Wait,       // Hyprland still refuses (lock, Exclusive layer) or that layer surface keeps the keyboard: try again later
        Focus,      // focus the remembered window now (what Hyprland's own refocus after the layer picked, a window or a
                    // surface under the cursor, is replaced: ST23)
        FocusFront, // the remembered window is gone or no longer in front: the front window of its Desktop's active stage
                    // takes the focus instead (also replacing Hyprland's pick, which may be nothing)
        Drop,       // forget it: that Desktop has no stage left, the target already holds the keyboard, or the Desktop is not
                    // shown or a special workspace covers it (nothing is switched or closed after the fact; the keyboard
                    // rule focuses the active stage when that Desktop is shown again: ST22)
    };

    PendingFocusAction pendingFocusAction(const PendingFocusState& state);

    enum class PointerEvent : uint8_t { Press, Release, Axis };

    struct PointerState {
        bool onBlocked = false; // the seat's pointer focus belongs to a strip window (or one of its popups)
        bool hasFocus  = false; // there is a pointer focus at all
        bool parked    = false; // the plugin cleared the pointer focus while a button was held on a window being blocked
    };

    enum class PointerAction : uint8_t {
        None,
        Refresh, // run Hyprland's pointer focus logic again at the cursor first (as a pointer motion would); if a held button
                 // still keeps a blocked surface, park the pointer
        Park,    // clear the pointer focus: the event reaches no surface (the blocked window had its wl_pointer.leave)
    };

    // Before Hyprland delivers a pointer event to its pointer focus. A press on a stale blocked focus, or the first press
    // after the pointer was parked, refreshes the focus; a release whose focus is blocked is dropped (parked); a scroll
    // refreshes like a press. Button events are never cancelled (Hyprland's held-button state must see them all).
    PointerAction beforePointerEvent(PointerEvent event, const PointerState& state);

    // ---- feature flag ----

    // hl.plugin.grassfield.config("stagesEnabled", "true" | "false").
    inline constexpr std::string_view kConfigStagesEnabled = "stagesEnabled";
    std::optional<bool>               parseStagesEnabled(std::string_view key, std::string_view value);

} // namespace gf::stages
