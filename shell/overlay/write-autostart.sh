#!/bin/sh
# write-autostart.sh PATH TEXT: writes the autostart desktop file PATH atomically (temporary file in the same directory, then
# rename). Refuses unless PATH is `<dir>/autostart/<name>.desktop` with a plain file name and TEXT is non-empty. The Dock menu
# (Open at Login) calls it with the isolated config home in a dev session. Exit 0 written, 2 refused.
path=$1
text=$2
case $path in
  */autostart/*.desktop) ;;
  *) echo "write-autostart: not an autostart file: $path" >&2; exit 2 ;;
esac
case $path in
  */../* | */..) echo "write-autostart: parent directory reference: $path" >&2; exit 2 ;;
esac
name=${path##*/}
dir=${path%/*}
case $dir in
  */autostart) ;;
  *) echo "write-autostart: not directly in an autostart directory: $path" >&2; exit 2 ;;
esac
case $name in
  .*) echo "write-autostart: hidden file name: $path" >&2; exit 2 ;;
esac
[ -n "$text" ] || { echo "write-autostart: empty text" >&2; exit 2; }
mkdir -p -- "$dir" || exit 1
tmp=$(mktemp -- "$dir/.grassfield-autostart.XXXXXX") || exit 1
trap 'rm -f -- "$tmp"' EXIT
printf '%s' "$text" > "$tmp" || exit 1
chmod 644 -- "$tmp" || exit 1
mv -f -- "$tmp" "$path" || exit 1
