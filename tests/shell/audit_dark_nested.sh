#!/usr/bin/env bash
# Dark-appearance captures of the surfaces the visual audit changed (the audit and f1-audit.sh are light only: the macOS
# references are). Bare command, nested session of this tree (tests/visual/lib.sh starts it). Writes
# .dev/f1-audit-dark/<scenario>.en.png for contrast measured on the captures (tests/visual/measure-audit.py dark).
#   tests/shell/audit_dark_nested.sh [scenario ...]     default: settings controlcenter files menubar search apps overview
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
export VISUAL_APPEARANCE=dark VISUAL_LANG=en VISUAL_SHOTS=$root/.dev/f1-audit-dark
mkdir -p "$VISUAL_SHOTS"
scenarios=("$@")
[[ ${#scenarios[@]} -gt 0 ]] || scenarios=(settings controlcenter files menubar search apps overview)
# The scenarios start their own nested session and leave it up: stop it whatever happens, so the slot can be released.
trap '"$root/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true' EXIT
failed=0
for s in "${scenarios[@]}"; do
  if "$root/tests/visual/scenarios/$s.sh" >"$VISUAL_SHOTS/log-$s.txt" 2>&1; then
    echo "ok    $s"
  else
    echo "FAIL  $s (see .dev/f1-audit-dark/log-$s.txt)"
    failed=$((failed + 1))
  fi
done
echo "dark captures in $VISUAL_SHOTS, failed: $failed"
[[ $failed == 0 ]]
