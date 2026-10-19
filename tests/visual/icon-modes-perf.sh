#!/usr/bin/env bash
# Frame cost of the icon appearance modes (ADR-0014, docs/specs/ui.md "Icon shader"): Files shows 1000 plain folders in the icon
# view; it opens, then the pointer scrolls down and up through them while the scene graph logs every frame
# (qt.scenegraph.time.renderloop), once per icon mode (default, dark, clear, tinted). Prints, per mode and phase (open = window
# shown and first rows populated, scroll): the GUI thread's frame time, the render thread's frame time and the gap between two
# frame starts, each as frames, frames over 33 ms and over 100 ms, and the slowest; and the CPU seconds over the scroll. Then,
# per mode, the Apps panel opening 5 times: the shell's frames during the openings (the shell must run with render timing:
# scripts/dev/nested-up.sh --render-timing). NOT a regression scenario (timings vary with the machine): it writes
# .dev/visual/icon-modes-perf/<mode>.{open,scroll,apps}.log. Run it as a BARE command.
#
#   tests/visual/icon-modes-perf.sh [en|fr] [notches] ["default dark clear tinted"]
#
# The folders it creates live under .dev/visual/ (this worktree's sandbox), never the owner's files.
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
NOTCHES=${2:-60}
KINDS=${3:-"default dark clear tinted"}
OUT=$VS_STATE/icon-modes-perf
SB=$VS_STATE/icon-modes-perf-sandbox
mkdir -p "$OUT"

