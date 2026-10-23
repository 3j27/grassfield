-- Which build of the compositor extension the session loads (ADR-0009, amendment 2026-10-23; audit GF-033).
-- Reads two small text files (Hyprland's version.h, the builds' stamps) and the environment; writes nothing.
--
-- A plugin only hooks into the Hyprland build it was compiled for: Hyprland compares its own hash with the plugin's (the
-- commit and the Hypr library minors, PluginAPI.hpp __hyprland_api_get_client_hash). Two builds may exist: the packaged
-- one, and the one the pacman hook rebuilt on this machine for the installed Hyprland
-- (/usr/lib/grassfield/grassfield-compositor-rebuild). Each has a stamp next to it (<name>.abi, first line: that ABI
-- string). The session loads the first build whose stamp is the ABI of the Hyprland that runs, the packaged one first (it
-- is never older than the sources a rebuild used); with none, the packaged one anyway: it refuses to hook into another
-- Hyprland build and says so in a notification (the shell runs in its degraded mode, gate C2).

local M = {}

M.packaged = "/usr/lib/grassfield/grassfield-compositor.so"
M.rebuilt = "/var/lib/grassfield/compositor/grassfield-compositor.so"
M.version_h = "/usr/include/hyprland/src/version.h"

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- "0.15.0" -> "0.15", "1" -> "1": what follows the last dot goes (PluginAPI.hpp stripPatch).
function M.strip_patch(v)
  return v:match("^(.*)%.[^.]*$") or v
end

-- The ABI string of the Hyprland whose version.h text is `text`, or nil when a field is missing.
function M.abi(text)
  if type(text) ~= "string" then return nil end
  local function def(name)
    local v = text:match("#define%s+" .. name .. '%s+"([^"\n]*)"')
    if v == "" then return nil end
    return v
  end
  local commit = def("GIT_COMMIT_HASH")
  local aq, hu, hg = def("AQUAMARINE_VERSION"), def("HYPRUTILS_VERSION"), def("HYPRGRAPHICS_VERSION")
  local hc, hlg = def("HYPRCURSOR_VERSION"), def("HYPRLANG_VERSION")
  if not (commit and aq and hu and hg and hc and hlg) then return nil end
  return string.format("%s_aq_%s_hu_%s_hg_%s_hc_%s_hlg_%s", commit, M.strip_patch(aq), M.strip_patch(hu), M.strip_patch(hg),
    M.strip_patch(hc), M.strip_patch(hlg))
end

-- The commit of the Hyprland that runs: HYPRLAND_INSTANCE_SIGNATURE starts with it (<commit>_<time>_<random>), or nil.
function M.running_commit(signature)
  if type(signature) ~= "string" then return nil end
  local commit = signature:match("^(%x+)_")
  if commit and #commit >= 7 then return commit end
  return nil
end

-- The stamp of a build: the first line of <path without .so>.abi, or nil.
function M.stamp(path, reader)
  local text = (reader or read)((path:gsub("%.so$", ".abi")))
  if type(text) ~= "string" then return nil end
  return text:match("^([^\n]+)")
end

-- The build to load and why: path, "packaged" | "rebuilt" | "no-match" (the packaged one, which will refuse) | nil, "none".
-- `env` (tests): { reader = fn(path) -> text | nil, exists = fn(path) -> bool, signature = string | false }.
function M.choose(env)
  env = env or {}
  local reader = env.reader or read
  local present = env.exists or exists
  local signature = env.signature
  if signature == nil then signature = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") end
  local installed = M.abi(reader(M.version_h))
  local running = M.running_commit(signature or nil)
  -- The installed headers describe the Hyprland that runs, unless it was updated under this session (a config reload
  -- after an update): then the build for the running commit is the one (its library minors cannot be known here).
  local function wanted(stamp)
    if not stamp then return false end
    if installed and (not running or installed:sub(1, #running + 1) == running .. "_") then return stamp == installed end
    if running then return stamp:sub(1, #running + 1) == running .. "_" end
    return false
  end
  for _, c in ipairs({ { M.packaged, "packaged" }, { M.rebuilt, "rebuilt" } }) do
    if present(c[1]) and wanted(M.stamp(c[1], reader)) then return c[1], c[2] end
  end
  if present(M.packaged) then return M.packaged, "no-match" end
  return nil, "none"
end

return M
