#!/usr/bin/env bash
# open-real.sh OPENER TARGET...: the open policy of a REAL Grassfield session (GRASSFIELD_SESSION=1, not dev).
#
# macOS model: Finder is the file manager of every folder the system opens, whatever the user's default handler is. Here
# every folder target (a directory, or trash:///) opens in Grassfield Files, one process for all of them; every other target
# goes to the opener the shell asked for (OPENER: `gio` runs `gio open`, `xdg-open` runs `xdg-open`) so files keep the user's
# default handler. The shell starts this script in an application scope of its own (Apps.scoped, uwsm-app), so the
# application it starts lives there too.
#
# GRASSFIELD_FILES_BIN overrides the Files command (tests). Without it, and when grassfield-files is not installed, the
# targets go to the opener like any other (nothing is lost).
set -u

opener=${1:-}
shift || true
[[ $# -gt 0 ]] || exit 1

files_bin=${GRASSFIELD_FILES_BIN:-grassfield-files}

# Percent-decoding of a file: URL path.
urldecode() { printf '%b' "${1//%/\\x}"; }

is_folder() { # <target>
  local t=$1 path
  case $t in
    trash:///) return 0 ;;
    file://localhost/*) path=$(urldecode "${t#file://localhost}") ;;
    file:///*) path=$(urldecode "${t#file://}") ;;
    /*) path=$t ;;
    *) return 1 ;;
  esac
  [[ -d $path ]]
}

folders=()
others=()
for t in "$@"; do
  if command -v -- "$files_bin" >/dev/null 2>&1 && is_folder "$t"; then
    folders+=("$t")
  else
    others+=("$t")
  fi
done

run_opener() {
  case $opener in
    xdg-open) for t in "$@"; do xdg-open "$t" >/dev/null 2>&1 </dev/null & done ;;
    *) gio open "$@" >/dev/null 2>&1 </dev/null ;;
  esac
}

if [[ ${#others[@]} -gt 0 ]]; then
  run_opener "${others[@]}"
fi
if [[ ${#folders[@]} -gt 0 ]]; then
  exec "$files_bin" "${folders[@]}"
fi
wait
