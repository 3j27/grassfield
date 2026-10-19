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

-- App switcher (macOS Cmd+Tab, shell/switcher; docs/specs/switcher.md, Key handling). No key map (submap) is used: the
-- shell takes the keyboard with an exclusive layer surface when SUPER+TAB fires, so no global mode can get stuck.
-- Hyprland records the key map that was active when a key went DOWN and checks only that map's binds on release
-- (KeybindManager.cpp, efb5099), so a release bind inside a map entered after SUPER went down never fires; the release
-- bind below lives in the default map, where SUPER went down.
--
-- Every request carries a hold id (one per physical hold of SUPER): `next` and `release` are separate `qs ipc`
-- processes that can arrive in either order after a quick tap, and the shell orders them by id.
local switcher_id = 0
local switcher_held = false

local function switcher_request(request)
  return function()
    if not switcher_held then
      switcher_held = true
      switcher_id = switcher_id + 1
    end
    hl.dispatch(shell("switcher", request .. " " .. switcher_id))
  end
end

-- SUPER released: tell the shell once per hold (a stale request is ignored by the shell).
local function switcher_release()
  if not switcher_held then
    return
  end
  switcher_held = false
  hl.dispatch(shell("switcher", "release " .. switcher_id))
end

-- True while the switcher surface (exclusive keyboard grab) is mapped: SUPER+Q and SUPER+H then act on the selected app.
local function switcher_mapped()
  for _, layer in ipairs(hl.get_layers({ namespace = "grassfield-switcher" })) do
    if layer.mapped then
      return true
    end
  end
  return false
end

local function in_switcher_else(request, otherwise)
  return function()
    hl.dispatch(switcher_mapped() and shell("switcher", request) or otherwise)
  end
end

-- Windows
bind("SUPER + Q", "Close window", in_switcher_else("quit", hl.dsp.window.close()))
bind("SUPER + W", "Close window", hl.dsp.window.close())
bind("SUPER + CTRL + F", "Full screen", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + ALT + F", "Zoom (fill the screen)", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + T", "Toggle floating/tiling", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + M", "Minimize window", shell("windows", "minimize"))
bind("SUPER + H", "Hide app", in_switcher_else("hide", shell("windows", "hide")))
bind("SUPER + mouse:272", "Move window", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })

-- Application switcher: Tab (and its key repeat) moves the selection; arrows and Esc reach the shell through its grab.
bind("SUPER + TAB", "Switch application", switcher_request("next"), { repeating = true })
bind("SUPER + SHIFT + TAB", "Switch to the previous application", switcher_request("previous"), { repeating = true })
for _, key in ipairs({ "SUPER + Super_L", "SUPER + Super_R", "Super_L", "Super_R" }) do
  bind(key, "Activate the selected application", switcher_release, { release = true, non_consuming = true })
end
-- The key above Tab (grave on a US layout, ² on AZERTY): bound by keycode, so it works on every layout.
bind("SUPER + code:49", "Next window of the application", shell("windows", "cycleApp"))

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
