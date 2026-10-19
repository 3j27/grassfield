#!/usr/bin/env bash
# Nested-session helper for the app switcher (NOT run by scripts/dev/test.sh: needs `just nested-up`). Run it bare.
# Every action goes through the real binds: keys come from the virtual keyboard (tests/tools/vkbd, verified nested socket
# only), requests to the shell through tests/visual/ipc.sh (nested shell by PID), never by path or on another display.
#   nested.sh apps                    open three foot windows with distinct app ids (gf-switcher-alpha, -beta, -gamma)
#   nested.sh hold [MS]               SUPER down, Tab, wait MS (default 400: panel shown), SUPER up   (panel, then activation)
#   nested.sh quick                   SUPER down, Tab, SUPER up at once                               (quick switch, no panel)
#   nested.sh second                  SUPER down, Tab, Tab, wait 400, SUPER up                        (second app after the first)
#   nested.sh keys ARGS...            any vkbd commands (down|up|tap KEY, sleep MS)
#   nested.sh status                  controller status (JSON) and the focused window class
#   nested.sh layers                  the switcher's layer surfaces as the compositor sees them
# Never types into a lock screen: do not run it while the session is locked.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=../../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$root/.dev" || exit 1
sock=$DEV_NESTED_SOCK
vkbd=$root/tests/tools/vkbd/vkbd.sh

case ${1:-} in
apps)
  for id in alpha beta gamma; do
    WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name "switcher-$id" foot --app-id="gf-switcher-$id" --title="Switcher $id" \
      >/dev/null 2>&1 </dev/null &
    sleep 1.5
  done
  ;;
hold)
  "$vkbd" down Super_L tap Tab sleep "${2:-400}" up Super_L
  ;;
quick)
  "$vkbd" down Super_L tap Tab up Super_L
  ;;
second)
  "$vkbd" down Super_L tap Tab sleep 60 tap Tab sleep 400 up Super_L
  ;;
keys)
  shift
  "$vkbd" "$@"
  ;;
status)
  "$root/tests/visual/ipc.sh" switcher status
  "$root/scripts/nestctl" activewindow -j | jq -r '"focused: \(.class) \(.title)"'
  ;;
layers)
  "$root/scripts/nestctl" layers -j | jq -c '.. | objects | select(.namespace? == "grassfield-switcher") | {namespace, w, h}'
  ;;
*)
  echo "usage: nested.sh apps | hold [MS] | quick | second | keys ARGS... | status | layers" >&2
  exit 2
  ;;
esac
