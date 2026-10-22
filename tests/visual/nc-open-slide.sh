#!/usr/bin/env bash
# The Notification Center comes in from the right edge (macOS model) and never sweeps across the screen from the left
# (owner, real session 2026-10-22: on an open the column came in from the left: its x was animated while the window
# was still 0 wide). For each of several opens on a fresh shell, GF-REF is captured as fast as possible while the
# column slides in. Every capture's LEFT half must equal the closed state; at least one capture must show the column
# part-way in (the right strip differs from both the closed and the open state), otherwise the open was not measured
# and the check FAILs rather than passing on nothing.
# Usage (bare command): tests/visual/nc-open-slide.sh [opens]      Captures: .dev/shots/nc-slide-*.png
source "$(dirname "$0")/lib.sh"

opens=${1:-3}
fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

shot() { # name -> path
  "$VS_ROOT/scripts/dev/shot.sh" "$1" "$VS_OUTPUT" >/dev/null && echo "$VS_DEV/shots/$1.png"
}
# Pixels that differ (fuzz 6 %) between two captures, inside a crop "WxH+X+Y".
diff_px() {
  # (compare exits 1 when the images differ: not an error here, lib.sh runs with set -e and pipefail)
  { magick compare -fuzz 6% -metric AE <(magick "$1" -crop "$3" +repage png:-) <(magick "$2" -crop "$3" +repage png:-) null: 2>&1 || true; } | awk '{print int($1)}'
}

read -r W H < <(magick identify -format '%w %h\n' "$(vs_session >/dev/null; vs_reset >/dev/null; shot nc-slide-probe)")
left="$((W / 2))x$((H - 40))+0+40"
# The column is 344 wide at the right edge: a strip around its middle tells closed, part-way and open apart.
strip="120x$((H - 120))+$((W - 230))+80"
total_left=0
inside=0
for ((n = 1; n <= opens; n++)); do
  # A fresh shell each time: the bug showed on the first open, when the Center's window is created.
  vs_session >/dev/null
  vs_reset >/dev/null
  vs_ipc controlcenter reduceMotion false >/dev/null
  # The pointer goes to the clock first: the closed reference must not differ by the cursor's own move.
  vs_pointer abs 1850 12 >/dev/null
  vs_sleep 0.5
  closed=$(shot nc-slide-closed)
  # The owner's gesture: a click on the clock of this output's menu bar (the Center opens on the clicked output).
  vs_pointer abs 1850 12 click >/dev/null &
  frames=()
  for ((k = 0; k < 8; k++)); do frames+=("$(shot "nc-slide-$n-$k")"); done
  wait
  vs_sleep 1
  open=$(shot nc-slide-open)
  vs_ipc notifications toggleCenter >/dev/null
  vs_sleep 1
  for f in "${frames[@]}"; do
    l=$(diff_px "$closed" "$f" "$left")
    total_left=$((total_left + l))
    c=$(diff_px "$closed" "$f" "$strip")
    o=$(diff_px "$open" "$f" "$strip")
    ((c > 200 && o > 200)) && inside=$((inside + 1))
    echo "open $n $(basename "$f"): left-half changed $l px, strip vs closed $c, vs open $o"
  done
done
check "the left half never changed while the Center opened (${total_left} px over $opens opens)" test "$total_left" -lt 50
check "at least one capture landed inside the slide ($inside), so the opens were measured" test "$inside" -ge 1
check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
