#!/usr/bin/env bash
# The whole drawn (magnified) Dock icon takes the pointer (owner report 2026-10-25: "an app is open, I click it in the Dock and
# nothing happens"; the owner runs magnification and auto-hide). Real virtual-pointer clicks on GF-REF (the rendering output) at the
# top, the middle and the bottom of a magnified icon (cross axis: "top" is the far side from the screen edge, the part that sticks
# out of the tile box), for magnification 1.6 and 2.5 on a Dock at the bottom, left and right, with auto-hide on and magnification
# on. Each click must run the tap handler of exactly the tile whose drawn icon holds the pointer (`dock iconrect`), once, no other.
# Nothing is started or opened by the clicks: `dock noactivate` (fixtures) makes the Dock's activation a no-op after the tap handler
# logged "dock-launch: tapped <tile key>" (the key form `dock tiles` prints). One more click, on the Apps tile (key "grid") with
# activation back on, must open the Apps panel from the top of its magnified icon. The shell runs with the fixture HOME
# (.dev/apps-home/home, scripts/dev/shell-run.sh) and the test seeds a throwaway Downloads there: the owner's files are never read
# (the test stops, exit 2, when the shell's HOME is not the fixture one).
# Run as a BARE command (reference machine only). The nested session this script starts is torn down on exit.
#   tests/visual/dock-hit.sh [edge ...] [-- scale ...]     default: bottom left right, scales 1.6 2.5
# Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_ipc dock noactivate false >/dev/null 2>&1 || true
  vs_nested_running && vs_kill_clients || true
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

edges=() scales=()
mode=e
for a in "$@"; do
  if [[ $a == -- ]]; then mode=s; continue; fi
  if [[ $mode == e ]]; then edges+=("$a"); else scales+=("$a"); fi
