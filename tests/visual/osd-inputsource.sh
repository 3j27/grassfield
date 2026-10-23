#!/usr/bin/env bash
# Input source HUD (docs/specs/osd.md requirement 9), on the nested session: a layout event of the compositor shows the layout
# name in the OSD pill only when the keyboard had another layout; the first layout of a keyboard, and a session that never
# changes layout, show nothing. Fed through the dev hook `osd layout "<keyboard>,<layout name>"`, which takes the same path as
# Hyprland's `activelayout` event (Hyprland itself has one layout configured here, so a real switch cannot be made in nested).
# Run as a BARE command with a relative path, on the reference machine only; the nested session it starts is torn down on exit.
#   tests/visual/osd-inputsource.sh
# Capture: .dev/visual/osd-inputsource/hud.png (the pill with the layout name). Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e
out=$VS_STATE/osd-inputsource
was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && vs_ipc osd hide >/dev/null 2>&1
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
fail=0
check() { if [[ $2 -eq 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
vs_session en
vs_reset dark 0.25
sleep 4
vs_ipc osd hide >/dev/null
vs_ipc osd layout "gfkbd,English (US)" >/dev/null
sleep 0.4
[[ $(vs_ipc osd state) == false* ]]; check "the first layout of a keyboard shows nothing" $?
vs_ipc osd layout "gfkbd,English (US)" >/dev/null
sleep 0.4
[[ $(vs_ipc osd state) == false* ]]; check "the same layout again shows nothing (a single layout never shows)" $?
vs_ipc osd layout "gfkbd,French" >/dev/null
sleep 0.5
[[ $(vs_ipc osd state) == "true|inputsource|French" ]]; check "a change shows the input source HUD with the layout name ($(vs_ipc osd state))" $?
vs_ipc controlcenter reduceMotion false >/dev/null
sleep 0.5
shot=$(VS_SETTLE=0.2 vs_capture osd-inputsource)
cp "$shot" "$out/hud.png" 2>/dev/null
sleep 3
[[ $(vs_ipc osd state) == false* ]]; check "the HUD fades after the OSD delay" $?
exit $fail
