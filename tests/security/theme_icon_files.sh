#!/usr/bin/env bash
# Review of 2dfd992: a valid theme icon NAME must never make Qt read a FIFO or a device. Runs
# tests/security/theme_icon_files.d/probe.qml offscreen against the REAL Notifications and ThemeIcons singletons, in a
# scratch HOME / XDG_DATA_HOME / XDG_DATA_DIRS, once per planted file for the name "evil":
#   reg      a regular PNG in <XDG_DATA_DIRS entry>/pixmaps        -> shown (control: the guard does not hide icons)
#   fifo     a FIFO there                                          -> refused, the image loader never stalls
#   link     a symlink there to a FIFO elsewhere                   -> refused
#   zero     a symlink there to /dev/zero                          -> refused
#   null     a symlink in XDG_DATA_HOME/icons/hicolor/... to /dev/null (.svg) -> refused
#   svgfifo  a FIFO evil.svg in the pixmaps directory              -> refused
#   homefifo a FIFO evil.xpm under ~/.icons                        -> refused
# Each run must print the probe line within its time limit (a stalled loader keeps the process from exiting) with the
# expected verdict, empty icon sources for both call sites (notification iconSource, polkit ThemeIcons.source), and the
# control icon loaded afterwards. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/theme-icon-files.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/security/theme_icon_files.d/probe.qml "$tmp/cfg/shell.qml"
png=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==

fail=0
run() { # <kind> <expected verdict>
  local kind=$1 want=$2 s out rc line
  s=$tmp/$kind
  mkdir -p -m 700 "$s/runtime" "$s/cache"
  mkdir -p "$s/home/.local/share/icons/hicolor/48x48/apps" "$s/home/.icons/t" "$s/data/pixmaps" "$s/elsewhere" "$s/state" "$s/config"
  printf '%s' "$png" | base64 -d >"$s/data/pixmaps/ctl.png"
  case $kind in
    reg) cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
    fifo) mkfifo "$s/data/pixmaps/evil.png" ;;
    link) mkfifo "$s/elsewhere/f" && ln -s "$s/elsewhere/f" "$s/data/pixmaps/evil.png" ;;
    zero) ln -s /dev/zero "$s/data/pixmaps/evil.png" ;;
    null) ln -s /dev/null "$s/home/.local/share/icons/hicolor/48x48/apps/evil.svg" && cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
    svgfifo) mkfifo "$s/data/pixmaps/evil.svg" ;;
    homefifo) mkfifo "$s/home/.icons/t/evil.xpm" && cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
  esac
  rc=0
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 PROBE_KIND="$kind" HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" \
    GRASSFIELD_TEST_TMP="$s" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
    timeout -k 3 30 qs -p "$tmp/cfg" --no-color 2>&1) || rc=$?
  line=$(grep -o "probe: .*" <<<"$out" | head -n 1 || true)
  local ok=1
  ((rc == 0)) || ok=0
  [[ $line == *" verdict=$want "* ]] || ok=0
  [[ $line == *" ctl=1"* ]] || ok=0
  if [[ $want == ok ]]; then
    [[ $line == *" notif=image://icon/evil "* && $line == *" polkit=image://icon/evil "* && $line == *" evil=1 "* ]] || ok=0
  else
    [[ $line == *" notif= polkit= evil=0 "* ]] || ok=0
  fi
  if ((ok)); then
    echo "PASS: theme icon files $kind ($line)"
  else
    echo "FAIL: theme icon files $kind: rc $rc, ${line:-no probe line} $(grep -E 'ERROR|TypeError|ReferenceError' <<<"$out" | head -n 3)"
    fail=1
  fi
}

run reg ok
for kind in fifo link zero null svgfifo homefifo; do
  run "$kind" no
done
exit $fail
