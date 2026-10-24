#!/usr/bin/env bash
# The Quick Settings slider IPC hooks (controlcenter volume, brightness, volumeLevel, brightnessLevel) read and test the
# REAL device (Audio.deviceReady / deviceVolume, Brightness.deviceAvailable / deviceLevel), never the visual-fixture values
# of Audio.ready / Audio.volume / Brightness.available / Brightness.level (a fixture session answered a fixed 0.50).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
file=$root/shell/menubar/MenuBar.qml
# The text of the controlcenter IpcHandler.
block=$(awk '/target: "controlcenter"/{f=1} f{print} f&&/^    }$/{exit}' "$file")
fail=0
# Only the real-device members (and the guarded writers) may be used: any other member of Audio or Brightness is
# fixture-backed or unknown (ready, volume, muted, available, level ...), and bracket access (Audio["volume"]) hides one.
allowed_audio='deviceReady|deviceVolume|setVolume'
allowed_brightness='deviceAvailable|deviceLevel|setLevel'
if grep -nE '\b(Audio|Brightness)\s*\[' <<<"$block"; then
  echo "FAIL: a controlcenter IPC hook reads Audio or Brightness through bracket access"
  fail=1
fi
if grep -noE '\bAudio\.[A-Za-z_]+' <<<"$block" | grep -vE "Audio\.($allowed_audio)\$"; then
  echo "FAIL: a controlcenter IPC hook reads a fixture-backed Audio member"
  fail=1
fi
if grep -noE '\bBrightness\.[A-Za-z_]+' <<<"$block" | grep -vE "Brightness\.($allowed_brightness)\$"; then
  echo "FAIL: a controlcenter IPC hook reads a fixture-backed Brightness member"
  fail=1
fi
for want in 'Audio.deviceReady' 'Audio.deviceVolume' 'Brightness.deviceAvailable' 'Brightness.deviceLevel'; do
  grep -q "$want" <<<"$block" || { echo "FAIL: the controlcenter IPC hooks do not use $want"; fail=1; }
done
((fail == 0)) || exit 1
echo "PASS: the slider IPC hooks read the real device values"
