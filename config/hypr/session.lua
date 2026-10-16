-- Grassfield Desktop session (ADR-0001). Installed to /usr/share/grassfield/hypr/session.lua and started by
-- /usr/share/wayland-sessions/grassfield.desktop through uwsm. The Omarchy session stays untouched.

local config_dir = os.getenv("GRASSFIELD_CONFIG_DIR") or "/usr/share/grassfield/hypr"
package.path = config_dir .. "/?.lua;" .. package.path

-- Hardware/env from Omarchy (read-only). Grassfield defaults apply if it fails.
local omarchy = require("grassfield.omarchy")
if not omarchy.ok then
  print("grassfield: Omarchy include skipped: " .. tostring(omarchy.reason))
  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end

hl.env("XDG_SESSION_DESKTOP", "Grassfield")
hl.env("GRASSFIELD_SESSION", "1")

require("grassfield.core")
require("grassfield.autostart")

-- Optional compositor extension (ADR-0009). Loaded at parse time (Hyprland applies the plugin list right
-- after parsing). A build for another Hyprland ABI is refused by the plugin itself; the shell then runs in
-- degraded mode and notifies once (§5.6).
local plugin = "/usr/lib/grassfield/grassfield-compositor.so"
local f = io.open(plugin, "r")
if f then
  f:close()
  local ok, err = pcall(hl.plugin.load, plugin)
  if not ok then
    print("grassfield: compositor extension not loaded: " .. tostring(err))
  end
end
