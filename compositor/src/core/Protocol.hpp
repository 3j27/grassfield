#pragma once

// gfc/1: the versioned shell <-> grassfield-compositor protocol (master-prompt §5.3, ADR-0007 input).
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/).
//
// Transport measured in spike S2:
//   plugin -> shell: Hyprland's socket2 event stream. Hyprland formats each event as
//                    "<name>>><data>\n"; the plugin posts name "grassfield" with compact JSON as data.
//   shell -> plugin: Lua functions under hl.plugin.grassfield.*, reached with
//                    `hyprctl dispatch 'hl.plugin.grassfield.<verb>()'` / Hyprland.dispatch(...) in
//                    Quickshell (Hyprland evaluates `return hl.dispatch(<arg>)` under the Lua config).
//   query:           `hyprctl grassfield` returns the capabilities JSON.

#include "Theme.hpp"

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace gf::gfc {

    inline constexpr std::string_view kVersion        = "gfc/1";
    inline constexpr std::string_view kEventName      = "grassfield"; // socket2 event name
    inline constexpr std::string_view kHyprctlCommand = "grassfield"; // `hyprctl grassfield`
    inline constexpr std::string_view kLuaNamespace   = "grassfield"; // hl.plugin.grassfield
    inline constexpr std::string_view kLuaHello       = "hello";      // hl.plugin.grassfield.hello(): re-posts capabilities
    inline constexpr std::string_view kLuaMinimize    = "minimize";   // hl.plugin.grassfield.minimize(address, x, y, w, h)
    inline constexpr std::string_view kLuaRestore     = "restore";    // hl.plugin.grassfield.restore(address, x, y, w, h)
    inline constexpr std::string_view kLuaConfig      = "config";     // hl.plugin.grassfield.config(key, value)
    inline constexpr std::string_view kLuaAppmenu     = "appmenu";    // hl.plugin.grassfield.appmenu(address): re-posts its appmenu event
    inline constexpr std::string_view kLuaOverview    = "overview";   // hl.plugin.grassfield.overview(json): live window transforms
    inline constexpr std::string_view kLuaStages      = "stages";     // hl.plugin.grassfield.stages(json): Stages (behind config stagesEnabled)
    inline constexpr std::string_view kLuaCursorRefresh = "cursor_refresh"; // hl.plugin.grassfield.cursor_refresh(): redraw the pointer at its size
    inline constexpr std::string_view kLuaOverviewFocus = "overview_focus"; // hl.plugin.grassfield.overview_focus(json): focus after the Overview closes
    inline constexpr std::string_view kLuaTile = "tile"; // hl.plugin.grassfield.tile(address, place): Window > Move & Resize (core/Tiling.hpp)

    // What a shell sends through Hyprland.dispatch() to call a plugin verb.
    std::string luaDispatchRequest(std::string_view verb);

    // Features. Only advertise what really works (R11): decorations whenever the plugin is active, the others
    // only when their entry points (and, for minimize, its render hooks) registered at load.
    inline constexpr std::string_view kFeatureDecorations = "decorations";
    inline constexpr std::string_view kFeatureMinimize    = "minimize";
    inline constexpr std::string_view kFeatureConfig      = "config";
    inline constexpr std::string_view kFeatureAppmenu     = "appmenu"; // org_kde_kwin_appmenu_manager global + appmenu events
    inline constexpr std::string_view kFeatureOverview    = "overview"; // hl.plugin.grassfield.overview + window transformers + overview events
    inline constexpr std::string_view kFeatureDesktopFocus = "desktop-focus"; // click-to-focus policy for the desktop surface (ADR-0012)
    // Same policy, with the press target taken from under the cursor when the pointer focus is stale (a click without
    // motion after a popup closed) and late grants dropped on any other focus change. Always advertised together with
    // desktop-focus; the shell enables its file-changing desktop keys only with this one (shell main 23caeab).
    inline constexpr std::string_view kFeatureDesktopFocusV2 = "desktop-focus-v2";
    // Stages (ADR-0013): "stages-available" when the hooks and hl.plugin.grassfield.stages registered (the shell shows the
    // Control Center toggle); "stages" only while the feature flag config stagesEnabled is true (the shell shows its strip).
    inline constexpr std::string_view kFeatureStagesAvailable = "stages-available";
    inline constexpr std::string_view kFeatureStages          = "stages";
    // hl.plugin.grassfield.cursor_refresh(): the pointer on screen is drawn again at the size Hyprland holds (after the
    // shell's `setcursor <theme> <size>`), same shape, same place (Settings > Accessibility > Pointer, ADR-0014).
    inline constexpr std::string_view kFeatureCursorRefresh = "cursor-refresh";
    // hl.plugin.grassfield.overview_focus(json): the shell names what gets the keyboard when the Overview closes; the plugin
    // focuses it once no Exclusive layer surface is left (docs/specs/overview.md "Close focus", owner decision batch 5).
    inline constexpr std::string_view kFeatureOverviewFocus = "overview-focus";
    // hl.plugin.grassfield.config("minimizeEffect", "funnel" | "shrink" | "fade") is accepted: the minimize animation follows
    // Settings dock.minimizeEffect ("Minimize animation"), "fade" while Reduce Motion is on. Advertised with
    // minimize and config; a shell pushes the key only when it sees this feature (older plugins reject the key).
    inline constexpr std::string_view kFeatureMinimizeEffect = "minimize-effect";
    // Window tiling (core/Tiling.hpp, FR47-FR50): titlebar drags tile at the free side edges, their corners and the menu
    // bar; hl.plugin.grassfield.tile(address, place) and the config keys tilingEdges / tilingMenuBar / tilingMargins.
    inline constexpr std::string_view kFeatureWindowTiling = "window-tiling";
    // No verb: when a layer surface of the shell ("grassfield-*") maps or takes the keyboard, the plugin re-runs Hyprland's
    // pointer focus at the cursor, so a click without motion reaches what is under the pointer (spec FR51-FR52,
    // core/LayerPointer.hpp).
    inline constexpr std::string_view kFeatureLayerPointer = "layer-pointer";
    // hl.plugin.grassfield.config("appearance", "dark" | "light") is accepted: the compositor-drawn chrome (titlebars, the
    // tiling preview) follows the appearance (audit UX-06). Advertised with config; a shell pushes the key only when it sees
    // this feature (older plugins reject the key).
    inline constexpr std::string_view kFeatureAppearance = "appearance";
    inline constexpr std::string_view kFeatures[]         = {kFeatureDecorations}; // always on

    // The advertised list, in a stable order: decorations, then minimize, config, appmenu, overview, desktop-focus and
    // desktop-focus-v2 (together), stages-available, stages (stages only together with stages-available), cursor-refresh,
    // overview-focus, minimize-effect, window-tiling, layer-pointer, appearance.
    std::vector<std::string_view> features(bool minimize, bool config, bool appmenu, bool overview = false, bool desktopFocus = false, bool stagesAvailable = false,
                                           bool stagesEnabled = false, bool cursorRefresh = false, bool overviewFocus = false, bool minimizeEffect = false,
                                           bool windowTiling = false, bool layerPointer = false, bool appearance = false);

    // Settings the shell pushes with hl.plugin.grassfield.config(key, value). Allowlist: this key, appearance (below),
    // stagesEnabled (core/Stages.hpp), minimizeEffect (core/Minimize.hpp) and the tiling keys (core/Tiling.hpp).
    inline constexpr std::string_view kConfigTitlebarDoubleClick = "titlebarDoubleClick";

    // The appearance the chrome follows (Settings appearance, the effective light/dark the shell shows).
    inline constexpr std::string_view kConfigAppearance = "appearance";

    // nullopt unless key is kConfigAppearance and value is exactly "dark" or "light".
    std::optional<theme::Appearance> parseAppearance(std::string_view key, std::string_view value);

    // What a double-click on a titlebar's drag area does (Settings windows.titlebarDoubleClick).
    enum class DoubleClickAction : uint8_t {
        Zoom,     // the zoom button's toggle (default)
        Minimize, // the minimize button's path (minimize-request)
        None,     // nothing: the second press is handled like a single press
    };

    // nullopt unless key is kConfigTitlebarDoubleClick and value is exactly "zoom", "minimize" or "none".
    std::optional<DoubleClickAction> parseDoubleClickAction(std::string_view key, std::string_view value);

    // JSON string escaping (RFC 8259): quotes, backslash and control characters.
    std::string jsonEscape(std::string_view in);

    // {"v":"gfc/1","type":"capabilities","features":[...]}. At unload the plugin posts it with an empty list: no feature
    // is available any more (the shell goes back to its fallbacks, as without the plugin).
    std::string capabilitiesJson(std::span<const std::string_view> features = kFeatures);

    // The minimize button (or a double-click set to minimize) asks the shell, which owns the Dock tile
    // rectangle, to minimize; the shell answers with hl.plugin.grassfield.minimize(address, x, y, w, h).
    // {"v":"gfc/1","type":"minimize-request","address":"<hex address, no 0x, as in socket2 events>"}
    std::string minimizeRequestJson(std::string_view windowAddress);

    // Posted when a minimize / restore has completed (end of its animation, or at once without one).
    // {"v":"gfc/1","type":"minimized","address":"<hex>"} / {"v":"gfc/1","type":"restored","address":"<hex>"}
    std::string minimizedJson(std::string_view windowAddress);
    std::string restoredJson(std::string_view windowAddress);

    // A window's DBusMenu address, from org_kde_kwin_appmenu.set_address (validated by core/Appmenu); empty
    // service and path when the window has no (more) registration. `pid`: process id of the Wayland client that
    // registered it (additive gfc/1 field; 0 when unknown or cleared; negative values are written as 0).
    // {"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<object path>","pid":N}
    std::string appmenuJson(std::string_view windowAddress, std::string_view service, std::string_view path, int pid);

    // The line a socket2 subscriber receives for a given payload (without the trailing newline).
    std::string socket2Line(std::string_view json);

} // namespace gf::gfc
