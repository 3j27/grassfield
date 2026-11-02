.pragma library

// Windows that draw their own chrome (ADR-0015) leave no titlebar band in Overview v2: the compositor plugin draws no strip on
// them, so the layout must not reserve one. The plugin and the shell decide by the same Hyprland tag, which the session's
// window rule `gf-client-chrome` (config/hypr/grassfield/windows.lua) puts on the windows that carry an xdg-toplevel tag:
// plugin work item P1 (docs/specs/compositor.md). This file is the shell's one copy of the names; tests/shell/
// client_chrome_rules.sh checks that the rule and the spec use the same ones. Pure functions, unit-tested in
// tests/unit/tst_clientchrome.qml.

// The Hyprland tag name, and the gfc/1 feature the plugin advertises once it honours it (P2).
var TAG = "grassfield-client-chrome";
var FEATURE = "client-chrome";

// Hyprland prints a dynamic (rule-set) tag with a trailing "*"; the name is what counts.
function hasClientChrome(tags) {
    if (!Array.isArray(tags))
        return false;
    return tags.some(t => typeof t === "string" && t.replace(/\*$/, "") === TAG);
}

// The band the layout reserves above `win` (an entry of Compositor.windowsAcross, with its Hyprland `tags`): 0 for a window
// that draws its own chrome while the plugin says it steps aside (`advertised`: Capabilities.has(FEATURE)), else the plugin's
// strip height. Without the feature the plugin still draws its strip on every window, so the band stays. `titleAway`: the
// window's titlebar is away (a Split View member with the plugin's tiling-split-titles, WindowTiling.splitTitleAway; tiling
// step 6e, ADR-0036 D73): no band either.
function band(win, advertised, stripHeight, titleAway) {
    if (titleAway === true)
        return 0;
    return advertised && win && hasClientChrome(win.tags) ? 0 : stripHeight;
}
