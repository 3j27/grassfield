-- Stacking (macOS model): the window that takes focus comes to the front, whole, above every other window.
--
-- Hyprland 0.56 focuses a floating window on a click but does not raise it, so clicking the visible part of a
-- window that sits behind another one left the front window on top. The Grassfield titlebar already raises on its
-- own press (compositor/src/Titlebar.cpp focusAndRaise); this covers a press anywhere else in the window, and every
-- other way a window becomes active (Dock click, switcher, a program asking for focus).
--
-- Windows that are not floating cannot overlap, and a full-screen window (or any window on a workspace that shows one)
-- is left alone: raising there would draw a window over the full-screen one. A zoomed window (Grassfield Zoom is
-- Hyprland's maximized mode) is an ordinary window on macOS: it is raised when it takes focus, and a window activated
-- over it comes in front of it (owner report 2026-10-23: a zoomed Spotify clicked behind Chrome took the focus and
-- stayed behind). Hyprland's fullscreen value is a mode mask: 1 maximized, 2 full screen, 3 both.

local function full_screen(window)
  return window ~= nil and (window.fullscreen or 0) >= 2
end

-- Grassfield Memos' Float on Top (ADR-0051 D-6): a memo whose xdg-toplevel tag says ":top" ("memo:<id>:top...") stays above
-- the other windows: after any window is raised, those memos are raised again over it (the active one last, so it keeps its
-- place among them). Not Hyprland's `pin`, which would also show the memo on every Desktop (macOS's Float on Top does not).
-- Memos sends the tag again when the user turns Float on Top on or off.
-- The app id exactly (case-sensitive) and the tag exactly: "memo:", 32 lowercase hex digits, ":top", then nothing or the position.
-- Known residual risk (ADR-0051 D-6): a Wayland client chooses its own app id and tag, so another program could claim
-- Memos' and keep its own window above the other windows (never above the shell's layers: the lock, the polkit and secret
-- sheets, the menu bar).
local MEMO_TOP = "^memo:" .. string.rep("[0-9a-f]", 32) .. ":top"

local function floats_on_top(window)
  if window == nil or window.class ~= "org.grassfield.Memos" then
    return false
  end
  local tag = window.xdg_tag or ""
  return tag:match(MEMO_TOP .. "$") ~= nil or tag:match(MEMO_TOP .. "@%-?%d+,%-?%d+$") ~= nil
end

local function raise_floating_memos(active)
  for _, other in ipairs(hl.get_windows({ mapped = true }) or {}) do
    if floats_on_top(other) and other.floating and other.address ~= active.address then
      hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = "address:" .. other.address }))
    end
  end
  if floats_on_top(active) then
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = active }))
  end
end

local function raise(window)
  if not window then
    return
  end
  if not window.floating or full_screen(window) then
    return
  end
  local workspace = window.workspace
  if workspace and full_screen(workspace.fullscreen_window) then
    return
  end
  local ok, err = pcall(function()
    -- Hyprland draws the zoomed (maximized) window of a workspace in its own pass: a floating window raised over it
    -- (allowed_over_fullscreen) stays drawn above it whatever the order. When the zoomed window itself takes focus,
    -- those windows go behind it, top one first so that they keep their order among themselves; activating one of
    -- them later raises it over the zoomed window again. Pinned windows stay above everything.
    if window.fullscreen == 1 and workspace then
      local others = workspace:get_windows() or {}
      for i = #others, 1, -1 do
        local other = others[i]
        if other.address ~= window.address and other.floating and other.allowed_over_fullscreen and not other.pinned then
          hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom", window = "address:" .. other.address }))
        end
      end
    end
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = window }))
    raise_floating_memos(window)
  end)
  if not ok then
    print("grassfield: raise on focus failed: " .. tostring(err))
  end
end

hl.on("window.active", function(window)
  raise(window or hl.get_active_window())
end)
