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

# qmllint 6.12.0 reports "Type X not declared as singleton in qmldir but using pragma Singleton [import]" for singletons
# that their qmldir does declare (Tokens, Appearance, every qs.* service; it reproduces on a three-line module and goes away
# only when that module's qmldir is passed with -i, which breaks the rest). That one message is set aside; every other
# warning, the other [import] ones included, still fails the gate. Remove the filter once qmllint no longer reports it.
out="$tmp/qmllint.out"
set +e
/usr/lib/qt6/bin/qmllint --bare -I ui -I "$root/.dev/build/qml" -I "$tmp" -I "$sysqml" --max-warnings -1 "${files[@]}" >"$out" 2>&1
lint_rc=$?
set -e
false_positive='not declared as singleton in qmldir but using pragma Singleton \[import\]$'
grep -vE "$false_positive" "$out" || true
counted=$(grep -E '^(Warning|Error|Critical): ' "$out" | grep -vcE "$false_positive" || true)
set_aside=$(grep -cE "$false_positive" "$out" || true)
if ((counted > 0)); then
  echo "qmllint: $counted warning(s) (gate Q1 allows none)" >&2
  exit 1
fi
# Without a counted warning qmllint still fails on what it does not print as one (a file it cannot read or parse).
if ((lint_rc != 0 && set_aside == 0)); then
  echo "qmllint: exit $lint_rc without a warning line" >&2
  exit 1
fi
echo "qmllint: ${#files[@]} files, 0 warnings ($set_aside qmllint 6.12 singleton false positives set aside)"
python3 -I "$root/scripts/dev/check-textformat.py"
