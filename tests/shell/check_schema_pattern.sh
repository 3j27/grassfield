#!/usr/bin/env bash
# scripts/dev/check-schema.py evaluates `pattern`: icons.tint accepts "accent" and #rrggbb and rejects anything else
# (ADR-0014; the stores validate the same pattern at runtime). Offline, no session. Exit 0 when every check passes.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

doc() { python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["icons"]["tint"] = sys.argv[2]
json.dump(d, open(sys.argv[3], "w"))' "$root/config/defaults/grassfield.json" "$1" "$tmp/$2.json"; }

for ok in accent '#12abEF'; do
  doc "$ok" ok
  python3 -I "$root/scripts/dev/check-schema.py" "$tmp/ok.json" >/dev/null 2>&1
  check "tint $ok accepted" $?
done
for bad in red '#12345' '#12345g' 'Accent' '' '#1234567'; do
  doc "$bad" bad
  python3 -I "$root/scripts/dev/check-schema.py" "$tmp/bad.json" >/dev/null 2>&1
  [[ $? == 1 ]]
  check "tint '$bad' rejected" $?
done
exit $fails
