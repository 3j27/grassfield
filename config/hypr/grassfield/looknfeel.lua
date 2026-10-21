-- Grassfield look and feel (master-prompt §5.5, ADR-0002, ADR-0003).
-- Values mirror ui/tokens/tokens.json ("window.*", "motion.*"); keep both in sync.

hl.config({
  general = {
    -- Floating-first desktop: gaps only matter for the rare tiled window.
    gaps_in = 4,
    gaps_out = 8,
    float_gaps = 0,
    border_size = 1,
    col = {
      -- Hairline window outline, like the macOS window edge.
      active_border = "rgba(ffffff26)",
      inactive_border = "rgba(ffffff14)",
    },
    resize_on_border = true,
    extend_border_grab_area = 8,
    hover_icon_on_border = true,
    allow_tearing = false,
    layout = "dwindle",
    snap = {
      enabled = true,
      window_gap = 8,
      monitor_gap = 8,
    },
  },

  decoration = {
    -- Fixed-radius window corners (macOS 27). Continuous-corner approximation.
    rounding = 12,
    rounding_power = 2.6,
    active_opacity = 1.0,
    inactive_opacity = 1.0,
    fullscreen_opacity = 1.0,
    dim_inactive = false,

    -- Diffused shadow: large range, low power, offset downwards.
    shadow = {
      enabled = true,
      range = 38,
      render_power = 2,
      sharp = false,
      color = "rgba(00000059)",
      color_inactive = "rgba(00000033)",
      offset = { 0, 14 },
      scale = 1.0,
    },

    -- Blur is used by Grassfield shell surfaces (layer rules); app windows stay opaque.
    blur = {
      enabled = true,
      size = 18,
      passes = 3,
      new_optimizations = true,
      ignore_opacity = true,
      xray = false,
      noise = 0.015,
      contrast = 1.0,
      brightness = 1.0,
      vibrancy = 0.18,
      vibrancy_darkness = 0.0,
      popups = true,
      special = false,
    },
  },

  animations = {
    enabled = true,
    workspace_wraparound = false,
  },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    disable_scale_notification = true,
    focus_on_activate = true,
    animate_manual_resizes = false,
    animate_mouse_windowdragging = false,
    allow_session_lock_restore = true,
    session_lock_xray = false,
    on_focus_under_fullscreen = 1,
    initial_workspace_tracking = 0,
    background_color = "rgba(1c1c1eff)",
  },

  cursor = {
    hide_on_key_press = false,
    -- The shell focuses windows explicitly (desktop keyboard handoff); never warp the pointer to them.
    no_warps = true,
  },
})

-- Motion curves (tokens "motion.curve.*").
hl.curve("gfStandard", { type = "bezier", points = { { 0.2, 0.0 }, { 0.0, 1.0 } } })
hl.curve("gfDecelerate", { type = "bezier", points = { { 0.32, 0.72 }, { 0.0, 1.0 } } })
hl.curve("gfAccelerate", { type = "bezier", points = { { 0.4, 0.0 }, { 1.0, 1.0 } } })
hl.curve("gfLinear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })

-- Speeds are in Hyprland units (1 = 100 ms).
hl.animation({ leaf = "global", enabled = true, speed = 3, bezier = "gfDecelerate" })
hl.animation({ leaf = "border", enabled = true, speed = 2, bezier = "gfStandard" })
-- macOS: a new window opens with a quick, subtle scale and fade (about 0.2 s); closing is the reverse and shorter (about 0.12 s).
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2, bezier = "gfDecelerate", style = "popin 94%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.2, bezier = "gfAccelerate", style = "popin 96%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 3, bezier = "gfDecelerate" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 2, bezier = "gfDecelerate" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.2, bezier = "gfAccelerate" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 2, bezier = "gfDecelerate", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.6, bezier = "gfAccelerate", style = "fade" })
-- Spaces slide horizontally, like swiping between desktops.
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "gfDecelerate", style = "slide" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3, bezier = "gfDecelerate", style = "fade" })
