#!/usr/bin/env bash
# scripts/dev/omarchy-compat.sh (docs/compat.md): passes against the installed Omarchy, fails when a dependency disappears
# (here: a stripped copy), skips without Omarchy and fails with --require.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/omarchy-compat.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/scripts/dev/omarchy-compat.sh

desc="without Omarchy the check skips (exit 0), and --require fails"
out=$(OMARCHY_PATH=$tmp/none "$script"); status=$?
check bash -c '[[ $2 == 0 ]] && grep -q "^SKIP" <<<"$1"' _ "$out" "$status"
status=0; OMARCHY_PATH=$tmp/none "$script" --require >/dev/null || status=$?
check test "$status" = 1

if [[ -d /usr/share/omarchy/default/hypr ]]; then
  desc="against the installed Omarchy every dependency is present"
  status=0; out=$("$script") || status=$?
  check bash -c '[[ $2 == 0 ]] && ! grep -q "^FAIL" <<<"$1" && grep -q "all Omarchy dependencies present" <<<"$1"' _ "$out" "$status"

  # A copy of the installed tree (cheap: scripts and Lua only) with one dependency removed at a time.
  copy=$tmp/omarchy
  mkdir -p "$copy"
  cp -rL /usr/share/omarchy/default "$copy/default"
  mkdir -p "$copy/bin"
  for f in /usr/share/omarchy/bin/omarchy-*; do cp -L "$f" "$copy/bin/" 2>/dev/null || true; done
  run_copy() { OMARCHY_PATH=$copy "$script"; }
  status=0; out=$(run_copy) || status=$?
  desc="the copy of the installed tree passes (the fixture is faithful)"
  check bash -c '[[ $2 == 0 ]]' _ "$out" "$status"

  rm "$copy/default/hypr/input.lua"
  status=0; out=$(run_copy) || status=$?
  desc="a missing Lua module (default/hypr/input.lua) fails the check by name"
  check bash -c '[[ $2 == 1 ]] && grep -q "^FAIL: Lua module default/hypr/input.lua" <<<"$1"' _ "$out" "$status"
  cp -L /usr/share/omarchy/default/hypr/input.lua "$copy/default/hypr/input.lua"

  rm "$copy/bin/omarchy-hook"
  status=0; out=$(run_copy) || status=$?
  desc="a missing command (omarchy-hook) fails the check by name"
  check bash -c '[[ $2 == 1 ]] && grep -q "^FAIL: command omarchy-hook" <<<"$1"' _ "$out" "$status"
  cp -L /usr/share/omarchy/bin/omarchy-hook "$copy/bin/"

  sed -i 's/omarchy-restart-shell/omarchy-renamed-shell/' "$copy/bin/omarchy-update-restart"
  status=0; out=$(run_copy) || status=$?
  desc="Omarchy renaming the restart command (the stand-in would no longer be in the update's path) fails the check"
  check bash -c '[[ $2 == 1 ]] && grep -q "^FAIL: omarchy-update-restart still restarts" <<<"$1"' _ "$out" "$status"
else
  echo "SKIP: Omarchy is not installed here"
fi

exit $fail