done
(( ${#edges[@]} )) || edges=(bottom left right)
(( ${#scales[@]} )) || scales=(1.6 2.5)

log=$VS_DEV/shell.log
fails=0
checks=0
pass() { checks=$((checks + 1)); echo "PASS: $*"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL: $*"; }

fix_home=$VS_DEV/apps-home/home
mkdir -p "$fix_home/Downloads"
printf 'fixture\n' > "$fix_home/Downloads/dock-hit-fixture.txt"
vs_session en || { echo "dock-hit: the nested session did not come up"; exit 2; }
vs_reset dark 0.25
shell_pid=$(dev_live_pid "$VS_DEV/shell.pid")
shell_home=$(tr '\0' '\n' < "/proc/$shell_pid/environ" 2>/dev/null | sed -n 's/^HOME=//p')
[[ -n $shell_pid && $shell_home == "$fix_home" ]] || { echo "dock-hit: the shell's HOME is '$shell_home', not the fixture $fix_home: refusing to run (no owner files)"; exit 2; }
size=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.width) \(.height)"')
read -r W H <<<"$size"
[[ -n $W && -n $H ]] || { echo "dock-hit: no output $VS_OUTPUT"; exit 2; }
echo "dock-hit: $VS_OUTPUT ${W}x${H}; tiles: $(vs_ipc dock tiles)"
vs_ipc dock autohide true >/dev/null
vs_ipc dock noactivate true >/dev/null

# Number of log lines now: what a click wrote is what comes after.
mark() { wc -l < "$log"; }
# The keys tapped after line $1, one per line: the log lines carry a time stamp and a level before the message.
tapped_since() { tail -n +"$(($1 + 1))" "$log" | grep -a "dock-launch: tapped " | sed 's/.*dock-launch: tapped //; s/ [0-9]*$//'; }

# rects: "x y w h" of every tile's drawn icon, one line per tile index ("" for a separator).
rects() {
  local n i
  n=$(vs_ipc dock tiles | jq 'length')
  for i in $(seq 0 $((n - 1))); do
    printf '%s\n' "$(vs_ipc dock iconrect "$i" "$VS_OUTPUT")"
  done
}

# bring the pointer in from the screen edge to the main-axis position $1 (a coordinate along the Dock), then to the cross position
# $2 inside the Dock; settle.
approach() { # edge main cross
  local edge=$1 m=$2 c=$3
  case $edge in
    bottom) vs_pointer abs "$m" 300 sleep 300 abs "$m" $((H - 1)) sleep 1400 abs "$m" "$c" sleep 1300 >/dev/null 2>&1 ;;
    left) vs_pointer abs 960 "$m" sleep 300 abs 0 "$m" sleep 1400 abs "$c" "$m" sleep 1300 >/dev/null 2>&1 ;;
    right) vs_pointer abs 960 "$m" sleep 300 abs $((W - 1)) "$m" sleep 1400 abs "$c" "$m" sleep 1300 >/dev/null 2>&1 ;;
  esac
}

for edge in "${edges[@]}"; do
  for scale in "${scales[@]}"; do
    vs_ipc dock position "$edge" >/dev/null
    vs_ipc dock magnify 1 false >/dev/null
    sleep 1.5
    # Unmagnified geometry (Dock revealed for the read): pick three app tiles near the middle of the row.
    vs_ipc dock reveal true >/dev/null
    sleep 1.2
    keys=$(vs_ipc dock tiles)
    mapfile -t base < <(rects)
    vs_ipc dock reveal false >/dev/null
    vs_pointer abs 960 300 >/dev/null 2>&1
    sleep 1.5
    picks=()
    for i in $(seq 0 $((${#base[@]} - 1))); do
      k=$(jq -r --argjson i "$i" '.[$i]' <<<"$keys")
      [[ -n ${base[$i]} && $k != grid && $k != trash && $k != separator && $k != divider ]] && picks+=("$i")
    done
    (( ${#picks[@]} >= 2 )) || { fail "$edge $scale: fewer than 2 app tiles ($keys)"; continue; }
    vs_ipc dock magnify "$scale" true >/dev/null
    sleep 0.5
    for pi in 0 $((${#picks[@]} - 1)); do
      t=${picks[$pi]}
      read -r bx by bw bh <<<"${base[$t]}"
      if [[ $edge == bottom ]]; then m=$((bx + bw / 2)); else m=$((by + bh / 2)); fi
      # Aim at the middle of the icon; the position along the Dock is kept for the three clicks (the magnification follows it only).
      for frac in top middle bottom; do
        if [[ $edge == bottom ]]; then c0=$((by + bh / 2)); elif [[ $edge == left ]]; then c0=$((bx + bw / 2)); else c0=$((bx + bw / 2)); fi
        approach "$edge" "$m" "$c0"
        mapfile -t now < <(rects)
        read -r nx ny nw nh <<<"${now[$t]}"
        # The cross extent of the drawn icon of the aimed tile: "top" is its outermost 10 %, "bottom" its innermost 10 %.
        if [[ $edge == bottom ]]; then lo=$ny hi=$((ny + nh)); elif [[ $edge == left ]]; then lo=$nx hi=$((nx + nw)); else lo=$nx hi=$((nx + nw)); fi
        span=$((hi - lo))
        # "top" = far from the screen edge: small y (bottom Dock), large x (left Dock), small x (right Dock).
        case $edge:$frac in
          bottom:top) c=$((lo + span / 10)) ;;
          bottom:bottom) c=$((hi - span / 10)) ;;
          left:top) c=$((hi - span / 10)) ;;
          left:bottom) c=$((lo + span / 10)) ;;
          right:top) c=$((lo + span / 10)) ;;
          right:bottom) c=$((hi - span / 10)) ;;
          *) c=$((lo + span / 2)) ;;
        esac
        # The tile whose drawn icon holds the pointer at the click (the aimed one unless the row moved under it).
        if [[ $edge == bottom ]]; then px=$m py=$c; else px=$c py=$m; fi
        vs_pointer abs "$px" "$py" sleep 700 >/dev/null 2>&1
        mapfile -t now < <(rects)
        want=""
        for i in $(seq 0 $((${#now[@]} - 1))); do
          [[ -n ${now[$i]} ]] || continue
          read -r rx ry rw rh <<<"${now[$i]}"
          (( px >= rx && px < rx + rw && py >= ry && py < ry + rh )) && want=$(jq -r --argjson i "$i" '.[$i]' <<<"$keys")
        done
        before=$(mark)
        vs_pointer click >/dev/null 2>&1
        sleep 1.2
        got=$(tapped_since "$before" | tr '\n' ' ' | sed 's/ $//')
        label="$edge x$scale tile $(jq -r --argjson i "$t" '.[$i]' <<<"$keys") $frac (pointer $px,$py; icon ${now[$t]})"
        if [[ -z $want ]]; then
          [[ -z $got ]] && pass "$label: pointer outside every drawn icon, nothing tapped" || fail "$label: pointer outside every icon but tapped: $got"
        elif [[ $got == "$want" ]]; then
          pass "$label: exactly '$want' tapped"
        else
          fail "$label: expected exactly '$want' tapped, got '${got:-nothing}'"
        fi
      done
    done
    # The Apps tile (no interruption): a real activation from the top of its magnified icon.
    ai=$(jq -r 'index("grid")' <<<"$keys")
    if [[ $ai != null ]]; then
      vs_ipc dock noactivate false >/dev/null
      read -r bx by bw bh <<<"${base[$ai]}"
      if [[ $edge == bottom ]]; then m=$((bx + bw / 2)); else m=$((by + bh / 2)); fi
      c0=$((bx + bw / 2)); [[ $edge == bottom ]] && c0=$((by + bh / 2))
      approach "$edge" "$m" "$c0"
      mapfile -t now < <(rects)
      read -r nx ny nw nh <<<"${now[$ai]}"
      case $edge in
        bottom) px=$m py=$((ny + nh / 10)) ;;
        left) px=$((nx + nw - nw / 10)) py=$m ;;
        right) px=$((nx + nw / 10)) py=$m ;;
      esac
      vs_pointer abs "$px" "$py" sleep 700 click >/dev/null 2>&1
      sleep 1.5
      st=$(vs_ipc apps status 2>/dev/null)
      vs_ipc apps close >/dev/null 2>&1
      if [[ $(jq -r '.open' <<<"$st" 2>/dev/null) == true ]]; then pass "$edge x$scale: a click on the outer part of the Apps icon opened the Apps panel ($st)"; else fail "$edge x$scale: the Apps panel did not open from the outer part of its icon (status '$st')"; fi
      vs_ipc dock noactivate true >/dev/null
    fi
    vs_pointer abs 960 300 >/dev/null 2>&1
    sleep 1
  done
done

echo "dock-hit: $checks check(s), $fails failure(s)"
(( fails == 0 ))
