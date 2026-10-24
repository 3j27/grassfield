#!/usr/bin/env bash
# Quick Settings sliders by IPC (REQ-QS-CC5/CC6, docs/specs/controlcenter.md acceptance CC5/6) in the NESTED session. Run it
# bare with a nested session up (scripts/dev/nested-up.sh); skipped without one.
#   1. `controlcenter volumeLevel` equals `wpctl get-volume @DEFAULT_AUDIO_SINK@` (the slider shows the real value).
#   2. `controlcenter volume 0.30` is refused by the dev guard (the nested shell must never change the owner's audio):
#      the answer says so and `wpctl get-volume` is unchanged afterwards.
#   3. The same for `controlcenter brightness` against `brightnessctl` (skipped without a backlight).
# The write half of the acceptance (`volume 0.30` then `wpctl get-volume` prints 0.30) needs a session without the dev guard
# (the owner's L2 check, docs/owner-setup/real-session.md). Exit 0 when every check passes.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
if ! dev_nested_target "$dev" 2>/dev/null || ! dev_live_pid "$dev/shell.pid" >/dev/null; then
  echo "SKIP cc_sliders_ipc: no nested session of this tree (scripts/dev/nested-up.sh, as a bare command)"
  exit 0
fi
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
ipc() { "$root/tests/visual/ipc.sh" controlcenter "$@"; }
wp() { wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{printf "%.2f", $2}'; }

if command -v wpctl >/dev/null && [[ -n $(wp) ]]; then
  # Right after a shell start the PipeWire sink binds a moment later: allow it up to 5 s.
  level=""
  for _ in $(seq 1 25); do
    level=$(ipc volumeLevel)
    [[ $level == "$(wp)" ]] && break
    sleep 0.2
  done
  [[ $level == "$(wp)" ]]; check "volumeLevel equals wpctl get-volume (shell $level, wpctl $(wp))" $?
  before=$(wp)
  answer=$(ipc volume 0.30)
  [[ $answer == "refused: dev guard" ]]; check "volume 0.30 refused by the dev guard (answer: $answer)" $?
  sleep 0.5
  [[ $(wp) == "$before" ]]; check "wpctl get-volume unchanged after the refused write" $?
else
  echo "SKIP volume: no PipeWire default sink in this environment"
fi

if command -v brightnessctl >/dev/null && [[ $(ipc brightnessLevel) != none ]]; then
  max=$(brightnessctl -m max 2>/dev/null)
  before=$(brightnessctl -m get 2>/dev/null)
  answer=$(ipc brightness 0.30)
  [[ $answer == "refused: dev guard" ]]; check "brightness 0.30 refused by the dev guard (answer: $answer)" $?
  sleep 0.5
  [[ $(brightnessctl -m get 2>/dev/null) == "$before" ]]; check "brightness unchanged after the refused write (max $max)" $?
else
  echo "SKIP brightness: no backlight device"
fi

exit $fails
