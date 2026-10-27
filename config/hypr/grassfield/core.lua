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
require("grassfield.bindings")
require("grassfield.forwarding")
