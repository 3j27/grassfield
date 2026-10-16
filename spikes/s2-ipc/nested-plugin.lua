-- S2 spike only (throwaway). config/hypr/dev.lua calls hl.plugin.load from a "hyprland.start"
-- callback; Hyprland applies the config's plugin list right after parsing the config
-- ("Loading plugin {} which is now present in config"), so a plugin registered from that
-- callback is never loaded. This wrapper registers it at parse time instead.
-- Used through spikes/s2-ipc/bin/Hyprland; proposed fix for dev.lua is in docs/specs/compositor.md.

dofile(os.getenv("GRASSFIELD_CONFIG_DIR") .. "/dev.lua")

local plugin = os.getenv("GRASSFIELD_PLUGIN")
if plugin and plugin ~= "" then
  hl.plugin.load(plugin)
end
