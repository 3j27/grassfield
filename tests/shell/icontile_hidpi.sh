#!/usr/bin/env bash
# The own-tile read (TintedIcon, IconShapePrewarm) at a window pixel ratio of 1.25 (the owner's laptop), 1.5 and 2: a Canvas keeps its picture at the window's
# ratio, and reading only its top-left n x n pixels made every icon "off centre" on a HiDPI output (not a tile: a pale plate around a
# coloured tile on every Dock icon in Tinted). Runs tests/unit/tst_icontile.qml (which reads the installed Dock icons where present)
# and tst_iconmodes.qml at QT_SCALE_FACTOR 1.25, 1.5 and 2, offscreen.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
unset QT_QPA_PLATFORMTHEME
fail=0
for f in tst_icontile.qml tst_iconmodes.qml tst_foldercolors.qml; do
  for s in 1.25 1.5 2; do
    out=$(QT_SCALE_FACTOR=$s QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import ui -input "tests/unit/$f" 2>&1)
    if grep -qE '^FAIL' <<<"$out" || ! grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out"; then
      echo "FAIL: $f at QT_SCALE_FACTOR=$s"
      grep -E '^FAIL' -A1 <<<"$out" | head -6
      fail=1
    else
      echo "PASS: $f at QT_SCALE_FACTOR=$s ($(grep -E '^Totals' <<<"$out"))"
    fi
  done
done
exit $fail
