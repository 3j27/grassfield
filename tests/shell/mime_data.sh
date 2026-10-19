#!/usr/bin/env bash
# Test for shell/dock/mime-data.sh: MimeType of desktop entries (highest-priority file per id, ids like Quickshell's) and the
# MIME database lines, with a temporary XDG tree.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/mimedata.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sys=$tmp/sys
home=$tmp/home
mkdir -p "$sys/applications/sub" "$home/applications" "$sys/mime"
printf '[Desktop Entry]\nName=Edit\nExec=edit %%F\nMimeType=text/plain;text/x-python;\n[Desktop Action a]\nMimeType=never/this;\n' > "$sys/applications/edit.desktop"
printf '[Desktop Entry]\nName=Term\nExec=foot\n' > "$sys/applications/foot.desktop"
printf '[Desktop Entry]\r\nName=Crlf\r\nMimeType = image/png;\r\n' > "$sys/applications/crlf.desktop"
printf '[Desktop Entry]\nName=Nested\nMimeType=audio/x-wav;\n' > "$sys/applications/sub/nested.desktop"
printf '[Desktop Entry]\nName=Shadowed\nMimeType=a/system;\n' > "$sys/applications/shadow.desktop"
printf '[Desktop Entry]\nName=Shadow\nMimeType=a/user;\n' > "$home/applications/shadow.desktop"
printf '# comment\n50:text/plain:*.txt\n' > "$sys/mime/globs2"
printf 'text/x-python text/plain\n' > "$sys/mime/subclasses"
printf 'text/x-markdown text/markdown\n' > "$sys/mime/aliases"

out=$(XDG_DATA_HOME=$home XDG_DATA_DIRS=$sys sh "$root/shell/dock/mime-data.sh")
fail=0
has() { if grep -qxF -- "$2" <<<"$out"; then echo "PASS: $1"; else echo "FAIL: $1 (missing: $2)"; fail=1; fi; }
lacks() { if grep -qF -- "$2" <<<"$out"; then echo "FAIL: $1 (found: $2)"; fail=1; else echo "PASS: $1"; fi; }
has "entry MimeType" $'E\tedit\ttext/plain;text/x-python;'
has "CRLF and spaced key" $'E\tcrlf\timage/png;'
has "subfolder id" $'E\tsub-nested\taudio/x-wav;'
has "user file shadows the system one" $'E\tshadow\ta/user;'
lacks "system file shadowed" "a/system"
lacks "entry without MimeType" $'E\tfoot'
lacks "MimeType of an action" "never/this"
has "globs2 line" $'G\t50:text/plain:*.txt'
has "subclasses line" $'S\ttext/x-python text/plain'
has "aliases line" $'A\ttext/x-markdown text/markdown'
lacks "comment lines" "# comment"
exit $fail
