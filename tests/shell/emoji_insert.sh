#!/usr/bin/env bash
# shell/services/emoji-insert.sh (Emoji & Symbols, ADR-0045 OC-3; docs/specs/clipboard.md ES-7): Omarchy's
# omarchy-menu-emoji-insert from PATH first, else the path the shell gives ($OMARCHY_PATH/bin's), else wtype, else "missing";
# the glyph reaches the command as one argument, exactly, and is never evaluated (a glyph that reads as a command substitution
# runs nothing); an empty glyph is refused. Stubs only: nothing types or copies anything.
set -uo pipefail   # no -e: every check runs and prints PASS or FAIL
root=$(cd "$(dirname "$0")/../.." && pwd)
script=$root/shell/services/emoji-insert.sh
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/emoji-insert.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [[ $2 == 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

# A stub that records its arguments, one per line, in $tmp/<name>.args.
stub() {
  mkdir -p "$1"
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >"%s/%s.args"\n' "$tmp" "$2" >"$1/$2"
  chmod 755 "$1/$2"
}
run() { env -i PATH="$1" HOME="$tmp" /bin/sh "$script" "${@:2}"; }

glyph=$(printf '\360\237\221\213')   # waving hand, U+1F44B
stub "$tmp/path" omarchy-menu-emoji-insert
stub "$tmp/path" wtype
stub "$tmp/omarchy/bin" omarchy-menu-emoji-insert-fallback
mv "$tmp/omarchy/bin/omarchy-menu-emoji-insert-fallback" "$tmp/omarchy/bin/omarchy-menu-emoji-insert"
sed -i 's/omarchy-menu-emoji-insert-fallback.args/fallback.args/' "$tmp/omarchy/bin/omarchy-menu-emoji-insert"

# 1. Omarchy's command in PATH wins, and gets the glyph alone.
out=$(run "$tmp/path" "$glyph" "$tmp/omarchy/bin/omarchy-menu-emoji-insert")
[[ $out == omarchy ]]; check "Omarchy's command in PATH runs (it says omarchy)" $?
[[ $(cat "$tmp/omarchy-menu-emoji-insert.args") == "$glyph" ]]; check "it gets the glyph as its one argument" $?
[[ ! -e $tmp/fallback.args && ! -e $tmp/wtype.args ]]; check "neither the fallback path nor wtype runs then" $?

# 2. Not in PATH: the path the shell gives ($OMARCHY_PATH/bin's).
rm -f "$tmp"/*.args
mkdir -p "$tmp/only-wtype"
stub "$tmp/only-wtype" wtype
out=$(run "$tmp/only-wtype" "$glyph" "$tmp/omarchy/bin/omarchy-menu-emoji-insert")
[[ $out == omarchy ]]; check "without it in PATH, \$OMARCHY_PATH/bin's runs" $?
[[ $(cat "$tmp/fallback.args") == "$glyph" ]]; check "the fallback path gets the glyph" $?
[[ ! -e $tmp/wtype.args ]]; check "wtype does not run when Omarchy's command exists" $?

# 3. No Omarchy command at all: wtype types the glyph after --.
rm -f "$tmp"/*.args
out=$(run "$tmp/only-wtype" "$glyph" "$tmp/nowhere/omarchy-menu-emoji-insert")
[[ $out == wtype ]]; check "without Omarchy's command, wtype runs (it says wtype)" $?
[[ $(cat "$tmp/wtype.args") == "--"$'\n'"$glyph" ]]; check "wtype gets -- then the glyph" $?

# 4. A directory where the command should be is not run.
rm -f "$tmp"/*.args
mkdir -p "$tmp/dir/omarchy-menu-emoji-insert"
out=$(run "$tmp/only-wtype" "$glyph" "$tmp/dir/omarchy-menu-emoji-insert")
[[ $out == wtype ]]; check "a directory in the command's place is skipped" $?

# 5. Neither: "missing", success, nothing run.
rm -f "$tmp"/*.args
mkdir -p "$tmp/empty"
rc=0; out=$(run "$tmp/empty" "$glyph" "$tmp/nowhere/omarchy-menu-emoji-insert") || rc=$?
[[ $out == missing && $rc == 0 ]]; check "without either it says missing and exits 0" $?
[[ -z $(ls "$tmp"/*.args 2>/dev/null) ]]; check "nothing ran" $?

# 6. A glyph that reads as shell code is an argument only.
rm -f "$tmp"/*.args
hostile='$(touch '"$tmp"'/pwned)`touch '"$tmp"'/pwned2`'
out=$(run "$tmp/path" "$hostile" "")
[[ $out == omarchy && $(cat "$tmp/omarchy-menu-emoji-insert.args") == "$hostile" ]]; check "a glyph that reads as code arrives as is" $?
[[ ! -e $tmp/pwned && ! -e $tmp/pwned2 ]]; check "it is never evaluated" $?

# 7. An empty glyph is refused before anything runs.
rm -f "$tmp"/*.args
rc=0; run "$tmp/path" "" "" >/dev/null || rc=$?
[[ $rc == 2 && -z $(ls "$tmp"/*.args 2>/dev/null) ]]; check "an empty glyph is refused (exit 2), nothing runs" $?

exit $fail
