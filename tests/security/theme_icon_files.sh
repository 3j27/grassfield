#!/usr/bin/env bash
# Reviews of 2dfd992 and eee45cc: a valid theme icon NAME must never make Qt read a FIFO, a device or a huge file.
#
# Part 1, the shell: tests/security/theme_icon_files.d/probe.qml offscreen against the REAL Notifications and ThemeIcons
# singletons, in a scratch HOME / XDG_DATA_HOME / XDG_DATA_DIRS, once per planted file for the name "evil" (offscreen
# Quickshell searches only the fallback pixmaps directories, so these cases sit there or are judged by the verdict):
#   reg      a regular PNG in <XDG_DATA_DIRS entry>/pixmaps        -> shown (control: the guard does not hide icons)
#   fifo     a FIFO there                                          -> refused, the image loader never stalls
#   link     a symlink there to a FIFO elsewhere                   -> refused
#   zero     a symlink there to /dev/zero                          -> refused
#   null     a symlink to /dev/null as XDG_DATA_HOME/icons/hicolor/48x48/apps/evil.svg -> refused
#   svgfifo  a FIFO evil.svg in the pixmaps directory              -> refused
#   homefifo a FIFO evil.xpm in ~/.icons/hicolor/48x48/apps        -> refused
#   swap     shown, then the file becomes a FIFO and a new notification names it: hidden at once, then refused
#   change   shown, then the file becomes a FIFO and nothing names it: the next signature finds its files changed, refused,
#            while "ctl" (unchanged) stays shown
#   linkswap evil.png is a symlink to a file outside every icon folder, whose target becomes a FIFO: refused, "ctl" shown
# Each run must print the probe line within its time limit (a stalled loader keeps the process from exiting) with the
# expected verdict, empty icon sources for both call sites (notification iconSource, polkit ThemeIcons.source), and the
# control icon loaded afterwards.
#
# Part 2, Qt itself with the theme search paths of a real session (theme_icon_files.d/qt_icon_lookup.cpp, built here; SKIP
# without g++ or the Qt headers): ThemeIcons' own checker script (extracted from ThemeIcons.qml) judges each case, and a
# name it passes is then looked up by Qt (hasThemeIcon on the "GUI thread", then a pixmap) and must not stall. For the
# refused cases Qt alone must stall (or the case proves nothing): a FIFO index.theme or icon-theme.cache of the current
# theme, a FIFO icon in the theme, in the inherited hicolor theme, behind a symlinked directory, in ~/.icons, in pixmaps.
# Plus the cost bound: a user theme of 300 directories with 99k files, 8 names in under 10 s.
#
# Part 3, application icons (Dock, Launchpad): see below.
# Plain shell test: PASS/FAIL lines, non-zero on failure.
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
  mkdir -p "$s/home/.local/share/icons/hicolor/48x48/apps" "$s/home/.icons/hicolor/48x48/apps" "$s/data/pixmaps" "$s/elsewhere" "$s/state" "$s/config"
  printf '%s' "$png" | base64 -d >"$s/data/pixmaps/ctl.png"
  case $kind in
    reg | swap | change) cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
    linkswap) cp "$s/data/pixmaps/ctl.png" "$s/elsewhere/target.png" && ln -s "$s/elsewhere/target.png" "$s/data/pixmaps/evil.png" ;;
    fifo) mkfifo "$s/data/pixmaps/evil.png" ;;
    link) mkfifo "$s/elsewhere/f" && ln -s "$s/elsewhere/f" "$s/data/pixmaps/evil.png" ;;
    zero) ln -s /dev/zero "$s/data/pixmaps/evil.png" ;;
    null) ln -s /dev/null "$s/home/.local/share/icons/hicolor/48x48/apps/evil.svg" && cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
    svgfifo) mkfifo "$s/data/pixmaps/evil.svg" ;;
    homefifo) mkfifo "$s/home/.icons/hicolor/48x48/apps/evil.xpm" && cp "$s/data/pixmaps/ctl.png" "$s/data/pixmaps/evil.png" ;;
  esac
  rc=0
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 PROBE_KIND="$kind" PROBE_PIXMAPS="$s/data/pixmaps" HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" \
    GRASSFIELD_TEST_TMP="$s" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
    timeout -k 3 40 qs -p "$tmp/cfg" --no-color 2>&1) || rc=$?
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
  case $kind in
    swap) [[ $line == *" before=ok:image://icon/evil atswap=|pending "* ]] || ok=0 ;;
    change | linkswap) [[ $line == *" before=ok:image://icon/evil atswap= ctlblanked=false "* ]] || ok=0 ;;
  esac
  if ((ok)); then
    echo "PASS: theme icon files $kind ($line)"
  else
    echo "FAIL: theme icon files $kind: rc $rc, ${line:-no probe line} $(grep -E 'TypeError|ReferenceError' <<<"$out" | head -n 3)"
    fail=1
  fi
}

