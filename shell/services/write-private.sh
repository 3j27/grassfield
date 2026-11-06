#!/bin/sh
# write-private.sh DIR FILE TEXT: writes TEXT to FILE (inside DIR) as a private state file, atomically: DIR is created 0700 and
# chmod 0700 when it already exists with other permissions, the temporary file is removed first (a stale 0644 one must not
# decide the mode), created under umask 077 and chmod 0600 before it replaces FILE. Used for airplane.json
# (shell/services/Connectivity.qml) and audio-routing.json (shell/services/Audio.qml, ADR-0047); tests/shell/write_private.sh.
umask 077
dir=$1
file=$2
text=$3
[ -n "$dir" ] && [ -n "$file" ] || exit 2
mkdir -p -m 700 "$dir" || exit 1
chmod 700 "$dir" || exit 1
tmp=$file.tmp
rm -f "$tmp"
printf '%s' "$text" >"$tmp" || exit 1
chmod 600 "$tmp" || exit 1
mv -f "$tmp" "$file"
