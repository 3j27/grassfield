-- Which build of the compositor extension the session loads (ADR-0009 option 1 and option 3, "Amendment 2026-10-23";
-- audit GF-033). Reads small text files (Hyprland's version.h, the builds' stamps) and the environment; writes nothing.
--
-- A plugin only hooks into the Hyprland build it was compiled for: Hyprland compares its own hash with the plugin's (the
-- commit and the Hypr library minors, PluginAPI.hpp __hyprland_api_get_client_hash). Each build has a stamp next to it
-- (<name>.abi, first line: that ABI string). The session loads, in this order, the first build whose stamp is the ABI of
-- the Hyprland that runs:
--   1. the packaged one (/usr/lib/grassfield/grassfield-compositor.so);
--   2. the one the user built with grassfield-compositor-rebuild ($XDG_CACHE_HOME/grassfield/compositor/<abi>/).
-- None: no extension is loaded (degraded mode, gate C2) and session.lua runs grassfield-compositor-rebuild --session, which
-- says so once, names the Hyprland version and the recovery (and, when the user opted in, builds it).

local M = {}

M.packaged = "/usr/lib/grassfield/grassfield-compositor.so"
M.version_h = "/usr/include/hyprland/src/version.h"
-- Set by session.lua to the build it loaded: a config reload after Hyprland was updated under the session keeps it.
M.loaded_env = "GRASSFIELD_COMPOSITOR_PLUGIN"

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

local function define(text, name)
  local v = text:match("#define%s+" .. name .. '%s+"([^"\n]*)"')
  if v == "" then return nil end
  return v
end

-- The ABI string of the Hyprland whose version.h text is `text`, or nil when a field is missing.
function M.abi(text)
  if type(text) ~= "string" then return nil end
  local commit = define(text, "GIT_COMMIT_HASH")
  local aq, hu, hg = define(text, "AQUAMARINE_VERSION"), define(text, "HYPRUTILS_VERSION"), define(text, "HYPRGRAPHICS_VERSION")
  local hc, hlg = define(text, "HYPRCURSOR_VERSION"), define(text, "HYPRLANG_VERSION")
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

-- The user's build directory for an ABI (grassfield-compositor-rebuild installs there).
function M.user_build(abi, getenv)
  local g = getenv or os.getenv
  local base = g("XDG_CACHE_HOME")
  if not base or base == "" then
    local home = g("HOME")
    if not home or home == "" then return nil end
    base = home .. "/.cache"
  end
  return base .. "/grassfield/compositor/" .. abi .. "/grassfield-compositor.so"
end

-- The stamp of a build: the first line of <path without .so>.abi, or nil.
function M.stamp(path, reader)
  local text = (reader or read)((path:gsub("%.so$", ".abi")))
  if type(text) ~= "string" then return nil end
  return text:match("^([^\n]+)")
end

-- The build to load, and why: path, "packaged" | "user" | "loaded" (kept across a config reload); or nil, and
-- "no-match" (no build for this Hyprland: degraded mode and the notice), "updated" (Hyprland was updated under this
-- session and the build it runs with is unknown: nothing until the next login), "none" (no extension installed).
-- `env` (tests): { reader = fn(path) -> text | nil, exists = fn(path) -> bool, getenv = fn(name) -> string | nil }.
function M.choose(env)
  env = env or {}
  local reader = env.reader or read
  local present = env.exists or exists
  local getenv = env.getenv or os.getenv
  local installed = M.abi(reader(M.version_h))
  local running = M.running_commit(getenv("HYPRLAND_INSTANCE_SIGNATURE"))
  local function stamped(path, accept)
    return path and present(path) and accept(M.stamp(path, reader))
  end
  if installed and (not running or installed:sub(1, #running + 1) == running .. "_") then
    local exact = function(s) return s == installed end
    if stamped(M.packaged, exact) then return M.packaged, "packaged" end
    local user = M.user_build(installed, getenv)
    if stamped(user, exact) then return user, "user" end
    return nil, present(M.packaged) and "no-match" or "none"
  end
  if running then
    -- Hyprland was updated under this session (a config reload after the update): the build for the commit that runs,
    -- the packaged one or the one loaded at login, keeps the extension until the next login.
    local same = function(s) return s ~= nil and s:sub(1, #running + 1) == running .. "_" end
    if stamped(M.packaged, same) then return M.packaged, "packaged" end
    local loaded = getenv(M.loaded_env)
    if loaded and loaded ~= "" and stamped(loaded, same) then return loaded, "loaded" end
    return nil, "updated"
  end
  return nil, present(M.packaged) and "no-match" or "none"
end

return M
