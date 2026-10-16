#!/usr/bin/env bash
# Lint all Grassfield QML (gate Q1). Fails on any warning.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mapfile -t files < <(git ls-files --cached --others --exclude-standard -- 'ui/*.qml' 'shell/*.qml' 'tests/*.qml')
[[ ${#files[@]} -gt 0 ]] || { echo "qmllint: no QML files"; exit 0; }
/usr/lib/qt6/bin/qmllint -I ui -I /usr/lib/qt6/qml --max-warnings 0 "${files[@]}"
echo "qmllint: ${#files[@]} files, 0 warnings"
