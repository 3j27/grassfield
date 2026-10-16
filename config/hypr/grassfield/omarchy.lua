-- Guarded, read-only include of Omarchy's hardware and environment setup (ADR-0001).
-- Loads only Omarchy env defaults and the user's monitors/input files. Never writes anything.
-- Returns a status table the shell can surface: { ok = bool, reason = string|nil }.

local M = { ok = false, reason = nil }

local omarchy_path = os.getenv("OMARCHY_PATH") or "/usr/share/omarchy"
local home = os.getenv("HOME") or ""

local function read_first_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Supported Omarchy major version for the module names used below.
local SUPPORTED_MAJOR = "4"

local version = read_first_line(omarchy_path .. "/version")
if not version then
  M.reason = "Omarchy not found at " .. omarchy_path
  return M
end
if version:match("^(%d+)") ~= SUPPORTED_MAJOR then
  M.reason = "unsupported Omarchy version " .. version
  return M
end

-- Same module search path Omarchy's bootstrap uses, appended after Grassfield's own path.
package.path = package.path .. ";" .. home .. "/.local/state/?.lua;" .. home .. "/.config/?.lua;" .. omarchy_path .. "/?.lua"

local ok, err = pcall(function()
  -- Omarchy helpers define the global `o` used by its modules.
  require("default.hypr.helpers")
  require("default.hypr.envs")
  if exists(home .. "/.config/hypr/monitors.lua") then require("hypr.monitors") end
  if exists(home .. "/.config/hypr/input.lua") then require("hypr.input") end
end)

if ok then
  M.ok = true
else
  M.reason = tostring(err)
end
return M
