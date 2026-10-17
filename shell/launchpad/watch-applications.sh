#!/bin/sh
# Prints one line per change under the XDG applications directories (desktop files added, removed,
# moved or rewritten in place), until killed. Quickshell's DesktopEntries only reports added and
# removed entries, not an edit of an existing file (OnlyShowIn / NotShowIn live in such an edit).
# Needs inotifywait (inotify-tools); exits 1 at once without it, and the caller then simply relies on
# DesktopEntries.applicationsChanged. Read only; no arguments. Dies with its parent (the shell).
command -v inotifywait >/dev/null 2>&1 || exit 1
IFS=:
set --
for d in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
  [ -d "$d/applications" ] && set -- "$@" "$d/applications"
done
[ "$#" -gt 0 ] || exit 1
# setpriv --pdeathsig (util-linux): the kernel sends SIGTERM when the shell dies, even on SIGKILL, so the
# watcher never outlives it (like the other long-lived children of the shell).
if command -v setpriv >/dev/null 2>&1; then
  exec setpriv --pdeathsig TERM -- inotifywait -m -q -r -e close_write,create,delete,moved_to,moved_from --format x -- "$@"
fi
exec inotifywait -m -q -r -e close_write,create,delete,moved_to,moved_from --format x -- "$@"
