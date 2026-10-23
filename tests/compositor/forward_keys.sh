#!/usr/bin/env bash
# GF-024 / A11Y-04, macOS model: what the focused window receives for the forwarded keys of config/hypr/grassfield/forwarding.lua.
# NESTED only (scripts/dev/nested-up.sh); never the owner's session. Keys are typed with scripts/dev/keys.sh (wtype, through
# the nested compositor's keybind path); a Qt window (tests/compositor/forward-keys-fixture) logs what it receives, a foot
# window (a terminal class) records the bytes it receives.
#
#   Alt+Left / Alt+Right                      -> Ctrl+Left / Ctrl+Right        (word navigation in an ordinary application)
#   Alt+Shift+Left                            -> Ctrl+Shift+Left               (select by word)
#   Alt+Backspace                             -> Ctrl+Backspace                (delete the previous word)
#   Super+1 .. Super+9, Super+Up              -> Ctrl+1 .. Ctrl+9, Ctrl+Up    (Command+number, Command+Up)
#   Super+[ / Super+]                         -> Alt+Left / Alt+Right          (Back / Forward)
#   Ctrl+Left, Ctrl+1                         -> consumed (Spaces): the application receives nothing
#   in a terminal (foot): Alt+Left stays Alt+Left (bytes ESC [ 1 ; 3 D)
# If a `code:` key (Super+digit) fails here but the Alt+arrow lines pass, Hyprland's send_key_state does not take keycodes.
# Exit: 0 PASS, 1 FAIL, 2 usage or environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sock=$DEV_NESTED_SOCK sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" || $sock == "${WAYLAND_DISPLAY:-}" ]]; then
  echo "forward_keys: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in jq foot qs wtype; do
  command -v "$tool" >/dev/null || { echo "forward_keys: $tool is needed" >&2; exit 2; }
done

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
run=$dev/forward-keys/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
fixlog=$run/fixture.log
cap=$run/foot.cap
fail=0
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
check() { # <description> <expected line regex> <log-line-count-before>
  local got
  got=$(tail -n +"$(($3 + 1))" "$fixlog" | grep "\[fk-fixture\] key=" | tail -n 1)
  if [[ -n $got && $got =~ $2 ]]; then echo "PASS: $1 ($got)"; else echo "FAIL: $1 (expected $2, got: ${got:-nothing})"; fail=1; fi
}
nothing() { # <description> <log-line-count-before>
  if [[ -z $(tail -n +"$(($2 + 1))" "$fixlog" | grep "\[fk-fixture\] key=") ]]; then echo "PASS: $1 (the application received nothing)"; else echo "FAIL: $1 (it received a key)"; fail=1; fi
}
keys() { timeout 10 "$root/scripts/dev/keys.sh" "$@" >>"$run/keys.log" 2>&1; sleep 0.4; }
lines() { wc -l <"$fixlog"; }

WAYLAND_DISPLAY=$sock HYPRLAND_INSTANCE_SIGNATURE=$sig setsid "$root/scripts/dev/isolated.sh" --name forward-keys-fixture \
  qs -p "$root/tests/compositor/forward-keys-fixture" --no-color >"$fixlog" 2>&1 </dev/null &
pids+=($!)
for _ in $(seq 1 60); do grep -q "\[fk-fixture\] mapped" "$fixlog" && break; sleep 0.1; done
grep -q "\[fk-fixture\] mapped" "$fixlog" || { echo "forward_keys: the fixture window did not map (see $fixlog)" >&2; exit 2; }
sleep 0.8

ALT=134217728 CTRL=67108864 SHIFT=33554432
n=$(lines); keys -M alt -k Left -m alt;                      check "Alt+Left -> Ctrl+Left" "key=16777234 mods=$CTRL " "$n"
n=$(lines); keys -M alt -k Right -m alt;                     check "Alt+Right -> Ctrl+Right" "key=16777236 mods=$CTRL " "$n"
n=$(lines); keys -M alt -M shift -k Left -m shift -m alt;    check "Alt+Shift+Left -> Ctrl+Shift+Left" "key=16777234 mods=$((CTRL + SHIFT)) " "$n"
n=$(lines); keys -M alt -k BackSpace -m alt;                 check "Alt+Backspace -> Ctrl+Backspace" "key=16777219 mods=$CTRL " "$n"
n=$(lines); keys -M logo -k bracketleft -m logo;             check "Super+[ -> Alt+Left" "key=16777234 mods=$ALT " "$n"
n=$(lines); keys -M logo -k bracketright -m logo;            check "Super+] -> Alt+Right" "key=16777236 mods=$ALT " "$n"
n=$(lines); keys -M logo -k Up -m logo;                      check "Super+Up -> Ctrl+Up" "key=16777235 mods=$CTRL " "$n"
for d in 1 2 3 4 5 6 7 8 9; do
  n=$(lines); keys -M logo -k "$d" -m logo;                  check "Super+$d -> Ctrl+$d" "key=$((48 + d)) mods=$CTRL " "$n"
done
# Spaces keep Ctrl+arrows and Ctrl+digits: the window must not see them (and the Space is put back).
n=$(lines); keys -M ctrl -k Right -m ctrl;                   nothing "Ctrl+Right switches the Space, not delivered" "$n"
keys -M ctrl -k Left -m ctrl
n=$(lines); keys -M ctrl -k 2 -m ctrl;                       nothing "Ctrl+2 switches to Space 2, not delivered" "$n"
keys -M ctrl -k 1 -m ctrl

# A terminal keeps its Alt+arrows: foot writes the raw bytes it gets to a file.
: >"$cap"
WAYLAND_DISPLAY=$sock setsid "$root/scripts/dev/isolated.sh" --name forward-keys-foot foot -e sh -c 'stty raw -echo; exec cat -v >"$0"' "$cap" \
  >/dev/null 2>&1 </dev/null &
pids+=($!)
sleep 1.5
keys -M alt -k Left -m alt
if grep -qF '^[[1;3D' "$cap"; then echo "PASS: in a terminal Alt+Left stays Alt+Left ($(cat "$cap"))"; else echo "FAIL: terminal got: $(cat "$cap")"; fail=1; fi

alive=0; kill -0 "$hypr_pid" 2>/dev/null && alive=1
if ((alive)) && ! nestctl -j version >/dev/null 2>&1; then alive=0; fi
if ((alive)); then echo "PASS: nested Hyprland alive"; else echo "FAIL: nested Hyprland not responding"; fail=1; fi
echo "log: $run"
exit $fail
