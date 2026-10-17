#!/usr/bin/env bash
# Regenerate translations/grassfield_fr.ts from shell/, ui/ and apps/ (QML, JS, C++ tr()).
# Stable options: -no-obsolete (dropped strings vanish), -locations none (no line numbers: unrelated code edits never stale the catalog).
# English is the source language: no catalog is needed for it. Existing translations are kept.
# Usage: scripts/dev/i18n-update.sh [--check]
#   --check: run lupdate, print the diff against the committed file, restore it; exit 1 if it was stale.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
lupdate=/usr/lib/qt6/bin/lupdate
ts=translations/grassfield_fr.ts

run() {
  "$lupdate" -no-obsolete -locations none -source-language en -target-language fr \
    shell ui apps -ts "$ts" >/dev/null
}

if [[ ${1:-} == "--check" ]]; then
  orig=$(mktemp)
  cp "$ts" "$orig"
  trap 'cp "$orig" "$ts"; rm -f "$orig"' EXIT
  run
  diff -u "$orig" "$ts"
  exit 0
fi
run
echo "i18n-update: $ts"
