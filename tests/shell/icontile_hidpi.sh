#!/usr/bin/env bash
# The icon shape reads (TintedIcon, IconShapePrewarm, FolderIcon: the image's own pixels through createImageData) and the wallpaper grid probe at window
# pixel ratios of 1.05, 1.25 (the owner's laptop), 1.5 and 2. drawImage scales an image://icon pixmap by the ratio (half the box on a 1.25
# output), so every icon read "empty" there: a pale plate around a coloured tile on every Dock icon in Tinted. Runs tests/unit/tst_icontile.qml
# (which reads the installed Dock icons where present), tst_iconmodes.qml, tst_foldercolors.qml and tst_wallpapergrab.qml at QT_SCALE_FACTOR
# 1.05, 1.25, 1.5 and 2, offscreen.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
unset QT_QPA_PLATFORMTHEME
fail=0
for f in tst_icontile.qml tst_iconmodes.qml tst_foldercolors.qml tst_wallpapergrab.qml; do
  for s in 1.05 1.25 1.5 2; do
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