run reg ok
for kind in fifo link zero null svgfifo homefifo swap change linkswap; do
  run "$kind" no
done

# ---- Part 3: applications whose Icon= is a FIFO (review of eee45cc) ----
# The Dock and the Launchpad load an application's Icon= through ThemeIcons.appIcon. Real Launchpad cells and the Apps
# prewarm list, for four entries in a scratch applications directory: a FIFO path, a theme name whose file is a FIFO, a
# regular path, a regular theme name. The FIFOs are refused (no source), the regular ones shown, and a control icon loads
# afterwards (the loader never stalled).
dcfg=$tmp/dcfg
mkdir -p "$dcfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$dcfg/$(basename "$entry")"
done
cp tests/security/theme_icon_files.d/desktop_probe.qml "$dcfg/shell.qml"
s=$tmp/desktop
mkdir -p -m 700 "$s/runtime" "$s/cache"
mkdir -p "$s/home/.local/share/applications" "$s/home/Desktop" "$s/data/pixmaps" "$s/elsewhere" "$s/state" "$s/config"
printf '%s' "$png" | base64 -d >"$s/data/pixmaps/ctl.png"
cp "$s/data/pixmaps/ctl.png" "$s/elsewhere/good.png"
mkfifo "$s/elsewhere/evil-path.png" "$s/data/pixmaps/evilname.png"
desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$1" "$2" >"$s/home/.local/share/applications/$1.desktop"; }
desk gf-fifo-path "$s/elsewhere/evil-path.png"
desk gf-fifo-name evilname
desk gf-ok-path "$s/elsewhere/good.png"
desk gf-ok-name ctl
cp "$s/home/.local/share/applications/gf-fifo-path.desktop" "$s/home/.local/share/applications/gf-fifo-name.desktop" "$s/home/Desktop/"
mkfifo "$s/home/Desktop/photo.png"
rc=0
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
  GRASSFIELD_DEV=1 PROBE_DESKTOP="$s/home/Desktop" HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
  XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" \
  GRASSFIELD_TEST_TMP="$s" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
  timeout -k 3 90 qs -p "$dcfg" --no-color 2>&1) || rc=$?
dline() { grep -o "probe: $1 .*" <<<"$out" | head -n 1 || true; }
dcheck() { # <label> <ok>
  if [[ $2 == 1 ]]; then echo "PASS: theme icon files, application icons: $1"; else echo "FAIL: theme icon files, application icons: $1 (rc $rc; $(grep -o 'probe: .*' <<<"$out" | tr '\n' '|' | cut -c1-400))"; fail=1; fi
}
l=$(dline gf-fifo-path); dcheck "a FIFO Icon= path is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-fifo-name); dcheck "an Icon= theme name whose file is a FIFO is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-ok-path); dcheck "a regular Icon= path is shown and prewarmed" "$([[ $l == *" verdict=ok source=file://$s/elsewhere/good.png prewarmed=true"* ]] && echo 1)"
l=$(dline gf-ok-name); dcheck "a regular Icon= theme name is shown and prewarmed" "$([[ $l == *" verdict=ok source=image://icon/ctl prewarmed=true"* ]] && echo 1)"
l=$(dline thumbnail); dcheck "a desktop picture that is a FIFO gets no thumbnail" "$([[ $l == "probe: thumbnail verdict=no source=" ]] && echo 1)"
dcheck "Launchpad cells, desktop icons and the About panel never stalled the loader or the GUI thread" "$([[ $rc == 0 && $(dline done) == "probe: done ctl=1" ]] && echo 1)"
# The other sites (their windows need toplevels or layer-shell, not made offscreen) use the same call, asynchronously.
site_ok=1
for site in 'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(Apps.lookup(tile.modelData.appIds[index])' 'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(mini.entry ? mini.entry.icon' \
  'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(label.entry ? label.entry.icon' 'shell/overlay/ForceQuitPanel.qml:return ThemeIcons.appIcon(e ? e.icon' \
  'shell/overlay/AppAboutPanel.qml:ThemeIcons.appIcon(root.entry ? root.entry.icon' 'shell/switcher/SwitcherWindow.qml:ThemeIcons.appIcon(tile.modelData.icon' \
  'shell/search/SearchPanel.qml:ThemeIcons.appIcon(row.info.appIcon' 'shell/search/Search.qml:iconSource: "", appIcon: r.app.icon'; do
  grep -qF -- "${site#*:}" "${site%%:*}" || { echo "missing: $site"; site_ok=0; }
