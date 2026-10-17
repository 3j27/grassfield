#!/usr/bin/env bash
# Lint all Grassfield QML (gate Q1). Fails on any warning. Also fails if Tokens.qml is stale.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

python3 ui/tools/gen-tokens.py --check

mapfile -t files < <(git ls-files --cached --others --exclude-standard -- 'ui/*.qml' 'shell/*.qml' 'tests/*.qml')
[[ ${#files[@]} -gt 0 ]] || { echo "qmllint: no QML files"; exit 0; }

# Quickshell resolves `import qs.<dir>` against the shell root; expose the same mapping to
# qmllint through a temporary import root containing a `qs` symlink.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ln -s "$root/shell" "$tmp/qs"

/usr/lib/qt6/bin/qmllint -I ui -I "$tmp" -I /usr/lib/qt6/qml --max-warnings 0 "${files[@]}"
echo "qmllint: ${#files[@]} files, 0 warnings"
python3 -I "$root/scripts/dev/check-textformat.py"
