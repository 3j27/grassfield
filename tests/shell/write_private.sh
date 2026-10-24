#!/usr/bin/env bash
# shell/services/write-private.sh (the airplane.json writer): an existing 0755 directory becomes 0700, a stale 0644 .tmp does
# not decide the mode, the file is 0600 with the new content, no .tmp is left, and a fresh directory is 0700.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
script=$root/shell/services/write-private.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
mode() { stat -c %a "$1"; }

# Existing 0755 directory, stale 0644 temporary file, old 0644 file.
mkdir -m 755 "$tmp/state"
chmod 755 "$tmp/state"
printf old >"$tmp/state/airplane.json.tmp"
chmod 644 "$tmp/state/airplane.json.tmp"
printf old >"$tmp/state/airplane.json"
chmod 644 "$tmp/state/airplane.json"
sh "$script" "$tmp/state" "$tmp/state/airplane.json" '{"on":true}'
[[ $(mode "$tmp/state") == 700 ]]; check "an existing 0755 directory becomes 0700" $?
[[ $(mode "$tmp/state/airplane.json") == 600 ]]; check "airplane.json is 0600 although a 0644 .tmp and file existed" $?
[[ $(cat "$tmp/state/airplane.json") == '{"on":true}' ]]; check "the new content replaced the old" $?
[[ ! -e $tmp/state/airplane.json.tmp ]]; check "no .tmp is left" $?

# A directory that does not exist yet.
sh "$script" "$tmp/fresh/grassfield" "$tmp/fresh/grassfield/airplane.json" 'x'
[[ $(mode "$tmp/fresh/grassfield") == 700 ]]; check "a new directory is 0700" $?
[[ $(mode "$tmp/fresh/grassfield/airplane.json") == 600 ]]; check "a new file is 0600" $?

# Missing arguments write nothing.
if sh "$script" "" "" "x" 2>/dev/null; then check "empty arguments are refused" 1; else check "empty arguments are refused" 0; fi
exit $fail
