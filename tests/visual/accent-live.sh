#!/usr/bin/env bash
# Accent colour follows grassfield.json live (docs/specs/ui.md "Accent colour"): for each accent the Control Center (its
# toggles: the glyph of an on toggle on its white disk and the Night Light switch, macOS 27) and the Settings app (the Accent
# colour row, the Apps tile of the Dock, the sidebar selection) are captured with NO restart of the shell, the config file
# is only rewritten. NOT a regression scenario: it writes .dev/visual/accent-live/<n>-<accent>.{controlcenter,settings}.<lang>.png
# and exits 1 when an accent's Control Center does not differ from the first accent's by more than the noise.
#
# What is compared (a review of the 500 px threshold, 2026-10-31): only the Control Center panel (the top right of GF-REF
# under the menu bar), not the whole screen, whose Dock and windows change between the captures; and against the noise,
# measured by capturing the first accent again at the end; every capture is repeated until the panel has settled. Since the macOS 27 Control Center the accent is a small area: the
# glyphs of the on toggles (Wi-Fi and Bluetooth with the visual fixtures) and the Night Light switch, some 100 to 200 pixels
# between two accents, under the old whole-screen 500 px threshold. An accent passes when its panel differs from the first
# accent's by at least ACCENT_MIN_PX (60) pixels and by more than three times the noise, once the panel has settled.
#
#   tests/visual/accent-live.sh [en|fr] [accent...]      (default accents: blue pink graphite)
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
shift || true
accents=("$@")
[[ ${#accents[@]} -gt 0 ]] || accents=(blue pink graphite)
OUT=$VS_STATE/accent-live
rm -rf "$OUT"
mkdir -p "$OUT"
min_px=${ACCENT_MIN_PX:-60}
# The Control Center panel on GF-REF (1920x1080): anchored at the top right, under the menu bar.
cc_box=320x470+1600+30

vs_session
vs_reset
# capture_cc N ACCENT: the accent written to the config, the Control Center opened and captured, the panel cropped.
capture_cc() {
  printf '{"version":1,"appearance":"dark","accent":{"color":"%s"}}\n' "$2" > "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
  vs_ipc menubar open controlcenter GF-REF >/dev/null
  vs_sleep 1
  vs_capture "accent-$2-cc" >/dev/null
  cp "$VS_SHOTS/accent-$2-cc.$VS_LANG.png" "$OUT/$1-$2.controlcenter.$VS_LANG.png"
  magick "$OUT/$1-$2.controlcenter.$VS_LANG.png" -crop "$cc_box" +repage "$OUT/$1-$2.panel.$VS_LANG.png"
  vs_ipc menubar close >/dev/null || true
}
# differ A B: pixels that differ between two panel crops.
differ() {
  local out
  out=$(magick compare -metric AE "$1" "$2" null: 2>&1 || true)
  echo "${out%%[. ]*}"
}

# capture_settled N ACCENT: capture_cc until two captures in a row agree (at most 8): the panel's glass does not always settle
# at once (its tint follows the backdrop it samples). In two runs of five a single capture differed from another of the same
# accent by some 7300 pixels, all in the modules' glass, at the first capture after the shell started or after a Settings
# window closed. Prints the number of captures, or fails.
capture_settled() {
  local try
  capture_cc "$1" "$2"
  for try in 2 3 4 5 6 7 8; do
    cp "$OUT/$1-$2.panel.$VS_LANG.png" "$OUT/$1-$2.previous.png"
    vs_sleep 1.5
    capture_cc "$1" "$2"
    if [[ $(differ "$OUT/$1-$2.previous.png" "$OUT/$1-$2.panel.$VS_LANG.png") == 0 ]]; then
      rm -f "$OUT/$1-$2.previous.png"
      echo "$try"
      return 0
    fi
  done
  echo "more than 8"
  return 1
}

status=0
first=${accents[0]}
n=0
for accent in "${accents[@]}"; do
  n=$((n + 1))
  tries=$(capture_settled "$n" "$accent") || status=1
  echo "controlcenter $accent: settled after $tries captures"
  vs_spawn "$VS_DEV/build/grassfield-settings"
  vs_wait_clients 1
  vs_sleep 2.5
  vs_capture "accent-$accent-settings" >/dev/null
  cp "$VS_SHOTS/accent-$accent-settings.$VS_LANG.png" "$OUT/$n-$accent.settings.$VS_LANG.png"
  vs_kill_clients
done
# The noise: the first accent once more, after the others.
tries=$(capture_settled again "$first") || status=1
noise=$(differ "$OUT/1-$first.panel.$VS_LANG.png" "$OUT/again-$first.panel.$VS_LANG.png")
echo "controlcenter $first vs $first again (noise): $noise pixels differ (settled after $tries captures)"
n=1
for accent in "${accents[@]:1}"; do
  n=$((n + 1))
  d=$(differ "$OUT/1-$first.panel.$VS_LANG.png" "$OUT/$n-$accent.panel.$VS_LANG.png")
  echo "controlcenter $first vs $accent: $d pixels differ (need >= $min_px and > 3 x $noise)"
  [[ $d -ge $min_px && $d -gt $((3 * noise)) ]] || status=1
done
exit $status
