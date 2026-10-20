-- Placement (macOS model): an application's first window opens large and centred, never smaller than the application's
-- usual default, and a window that arrives with a size of its own keeps it.
--
-- Every new window floats (windows.lua) and Hyprland gives a floating window the size its client committed. A browser
-- that has no stored geometry commits a small one, so it opened as a small window.
--   * Hyprland already centres a new floating window (over its parent for a dialog); no rule overrides that.
--   * A browser window smaller than the default below is grown to it. Size is only ever raised, so a size the browser
--     restores from its own state is kept; popups have an empty title when they open and are skipped.
-- Other applications decide their own size (Grassfield apps, terminals, dialogs, panels).

-- Fraction of the monitor's usable area. The window never covers the whole screen.
local DEFAULT_WIDTH = 0.72
local DEFAULT_HEIGHT = 0.82

-- Window classes (lower case) whose main window is grown to the default size.
local LARGE_CLASSES = {
  ["chromium"] = true, ["google-chrome"] = true, ["google-chrome-stable"] = true, ["google-chrome-beta"] = true,
  ["google-chrome-unstable"] = true, ["brave-browser"] = true, ["microsoft-edge"] = true, ["vivaldi-stable"] = true,
  ["helium"] = true, ["firefox"] = true, ["zen"] = true, ["zen-browser"] = true, ["librewolf"] = true,
  ["org.mozilla.firefox"] = true, ["org.chromium.chromium"] = true,
}

local function xy(value)
  if type(value) ~= "table" then
    return nil
  end
  local x, y = value.x or value[1], value.y or value[2]
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  return x, y
end

local function usable_size(monitor)
  local width, height = monitor.width, monitor.height
  if type(width) ~= "number" or type(height) ~= "number" then
    return nil
  end
  local scale = type(monitor.scale) == "number" and monitor.scale > 0 and monitor.scale or 1
  width, height = width / scale, height / scale
  local reserved = monitor.reserved
  if type(reserved) == "table" then
    -- Reserved area (menu bar, dock): { top, bottom, left, right } or the same names as fields.
    local top = reserved.top or reserved[1] or 0
    local bottom = reserved.bottom or reserved[2] or 0
    local left = reserved.left or reserved[3] or 0
    local right = reserved.right or reserved[4] or 0
    height = height - top - bottom
    width = width - left - right
  end
  return width, height
end

local function grow(window)
  if not window or not window.floating or window.fullscreen ~= 0 then
    return
  end
  if not LARGE_CLASSES[(window.class or ""):lower()] or (window.title or "") == "" then
    return
  end
  local monitor = window.monitor
  local usable_w, usable_h
  if monitor then
    usable_w, usable_h = usable_size(monitor)
  end
  local w, h = xy(window.size)
  if not usable_w or not w then
    return
  end
  local want_w, want_h = math.floor(usable_w * DEFAULT_WIDTH), math.floor(usable_h * DEFAULT_HEIGHT)
  if w >= want_w and h >= want_h then
    return
  end
  want_w, want_h = math.max(w, want_w), math.max(h, want_h)
  hl.dispatch(hl.dsp.window.resize({ x = want_w, y = want_h, window = window }))
  hl.dispatch(hl.dsp.window.center({ window = window }))
end

hl.on("window.open", function(window)
  local ok, err = pcall(grow, window)
  if not ok then
    print("grassfield: default size failed: " .. tostring(err))
  end
end)
