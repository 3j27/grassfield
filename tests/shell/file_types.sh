#!/usr/bin/env bash
# Test for shell/dock/file-types.sh: real types of dropped paths (folder, extensionless file by magic, FIFO never opened).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/filetypes.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/Photos" "$tmp/with space"
printf '#!/bin/sh\necho hi\n' > "$tmp/run"
printf 'hello\n' > "$tmp/notes.txt"
mkfifo "$tmp/pipe"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }
out=$(timeout 20 sh "$root/shell/dock/file-types.sh" "$tmp/Photos" "$tmp/run" "$tmp/notes.txt" "$tmp/pipe" "$tmp/missing" "$tmp/with space")
rc=$?
check "exit status (a FIFO does not block)" "$rc" 0
check "one line per argument, in order" "$(wc -l <<<"$out")" 6
check "folder" "$(sed -n 1p <<<"$out")" inode/directory
check "extensionless script by content" "$(sed -n 2p <<<"$out")" text/x-shellscript
check "text file" "$(sed -n 3p <<<"$out")" text/plain
check "FIFO is not opened" "$(sed -n 4p <<<"$out")" "-"
check "missing" "$(sed -n 5p <<<"$out")" "-"
check "folder with a space" "$(sed -n 6p <<<"$out")" inode/directory
many=()
for i in $(seq 40); do many+=("$tmp/notes.txt"); done
check "at most 32 looked at" "$(timeout 60 sh "$root/shell/dock/file-types.sh" "${many[@]}" | grep -c '^-$')" 8
exit $fail