setattr() { # an xattr on a folder inside .dev/visual only
  case $(realpath -m -- "$1") in "$VS_STATE"/*) ;; *) echo "refusing $1" >&2; return 1 ;; esac
  setfattr -n user.grassfield.folder -v "$2" "$1"
}

fixtures() { # 1000 plain folders
  rm -rf "$SB"
  mkdir -p "$SB"
  local i
  for i in $(seq 0 999); do mkdir -p "$SB/$(printf 'd%04d' "$i")"; done
}

# CPU seconds of a process and its descendants.
tree_cpu() {
  ps -eo pid=,ppid=,cputimes= | awk -v root="$1" '
    { ppid[$1] = $2; cpu[$1] = $3 }
    END { for (p in cpu) { q = p; while (q != "" && q != 0) { if (q == root) { total += cpu[p]; break } q = ppid[q] } } print total + 0 }'
}

# report KIND PHASE FILE [CPU0 CPU1]
report() {
  python3 -I - "$@" <<'PY'
import re, sys
text = open(sys.argv[3], errors="replace").read()
# qt.scenegraph.time.renderloop lines: the GUI thread's "Frame prepared, polish=P ms, lock=L ms, blockedForSync=B ms"
# (polish + the wait for the render thread's sync, where a grab or a layer render lands) and the render thread's "frame
# rendered in R ms" (sync + render + swap). "gap" = the time between two consecutive frame starts on the GUI thread
# ("polishAndSync: start, elapsed since last call"): JavaScript, timers and image decoding of the GUI thread land there.
gui = [int(p) + int(l) + int(b) for p, l, b in re.findall(r"Frame prepared, polish=(\d+) ms, lock=(\d+) ms, blockedForSync=(\d+) ms", text)]
render = [int(r) for r in re.findall(r"frame rendered in (\d+)ms", text)]
gaps = [int(g) for g in re.findall(r"\[gui thread\] polishAndSync: start, elapsed since last call: (\d+) ms", text)]
def row(ms):
    return "%4d frames, > 33 ms: %3d, > 100 ms: %3d, slowest %4d ms" % (len(ms), sum(1 for v in ms if v > 33), sum(1 for v in ms if v > 100), max(ms) if ms else 0)
cpu = " | CPU %.0f s" % (float(sys.argv[5]) - float(sys.argv[4])) if len(sys.argv) > 5 else ""
print("%-9s %-6s GUI frame: %s" % (sys.argv[1], sys.argv[2], row(gui)))
print("%-9s %-6s render:    %s" % ("", "", row(render)))
print("%-9s %-6s gap:       %s%s" % ("", "", row(gaps), cpu))
PY
}

run() { # run KIND
  local kind=$1 log=$OUT/$1.log pid sock bus="" cpu0 cpu1 i m1 cx cy
  vs_kill_clients
  for i in $(seq 1 40); do [[ $(vs_client_count) -eq 0 ]] && break; sleep 0.5; done
  fixtures
  printf '{"version":1,"appearance":"dark","icons":{"folderColor":"theme","mode":"%s"}}\n' "$kind" > "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
  sock=$(vs_nested_wayland)
  [[ -f $VS_DEV/bus.address ]] && bus=$(<"$VS_DEV/bus.address")
  : > "$log"
  "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
    env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="${bus:-}" LC_ALL=en_US.UTF-8 \
    QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES="qt.scenegraph.time.renderloop=true" \
    QT_QPA_PLATFORM=wayland QT_NO_XDG_DESKTOP_PORTAL=1 QML_IMPORT_PATH="$VS_ROOT/ui:$VS_DEV/build/qml" \
    GRASSFIELD_TRANSLATIONS_DIR="$VS_DEV/translations" GRASSFIELD_LANG="$(<"$VS_STATE/session.lang")" \
    HYPRLAND_INSTANCE_SIGNATURE="$(<"$VS_DEV/nested.instance")" "$VS_DEV/build/grassfield-files" "$SB" >"$log" 2>&1 </dev/null &
  pid=$!
  vs_track "$pid"
  vs_wait_clients 1
  vs_sleep 3
  "$VS_ROOT/scripts/dev/keys.sh" -M ctrl -k 1 -m ctrl
  vs_sleep 4
  m1=$(wc -l < "$log")
  head -n "$m1" "$log" > "$OUT/$kind.open.log"
  # The window lands where the compositor puts it: aim at its middle (in GF-REF coordinates).
  read -r cx cy < <("$VS_ROOT/scripts/nestctl" clients -j | jq -r --argjson mon "$("$VS_ROOT/scripts/nestctl" monitors -j | jq --arg n "$VS_OUTPUT" '.[] | select(.name == $n)')" \
    '[.[] | select(.class == "org.grassfield.Files")][0] | "\((.at[0] + .size[0] / 2 - $mon.x) | floor) \((.at[1] + .size[1] / 2 - $mon.y) | floor)"')
  # A first move elsewhere: the pointer must enter the window (a position equal to the last one sends no motion).
  local args=(output "$VS_OUTPUT" abs 40 540 sleep 300 abs "$cx" "$cy" sleep 400)
  for i in $(seq 1 "$NOTCHES"); do args+=(scroll 3 sleep 150); done
  for i in $(seq 1 "$NOTCHES"); do args+=(scroll -3 sleep 150); done
  cpu0=$(tree_cpu "$pid")
  "$VS_ROOT/scripts/dev/pointer.sh" "${args[@]}" >/dev/null
  vs_sleep 2
  cpu1=$(tree_cpu "$pid")
  tail -n +"$((m1 + 1))" "$log" > "$OUT/$kind.scroll.log"
  vs_kill_clients
  for i in $(seq 1 40); do [[ $(vs_client_count) -eq 0 ]] && break; sleep 0.5; done
  vs_sleep 2
  report "$kind" open "$OUT/$kind.open.log"
  report "$kind" scroll "$OUT/$kind.scroll.log" "$cpu0" "$cpu1"
  apps "$kind"
}

# The Apps panel opening 5 times: frames of the shell (its log carries them with --render-timing).
apps() { # apps MODE
  local kind=$1 m0 i
  m0=$(wc -l < "$VS_DEV/shell.log")
  for i in 1 2 3 4 5; do
    vs_ipc apps open >/dev/null
    vs_sleep 1.5
    vs_ipc apps close >/dev/null
    vs_sleep 1
  done
  tail -n +"$((m0 + 1))" "$VS_DEV/shell.log" > "$OUT/$kind.apps.log"
  report "$kind" apps "$OUT/$kind.apps.log"
}

vs_session
vs_reset
printf '{"version":1,"appearance":"dark","icons":{"folderColor":"theme","mode":"default"}}\n' > "$VS_DEV/config/grassfield.json"
vs_sleep 1.5
for kind in $KINDS; do run "$kind"; done
rm -rf "$SB"
