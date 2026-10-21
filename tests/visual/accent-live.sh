#!/usr/bin/env bash
# Accent colour follows grassfield.json live (docs/specs/ui.md "Accent colour"): for each accent the Control Center (its
# toggles and the menu bar highlight) and the Settings app (the Accent colour row, the Apps tile of the Dock, the sidebar
# selection) are captured with NO restart of the shell, the config file is only rewritten. NOT a regression scenario: it
# writes .dev/visual/accent-live/<accent>.{controlcenter,settings}.<lang>.png and exits 1 when two accents gave
# identical Control Center captures. Run it as a BARE command.
#
#   tests/visual/accent-live.sh [en|fr] [accent...]      (default accents: blue pink graphite)
source "$(dirname "$0")/lib.sh"
VS_LANG=${1:-$VS_LANG}
export VISUAL_LANG=$VS_LANG
shift || true
accents=("$@")
[[ ${#accents[@]} -gt 0 ]] || accents=(blue pink graphite)
OUT=$VS_STATE/accent-live
mkdir -p "$OUT"

vs_session
vs_reset
for accent in "${accents[@]}"; do
  printf '{"version":1,"appearance":"dark","accent":{"color":"%s"}}\n' "$accent" > "$VS_DEV/config/grassfield.json"
  vs_sleep 1.5
  vs_ipc menubar open controlcenter GF-REF >/dev/null
  vs_capture "accent-$accent-cc" >/dev/null
  cp "$VS_SHOTS/accent-$accent-cc.$VS_LANG.png" "$OUT/$accent.controlcenter.$VS_LANG.png"
  vs_ipc menubar close >/dev/null || true
  vs_spawn "$VS_DEV/build/grassfield-settings"
  vs_wait_clients 1
  vs_sleep 2.5
  vs_capture "accent-$accent-settings" >/dev/null
  cp "$VS_SHOTS/accent-$accent-settings.$VS_LANG.png" "$OUT/$accent.settings.$VS_LANG.png"
  vs_kill_clients
done
status=0
first=${accents[0]}
for accent in "${accents[@]:1}"; do
  same=$(magick compare -metric AE "$OUT/$first.controlcenter.$VS_LANG.png" "$OUT/$accent.controlcenter.$VS_LANG.png" null: 2>&1 || true)
  echo "controlcenter $first vs $accent: ${same%%[. ]*} pixels differ"
  [[ ${same%%[. ]*} -gt 500 ]] || status=1
done
exit $status
