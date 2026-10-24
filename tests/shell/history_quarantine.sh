#!/usr/bin/env bash
# shell/notifications/quarantine-history.sh: a damaged history file is moved aside (0600) and replaced by an empty 0600 file;
# when the move cannot happen the damaged file is left alone and the status is not 0 (the shell then never rewrites it).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/quarantine.XXXXXX")
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
script=$root/shell/notifications/quarantine-history.sh

mkdir "$tmp/a"
printf 'damaged' >"$tmp/a/notifications.json"
sh "$script" "$tmp/a/notifications.json" 42
rc=$?
desc="success: status 0, damaged file kept as .corrupt-42 with its content and mode 600, fresh empty file mode 600"
check test "$rc" = 0 -a "$(cat "$tmp/a/notifications.json.corrupt-42")" = damaged -a "$(stat -c %a "$tmp/a/notifications.json.corrupt-42")" = 600 -a ! -s "$tmp/a/notifications.json" -a "$(stat -c %a "$tmp/a/notifications.json")" = 600

mkdir "$tmp/b"
printf 'damaged' >"$tmp/b/notifications.json"
printf 'earlier copy' >"$tmp/b/notifications.json.corrupt-42"
sh "$script" "$tmp/b/notifications.json" 42
rc=$?
desc="an earlier quarantine copy is never overwritten: status 1, the damaged file stays where it was"
check test "$rc" = 1 -a "$(cat "$tmp/b/notifications.json")" = damaged -a "$(cat "$tmp/b/notifications.json.corrupt-42")" = "earlier copy"

mkdir "$tmp/c"
printf 'damaged' >"$tmp/c/notifications.json"
chmod 500 "$tmp/c"
sh "$script" "$tmp/c/notifications.json" 42
rc=$?
chmod 700 "$tmp/c"
desc="a folder that cannot be written: status 1, nothing replaced"
if [[ $(id -u) == 0 ]]; then echo "SKIP: running as root, directory modes do not apply"; else check test "$rc" = 1 -a "$(cat "$tmp/c/notifications.json")" = damaged; fi
exit $fail