done
for f in shell/overview/OverviewWindow.qml shell/overlay/ForceQuitPanel.qml shell/overlay/AppAboutPanel.qml shell/switcher/SwitcherWindow.qml shell/search/SearchPanel.qml shell/launchpad/AppsCell.qml shell/desktop/DesktopIcon.qml shell/dock/Dock.qml; do
  grep -q 'Quickshell.iconPath(.*\(icon\|iconTheme\)' "$f" && { echo "unchecked: $f"; site_ok=0; }
done
dcheck "Search, the Switcher, the Overview, Force Quit and About load Icon= through ThemeIcons.appIcon" "$site_ok"
# The Dock's two application icon sites use the same call (its window is not made offscreen).
dock_ok=$( [[ $(grep -c 'ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable")' shell/dock/Dock.qml) == 2 ]] && ! grep -q 'Quickshell.iconPath(tile.modelData.icon' shell/dock/Dock.qml && echo 1)
dcheck "the Dock loads application icons through ThemeIcons.appIcon" "$dock_ok"

# ---- Part 2: Qt with real-session search paths ----
probe=$tmp/qt_icon_lookup
if ! command -v g++ >/dev/null || [[ ! -f /usr/include/qt6/QtGui/QIcon ]]; then
  echo "SKIP: theme icon files, Qt lookup with real-session search paths (g++ or Qt headers missing)"
  exit $fail
fi
g++ -std=c++20 -fPIC -O1 -o "$probe" tests/security/theme_icon_files.d/qt_icon_lookup.cpp -I/usr/include/qt6 -I/usr/include/qt6/QtGui -I/usr/include/qt6/QtCore -lQt6Gui -lQt6Core
# ThemeIcons' checker, exactly as the shell runs it (the string literal of ThemeIcons.script).
python3 -I - shell/services/ThemeIcons.qml "$tmp/checker.sh" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("readonly property string script:")
j = src.index("\n\n", i)
literals = re.findall(r'"((?:[^"\\]|\\.)*)"', src[i:j])
open(sys.argv[2], "w", encoding="utf-8").write("".join(json.loads('"' + l + '"') for l in literals))
PY

qcase() { # <kind> <expected verdict> <qt alone must stall: yes|no> <setup> [name]
  local kind=$1 want=$2 stall=$3 name=${5:-evil} s H U D verdict qt qrc
  s=$(mktemp -d "$tmp/q.XXXXXX"); H=$s/home; U=$H/.local/share/icons; D=$s/data
  mkdir -p "$U/hicolor/48x48/apps" "$U/mytheme/48x48/apps" "$H/.icons" "$D/pixmaps" "$s/elsewhere"
  printf '%s' "$png" | base64 -d >"$s/ok.png"
  printf '[Icon Theme]\nName=mytheme\nInherits=hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n' >"$U/mytheme/index.theme"
  cp "$s/ok.png" "$U/mytheme/48x48/apps/evil.png"
  eval "$4"
  local envs=(env -i PATH="$PATH" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS="$D:/usr/local/share:/usr/share" XDG_RUNTIME_DIR="$s" QT_QPA_PLATFORM=offscreen)
  verdict=$("${envs[@]}" timeout -k 2 30 sh "$tmp/checker.sh" 8388608 67108864 67108864 check "$name" | grep -E "^(ok|no) $name\$" | cut -d' ' -f1 || true)
  local ok=1 note=
  [[ $verdict == "$want" ]] || ok=0
  if [[ $verdict == ok ]]; then
    # What ThemeIcons does next: Qt's lookup, which must finish.
    qrc=0; qt=$("${envs[@]}" timeout -k 1 8 "$probe" mytheme "$name" 2>/dev/null | tail -n 1) || qrc=$?
    [[ $qrc == 0 && $qt == done ]] || { ok=0; note="Qt stalled or failed after an ok (rc $qrc)"; }
  elif [[ $stall == yes ]]; then
    # The case is real: Qt alone stalls on it.
    qrc=0; "${envs[@]}" timeout -k 1 4 "$probe" mytheme "$name" >/dev/null 2>&1 || qrc=$?
    [[ $qrc == 124 ]] || { ok=0; note="Qt alone did not stall (rc $qrc): the case proves nothing"; }
  fi
  if ((ok)); then echo "PASS: theme icon files, Qt search paths: $kind (verdict $verdict)"; else echo "FAIL: theme icon files, Qt search paths: $kind: verdict ${verdict:-none} (want $want) $note"; fail=1; fi
  rm -rf "$s"
}

