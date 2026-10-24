#!/usr/bin/env bash
# GF-105: every file name a view of Files, Preview, the desktop icons or the Dock stack shows goes through
# DisplayName.text (ui/Grassfield/Ui/DisplayName.js; C++ messages through FileLogic::displayName). Static check: fails on
#  * a QML line that puts a raw file name into a visible text, title or accessible name;
#  * a hand-made line-break replacement (the helper does that);
#  * a message in apps/files/src/filesapp.cpp that names a file without FileLogic::displayName.
# A line that is deliberately raw says so with the comment `raw-name-ok` (a name that is never shown).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

files=(apps/files/qml/*.qml apps/preview/qml/*.qml shell/desktop/DesktopIcon.qml shell/overlay/StackPopup.qml)
# Expressions that hold a file name: .name of a row/cell/entry/page/info record, a path segment label, nameAt(...), fileName().
name_expr='(row|cell|entry|page|info|previewInfo|modelData|i|slot\.entry)\.name\b|segment\.modelData\.label|nameAt\(|fileName\(\)'
hits=$(grep -nE "(text|title|name): .*($name_expr)|\.arg\(.*($name_expr)" "${files[@]}" | grep -v "DisplayName.text" | grep -v "raw-name-ok" \
  | grep -vE "Accessible\.name: (qsTr|root\.title|win\.title)|tagName|appName|\.id\b|bar\.label\(" || true)
# Set B: anywhere in the shell (Dock, overlays, desktop) a base name or file name reaches a text, title, label or accessible name only
# through the helper; the Dock's tile label (a folder's name, an app's, a window's) too.
filesB=(shell/dock/*.qml shell/overlay/*.qml shell/desktop/*.qml)
hitsB=$(grep -nE "(text|title|name|label): .*(baseName\(|fileName)|\.arg\(.*(baseName\(|fileName)" "${filesB[@]}" | grep -v "DisplayName.text" | grep -v "raw-name-ok" || true)
hitsB+=$(grep -nE "property string label:" shell/dock/Dock.qml | grep -v "DisplayName.text" || true)
desc="no Dock, overlay or desktop view shows a raw base name${hitsB:+ (found: $(tr '\n' ' ' <<<"$hitsB"))}"
check test -z "$hitsB"

desc="no QML view shows a raw file name${hits:+ (found: $(tr '\n' ' ' <<<"$hits"))}"
check test -z "$hits"

hits=$(grep -nE 'replace\(/\[\\r\\n\]' "${files[@]}" shell/desktop/*.qml | grep -v raw-name-ok || true)
desc="no view replaces line breaks by hand${hits:+ (found: $(tr '\n' ' ' <<<"$hits"))}"
check test -z "$hits"

hits=$(grep -nE 'tr\("[^"]*“%1”[^"]*"\)\.arg\(' apps/files/src/filesapp.cpp | grep -v "displayName" | grep -vE 'tr\("[^"]*%1[^"]*%2' || true)
hits+=$(grep -nE 'tr\("[^"]*%[12][^"]*"\)\.arg\([^)]*fileName\(\)' apps/files/src/filesapp.cpp | grep -v displayName || true)
desc="no Files message names a file without FileLogic::displayName${hits:+ (found: $(tr '\n' ' ' <<<"$hits"))}"
check test -z "$hits"

exit $fail
