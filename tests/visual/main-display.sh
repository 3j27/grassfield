#!/usr/bin/env bash
# The main display and the wallpaper per display, in a nested session with TWO outputs (WAYLAND-1 and GF-REF, ADR-0044).
# Usage (bare command; the nested session is already up, started WITHOUT --desktop-screen so that the main display decides):
#   tests/visual/main-display.sh open <section> [display]   open Settings on a pane (the session's own config directory)
#   tests/visual/main-display.sh close                      close the Settings window
#   tests/visual/main-display.sh click <x> <y>              click at x y on GF-REF
#   tests/visual/main-display.sh shot <name> [output]       capture an output (default GF-REF) to .dev/shots/<name>.png
#   tests/visual/main-display.sh main <output>              what the Settings pop-up writes: displays.main for the two outputs
#   tests/visual/main-display.sh state                      the Dock's output and the desktop-icons output
source "$(dirname "$0")/lib.sh"

cfg=$VS_DEV/config/grassfield.json
[[ -f $VS_STATE/session.lang ]] || printf 'en\n' > "$VS_STATE/session.lang"

case ${1:-} in
  open)
    "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({ monitor = '$VS_OUTPUT' })" >/dev/null
    args=("--section=${2:?section}")
    [[ -z ${3:-} ]] || args+=("--display=$3")
    vs_spawn "$VS_DEV/build/grassfield-settings" "${args[@]}"
    ;;
  close)
    vs_kill_clients
    ;;
  click)
    vs_pointer abs "${2:?x}" "${3:?y}" sleep 300 click >/dev/null
    ;;
  rclick)
    vs_pointer abs "${2:?x}" "${3:?y}" sleep 300 rclick >/dev/null
    ;;
  shot)
    # A capture of the nested window output (WAYLAND-1) can hang: bounded.
    timeout 40 "$VS_ROOT/scripts/dev/shot.sh" "${2:?name}" "${3:-$VS_OUTPUT}"
    ;;
  main)
    # Both outputs have no EDID here: their identity is the connector (n:<name>).
    out=${2:?output}
    mkdir -p "$VS_DEV/config"
    [[ -f $cfg ]] || printf '{"version":1}\n' > "$cfg"
    jq --arg m "n:$out" '.displays.main = [{set: ["n:GF-REF", "n:WAYLAND-1"], main: $m}]' "$cfg" > "$cfg.new"
    mv "$cfg.new" "$cfg"
    ;;
  state)
    vs_ipc dock screen
    ;;
  *)
    echo "usage: main-display.sh open|close|click|shot|main|state" >&2
    exit 2
    ;;
esac
