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

-- App switching (window cycling until the Grassfield app switcher exists).
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
