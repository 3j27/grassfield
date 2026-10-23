#!/usr/bin/env bash
# Reduce Motion reaches the animations Hyprland runs itself (audit A11Y-06): with it on, window pop-in and the Spaces slide are
# crossfades of at most 100 ms and moves do not animate; off again, the config's own values are back. Read from the nested
# compositor's animation table (`hyprctl animations -j`), through the shell's setting (controlcenter IPC), never by a raw change.
# Usage (bare command): tests/visual/reduce-motion-compositor.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
leaf() { # name field
  "$VS_ROOT/scripts/nestctl" animations -j | jq -r --arg n "$1" --arg f "$2" '.[0][] | select(.name == $n) | .[$f]' | head -n 1
}
wait_leaf() { # name field value
  local i
  for i in $(seq 1 30); do
    [[ $(leaf "$1" "$2") == "$3" ]] && return 0
    sleep 0.2
  done
  return 1
}

vs_session >/dev/null
vs_ipc controlcenter reduceMotion false >/dev/null
wait_leaf windowsIn style "popin 94%" || true
echo "normal: windowsIn $(leaf windowsIn style) speed $(leaf windowsIn speed); workspaces $(leaf workspaces style) speed $(leaf workspaces speed); windowsMove enabled $(leaf windowsMove enabled)"
check "motion normal: windows pop in with the config's style" test "$(leaf windowsIn style)" = "popin 94%"
check "motion normal: Spaces slide" test "$(leaf workspaces style)" = slide

vs_ipc controlcenter reduceMotion true >/dev/null
wait_leaf workspaces style fade || true
echo "reduced: windowsIn $(leaf windowsIn style) speed $(leaf windowsIn speed); workspaces $(leaf workspaces style) speed $(leaf workspaces speed); windowsMove enabled $(leaf windowsMove enabled)"
check "Reduce Motion: window opening is a crossfade (popin 100%) of at most 100 ms" bash -c '[[ $1 == "popin 100%" ]] && awk -v s="$2" "BEGIN { exit !(s <= 1) }"' _ "$(leaf windowsIn style)" "$(leaf windowsIn speed)"
check "Reduce Motion: window closing is a crossfade of at most 100 ms" bash -c '[[ $1 == "popin 100%" ]] && awk -v s="$2" "BEGIN { exit !(s <= 1) }"' _ "$(leaf windowsOut style)" "$(leaf windowsOut speed)"
check "Reduce Motion: the Spaces slide is a crossfade of at most 100 ms" bash -c '[[ $1 == fade ]] && awk -v s="$2" "BEGIN { exit !(s <= 1) }"' _ "$(leaf workspaces style)" "$(leaf workspaces speed)"
check "Reduce Motion: moving a window does not animate" test "$(leaf windowsMove enabled)" = false

vs_ipc controlcenter reduceMotion false >/dev/null
wait_leaf workspaces style slide || true
check "Reduce Motion off: the Spaces slide is back" test "$(leaf workspaces style)" = slide
check "Reduce Motion off: window pop-in is back" test "$(leaf windowsIn style)" = "popin 94%"
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
vs_ipc controlcenter reduceMotion true >/dev/null
exit $fail
