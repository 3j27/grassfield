#!/usr/bin/env bash
# Activity Monitor's projection writer (shell/services/activity-projection.sh; ADR-0038 f, AM60): the file names this
# shell process (its pid and stat field 22) as its writer, holds the body's members after "v" and the writer, is 0600 in a
# 0700 folder and replaces the last one through a temporary name; --remove deletes it; a body that is not a JSON object is
# refused.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/activity-projection.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/shell/services/activity-projection.sh
dir=$tmp/grassfield/activity-wayland-1

body='{"windows":[{"pid":4242,"app":"foot","idleInhibit":false}],"notResponding":[4242]}'
sh "$script" "$dir" "$body"
start=$(sed 's/.*) //' /proc/$$/stat | cut -d' ' -f20)
desc="the file names this shell as its writer, then the body"
check test "$(cat "$dir/windows.json")" = "{\"v\":1,\"writer\":{\"pid\":$$,\"start\":$start},\"windows\":[{\"pid\":4242,\"app\":\"foot\",\"idleInhibit\":false}],\"notResponding\":[4242]}"
desc="0600 in a 0700 folder, no temporary file left"
check test "$(stat -c %a "$dir/windows.json") $(stat -c %a "$dir") $(ls -A "$dir" | wc -l)" = "600 700 1"
if command -v python3 >/dev/null; then
  desc="the file is JSON"
  check python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dir/windows.json"
fi
desc="a body that is not a JSON object is refused and leaves the file as it was"
before=$(cat "$dir/windows.json")
sh "$script" "$dir" 'windows' && st=0 || st=$?
check test "$st" = 2 -a "$(cat "$dir/windows.json")" = "$before"
desc="--remove deletes the file"
sh "$script" "$dir" --remove
check test ! -e "$dir/windows.json"
exit $fail
