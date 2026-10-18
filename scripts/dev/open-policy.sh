#!/usr/bin/env bash
# Dev open policy (ADR-0011): what a GRASSFIELD_DEV session does when the shell opens a folder or a file.
#
#   scripts/dev/open-policy.sh TARGET...      (absolute path or file: URL)
#
# A dev session never asks GIO, xdg-open or gtk-launch to start an application: the default handler of a folder is
# usually D-Bus activatable (Nautilus), so it would start in the owner's session with the owner's profile.
#   folder                         -> Grassfield Files (GRASSFIELD_FILES_CMD), started directly, isolated, GRASSFIELD_DEV=1
#   file Preview can show          -> Grassfield Preview (GRASSFIELD_PREVIEW_CMD), started directly, isolated
#   anything else                  -> refused: one line "open refused in dev: <type>" on stderr and in GRASSFIELD_OPEN_LOG
# GRASSFIELD_FILES_CMD / GRASSFIELD_PREVIEW_CMD are set by scripts/dev/shell-run.sh and already run through isolated.sh.
# Real sessions never run this script (shell/services/Apps.qml keeps `gio open`).
set -uo pipefail

log=${GRASSFIELD_OPEN_LOG:-}

refuse() { # <type>
  local line="open refused in dev: $1"
  printf '%s\n' "$line" >&2
  [[ -n $log ]] && printf '%s\n' "$line" >>"$log"
  return 1
}

# Percent-decoding of a file: URL path.
urldecode() { printf '%b' "${1//%/\\x}"; }

open_one() { # <target>
  local t=$1 path
  case $t in
    file://localhost/*) path=$(urldecode "${t#file://localhost}") ;;
    file:///*) path=$(urldecode "${t#file://}") ;;
    /*) path=$t ;;
    *:*) refuse "url (${t%%:*})"; return ;;
    *) refuse "relative path"; return ;;
  esac
  path=$(realpath -e -- "$path" 2>/dev/null) || { refuse "missing file"; return; }
  if [[ -d $path ]]; then
    [[ -n ${GRASSFIELD_FILES_CMD:-} ]] || { refuse "folder (grassfield-files is not built)"; return; }
    # shellcheck disable=SC2086
    setsid $GRASSFIELD_FILES_CMD "$path" >/dev/null 2>&1 </dev/null &
    return
  fi
  local mime
  mime=$(file -L --brief --mime-type -- "$path" 2>/dev/null) || mime=unknown
  case $mime in
    image/*|audio/*|video/*|text/*|application/pdf|application/json|application/xml|application/javascript|application/x-shellscript)
      [[ -n ${GRASSFIELD_PREVIEW_CMD:-} ]] || { refuse "$mime (grassfield-preview is not built)"; return; }
      # shellcheck disable=SC2086
      setsid $GRASSFIELD_PREVIEW_CMD "$path" >/dev/null 2>&1 </dev/null &
      ;;
    *) refuse "$mime" ;;
  esac
}

[[ $# -gt 0 ]] || { refuse "nothing to open"; exit 1; }
status=0
for target in "$@"; do open_one "$target" || status=1; done
exit "$status"
