#!/usr/bin/env bash
# Nested-session helper for the app switcher (NOT run by scripts/dev/test.sh: needs `just nested-up`). Run it bare.
#   nested.sh apps                    open three foot windows with distinct app ids (gf-switcher-alpha, -beta, -gamma)
#   nested.sh enter [next|previous]   what the SUPER+TAB bind does: enter the "switcher" key map, send the request
#   nested.sh quick                   enter, then release at once (two requests back to back: quick switch, no panel)
#   nested.sh keys ARGS...            any wtype arguments, forwarded through scripts/dev/keys.sh
# wtype cannot inject SUPER+TAB nor a Super release here (see docs/specs/switcher.md, Key handling), hence enter/quick.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$root/.dev" || exit 1
sock=$DEV_NESTED_SOCK

case ${1:-} in
apps)
  for id in alpha beta gamma; do
    WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name "switcher-$id" foot --app-id="gf-switcher-$id" --title="Switcher $id" \
      >/dev/null 2>&1 </dev/null &
    sleep 1.5
  done
  ;;
enter)
  "$root/scripts/nestctl" dispatch 'hl.dsp.submap("switcher")' >/dev/null
  qs ipc --any-display -p "$root/shell" call switcher "${2:-next}"
  ;;
quick)
  "$root/scripts/nestctl" dispatch 'hl.dsp.submap("switcher")' >/dev/null
  qs ipc --any-display -p "$root/shell" call switcher next
  qs ipc --any-display -p "$root/shell" call switcher release
  "$root/scripts/nestctl" dispatch 'hl.dsp.submap("reset")' >/dev/null
  ;;
keys)
  shift
  "$root/scripts/dev/keys.sh" "$@"
  ;;
*)
  echo "usage: nested.sh apps | enter [next|previous] | quick | keys ARGS..." >&2
  exit 2
  ;;
esac
