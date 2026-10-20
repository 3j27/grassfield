-- Stacking (macOS model): the window that takes focus comes to the front, whole, above every other window.
--
-- Hyprland 0.56 focuses a floating window on a click but does not raise it, so clicking the visible part of a
-- window that sits behind another one left the front window on top. The Grassfield titlebar already raises on its
-- own press (compositor/src/Titlebar.cpp focusAndRaise); this covers a press anywhere else in the window, and every
-- other way a window becomes active (Dock click, switcher, a program asking for focus).
--
-- Windows that are not floating cannot overlap, and a full-screen window (or any window on a workspace that shows one)
-- is left alone: raising there would draw a window over the full-screen one.

local function raise(window)
  if not window then
    return
  end
  if not window.floating or window.fullscreen ~= 0 then
    return
  end
  local workspace = window.workspace
  if workspace and workspace.fullscreen_window then
    return
  end
  local ok, err = pcall(function()
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = window }))
  end)
  if not ok then
    print("grassfield: raise on focus failed: " .. tostring(err))
  end
end

hl.on("window.active", function(window)
  raise(window or hl.get_active_window())
end)
