-- Pointer theme (ADR-0014): Grassfield's own cursors for Hyprland (hyprcursor), XWayland, GTK and Qt (XCursor).
-- hl.env() runs while the config is parsed, before Hyprland loads its cursor manager and before any client starts,
-- so the compositor and the processes it spawns itself (exec_cmd, Xwayland) see the same theme and size. Processes
-- started by systemd (grassfield-shell, D-Bus activated apps) do not inherit Hyprland's environment: in the real
-- session autostart.lua lists these variables in the `uwsm finalize` import; the nested dev session gets them from
-- scripts/dev/devenv.sh (shell, private bus, isolated apps).
--
-- Theme choice:
--   * dev (nested) session: the theme built by branding/cursors/build.sh into <repo>/.dev/share/icons, only if it exists;
--     the system theme stays in place otherwise. XDG_DATA_DIRS/XCURSOR_PATH point at .dev for the nested tree only.
--   * real session: always "grassfield-cursors" from the package, whatever is on disk. The theme regenerated for custom
--     pointer colours ($XDG_DATA_HOME/icons/grassfield-cursors-custom) is NOT picked here: which theme is right depends on
--     the stored colours, and only the shell reads them. The shell (shell/platform/Pointer.qml) asks the compositor for the
--     custom theme as soon as its settings are read, when the stamp inside the theme (colors) names the stored colours,
--     and for the packaged one (deleting the custom theme) when the colours are the defaults. Choosing the custom theme
--     here made "Reset Colour" a no-op after a login with the theme on disk, and showed stale colours after the colours
--     were edited by hand. Cost: a pointer with custom colours shows the packaged colours for the second or so between
--     the compositor start and the shell reading its settings.
-- Size: GRASSFIELD_CURSOR_SIZE (pixels) when set, 24 otherwise.

local M = {}

local DEFAULT_THEME = "grassfield-cursors"

local function exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function dev_icons_dir()
  local config_dir = os.getenv("GRASSFIELD_CONFIG_DIR") or ""
  local root = config_dir:match("^(.*)/config/hypr/?$")
  if root then
    return root .. "/.dev/share/icons"
  end
  return nil
end

function M.resolve()
  local size = tonumber(os.getenv("GRASSFIELD_CURSOR_SIZE") or "") or 24
  if _G.grassfield_dev then
    local dir = dev_icons_dir()
    if dir and exists(dir .. "/" .. DEFAULT_THEME .. "/manifest.hl") then
      return { theme = DEFAULT_THEME, size = size, icons_dir = dir }
    end
    return nil
  end
  return { theme = DEFAULT_THEME, size = size }
end

function M.apply()
  local choice = M.resolve()
  if not choice then
    return
  end
  if choice.icons_dir then
    local share = choice.icons_dir:match("^(.*)/icons$")
    local data_dirs = os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    -- devenv.sh already put .dev/share first for the nested tree: no second entry.
    if not (":" .. data_dirs .. ":"):find(":" .. share .. ":", 1, true) then
      hl.env("XDG_DATA_DIRS", share .. ":" .. data_dirs)
    end
    local xcursor_path = os.getenv("XCURSOR_PATH") or "~/.local/share/icons:~/.icons:/usr/share/icons"
    if not (":" .. xcursor_path .. ":"):find(":" .. choice.icons_dir .. ":", 1, true) then
      hl.env("XCURSOR_PATH", choice.icons_dir .. ":" .. xcursor_path)
    end
  end
  hl.env("HYPRCURSOR_THEME", choice.theme)
  hl.env("HYPRCURSOR_SIZE", tostring(choice.size))
  hl.env("XCURSOR_THEME", choice.theme)
  hl.env("XCURSOR_SIZE", tostring(choice.size))
end

return M