qcase control ok no ''
qcase index-current no yes 'rm "$U/mytheme/index.theme"; mkfifo "$U/mytheme/index.theme"'
qcase icon-theme-cache no yes 'mkfifo "$U/mytheme/icon-theme.cache"'
qcase inherited-index no no 'mkfifo "$U/hicolor/index.theme"'
qcase theme-icon no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkfifo "$U/mytheme/48x48/apps/evil.png"'
qcase hicolor-icon no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkfifo "$U/hicolor/48x48/apps/evil.png"'
qcase scalable-icon no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkdir -p "$U/hicolor/scalable/apps"; mkfifo "$U/hicolor/scalable/apps/evil.svg"'
qcase home-icons no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkdir -p "$H/.icons/mytheme/48x48/apps"; mkfifo "$H/.icons/mytheme/48x48/apps/evil.png"'
qcase dir-symlink no yes 'rm -r "$U/mytheme/48x48"; mkdir -p "$s/elsewhere/apps"; mkfifo "$s/elsewhere/apps/evil.png"; ln -s "$s/elsewhere" "$U/mytheme/48x48"'
qcase pixmaps no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkfifo "$D/pixmaps/evil.png"'
qcase dev-zero no no 'rm "$U/mytheme/48x48/apps/evil.png"; ln -s /dev/zero "$U/mytheme/48x48/apps/evil.png"'
qcase oversized no no 'rm "$U/mytheme/48x48/apps/evil.png"; truncate -s 9M "$U/mytheme/48x48/apps/evil.png"'
# Review of 100692f (regressions against eee45cc's walk, and more of Qt 6.11's reading of index.theme).
qcase section-not-in-Directories no yes 'rm "$U/mytheme/48x48/apps/evil.png"; printf "\n[hidden/apps]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; mkdir -p "$U/mytheme/hidden/apps"; mkfifo "$U/mytheme/hidden/apps/evil.png"'
qcase quoted-Directories no yes 'rm "$U/mytheme/48x48/apps/evil.png"; printf "[Icon Theme]\nName=mytheme\nInherits=hicolor\nDirectories=\"q,r\"\n\n[q,r]\nSize=48\nType=Fixed\n" >"$U/mytheme/index.theme"; mkdir -p "$U/mytheme/q,r"; mkfifo "$U/mytheme/q,r/evil.png"'
qcase inherits-dot-theme-index no yes 'rm "$U/mytheme/48x48/apps/evil.png"; sed -i "s/^Inherits=hicolor/Inherits=.x/" "$U/mytheme/index.theme"; mkdir -p "$H/.icons/.x"; mkfifo "$H/.icons/.x/index.theme"'
qcase inherits-dot-theme-icon no yes 'rm "$U/mytheme/48x48/apps/evil.png"; sed -i "s/^Inherits=hicolor/Inherits=.x/" "$U/mytheme/index.theme"; mkdir -p "$H/.icons/.x/48x48/apps"; printf "[Icon Theme]\nName=x\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n" >"$H/.icons/.x/index.theme"; mkfifo "$H/.icons/.x/48x48/apps/evil.png"'
qcase dash-shortened-7 no yes 'rm "$U/mytheme/48x48/apps/evil.png"; mkfifo "$U/mytheme/48x48/apps/evil.png"' evil-a-b-c-d-e-f
qcase section-traversal no yes 'rm "$U/mytheme/48x48/apps/evil.png"; printf "\n[../../../../../elsewhere/apps]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; mkdir -p "$s/elsewhere/apps"; mkfifo "$s/elsewhere/apps/evil.png"'
qcase inherits-traversal no yes 'rm "$U/mytheme/48x48/apps/evil.png"; sed -i "s|^Inherits=hicolor|Inherits=../../../../elsewhere/t|" "$U/mytheme/index.theme"; mkdir -p "$s/elsewhere/t"; mkfifo "$s/elsewhere/t/index.theme"'

# Cost: a user theme of 300 directories x 330 files; one batch of 8 names.
s=$tmp/cost; H=$s/home; U=$H/.local/share/icons/bigtheme
mkdir -p "$U"
dirs=$(seq -f "d%g/apps" 1 300 | paste -sd, -)
printf '[Icon Theme]\nName=bigtheme\nDirectories=%s\n' "$dirs" >"$U/index.theme"
for i in $(seq 1 300); do mkdir -p "$U/d$i/apps"; (cd "$U/d$i/apps" && touch $(seq -f "icon%g.png" 1 330)); done
start=$(date +%s%N)
mkdir -p -m 700 "$s/run"; out=$(env -i PATH="$PATH" XDG_RUNTIME_DIR="$s/run" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS=/usr/local/share:/usr/share timeout -k 2 30 sh "$tmp/checker.sh" 8388608 67108864 67108864 check $(seq -f "icon%g" 1 8)) || true
ms=$((($(date +%s%N) - start) / 1000000))
oks=$(grep -c '^ok icon' <<<"$out" || true)
if [[ $oks == 8 ]] && ((ms < 10000)); then echo "PASS: theme icon files, cost: 8 names against 99k files in ${ms} ms"; else echo "FAIL: theme icon files, cost: $oks/8 ok in ${ms} ms"; fail=1; fi
exit $fail
