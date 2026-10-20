#!/usr/bin/env bash
# Lint all Grassfield QML (gate Q1). Fails on any warning. Also fails if Tokens.qml is stale.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

python3 ui/tools/gen-tokens.py --check

# Grassfield.I18n is a native module: build it (skipped when current) so qmllint can see its types.
ui/i18n/build-direct.sh >&2

mapfile -t files < <(git ls-files --cached --others --exclude-standard -- 'ui/*.qml' 'shell/*.qml' 'apps/*.qml' 'tests/*.qml')
[[ ${#files[@]} -gt 0 ]] || { echo "qmllint: no QML files"; exit 0; }

# Quickshell resolves `import qs.<dir>` against the shell root; expose the same mapping to
# qmllint through a temporary import root containing a `qs` symlink.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ln -s "$root/shell" "$tmp/qs"

# Once grassfield-desktop is installed, /usr/lib/qt6/qml/Grassfield holds the PACKAGED Grassfield.Ui and Grassfield.I18n,
# and qmllint's default import path would resolve them instead of this tree's (new tokens reported as missing). Lint
# without the default paths (--bare) against Qt's own modules only: a copy of the system QML root without Grassfield.
sysqml="$tmp/sysqml"
mkdir "$sysqml"
for entry in /usr/lib/qt6/qml/*; do
  [[ ${entry##*/} == Grassfield ]] || ln -s "$entry" "$sysqml/"
done

/usr/lib/qt6/bin/qmllint --bare -I ui -I "$root/.dev/build/qml" -I "$tmp" -I "$sysqml" --max-warnings 0 "${files[@]}"
echo "qmllint: ${#files[@]} files, 0 warnings"
python3 -I "$root/scripts/dev/check-textformat.py"
