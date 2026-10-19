#!/bin/sh
# Data for "can this app open this dropped file" (Dock): prints, one record per line,
#   E<TAB>entry id<TAB>MimeType value      one per desktop entry that has a MimeType key (highest-priority file per id,
#                                          ids as Quickshell's DesktopEntry.id: no ".desktop", subfolders joined by "-")
#   G<TAB>line of <datadir>/mime/globs2    file name patterns -> MIME types
#   S<TAB>line of <datadir>/mime/subclasses
#   A<TAB>line of <datadir>/mime/aliases
# Quickshell's DesktopEntry does not expose MimeType. Read only; no arguments. File names containing a newline are skipped.
NL='
'
IFS=:
{
  for d in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    case $d in *"$NL"*) continue ;; esac
    for f in globs2 subclasses aliases; do
      [ -r "$d/mime/$f" ] || continue
      case $f in globs2) k=G ;; subclasses) k=S ;; *) k=A ;; esac
      awk -v k="$k" '!/^#/ && NF { sub(/\r$/, ""); printf "%s\t%s\n", k, $0 }' "$d/mime/$f"
    done
    [ -d "$d/applications" ] || continue
    printf '/%s/applications/\n' "${d#/}"
    find -L "$d/applications" -name '*.desktop' ! -name "*$NL*" ! -path "*$NL*" -printf '%P\n' 2>/dev/null
  done
} | awk '
  /^[GSA]\t/ { print; next }
  /^\// { base = $0; next }
  {
    id = $0
    sub(/\.desktop$/, "", id)
    gsub("/", "-", id)
    if (id in seen)
      next
    seen[id] = 1
    path = base $0
    grp = ""
    while ((getline line < path) > 0) {
      sub(/[ \t\r]+$/, "", line)
      if (line ~ /^\[/)
        grp = line
      else if (grp == "[Desktop Entry]" && line ~ /^MimeType[ \t]*=/) {
        sub(/^[^=]*=[ \t]*/, "", line)
        if (line != "")
          printf "E\t%s\t%s\n", id, line
      }
    }
    close(path)
  }'
