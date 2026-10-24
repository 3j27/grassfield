#!/usr/bin/env bash
# The "Grassfield" Qt Quick Controls style (ui/Grassfield) loads: with QT_QUICK_CONTROLS_STYLE=Grassfield the stock Button,
# ToolButton, CheckBox, ComboBox and TextField are the Grassfield.Ui controls, the others fall back (GF-085).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
out=$(QT_QPA_PLATFORMTHEME= QT_QPA_PLATFORM=offscreen QT_QUICK_CONTROLS_STYLE=Grassfield QT_QUICK_CONTROLS_FALLBACK_STYLE=Basic \
  timeout 120 /usr/lib/qt6/bin/qmltestrunner -import ui -input tests/shell/controls_style/tst_style.qml 2>&1)
rc=$?
if ((rc != 0)) || grep -q '^FAIL' <<<"$out"; then
  echo "$out"
  echo "FAIL: controls_style"
  exit 1
fi
# The style is never set for the session: no config, packaging or session script exports it (only an app's own main selects it).
if grep -rn "QT_QUICK_CONTROLS_STYLE" config packaging scripts/session 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'; then
  echo "FAIL: controls_style: something sets QT_QUICK_CONTROLS_STYLE for the session"
  exit 1
fi
echo "PASS: controls_style ($(grep -c '^PASS' <<<"$out") cases)"
