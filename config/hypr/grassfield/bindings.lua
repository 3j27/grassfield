-- Grassfield keyboard and pointer bindings (ADR-0002). SUPER plays the role of Command.
-- Shell actions go through `qs ipc` into the running grassfield-shell instance.

-- The dev session runs the shell from the repository (-p); the installed session by name (-c).
local shell_dir = os.getenv("GRASSFIELD_SHELL_DIR")
local shell_selector = (shell_dir and shell_dir ~= "") and ("-p '" .. shell_dir .. "'") or "-c grassfield"

local function shell(target, fn)
  return hl.dsp.exec_cmd("qs ipc " .. shell_selector .. " call " .. target .. " " .. fn)
end

local function bind(keys, description, dispatcher, opts)
  opts = opts or {}
  opts.description = description
  hl.bind(keys, dispatcher, opts)
end

-- Windows
bind("SUPER + Q", "Close window", hl.dsp.window.close())
bind("SUPER + W", "Close window", hl.dsp.window.close())
bind("SUPER + CTRL + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + ALT + F", "Zoom (fill the screen)", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + T", "Toggle floating/tiling", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + M", "Minimize window", shell("windows", "minimize"))
bind("SUPER + H", "Hide app", shell("windows", "hide"))
bind("SUPER + mouse:272", "Move window", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })

-- App switcher (macOS Cmd+Tab, shell/switcher). SUPER+TAB enters the "switcher" key map and asks the shell for the
-- next app; inside it Tab, arrows, Q, H and Esc act on the shell, and releasing SUPER leaves the map and tells the
-- shell to activate the selection. The shell also sees the map change (`submap` event) as a backstop.
local function leave_switcher(request)
  return function()
    hl.dispatch(hl.dsp.submap("reset"))
    hl.dispatch(shell("switcher", request))
  end
end

local function enter_switcher(request)
  return function()
    hl.dispatch(hl.dsp.submap("switcher"))
    hl.dispatch(shell("switcher", request))
  end
end

-- Declared through tables (not literal bind() lines): the Settings Keyboard list translates only the descriptions it knows
-- (apps/settings/qml/Bindings.js), and these are not there yet.
for _, b in ipairs({
  { "SUPER + TAB", "Switch application", enter_switcher("next") },
  { "SUPER + SHIFT + TAB", "Switch to the previous application", enter_switcher("previous") },
  { "SUPER + grave", "Next window of the application", shell("windows", "cycleApp") },
}) do
  bind(b[1], b[2], b[3])
end

hl.define_submap("switcher", function()
  for _, b in ipairs({
    { "SUPER + TAB", "Next application", shell("switcher", "next"), { repeating = true } },
    { "SUPER + SHIFT + TAB", "Previous application", shell("switcher", "previous"), { repeating = true } },
    { "SUPER + RIGHT", "Next application", shell("switcher", "right"), { repeating = true } },
    { "SUPER + LEFT", "Previous application", shell("switcher", "left"), { repeating = true } },
    { "SUPER + Q", "Quit the selected application", shell("switcher", "quit") },
    { "SUPER + H", "Hide the selected application", shell("switcher", "hide") },
    { "SUPER + ESCAPE", "Cancel the application switcher", leave_switcher("cancel") },
    { "ESCAPE", "Cancel the application switcher", leave_switcher("cancel") },
  }) do
    bind(b[1], b[2], b[3], b[4])
  end
  -- Releasing SUPER (either key) activates the selection.
  for _, key in ipairs({ "SUPER + Super_L", "SUPER + Super_R", "Super_L", "Super_R" }) do
    bind(key, "Activate the selected application", leave_switcher("release"), { release = true })
  end
end)

-- Window cycling inside the active Stage (Hyprland cycle_next; docs/specs/stages.md ST10).
bind("ALT + TAB", "Next window", hl.dsp.window.cycle_next())
bind("ALT + TAB", "Raise window", hl.dsp.window.bring_to_top())
bind("ALT + SHIFT + TAB", "Previous window", hl.dsp.window.cycle_next({ next = false }))
bind("ALT + SHIFT + TAB", "Raise window", hl.dsp.window.bring_to_top())

-- Spaces
bind("CTRL + LEFT", "Previous Space", hl.dsp.focus({ workspace = "r-1" }))
bind("CTRL + RIGHT", "Next Space", hl.dsp.focus({ workspace = "r+1" }))
for space = 1, 9 do
  bind("CTRL + code:" .. tostring(space + 9), "Switch to Space " .. space, hl.dsp.focus({ workspace = tostring(space) }))
end

-- Apps
bind("SUPER + RETURN", "Terminal", hl.dsp.exec_cmd("xdg-terminal-exec"))

-- Shell surfaces (handled by grassfield-shell IPC targets)
bind("SUPER + SPACE", "Search", shell("search", "toggle"))
bind("CTRL + UP", "Overview", shell("overview", "toggle"))
bind("SUPER + CTRL + Q", "Lock screen", shell("lock", "lock"))
bind("SUPER + N", "Notification Center", shell("notifications", "toggleCenter"))
bind("SUPER + ALT + ESCAPE", "Force Quit Applications", shell("menubar", "panel forcequit ''"))

-- Keyboard access to the menu bar and the Dock (gate A1), like Ctrl+F2 / Ctrl+F3.
bind("CTRL + F2", "Focus the menu bar", shell("menubar", "open system ''"))
bind("CTRL + F3", "Focus the Dock", shell("dock", "keyboard"))

-- Hardware keys: real volume/brightness changes plus the OSD (shell/osd).
bind("XF86AudioRaiseVolume", "Volume up", shell("volume", "up"), { repeating = true, locked = true })
bind("XF86AudioLowerVolume", "Volume down", shell("volume", "down"), { repeating = true, locked = true })
bind("XF86AudioMute", "Mute", shell("volume", "mute"), { locked = true })
bind("XF86MonBrightnessUp", "Brightness up", shell("brightness", "up"), { repeating = true, locked = true })
bind("XF86MonBrightnessDown", "Brightness down", shell("brightness", "down"), { repeating = true, locked = true })

-- Trackpad gestures (L2: verified by the owner on real hardware; nested sessions have no touchpad).
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 3, direction = "up", action = function() hl.exec_cmd("qs ipc " .. shell_selector .. " call overview open") end })
hl.gesture({ fingers = 3, direction = "down", action = function() hl.exec_cmd("qs ipc " .. shell_selector .. " call overview close") end })
