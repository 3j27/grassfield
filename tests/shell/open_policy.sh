#!/usr/bin/env bash
# Test for scripts/dev/open-policy.sh and the PATH shims (ADR-0011): folders go to Files, previewable files to Preview, the
# rest is refused with one line, and `gio open` through the shim never reaches GIO. Fake Files/Preview record their argv.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/open-policy.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
policy=$root/scripts/dev/open-policy.sh
fails=0
check() { # <name> <condition result 0/1>
  if [[ $2 == 0 ]]; then echo "PASS open-policy: $1"; else echo "FAIL open-policy: $1"; fails=1; fi
}

for app in files preview; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/%s.calls"\n' "$tmp" "$app" >"$tmp/fake-$app"
  chmod +x "$tmp/fake-$app"
done
mkdir -p "$tmp/dir with space" "$tmp/d"
printf 'hello\n' >"$tmp/note.txt"
head -c 64 /dev/urandom >"$tmp/blob.bin"
log=$tmp/refusals.log
export GRASSFIELD_FILES_CMD=$tmp/fake-files GRASSFIELD_PREVIEW_CMD=$tmp/fake-preview GRASSFIELD_OPEN_LOG=$log
wait_for() { for _ in $(seq 1 30); do [[ -s $1 ]] && return 0; sleep 0.1; done; return 1; }

"$policy" "$tmp/d" 2>/dev/null
wait_for "$tmp/files.calls"; [[ $(<"$tmp/files.calls") == "$tmp/d" ]]; check "folder opens in Files" $?

"$policy" "file://$tmp/note.txt" 2>/dev/null
wait_for "$tmp/preview.calls"; [[ $(<"$tmp/preview.calls") == "$tmp/note.txt" ]]; check "text file URL opens in Preview" $?

# A log of its own: a detached open from an earlier step may still append to $log under load.
refuse_log=$tmp/refuse.log
GRASSFIELD_OPEN_LOG=$refuse_log "$policy" "$tmp/blob.bin" 2>/dev/null && rc=0 || rc=$?
[[ $rc == 1 && $(wc -l <"$refuse_log") == 1 && $(<"$refuse_log") == "open refused in dev: application/octet-stream" ]]
check "unsupported file refused with one line" $?

trash_log=$tmp/trash.log
GRASSFIELD_OPEN_LOG=$trash_log "$policy" "trash:///" 2>/dev/null && rc=0 || rc=$?
[[ $rc == 1 && $(<"$trash_log") == "open refused in dev: url (trash)" ]]; check "trash:/// refused" $?

# The shim: gio open follows the policy, gio launch is refused, other subcommands reach the real gio.
export GRASSFIELD_OPEN_POLICY=$policy
PATH=$root/scripts/dev/open-shims:$PATH
[[ $(command -v gio) == "$root/scripts/dev/open-shims/gio" ]]; check "shim first on PATH" $?
# Never go on with a real gio first on PATH: `gio open` would start the owner's handler.
[[ $fails == 0 ]] || exit 1
rm -f "$tmp/preview.calls"
gio open "$tmp/note.txt" 2>/dev/null
wait_for "$tmp/preview.calls"; check "gio open through the shim opens in Preview" $?
: >"$log"
gio launch x.desktop 2>/dev/null && rc=0 || rc=$?
[[ $rc == 1 ]]; check "gio launch refused" $?
if command -v gio >/dev/null; then
  out=$(gio mime text/plain 2>&1 || true)
  [[ $out != *"open refused"* ]]; check "other gio subcommands reach the real gio" $?
fi
xdg-open "$tmp/blob.bin" 2>/dev/null && rc=0 || rc=$?
[[ $rc == 1 ]]; check "xdg-open follows the policy" $?
exit "$fails"
