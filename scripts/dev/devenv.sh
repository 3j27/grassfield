#!/usr/bin/env bash
# Dev-only environment (sourced by nested-up.sh, shell-run.sh and isolated.sh; never by anything that touches the
# owner's session). Puts <repo>/.dev/share first in XDG_DATA_DIRS so that dev processes find the icon and cursor
# themes provisioned there (scripts/dev/whitesur.sh, branding/cursors/build.sh), and, when WhiteSur is installed,
# selects it for every Qt process (Quickshell and the Grassfield apps) through QT_QPA_SYSTEM_ICON_THEME.
# Without .dev/share/icons/WhiteSur nothing changes: the current icons keep working (no hard dependency in dev).
# The Grassfield cursor theme (branding/cursors/build.sh, ADR-0014), when built under .dev/share/icons, is selected the
# way config/hypr/grassfield/cursor.lua selects it for Hyprland and its children (exec_cmd, Xwayland): the shell, the
# private bus and the apps are started outside Hyprland and would not see those variables otherwise.
# Only the environment of the calling process and its children is changed.

_gf_dev_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
if [[ -d $_gf_dev_root/.dev/share/icons ]]; then
  case ":${XDG_DATA_DIRS:-}:" in
    *":$_gf_dev_root/.dev/share:"*) ;;
    *) export XDG_DATA_DIRS="$_gf_dev_root/.dev/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
  esac
  if [[ -f $_gf_dev_root/.dev/share/icons/WhiteSur/index.theme ]]; then
    export QT_QPA_SYSTEM_ICON_THEME=WhiteSur
  fi
fi
if [[ -f $_gf_dev_root/.dev/share/icons/grassfield-cursors/manifest.hl ]]; then
  # The size follows Settings > Accessibility > Pointer (.dev/config/grassfield.json, pointer.size, 24..96 as an integer)
  # unless GRASSFIELD_CURSOR_SIZE overrides it; anything else is the default 24.
  _gf_cursor_size=${GRASSFIELD_CURSOR_SIZE:-}
  if [[ -z $_gf_cursor_size && -r $_gf_dev_root/.dev/config/grassfield.json ]] && command -v jq >/dev/null 2>&1; then
    _gf_cursor_size=$(jq -r 'if (.pointer.size | type) == "number" and .pointer.size == (.pointer.size | floor) and .pointer.size >= 24 and .pointer.size <= 96 then .pointer.size else 24 end' "$_gf_dev_root/.dev/config/grassfield.json" 2>/dev/null || true)
  fi
  [[ $_gf_cursor_size =~ ^[0-9]+$ ]] || _gf_cursor_size=24
  export HYPRCURSOR_THEME=grassfield-cursors HYPRCURSOR_SIZE=$_gf_cursor_size
  export XCURSOR_THEME=grassfield-cursors XCURSOR_SIZE=$_gf_cursor_size
  case ":${XCURSOR_PATH:-}:" in
    *":$_gf_dev_root/.dev/share/icons:"*) ;;
    *) export XCURSOR_PATH="$_gf_dev_root/.dev/share/icons:${XCURSOR_PATH:-~/.local/share/icons:~/.icons:/usr/share/icons}" ;;
  esac
  unset _gf_cursor_size
fi
unset _gf_dev_root
