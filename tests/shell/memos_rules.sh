#!/usr/bin/env bash
# Grassfield Memos' compositor rules (ADR-0051 D-6), offline: placement.lua and stacking.lua act only on the app id exactly as
# Memos sets it (case-sensitive) and on a tag of exactly 32 lowercase hex digits (review of the memos slice: a lowered class
# and `%x+` let any client claim the rules more easily). Static: no Lua interpreter or Hyprland is needed; what the rules do
# on screen is checked in a nested session (NOT VERIFIED here).
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

for f in placement stacking; do
  rules=$root/config/hypr/grassfield/$f.lua
  grep -q 'window.class ~= "org.grassfield.Memos"' "$rules"
  check "$f.lua compares the app id exactly (org.grassfield.Memos)" $?
  if grep -v '^ *--' "$rules" | grep -qi 'lower() *[=~]= *"org.grassfield.memos"'; then
    check "$f.lua never lowers the app id before comparing it" 1
  else
    check "$f.lua never lowers the app id before comparing it" 0
  fi
  grep -q 'string.rep("\[0-9a-f\]", 32)' "$rules"
  check "$f.lua asks for exactly 32 lowercase hex digits" $?
  if grep -v '^ *--' "$rules" | grep -q 'memo:%x+'; then
    check "$f.lua has no loose memo:%x+ pattern" 1
  else
    check "$f.lua has no loose memo:%x+ pattern" 0
  fi
done
# The app sends exactly that shape (apps/memos/src/hyprframes.cpp memoTag) and sets that app id (main.cpp).
grep -q 'QStringLiteral("memo:") + id' "$root/apps/memos/src/hyprframes.cpp"
check "the app's tag starts memo:<id>" $?
grep -q 'setDesktopFileName(QStringLiteral("org.grassfield.Memos"))' "$root/apps/memos/src/main.cpp"
check "the app's id is org.grassfield.Memos" $?
grep -q 'QStringLiteral(":top")' "$root/apps/memos/src/hyprframes.cpp"
check "the app's Float on Top suffix is :top" $?
exit $fails
