-- Nested development session (master-prompt §7.1 L1). Started by `just nested-up`, never by the owner's session.
-- It must not read or write the owner's Hyprland or Omarchy configuration.

local config_dir = os.getenv("GRASSFIELD_CONFIG_DIR")
if not config_dir or config_dir == "" then
  error("GRASSFIELD_CONFIG_DIR is not set; start this config with `just nested-up`")
end
package.path = config_dir .. "/?.lua;" .. package.path

_G.grassfield_dev = true

-- The nested output is a window inside the owner's session; keep it smaller than the 1080p panel.
hl.monitor({ output = "", mode = "1440x900", position = "auto", scale = 1 })

require("grassfield.core")

-- Optional: load grassfield-compositor into THIS nested instance at startup (R13).
-- nested-up.sh sets GRASSFIELD_PLUGIN when a built plugin exists; unset it to test degraded mode (C2).
local plugin = os.getenv("GRASSFIELD_PLUGIN")
if plugin and plugin ~= "" then
  local f = io.open(plugin, "r")
  if f then
    f:close()
    -- Must run at parse time: Hyprland applies the config's plugin list right after parsing,
    -- so a load requested from a "hyprland.start" callback is ignored (spike S2).
    local ok, err = pcall(hl.plugin.load, plugin)
    if not ok then
      print("grassfield: plugin load failed: " .. tostring(err))
    end
  end
end

-- Reference output for deterministic screenshots: 1920x1080 @ scale 1, like the reference machine panel.
-- The visible WAYLAND-1 window is sized by the owner's session layout, so it can't be relied on.
hl.monitor({ output = "GF-REF", mode = "1920x1080@60", position = "auto-right", scale = 1 })
hl.on("hyprland.start", function()
  -- Runs as a child of the nested compositor, so it can only reach the nested instance.
  hl.exec_cmd("hyprctl output create headless GF-REF")
end)

hl.config({
  -- Nested sessions don't need the watchdog warning (no start-hyprland in dev).
  misc = { disable_watchdog_warning = true },
  -- No `ecosystem` keys here: looknfeel.lua (through core.lua) sets them for both sessions, so a nested run shows what the
  -- real session gets (ADR-0035 D-1).
  debug = { disable_logs = false },
  -- Never write the cursor theme/size into gsettings: the owner's dconf database is shared with the nested session.
  cursor = { sync_gsettings_theme = false },
})
