-- Input defaults (ADR-0002). Pointer behaviour only. The keyboard (layout from /etc/vconsole.conf, compose:caps, repeat
-- rate and delay, numlock) is set by omarchy.lua, which loads Omarchy's default.hypr.input (or reproduces it) and the
-- user's own ~/.config/hypr/input.lua before this file; this file must not set any kb_*, repeat_* or numlock key.

hl.config({
  input = {
    -- Click to focus keyboard; pointer focus (scrolling, hover) follows the mouse, like macOS.
    follow_mouse = 2,
    float_switch_override_focus = 0,
    mouse_refocus = false,
    sensitivity = 0,
    touchpad = {
      natural_scroll = true,
      clickfinger_behavior = true,
      tap_to_click = true,
      scroll_factor = 0.5,
    },
  },
})
