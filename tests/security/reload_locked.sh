#!/usr/bin/env bash
# Nested scenario (L1 only): the session lock survives soft reloads and shell crashes (R12, gate L1).
# Never targets the owner's session. Never types a password and never presses Return: the probe
# words typed with wtype land in the lock screen's field without being submitted (no PAM attempt).
#
# Usage: tests/security/reload_locked.sh [step...]   (default: every step, in this order)
#   setup           foot probe window in the nested session; typing reaches it while unlocked (control)
#   nowatch         touching a shell QML file does not reload the configuration (file watcher off)
#   lock            lock through IPC
#   marker-missing  remove the crash marker, soft reload  -> still locked, nothing reaches foot
#   marker-unlocked forge the marker to "unlocked", soft reload -> still locked, nothing reaches foot
#   l1              kill -9 the shell -> nothing reaches foot; restart the shell -> locked again
#   forged-crash    forge the marker to "unlocked", kill -9, restart -> the shell re-acquires the lock
#   cleanup         close the foot probe window (run automatically after the default sequence)
#
# Requires scripts/dev/nested-up.sh (the shell runs with GRASSFIELD_DEV=1, which enables the
# `lock devReload` hook). The nested session stays locked afterwards: finish with nested-down.sh.
# Exit status: 0 when every requested step passed.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sig && -n $sock ]] || { echo "reload_locked: no nested instance (run scripts/dev/nested-up.sh)" >&2; exit 2; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || { echo "reload_locked: refusing the main instance" >&2; exit 2; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "reload_locked: refusing the main Wayland socket" >&2; exit 2; }
[[ -n ${XDG_RUNTIME_DIR:-} ]] || { echo "reload_locked: XDG_RUNTIME_DIR unset" >&2; exit 2; }

marker=$XDG_RUNTIME_DIR/grassfield-lock-${sig//[^A-Za-z0-9_.-]/_}
typed=$dev/reload-typed.txt
status=0

nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
ipc() { nested qs ipc -p "$root/shell" call "$@" 2>/dev/null; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
shot() { "$root/scripts/dev/shot.sh" "$1-gfref" GF-REF >/dev/null && "$root/scripts/dev/shot.sh" "$1-window" WAYLAND-1; }

# Read-only compositor view of the lock: Hyprland lists LOCK in solitaryBlockedBy while a session lock
# is held, including one whose client died.
compositor_lock() {
  nested hyprctl -j monitors 2>/dev/null | jq -c '[.[] | {name, blockedBy: (.solitaryBlockedBy // [])}]'
}

wait_status() { # <expected> <seconds>
  local want=$1 tries=$(($2 * 4)) got=""
  for _ in $(seq 1 "$tries"); do
    got=$(ipc lock status)
    [[ $got == "$want" ]] && { echo "$got"; return 0; }
    sleep 0.25
  done
  echo "${got:-no-answer}"
  return 1
}

# Types a probe word (letters only, never Return) and checks that foot did not receive it.
no_leak() { # <word> <step>
  nested wtype -d 15 "$1"
  sleep 0.7
  if grep -q "$1" "$typed" 2>/dev/null; then fail "$2: typed text reached the foot window ($1)"; else pass "$2: nothing reached the foot window"; fi
}

shell_pid() { cat "$dev/shell.pid" 2>/dev/null; }

step_setup() {
  : >"$typed"
  # New windows open on the monitor under the pointer: put it on the deterministic GF-REF output.
  "$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
  # Raw mode: every key reaches cat at once, no Return needed.
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    setsid foot --app-id=gf-reload-probe -- sh -c 'stty raw -echo; exec cat >"$1"' sh "$typed" >/dev/null 2>&1 </dev/null &
  echo $! >"$dev/reload-foot.pid"
  local geo=""
  for _ in $(seq 1 40); do
    geo=$(nested hyprctl -j clients 2>/dev/null | jq -r '.[] | select(.class == "gf-reload-probe") | "\(.monitor) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
    [[ -n $geo ]] && break
    sleep 0.25
  done
  [[ -n $geo ]] || { fail "setup: the foot probe window did not appear"; return; }
  local mon x y w h name mx my
  read -r mon x y w h <<<"$geo"
  read -r name mx my < <(nested hyprctl -j monitors | jq -r --argjson m "$mon" '.[] | select(.id == $m) | "\(.name) \(.x) \(.y)"')
  # Focus it with a click (focus follows the pointer; no state-changing hyprctl).
  "$root/scripts/dev/pointer.sh" output "$name" abs $((x - mx + w / 2)) $((y - my + h / 2)) sleep 200 click >/dev/null
  sleep 0.5
  nested wtype -d 15 control
  sleep 0.7
  if grep -q control "$typed"; then pass "setup: typing reaches the foot window on $name while unlocked (control)"; else fail "setup: control text did not reach foot; leak checks are meaningless"; fi
}

step_nowatch() {
  local before after
  before=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  touch "$root/shell/security/lock/LockView.qml"
  sleep 3
  after=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  if [[ $before == "$after" ]]; then pass "nowatch: a touched QML file did not reload the shell"; else fail "nowatch: the shell reloaded after a file change"; fi
}

step_lock() {
  echo "lock lock -> $(ipc lock lock)"
  local s
  if s=$(wait_status locked 10); then pass "lock: status $s"; else fail "lock: status $s"; fi
  echo "marker: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot reload-locked
}

reload_case() { # <name> <marker action>
  local name=$1 s
  case $2 in
    remove) rm -f "$marker" ;;
    unlocked) printf 'unlocked\n' >"$marker" ;;
  esac
  echo "marker before reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "lock devReload -> $(ipc lock devReload)"
  sleep 3
  if s=$(wait_status locked 5); then pass "$name: status after reload $s"; else fail "$name: status after reload $s"; fi
  echo "marker after reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot "reload-$name"
  no_leak "leak${name//-/}" "$name"
}

step_marker_missing() { reload_case marker-missing remove; }
step_marker_unlocked() { reload_case marker-unlocked unlocked; }

crash_and_restart() { # <name> <wait seconds>
  local name=$1 pid s
  pid=$(shell_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || { fail "$name: shell not running"; return; }
  kill -9 "$pid"
  sleep 1.5
  echo "compositor after kill -9: $(compositor_lock)"
  shot "$name-dead"
  no_leak "dead${name//-/}" "$name (shell dead)"
  "$root/scripts/dev/shell-run.sh"
  if s=$(wait_status locked "$2"); then pass "$name: restarted shell status $s"; else fail "$name: restarted shell status $s"; fi
  shot "$name-restarted"
  no_leak "back${name//-/}" "$name (restarted)"
}

step_l1() { crash_and_restart l1 10; }

step_forged_crash() {
  printf 'unlocked\n' >"$marker"
  echo "marker forged: $(cat "$marker")"
  crash_and_restart forged-crash 15
}

# Leave nothing behind but the (locked) nested session.
step_cleanup() {
  echo "typed into foot: $(tr -c '[:alnum:]' ' ' <"$typed" 2>/dev/null)"
  if [[ -s $dev/reload-foot.pid ]]; then
    kill -- "-$(<"$dev/reload-foot.pid")" 2>/dev/null || kill "$(<"$dev/reload-foot.pid")" 2>/dev/null || true
    rm -f "$dev/reload-foot.pid"
  fi
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup nowatch lock marker-missing marker-unlocked l1 forged-crash cleanup)
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "reload_locked: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
done
exit $status
