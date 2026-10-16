-- Input defaults (ADR-0002). Keyboard layout comes from the Omarchy include in the real session.

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
