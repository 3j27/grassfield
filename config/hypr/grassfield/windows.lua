-- Window behavior (ADR-0002): floating-first, centered, opaque application windows.

-- Every new window floats. Users can still tile a window explicitly.
hl.window_rule({ name = "gf-float-all", match = { class = ".*" }, float = true })

-- Don't let apps maximize themselves into a tiled state; Zoom is a Grassfield action.
-- Only a client-chrome window (ADR-0015, apps/windowchrome.h; the gf-client-chrome matches below) is exempt: its own zoom
-- control sends the request, and it is the only one that window has. Hyprland toggles the maximized mode on any maximize
-- request, so one request per press zooms and unzooms. Every other window, tagged by its toolkit or not, keeps the
-- suppression. Two rules make the negation of those matches (any class but Grassfield's and the third-party list below;
-- or no xdg tag and not in that list) without reading the tag itself: the tag is a dynamic effect, the suppression a
-- static one read at map. tests/shell/client_chrome_rules.sh checks that both negations are built from the two lists.
hl.window_rule({ name = "gf-no-maximize-event", match = { class = "negative:^(org\\.grassfield\\.(Files|Settings|Preview)|chromium|md\\.obsidian\\.Obsidian)$" }, suppress_event = "maximize" })
hl.window_rule({ name = "gf-no-maximize-event-untagged", match = { class = "negative:^(chromium|md\\.obsidian\\.Obsidian)$", xdg_tag = "negative:.+" }, suppress_event = "maximize" })

-- Client chrome (ADR-0015): Grassfield apps that draw their own lights and toolbar are tagged
-- `grassfield-client-chrome`; the compositor plugin draws no titlebar on them (plugin work item P1, docs/specs/compositor.md)
-- and Overview and Stages leave no band above them. The tag is set at map (the xdg tag comes with the first commit). The
-- class list is the apps that set a tag; KIO and widget dialogs set none and keep the plugin titlebar. The plugin and the
-- shell read the same tag name: keep it in step with shell/overview/ClientChrome.js. Never `decorate = false`: it also
-- drops Hyprland's border and shadow.
hl.window_rule({ name = "gf-client-chrome", match = { class = "^org\\.grassfield\\.(Files|Settings|Preview)$", xdg_tag = ".+" }, tag = "+grassfield-client-chrome" })

-- Third-party apps that draw their own window controls (GF-056; ADR-0015 amendment 2026-10-25). macOS: a window has one
-- set of traffic lights, close, minimize, zoom, top-left; an app that draws its own title bar gets no second bar from the
-- system. Hyprland 0.56.2 gives a plugin no per-window decoration signal it could use instead (the xdg-decoration request
-- is kept in a private map, and header-bar toolkits never negotiate), so the list is by Wayland app id. Only apps whose
-- own close, minimize and zoom were seen to work in the nested session with the session's GTK button layout
-- (close,minimize,maximize: on the left, packaging/dconf/grassfield.d/20-window-buttons.conf;
-- tests/compositor/third_party_chrome.sh): Chromium's browser window (its --app web apps draw no frame and keep the
-- plugin's titlebar) and Obsidian (its controls top right, in its own order). Evince and Nautilus are not on it: under
-- Hyprland 0.56.2 Evince's zoom button does nothing and Nautilus greys its minimize button, so they keep the plugin's
-- working set. Others join only once verified. Same tag as Grassfield's apps: no plugin titlebar, no band in Overview
-- and Stages, the app's own minimize and zoom work (exempt from the maximize suppression above). An app set to use the
-- system title bar (Chromium's "Use system title bar and borders") draws no controls: take it out of this list.
hl.window_rule({ name = "gf-client-chrome-third-party", match = { class = "^(chromium|md\\.obsidian\\.Obsidian)$" }, tag = "+grassfield-client-chrome" })

-- Get Info and Customize Folder draw the titlebar-only style (role "info"): radius 12 like every titlebar window; the
-- main windows keep the toolbar radius 26 (ADR-0015 Q5).
hl.window_rule({ name = "gf-client-chrome-info-rounding", match = { class = "^org\\.grassfield\\.Files$", xdg_tag = "^info$" }, rounding = 12 })

-- Corner radius (docs/testing/f1-reference-gaps.md, "Window chrome"): Grassfield's own windows keep the default 26
-- (looknfeel.lua, the macOS toolbar-window radius); every other window, matched by a negated class regex (also a window
-- without a class), gets 12, the titlebar-only radius (under the rule's cap of 20). Rule regexes match the whole class:
-- the pattern must cover all of it (a bare prefix never matches, so its negation would match every window).
hl.window_rule({ name = "gf-third-party-rounding", match = { class = "negative:^org\\.grassfield\\..*$" }, rounding = 12 })

-- Glance (quick look of Preview): a floating panel centered on the screen, without the plugin titlebar.
hl.window_rule({ name = "gf-glance", match = { class = "^org\\.grassfield\\.Preview\\.Glance$" }, float = true, center = true, decorate = false })

-- Grassfield shell surfaces (layer-shell namespaces start with "grassfield-").
-- Blur behind them comes from BackgroundEffect when available; this rule is the fallback (§5.5).
hl.layer_rule({ name = "gf-shell-blur", match = { namespace = "^grassfield-(menubar|dock|overlay|overview|search|switcher|banners|notification-center|apps|osd|polkit|widgets|widgets-menu|stages)$" }, blur = true, ignore_alpha = 0.01 })
-- The desktop's context menu is an xdg popup of the icons layer; Hyprland 0.56.2 left it unblurred with
-- BackgroundEffect alone. Only its popups blur (never the icons layer itself), limited to the menu's own pixels.
hl.layer_rule({ name = "gf-desktop-menu-blur", match = { namespace = "^grassfield-desktop-icons$" }, blur_popups = true, ignore_alpha = 0.01 })

-- The menu bar and dock must appear instantly; panels fade.
hl.layer_rule({ name = "gf-bar-no-anim", match = { namespace = "^grassfield-(menubar|dock)$" }, no_anim = true })
