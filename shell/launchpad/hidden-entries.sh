#!/bin/sh
# Prints the desktop entry ids hidden by OnlyShowIn / NotShowIn for $XDG_CURRENT_DESKTOP, one per
# line. Quickshell's DesktopEntry does not expose those keys. Read only; no arguments.
IFS=:
for d in "${XDG_DATA_HOME:-$HOME/.local/share}" $XDG_DATA_DIRS /usr/share; do
  [ -d "$d/applications" ] || continue
  find "$d/applications" -name '*.desktop' -print0 | xargs -0 -r awk -v cur="$XDG_CURRENT_DESKTOP" -v base="$d/applications/" '
    function has(list,    i, n, a) {
      n = split(list, a, ";")
      for (i = 1; i <= n; i++)
        if (a[i] != "" && index(":" cur ":", ":" a[i] ":") > 0)
          return 1
      return 0
    }
    function flush(    id) {
      if (file == "")
        return
      id = substr(file, length(base) + 1)
      gsub("/", "-", id)
      if ((only != "" && !has(only)) || (not != "" && has(not)))
        print id
    }
    FNR == 1 { flush(); file = FILENAME; grp = ""; only = ""; not = "" }
    /^\[/ { grp = $0 }
    grp == "[Desktop Entry]" && /^OnlyShowIn=/ { only = substr($0, 13) }
    grp == "[Desktop Entry]" && /^NotShowIn=/ { not = substr($0, 12) }
    END { flush() }'
done
