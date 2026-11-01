#!/bin/sh
# activity-projection.sh DIR BODY | DIR --remove: Activity Monitor's projection (ADR-0038 f, AM60). Writes DIR/windows.json
# as {"v":1,"writer":{"pid":P,"start":S},<BODY's members>}: the writer is the shell that runs this script (its parent), named
# by its pid and its start time (stat field 22), so the app ignores a file the shell left behind (Terms: writer). Written
# 0600 in a 0700 folder, through a temporary name (write-private.sh). --remove deletes it (the app's last window closed).
# BODY is ActivityLinkLogic.projection's JSON object. tests/shell/activity_projection.sh.
dir=$1
[ -n "$dir" ] || exit 2
if [ "${2:-}" = --remove ]; then
  rm -f "$dir/windows.json"
  exit 0
fi
body=${2:-}
case $body in
  "{"*"}") ;;
  *) exit 2 ;;
esac
pid=$PPID
# The fields after the name's last ") " start at field 3 (the state): field 22 is the 20th of them.
start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f20)
case $start in
  "" | *[!0-9]*) exit 1 ;;
esac
exec sh "$(dirname "$0")/write-private.sh" "$dir" "$dir/windows.json" "{\"v\":1,\"writer\":{\"pid\":$pid,\"start\":$start},${body#\{}"
