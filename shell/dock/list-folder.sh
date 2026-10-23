#!/bin/sh
# Entries of one folder for a Dock stack (docs/specs/dock.md requirement 25): read-only, one `find`, no recursion, no hidden
# names, symbolic links not followed (the type is the link's target type: %Y). Usage: list-folder.sh <absolute folder>.
# Output: records ended by RS (0x1e), fields by US (0x1f): birth time, modified time, changed time (seconds), type letter
# (d folder, f file, ...), name. At most about 4 MB are read (a huge folder is cut, the stack shows the part that came).
case "$1" in
  /*) ;;
  *) echo "list-folder: absolute path needed" >&2; exit 2 ;;
esac
[ -d "$1" ] || exit 0
find "$1" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%B@\037%T@\037%C@\037%Y\037%P\036' 2>/dev/null | head -c 4000000
