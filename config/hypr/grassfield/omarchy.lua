-- Guarded, read-only include of Omarchy's hardware and environment setup (ADR-0001).
-- Loads Omarchy's environment and input defaults and the user's monitors/input files. Never writes anything.
-- Returns a status table the session can surface:
--   ok       Omarchy's helpers and environment loaded (false: Grassfield defaults apply, session.lua adds a monitor rule)
--   reason   why ok is false
--   monitors the user's monitors.lua loaded (or does not exist)
--   input    "omarchy" (default.hypr.input: layout from /etc/vconsole.conf, compose:caps, repeat rate, numlock) or
--            "fallback" (the same defaults reproduced below because that module could not be loaded)
--   input_applied  Grassfield's pointer defaults went in before the user's input.lua (else session.lua applies them)
--   problems list of one-line descriptions of every step that failed (logged, and one notification at start)
--
-- Capability check, not a version check: /usr/share/omarchy/version is a stale upstream file (docs/compat.md). What
-- matters is whether the modules named below exist; scripts/dev/omarchy-compat.sh checks the same list.

local M = { ok = false, reason = nil, monitors = true, input = "none", input_applied = false, problems = {} }

local omarchy_path = os.getenv("OMARCHY_PATH") or "/usr/share/omarchy"
local home = os.getenv("HOME") or ""

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function problem(text)
  M.problems[#M.problems + 1] = text
  print("grassfield: Omarchy include: " .. text)
end

-- GF-032: Omarchy's maintenance tools (the update ends with omarchy-update-restart, which restarts the Omarchy shell;
-- theme, font and voxtype changes do too) start Omarchy's own shell in whatever Hyprland instance asks. Inside a
-- Grassfield session that would add a second bar, notification server, polkit agent, idle timer and locker. The two
-- commands that start it are shadowed by no-op scripts placed first in PATH (packaging/shims/). Omarchy's envs.lua puts
-- its own bin directory first, so this has to run after the include; packaging/uwsm/env-grassfield does the same for the
-- systemd user manager (applications started by the Dock or by D-Bus). No Omarchy file is touched.
-- Defined before the include's early returns: session.lua calls it whatever the include did, and a failed include must
-- leave a working session (ADR-0001); before, a missing Omarchy made `omarchy.guard_path` nil and Hyprland rejected the
-- whole session config (found by tests/shell/hyprland_screens.sh). An error inside Omarchy's envs.lua does not reach the
-- early return below: Hyprland's own `require` turns it into a config error and returns an empty table (Hyprland 0.56.2
-- src/config/lua/ConfigManager.cpp:312-377); only a module that cannot be found is raised to `pcall`.
function M.guard_path(shim_dir)
  if not exists(shim_dir .. "/omarchy-restart-shell") then return false end
  local bin = omarchy_path .. "/bin"
  local parts = { shim_dir }
  if M.ok then parts[#parts + 1] = bin end
  for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
    if entry ~= shim_dir and entry ~= bin then parts[#parts + 1] = entry end
  end
  hl.env("PATH", table.concat(parts, ":"))
  return true
end

if not exists(omarchy_path .. "/default/hypr/helpers.lua") or not exists(omarchy_path .. "/default/hypr/envs.lua") then
  M.reason = "Omarchy's Hyprland modules not found at " .. omarchy_path
  return M
end

-- Same module search path Omarchy's bootstrap uses, appended after Grassfield's own path.
package.path = package.path .. ";" .. home .. "/.local/state/?.lua;" .. home .. "/.config/?.lua;" .. omarchy_path .. "/?.lua"

-- Omarchy helpers define the global `o` used by its modules; envs sets the Wayland toolkit environment and PATH.
local ok, err = pcall(function()
  require("default.hypr.helpers")
  require("default.hypr.envs")
end)
if not ok then
  M.reason = tostring(err)
  problem("environment: " .. M.reason)
  return M
end
M.ok = true

-- The system keyboard defaults, as the Omarchy session gets them. Grassfield's own input.lua follows (below, before the
-- user's input.lua) and only sets pointer-related keys, so layout, options, repeat and numlock stay as set here.
local input_ok, input_err = pcall(require, "default.hypr.input")
if input_ok then
  M.input = "omarchy"
else
  M.input = "fallback"
  problem("input defaults: " .. tostring(input_err))
  -- Same rules as default/hypr/input.lua (layout and variant from /etc/vconsole.conf, Caps Lock as Compose with both
  -- Shifts as Caps Lock, 40/250 repeat, numlock on), so a rename in Omarchy cannot cost a French user their layout.
  local layout, variant = "us", ""
  local f = io.open("/etc/vconsole.conf", "r")
  if f then
    for line in f:lines() do
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key and value then
        value = value:gsub("%s+#.*$", ""):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
        if key == "XKBLAYOUT" and value ~= "" then layout = value end
        if key == "XKBVARIANT" then variant = value end
      end
    end
    f:close()
  end
  hl.config({
    input = {
      kb_layout = layout,
      kb_variant = variant,
      kb_options = "compose:caps,shift:both_capslock_cancel",
      repeat_rate = 40,
      repeat_delay = 250,
      numlock_by_default = true,
    },
  })
end

-- GF-066: Grassfield's pointer defaults and the Mouse & Trackpad choices saved by Settings go BEFORE the user's own
-- input.lua, so the user's file wins (macOS: these settings belong to the user). Applied here, not in core.lua.
local gi_ok, gi_err = pcall(require, "grassfield.input")
M.input_applied = gi_ok
if not gi_ok then problem("pointer defaults: " .. tostring(gi_err)) end

-- The user's own files (Omarchy templates; they may call `o.*`). A failure in one does not drop the others.
if exists(home .. "/.config/hypr/monitors.lua") then
  local mok, merr = pcall(require, "hypr.monitors")
  if not mok then
    M.monitors = false
    problem("monitors.lua: " .. tostring(merr))
  end
end
if exists(home .. "/.config/hypr/input.lua") then
  local uok, uerr = pcall(require, "hypr.input")
  if not uok then problem("input.lua: " .. tostring(uerr)) end
end

return M
