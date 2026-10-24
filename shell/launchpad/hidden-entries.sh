#!/bin/sh
# Prints the desktop entry ids hidden by OnlyShowIn / NotShowIn for $XDG_CURRENT_DESKTOP, and the helper launchers
# (GF-102; macOS Launchpad lists applications, not their helpers): the ids in the helpers list below (Avahi browsers, lstopo,
# the Fcitx daemon, migrator and Qt wrappers; NOT fcitx5-configtool, the only way to the input-method settings, which
# Grassfield Settings has no page for), and terminal emulators' server and client launchers (a TerminalEmulator
# entry whose Exec runs "--server" or whose program is "<name>client": foot-server, footclient). The list can be replaced
# for a test or a distribution with GRASSFIELD_HELPER_IDS (space-separated ids; empty hides no helper by id). One per
# line, in the form of Quickshell's DesktopEntry.id: no ".desktop" suffix, subfolders joined with
# "-" (applications/kde/foo.desktop -> kde-foo). Quickshell's DesktopEntry does not expose those
# keys. Read only; no arguments. Handles CRLF files, "Key = value" spacing and symlinked folders.
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
    find -L "$d/applications" -name '*.desktop' ! -name "*$NL*" ! -path "*$NL*" -printf '%P\n' 2>/dev/null
  done
} | awk -v cur="$XDG_CURRENT_DESKTOP" -v helpers="${GRASSFIELD_HELPER_IDS-avahi-discover bssh bvnc lstopo org.fcitx.Fcitx5 org.fcitx.fcitx5-qt5-gui-wrapper org.fcitx.fcitx5-qt6-gui-wrapper fcitx5-migrator}" '
  function has(list,    i, n, a) {
    n = split(list, a, ";")
    for (i = 1; i <= n; i++)
      if (a[i] != "" && index(":" cur ":", ":" a[i] ":") > 0)
        return 1
    return 0
  }
  function terminalHelper(cats, exec,    prog, n, a, i) {
    if (index(";" cats, ";TerminalEmulator;") == 0)
      return 0
    n = split(exec, a, /[ \t]+/)
    prog = a[1]
    sub(/^.*\//, "", prog)
    if (prog ~ /client$/)
      return 1
    for (i = 2; i <= n; i++)
      if (a[i] == "--server" || a[i] == "--daemon")
        return 1
    return 0
  }
  function scan(path,    line, grp, only, not, cats, exec) {
    while ((getline line < path) > 0) {
      sub(/[ \t\r]+$/, "", line)
      if (line ~ /^\[/)
        grp = line
      else if (grp == "[Desktop Entry]" && line ~ /^OnlyShowIn[ \t]*=/) {
        sub(/^[^=]*=[ \t]*/, "", line)
        only = line
      } else if (grp == "[Desktop Entry]" && line ~ /^NotShowIn[ \t]*=/) {
        sub(/^[^=]*=[ \t]*/, "", line)
        not = line
      } else if (grp == "[Desktop Entry]" && line ~ /^Categories[ \t]*=/) {
        sub(/^[^=]*=[ \t]*/, "", line)
        cats = line
      } else if (grp == "[Desktop Entry]" && line ~ /^Exec[ \t]*=/) {
        sub(/^[^=]*=[ \t]*/, "", line)
        exec = line
      }
    }
    close(path)
    return (only != "" && !has(only)) || (not != "" && has(not)) || terminalHelper(cats, exec)
  }
  BEGIN {
    n = split(helpers, h, " ")
    for (i = 1; i <= n; i++)
      isHelper[h[i]] = 1
  }
  /^\// { base = $0; next }
  {
    id = $0
    sub(/\.desktop$/, "", id)
    gsub("/", "-", id)
    if (id in seen)
      next
    seen[id] = 1
    if (id in isHelper || scan(base $0))
      print id
  }'
