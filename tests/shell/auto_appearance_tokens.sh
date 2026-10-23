#!/usr/bin/env bash
# The C++ copy of the Auto appearance schedule (apps/autoappearance.h, Files and Preview) equals the tokens
# autoAppearance.darkFromHour, darkToHour and recheckInterval of ui/tokens/tokens.json.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
want() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["autoAppearance"][sys.argv[2]]["value"])' "$root/ui/tokens/tokens.json" "$1"; }
have() { sed -n "s/.*$1 = \([0-9]*\);.*/\1/p" "$root/apps/autoappearance.h"; }
fail=0
for pair in "darkFromHour:kAutoDarkFromHour" "darkToHour:kAutoDarkToHour" "recheckInterval:kAutoRecheckMs"; do
  t=${pair%%:*}
  c=${pair##*:}
  if [[ $(want "$t") != "$(have "$c")" ]]; then
    echo "FAIL: $t token $(want "$t") != $c $(have "$c")"
    fail=1
  fi
done
((fail == 0)) || exit 1
echo "PASS: apps/autoappearance.h equals the autoAppearance tokens"
