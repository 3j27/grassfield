#!/bin/sh
# Real MIME types of dropped files (Dock), resolved at drop time for the dropped paths only. Prints one line per argument,
# in order: the type (inode/directory for a folder, otherwise the content type from the shared MIME database including
# magic, as `gio info` reports it) or "-" when unknown. Only regular files and folders are looked at (a FIFO or a device
# is never opened: reading it could block); at most 32 paths, each lookup bounded.
n=0
for p in "$@"; do
  n=$((n + 1))
  if [ "$n" -gt 32 ]; then
    echo -
  elif [ -d "$p" ]; then
    echo inode/directory
  elif [ -f "$p" ] && [ -r "$p" ]; then
    t=$(timeout 2 gio info -a standard::content-type -- "$p" 2>/dev/null | sed -n 's/^ *standard::content-type: //p' | head -n 1)
    echo "${t:--}"
  else
    echo -
  fi
done
