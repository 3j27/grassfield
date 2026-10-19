#!/usr/bin/env bash
# Dock running dots over a WINDOW under the shelf (autohide on: exclusive zone 0, so windows extend under it), a white
# and a black one, in both appearances: captures the Dock and measures the contrast between a running dot and the shelf
# pixels beside it (WCAG ratio, 3:1 required). Run as a BARE command (reference machine only). The nested session this script
# starts is torn down on exit.
#   tests/visual/dock-backdrop.sh
# Output: .dev/visual/dock-backdrop/<appearance>-<backdrop>.png and a table on stdout. Exit status 1 when a ratio is below 3.
source "$(dirname "$0")/lib.sh"

out=$VS_STATE/dock-backdrop
was_running=0
vs_nested_running && was_running=1
cleanup() {
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Dot centres of the first two running test apps on GF-REF (see contrast.sh: pinned foot, then A and B).
DOT_Y=1062
DOT_XS="927 979"

# ratio PNG X Y: WCAG contrast between the pixel at (X,Y) and the pixels 7 px to the left and right (the shelf).
measure() {
  python3 -I - "$@" <<'PY'
import subprocess, sys
png, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def px(xx):
    fmt = " ".join("%[fx:int(255*p{" + str(xx) + "," + str(y) + "}." + c + ")]" for c in "rgb")
    o = subprocess.run(["magick", png, "-format", fmt, "info:"], capture_output=True, text=True, check=True).stdout.split()
    return [int(v) / 255 for v in o]
def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(p): return 0.2126 * lin(p[0]) + 0.7152 * lin(p[1]) + 0.0722 * lin(p[2])
dot = px(x)
shelf = [px(x - 7), px(x + 7)]
sl = sum(lum(p) for p in shelf) / 2
dl = lum(dot)
r = (max(dl, sl) + 0.05) / (min(dl, sl) + 0.05)
print("%.2f dot=%s shelf=%s" % (r, [round(v * 255) for v in dot], [round(v * 255) for v in shelf[0]]))
PY
}

mkdir -p "$out"
rm -f "$out"/*.png
vs_session en
vs_reset dark 0.25
fail=0
printf '%-14s %-6s %-6s %s\n' appearance window dot-x "contrast (dot vs shelf)"
for appearance in light dark; do
  for backdrop in white black; do
    vs_reset "$appearance" 0.25
    vs_ipc dock autohide on >/dev/null
    vs_ipc dock reveal on >/dev/null
    if [[ $backdrop == white ]]; then bg=ffffff; else bg=000000; fi
    # Two big floating windows (taller than the screen: clamped to it) cover the revealed shelf.
    vs_spawn foot --app-id gfdockA -w 1920x1400 -o "colors-dark.background=$bg" -o "colors-dark.alpha=1"
    vs_sleep 1.5
    vs_spawn foot --app-id gfdockB -w 1920x1400 -o "colors-dark.background=$bg" -o "colors-dark.alpha=1"
    vs_sleep 2.5
    VS_SHOTS=$out VS_SETTLE=1 vs_capture "$appearance-$backdrop" >/dev/null
    mv "$out/$appearance-$backdrop.en.png" "$out/$appearance-$backdrop.png"
    for x in $DOT_XS; do
      res=$(measure "$out/$appearance-$backdrop.png" "$x" "$DOT_Y")
      printf '%-14s %-6s %-6s %s\n' "$appearance" "$backdrop" "$x" "$res"
      awk -v r="${res%% *}" 'BEGIN { exit !(r + 0 >= 3) }' || fail=1
    done
    vs_ipc dock reveal off >/dev/null
    vs_ipc dock autohide off >/dev/null
    vs_kill_clients
  done
done
exit $fail
