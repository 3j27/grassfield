-- Window behavior (ADR-0002): floating-first, centered, opaque application windows.

-- Every new window floats. Users can still tile a window explicitly.
hl.window_rule({ name = "gf-float-all", match = { class = ".*" }, float = true })

-- Don't let apps maximize themselves into a tiled state; Zoom is a Grassfield action.
hl.window_rule({ name = "gf-no-maximize-event", match = { class = ".*" }, suppress_event = "maximize" })

-- Corner radius (docs/testing/f1-reference-gaps.md, "Window chrome"): Grassfield's own windows keep the default 26
-- (looknfeel.lua, the macOS toolbar-window radius); every other window, matched by a negated class regex (also a window
-- without a class), gets 12, the titlebar-only radius (under the rule's cap of 20). Rule regexes match the whole class:
-- the pattern must cover all of it (a bare prefix never matches, so its negation would match every window).
hl.window_rule({ name = "gf-third-party-rounding", match = { class = "negative:^org\\.grassfield\\..*$" }, rounding = 12 })

-- Glance (quick look of Preview): a floating panel centered on the screen, without the plugin titlebar.
hl.window_rule({ name = "gf-glance", match = { class = "^org\\.grassfield\\.Preview\\.Glance$" }, float = true, center = true, decorate = false })

-- Grassfield shell surfaces (layer-shell namespaces start with "grassfield-").
-- Blur behind them comes from BackgroundEffect when available; this rule is the fallback (§5.5).
hl.layer_rule({ name = "gf-shell-blur", match = { namespace = "^grassfield-(menubar|dock|overlay|overview|search|switcher|banners|notification-center|apps|osd|polkit)$" }, blur = true, ignore_alpha = 0.01 })

-- The menu bar and dock must appear instantly; panels fade.
hl.layer_rule({ name = "gf-bar-no-anim", match = { namespace = "^grassfield-(menubar|dock)$" }, no_anim = true })
