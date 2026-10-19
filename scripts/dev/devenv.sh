#!/usr/bin/env bash
# Dev-only environment (sourced by nested-up.sh, shell-run.sh and isolated.sh; never by anything that touches the
# owner's session). Puts <repo>/.dev/share first in XDG_DATA_DIRS so that dev processes find the icon and cursor
# themes provisioned there (scripts/dev/whitesur.sh, branding/cursors/build.sh), and, when WhiteSur is installed,
# selects it for every Qt process (Quickshell and the Grassfield apps) through QT_QPA_SYSTEM_ICON_THEME.
# Without .dev/share/icons/WhiteSur nothing changes: the current icons keep working (no hard dependency in dev).
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
unset _gf_dev_root
