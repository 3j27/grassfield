#!/usr/bin/env bash
# Test for shell/services/open-real.sh, the open policy of a real Grassfield session: every folder (a directory path, a
# file: URL, trash:///) goes to Grassfield Files in one call, whatever the default handler is; other targets go to the
# opener the shell asked for. Fake Files, gio and xdg-open record their argv.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/open-real.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
script=$root/shell/services/open-real.sh
fails=0
check() { # <name> <0 = pass>
  if [[ $2 == 0 ]]; then echo "PASS open-real: $1"; else echo "FAIL open-real: $1"; fails=1; fi
}
mkdir -p "$tmp/bin" "$tmp/dir with space" "$tmp/d"
for app in files gio xdg-open; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/%s.calls"\n' "$tmp" "$app" >"$tmp/bin/$app"
  chmod +x "$tmp/bin/$app"
done
printf 'hello\n' >"$tmp/note.txt"
export GRASSFIELD_FILES_BIN=$tmp/bin/files PATH=$tmp/bin:$PATH

bash "$script" gio "$tmp/d"
[[ $(<"$tmp/files.calls") == "$tmp/d" && ! -e "$tmp/gio.calls" ]]; check "folder opens in Files, gio untouched" $?

rm -f "$tmp"/*.calls
bash "$script" gio "file://$tmp/dir%20with%20space"
[[ $(<"$tmp/files.calls") == "file://$tmp/dir%20with%20space" && ! -e "$tmp/gio.calls" ]]; check "folder URL with a space opens in Files" $?

rm -f "$tmp"/*.calls
bash "$script" gio "trash:///"
[[ $(<"$tmp/files.calls") == "trash:///" ]]; check "trash opens in Files" $?

rm -f "$tmp"/*.calls
bash "$script" gio "$tmp/note.txt"
[[ $(<"$tmp/gio.calls") == "open $tmp/note.txt" && ! -e "$tmp/files.calls" ]]; check "file goes to gio open" $?

rm -f "$tmp"/*.calls
bash "$script" xdg-open "$tmp/note.txt"
for _ in $(seq 1 20); do [[ -s $tmp/xdg-open.calls ]] && break; sleep 0.1; done
[[ $(<"$tmp/xdg-open.calls") == "$tmp/note.txt" && ! -e "$tmp/files.calls" ]]; check "file goes to xdg-open when asked" $?

rm -f "$tmp"/*.calls
bash "$script" gio "$tmp/d" "$tmp/note.txt" "$tmp/dir with space"
[[ $(<"$tmp/files.calls") == "$tmp/d $tmp/dir with space" && $(<"$tmp/gio.calls") == "open $tmp/note.txt" ]]; check "mixed targets are split" $?

rm -f "$tmp"/*.calls
GRASSFIELD_FILES_BIN=$tmp/bin/not-installed bash "$script" gio "$tmp/d"
[[ $(<"$tmp/gio.calls") == "open $tmp/d" ]]; check "without Files installed the folder goes to the opener" $?

bash "$script" gio >/dev/null 2>&1; [[ $? == 1 ]]; check "nothing to open fails" $?

[[ $fails == 0 ]] && echo "open-real: PASS" && exit 0
echo "FAIL: tests/shell/open_real.sh"
exit 1
