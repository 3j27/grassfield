-- Grassfield core modules shared by the real session (session.lua) and the nested dev session (dev.lua). Each is
-- mandatory: the bindings, the lock key and the window rules come from here. session.lua and dev.lua drop Grassfield's
-- modules from package.loaded when their parse starts (not here: bindings.lua reads grassfield.input, which the real
-- session loads before this file).

require("grassfield.cursor").apply()
require("grassfield.looknfeel")
-- Pointer defaults: in the real session omarchy.lua applies them before the user's input.lua (GF-066); the nested dev
-- session has no user files and applies them here. Optional: a failure is logged and costs the pointer defaults and the
-- Settings choices, never the modules below.
if _G.grassfield_dev then
  local input_ok, input_err = pcall(require, "grassfield.input")
  if not input_ok then
    print("grassfield: input: " .. tostring(input_err))
  end
end
require("grassfield.windows")
-- Omarchy's screen-share protection for password managers (SEC-01).
require("grassfield.privacy")
require("grassfield.placement")
require("grassfield.stacking")
-- Hyprland's require answers `true` for a module that ran to its end (bindings.lua returns nothing) and an empty table for
-- one that failed, after recording the error (Hyprland 0.56.2 src/config/lua/ConfigManager.cpp:315-356).
local bindings_loaded = require("grassfield.bindings") == true
require("grassfield.forwarding")

-- ADR-0035 D-2: Hyprland's red config-error bar gives way to the shell's notice, "Some settings could not be applied"
-- (shell/platform/ConfigErrors.qml). Only once the bindings are in: an error that leaves no binding trips Hyprland's
-- emergency mode, whose banner the same switch would hide (ConfigManager.cpp:773-801), and a parse that stops before
-- this line keeps Hyprland's bar.
if bindings_loaded then
  hl.config({ debug = { suppress_errors = true } })
end
