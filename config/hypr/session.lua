-- Grassfield Desktop session (ADR-0001). Installed to /usr/share/grassfield/hypr/session.lua and started by
-- /usr/share/wayland-sessions/grassfield.desktop through uwsm. The Omarchy session stays untouched.

local config_dir = os.getenv("GRASSFIELD_CONFIG_DIR") or "/usr/share/grassfield/hypr"
package.path = config_dir .. "/?.lua;" .. package.path

-- Hardware/env from Omarchy (read-only). Grassfield defaults apply if it fails.
local omarchy = require("grassfield.omarchy")
if not omarchy.ok then
  print("grassfield: Omarchy include skipped: " .. tostring(omarchy.reason))
end
if not omarchy.ok or not omarchy.monitors then
  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end
-- ADR-0001: a failed include is announced once (details in the journal, lines start with "grassfield: Omarchy include").
if not omarchy.ok or #omarchy.problems > 0 then
  hl.on("hyprland.start", function()
    hl.exec_cmd("sleep 8; notify-send -a Grassfield -u critical Grassfield "
      .. "'Some Omarchy settings (keyboard, monitors, environment) could not be loaded. "
      .. "See: journalctl --user -b | grep grassfield:'")
  end)
end
-- GF-032: the Omarchy shell must never start inside this session (updates, theme and font changes try to start it).
omarchy.guard_path(os.getenv("GRASSFIELD_SHIM_DIR") or "/usr/lib/grassfield/omarchy-shims")

hl.env("XDG_SESSION_DESKTOP", "Grassfield")
hl.env("GRASSFIELD_SESSION", "1")

require("grassfield.core")
require("grassfield.autostart")
require("grassfield.system")

-- Hyprland would write cursor-theme/cursor-size into the owner's dconf (org.gnome.desktop.interface), a database shared
-- with the Omarchy session. Never touch it from this session; the theme reaches clients through XCURSOR_* (cursor.lua).
-- GTK applications keep whatever theme dconf already holds.
hl.config({ cursor = { sync_gsettings_theme = false } })

-- Optional compositor extension (ADR-0009, "Amendment 2026-10-23"). Loaded at parse time (Hyprland applies the plugin
-- list right after parsing). grassfield.compositor picks the build made for the Hyprland that runs: the packaged one, else
-- the one the user built (grassfield-compositor-rebuild, vouched for by its --vetted check). With none, nothing is loaded:
-- the shell runs in degraded mode (§5.6, gate C2) and tells the user, translated, with the Hyprland version and the
-- recovery (it builds the extension itself when the user turned on Settings windows.rebuildExtension). A config reload in
-- the same Hyprland keeps the build its first parse loaded.
local plugin, why = nil, "no choice"
local chose, compositor = pcall(require, "grassfield.compositor")
if chose then
  local ok, path, reason = pcall(compositor.choose)
  if ok then
    plugin, why = path, reason
  else
    why = "choice failed: " .. tostring(path)
  end
else
  why = "module failed: " .. tostring(compositor)
end
if why:find("failed", 1, true) then
  -- A loader defect must not cost the extension: the packaged build checks Hyprland's hash itself and refuses another
  -- build with a notice.
  print("grassfield: compositor extension: " .. why)
  plugin = "/usr/lib/grassfield/grassfield-compositor.so"
end
local f = plugin and io.open(plugin, "r")
if f then
  f:close()
  local ok, err = pcall(hl.plugin.load, plugin)
  if ok and chose and why ~= "kept" then
    pcall(compositor.remember, plugin)
  elseif not ok then
    print("grassfield: compositor extension not loaded: " .. tostring(err))
  end
elseif why == "no-match" then
  print("grassfield: no compositor extension built for this Hyprland: degraded mode (grassfield-compositor-rebuild --check)")
elseif why == "updated" then
  print("grassfield: Hyprland was updated under this session: the compositor extension is reconsidered at the next login")
end
