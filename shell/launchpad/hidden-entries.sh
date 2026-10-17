#!/bin/sh
# Prints the desktop entry ids hidden by OnlyShowIn / NotShowIn for $XDG_CURRENT_DESKTOP, one per
# line. Quickshell's DesktopEntry does not expose those keys. Read only; no arguments.
# Only the highest-priority file per id counts (XDG_DATA_HOME shadows XDG_DATA_DIRS); file names
# containing a newline are skipped (they cannot be listed one per line).
NL='
'
IFS=:
{
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    [ -d "$d/applications" ] || continue
    case $d in *"$NL"*) continue ;; esac
    printf '/%s/applications/\n' "${d#/}"
    find "$d/applications" -name '*.desktop' ! -name "*$NL*" ! -path "*$NL*" -printf '%P\n' 2>/dev/null
  done
} | awk -v cur="$XDG_CURRENT_DESKTOP" '
  function has(list,    i, n, a) {
    n = split(list, a, ";")
    for (i = 1; i <= n; i++)
      if (a[i] != "" && index(":" cur ":", ":" a[i] ":") > 0)
        return 1
    return 0
  }
  function scan(path,    line, grp, only, not) {
    while ((getline line < path) > 0) {
      if (line ~ /^\[/)
        grp = line
      else if (grp == "[Desktop Entry]" && line ~ /^OnlyShowIn=/)
        only = substr(line, 12)
      else if (grp == "[Desktop Entry]" && line ~ /^NotShowIn=/)
        not = substr(line, 11)
    }
    close(path)
    return (only != "" && !has(only)) || (not != "" && has(not))
  }
  /^\// { base = $0; next }
  {
    id = $0
    gsub("/", "-", id)
    if (id in seen)
      next
    seen[id] = 1
    if (scan(base $0))
      print id
  }'
