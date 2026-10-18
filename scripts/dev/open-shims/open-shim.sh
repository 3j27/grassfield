#!/usr/bin/env bash
# PATH shim for a GRASSFIELD_DEV session (ADR-0011): gio, xdg-open and gtk-launch are symlinks to this script. Shell code
# that opens a file through them (shell/desktop/DesktopFiles.qml uses `gio open` with Apps.openEnvironment()) gets the dev
# open policy instead of a D-Bus activated handler. Every other `gio` subcommand (trash, mime, monitor...) runs the real one.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
policy=${GRASSFIELD_OPEN_POLICY:-}
name=$(basename "$0")
[[ -x $policy ]] || { echo "open refused in dev: no open policy helper" >&2; exit 1; }
case $name in
  xdg-open) exec "$policy" "$@" ;;
  gtk-launch)
    shift
    [[ $# -gt 0 ]] || { echo "open refused in dev: application launch" >&2; exit 1; }
    exec "$policy" "$@"
    ;;
  gio)
    case ${1:-} in
      open) shift; exec "$policy" "$@" ;;
      launch) echo "open refused in dev: application launch" >&2; exit 1 ;;
    esac
    # Any other subcommand: the real gio, found on PATH without this directory.
    clean=""
    IFS=: read -ra parts <<<"${PATH:-}"
    for p in "${parts[@]}"; do [[ $p == "$here" ]] || clean=${clean:+$clean:}$p; done
    PATH=$clean exec gio "$@"
    ;;
esac
