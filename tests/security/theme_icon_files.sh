#!/usr/bin/env bash
# Integrator decision after the review of 5ee6240: Qt never reads a user-writable icon file. The shell's icon search
# paths hold only directories the user can neither write nor replace (ui/i18n/iconsearchpaths.h); an icon found only in
# the user's folders, an Icon= path and a desktop picture are shown as private copies made by ThemeIcons' helper
# (O_NOFOLLOW|O_NONBLOCK open, fstat: a regular file within a size cap). Every run below uses the REAL shell modules
# offscreen in a scratch HOME / XDG_DATA_HOME / XDG_DATA_DIRS and must finish (a stalled GUI thread or image loader keeps
# the process from exiting).
#
# Part 1, files for the theme icon name "evil" in the user's icon folders (the notification icon and the polkit sheet's):
#   reg       a regular PNG                       -> shown, as a private copy
#   fifo      a FIFO                              -> the generic icon
#   link      a symlink to a FIFO elsewhere       -> the generic icon (O_NOFOLLOW)
#   zero      a symlink to /dev/zero              -> the generic icon
#   devnull   a symlink to /dev/null (.svg)       -> the generic icon
#   svgfifo   a FIFO evil.svg                     -> the generic icon
#   svgref    an SVG referencing an outside file  -> the generic icon
#   homefifo  a FIFO under ~/.icons/hicolor       -> the generic icon
#   swap      shown, then a FIFO named by a new notification -> its new copy is refused
# Qt must not see any of them (hasThemeIcon false: user folders are not searched).
# Part 2, the review's hostile user index.theme files (escaped sections and Inherits=, continuation lines, an escaped key,
# Inherits=.., Inherits=., a hicolor index in the user's folder with Adwaita as the theme): the shell's lookup never
# reads them, shows the generic icon and never stalls; Qt with a real session's search paths (user folders included,
# theme_icon_files.d/qt_icon_lookup.cpp, built here, SKIP without g++) stalls on each, so each case is real, and the same
# lookup after the shell's policy function (iconsearchpaths.h) finishes without finding the icon (offscreen, the shell
# itself never has user search paths, so this is what shows the policy at work).
# Part 3, icons named by applications and files (Launchpad cells, desktop icons, the About panel; the other sites'
# calls checked in the source).
# Part 4, the policy itself: the search paths the shell logs contain no directory the user can change; no process of the
# shell opens a file in the user's icon folders except the copy helper (O_NOFOLLOW|O_NONBLOCK) or for a directory
# listing (LD_PRELOAD open log, theme_icon_files.d/openlog.c); a child process (an application launched from the shell)
# gets the environment unchanged. Plus the helper's cost with a user theme of 99k files.
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
ui/i18n/build-direct.sh >/dev/null
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/theme-icon-files.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkcfg() { # <dir> <probe>
  mkdir -p "$1"
  for entry in shell/*; do
    [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$1/$(basename "$entry")"
  done
  cp "tests/security/theme_icon_files.d/$2" "$1/shell.qml"
}
mkcfg "$tmp/cfg" probe.qml
png=iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
fail=0
pass() { echo "PASS: theme icon files $*"; }
bad() { echo "FAIL: theme icon files $*"; fail=1; }

shellenv() { # <scratch> -> the environment of a probe run
  local s=$1
  printf '%s\n' -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION \
    GRASSFIELD_DEV=1 HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home/.config" XDG_STATE_HOME="$s/home/.local/state" GRASSFIELD_STATE_HOME="$s/state" GRASSFIELD_CONFIG_HOME="$s/config" \
    GRASSFIELD_TEST_TMP="$s" XDG_RUNTIME_DIR="$s/runtime" XDG_CACHE_HOME="$s/cache" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations"
}

scratch() { # <dir>: a fresh scratch tree with the regular user icon "ctl"
  local s=$1
  mkdir -p -m 700 "$s/runtime" "$s/cache"
  mkdir -p "$s/home/.local/share/icons/hicolor/48x48/apps" "$s/home/.icons" "$s/data/pixmaps" "$s/outside" "$s/state" "$s/config"
  printf '%s' "$png" | base64 -d >"$s/home/.local/share/icons/hicolor/48x48/apps/ctl.png"
}

probe() { # <scratch> <kind> [VAR=value...]: one run of probe.qml; prints its line, sets rc
  local s=$1 kind=$2
  shift 2
  local -a e
  mapfile -t e < <(shellenv "$s")
  rc=0
  out=$(env "${e[@]}" PROBE_KIND="$kind" PROBE_USER_ICON="$s/home/.local/share/icons/hicolor/48x48/apps/evil.png" "$@" \
    timeout -k 3 60 qs -p "$tmp/cfg" --no-color 2>&1) || rc=$?
  line=$(grep -o "probe: .*" <<<"$out" | head -n 1 || true)
}

# ---- Part 1 ----
for kind in reg fifo link zero devnull svgfifo svgref homefifo swap; do
  s=$tmp/p1-$kind
  scratch "$s"
  A=$s/home/.local/share/icons/hicolor/48x48/apps
  case $kind in
    reg | swap) printf '%s' "$png" | base64 -d >"$A/evil.png" ;;
    fifo) mkfifo "$A/evil.png" ;;
    link) mkfifo "$s/outside/f" && ln -s "$s/outside/f" "$A/evil.png" ;;
    zero) ln -s /dev/zero "$A/evil.png" ;;
    devnull) ln -s /dev/null "$A/evil.svg" ;;
    svgfifo) mkdir -p "$s/home/.local/share/icons/hicolor/scalable/apps" && mkfifo "$s/home/.local/share/icons/hicolor/scalable/apps/evil.svg" ;;
    svgref) mkfifo "$s/outside/f" && printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="%s"/></svg>' "$s/outside/f" >"$A/evil.svg" ;;
    homefifo) mkdir -p "$s/home/.icons/hicolor/48x48/apps" && mkfifo "$s/home/.icons/hicolor/48x48/apps/evil.png" ;;
  esac
  probe "$s" "$kind"
  ok=1
  ((rc == 0)) || ok=0
  [[ $line == *" has=false "* && $line == *" ctl=1"* ]] || ok=0
  case $kind in
    reg) [[ $line == *" state=ok notif=copy polkit=copy evil=1 "* ]] || ok=0 ;;
    swap) [[ $line == *" before=ok:shown state=no notif=none polkit=none evil=0 "* ]] || ok=0 ;;
    *) [[ $line == *" state=no notif=none polkit=none evil=0 "* ]] || ok=0 ;;
  esac
  if ((ok)); then pass "$kind ($line)"; else bad "$kind: rc $rc, ${line:-no probe line} $(grep -E 'TypeError|ReferenceError' <<<"$out" | head -n 2)"; fi
done

# ---- Part 2 ----
qprobe=$tmp/qt_icon_lookup
if command -v g++ >/dev/null && [[ -f /usr/include/qt6/QtGui/QIcon ]]; then
  g++ -std=c++20 -fPIC -O1 -o "$qprobe" tests/security/theme_icon_files.d/qt_icon_lookup.cpp -Iui/i18n -I/usr/include/qt6 -I/usr/include/qt6/QtGui -I/usr/include/qt6/QtCore -lQt6Gui -lQt6Core
else
  qprobe=
  echo "SKIP: theme icon files, part 2 controls (Qt alone with user search paths): g++ or Qt headers missing"
fi
hostile() { # <case> <theme> <setup> [nostall]: the shell shows the generic icon without a stall; Qt alone stalls
  # (unless "nostall": a case the review asked to confirm irrelevant, slow rather than stuck for Qt alone)
  local name=$1 theme=$2 mode=${4:-} s=$tmp/p2-$1 U H qrc
  scratch "$s"
  H=$s/home; U=$H/.local/share/icons
  mkdir -p "$U/mytheme/48x48/apps"
  printf '[Icon Theme]\nName=mytheme\nInherits=hicolor\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n' >"$U/mytheme/index.theme"
  mkfifo "$s/outside/evil.png" "$s/outside/index.theme"
  eval "$3"
  probe "$s" "hostile-$name" QS_ICON_THEME="$theme"
  local ok=1 note=
  [[ $rc == 0 && $line == *" has=false "* && $line == *" state=no notif=none polkit=none evil=0 "* && $line == *" ctl=1"* ]] || { ok=0; note="shell: rc $rc ${line:-no probe line}"; }
  if [[ -n $qprobe ]]; then
    qrc=0
    env -i PATH="$PATH" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" XDG_RUNTIME_DIR="$s/runtime" \
      QT_QPA_PLATFORM=offscreen timeout -k 1 4 "$qprobe" "$theme" evil >/dev/null 2>&1 || qrc=$?
    [[ $mode == nostall || $qrc == 124 ]] || { ok=0; note="$note; Qt alone did not stall (rc $qrc): the case proves nothing"; }
    # The same lookup after the shell's policy function (the offscreen shell above never had user search paths).
    qrc=0
    pout=$(env -i PATH="$PATH" HOME="$H" XDG_DATA_HOME="$H/.local/share" XDG_DATA_DIRS="$s/data:/usr/local/share:/usr/share" XDG_RUNTIME_DIR="$s/runtime" \
      QT_QPA_PLATFORM=offscreen timeout -k 1 8 "$qprobe" --policy "$theme" evil 2>/dev/null) || qrc=$?
    [[ $qrc == 0 && $pout == *"has evil=0"* && $pout == *done* ]] || { ok=0; note="$note; with the policy Qt still stalled or found it (rc $qrc)"; }
  fi
  local said="Qt alone stalls, Qt under the policy does not"
  [[ $mode == nostall ]] && said="Qt under the policy finishes"
  if ((ok)); then pass "hostile index.theme: $name (generic icon, no stall${qprobe:+; $said})"; else bad "hostile index.theme: $name: $note"; fi
}
hostile esc-section-backslash mytheme 'printf "\n[..\\\\..\\\\..\\\\..\\\\..\\\\outside]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; sed -i "s|^Directories=48x48/apps|Directories=48x48/apps,..\\\\\\\\..\\\\\\\\..\\\\\\\\..\\\\\\\\..\\\\\\\\outside|" "$U/mytheme/index.theme"'
hostile esc-section-percent mytheme 'printf "\n[%%2E%%2E/%%2E%%2E/%%2E%%2E/%%2E%%2E/%%2E%%2E/outside]\nSize=48\nType=Fixed\n" >>"$U/mytheme/index.theme"; sed -i "s|^Directories=48x48/apps|Directories=48x48/apps,%2E%2E/%2E%2E/%2E%2E/%2E%2E/%2E%2E/outside|" "$U/mytheme/index.theme"'
hostile inherits-hex-slash mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..\\\\x2f..\\\\x2f..\\\\x2f..\\\\x2foutside|" "$U/mytheme/index.theme"'
hostile inherits-octal-slash mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..\\\\57..\\\\57..\\\\57..\\\\57outside|" "$U/mytheme/index.theme"'
hostile inherits-escaped-key mytheme 'sed -i "s|^Inherits=hicolor|Inherit%73=../../../../outside|" "$U/mytheme/index.theme"'
hostile inherits-continuation mytheme 'sed -i "s|^Inherits=hicolor|Inherits=hicolor,\\\\\n../../../../outside|" "$U/mytheme/index.theme"'
hostile inherits-dotdot mytheme 'sed -i "s|^Inherits=hicolor|Inherits=..|" "$U/mytheme/index.theme"; mkfifo "$H/.local/share/index.theme"'
hostile inherits-dot mytheme 'sed -i "s|^Inherits=hicolor|Inherits=.|" "$U/mytheme/index.theme"; mkfifo "$U/index.theme"'
hostile user-hicolor-under-adwaita Adwaita 'printf "[Icon Theme]\nName=hicolor\nInherit%%73=../../../../outside\nDirectories=48x48/apps\n\n[48x48/apps]\nSize=48\nType=Fixed\n" >"$U/hicolor/index.theme"'
hostile fifo-index-and-cache mytheme 'rm "$U/mytheme/index.theme"; mkfifo "$U/mytheme/index.theme" "$U/mytheme/icon-theme.cache"'
# The review's minors, confirmed irrelevant once user folders are out of Qt's search paths: a 60 MiB index.theme, a theme
# that is a symlink to /proc/self.
hostile huge-index mytheme 'head -c 62914560 /dev/zero | tr "\\0" "x" >>"$U/mytheme/index.theme"' nostall
hostile proc-symlink-theme mytheme 'rm -r "$U/mytheme"; ln -s /proc/self "$U/mytheme"' nostall

# ---- Part 3: icons named by applications and files ----
mkcfg "$tmp/dcfg" desktop_probe.qml
s=$tmp/desktop
scratch "$s"
mkdir -p "$s/home/.local/share/applications" "$s/home/Desktop" "$s/elsewhere"
printf '%s' "$png" | base64 -d >"$s/data/pixmaps/ctl.png"
printf '%s' "$png" | base64 -d >"$s/elsewhere/good.png"
mkfifo "$s/elsewhere/evil-path.png" "$s/data/pixmaps/evilname.png"
desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$1" "$2" >"$s/home/.local/share/applications/$1.desktop"; }
desk gf-fifo-path "$s/elsewhere/evil-path.png"
desk gf-fifo-name evilname
desk gf-ok-path "$s/elsewhere/good.png"
desk gf-ok-name ctl
cp "$s/home/.local/share/applications/gf-fifo-path.desktop" "$s/home/.local/share/applications/gf-fifo-name.desktop" "$s/home/Desktop/"
mkfifo "$s/home/Desktop/photo.png"
mapfile -t e < <(shellenv "$s")
rc=0
out=$(env "${e[@]}" PROBE_DESKTOP="$s/home/Desktop" timeout -k 3 90 qs -p "$tmp/dcfg" --no-color 2>&1) || rc=$?
dline() { grep -o "probe: $1 .*" <<<"$out" | head -n 1 || true; }
dcheck() { # <label> <ok>
  if [[ $2 == 1 ]]; then pass "application icons: $1"; else bad "application icons: $1 (rc $rc; $(grep -o 'probe: .*' <<<"$out" | tr '\n' '|' | cut -c1-400))"; fi
}
l=$(dline gf-fifo-path); dcheck "a FIFO Icon= path is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-fifo-name); dcheck "an Icon= name whose user file is a FIFO is refused" "$([[ $l == *" verdict=no source= "* ]] && echo 1)"
l=$(dline gf-ok-path); dcheck "a regular Icon= path is shown as a copy and prewarmed" "$([[ $l == *" verdict=ok source=copy prewarmed=true"* ]] && echo 1)"
l=$(dline gf-ok-name); dcheck "a user-installed icon name is shown as a copy and prewarmed" "$([[ $l == *" verdict=ok source=copy prewarmed=true"* ]] && echo 1)"
l=$(dline thumbnail); dcheck "a desktop picture that is a FIFO gets no thumbnail" "$([[ $l == "probe: thumbnail verdict=no source=" ]] && echo 1)"
dcheck "Launchpad cells, desktop icons and the About panel never stalled the loader or the GUI thread" "$([[ $rc == 0 && $(dline done) == "probe: done ctl=1" ]] && echo 1)"
site_ok=1
for site in 'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(Apps.lookup(tile.modelData.appIds[index])' 'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(mini.entry ? mini.entry.icon' \
  'shell/overview/OverviewWindow.qml:ThemeIcons.appIcon(label.entry ? label.entry.icon' 'shell/overlay/ForceQuitPanel.qml:return ThemeIcons.appIcon(e ? e.icon' \
  'shell/overlay/AppAboutPanel.qml:ThemeIcons.appIcon(root.entry ? root.entry.icon' 'shell/switcher/SwitcherWindow.qml:ThemeIcons.appIcon(tile.modelData.icon' \
  'shell/search/SearchPanel.qml:ThemeIcons.appIcon(row.info.appIcon' 'shell/search/Search.qml:iconSource: "", appIcon: r.app.icon' \
  'shell/dock/Dock.qml:ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable")' 'shell/dock/StackIcon.qml:ThemeIcons.fileSource(root.path)' \
  'shell/dock/StackIcon.qml:ThemeIcons.appIcon(names.length > 0 ? names[0] : ""' 'shell/stages/Stages.qml:ThemeIcons.appIcon(tile.entry ? tile.entry.icon'; do
  grep -qF -- "${site#*:}" "${site%%:*}" || { echo "missing: $site"; site_ok=0; }
done
for f in shell/overview/OverviewWindow.qml shell/overlay/ForceQuitPanel.qml shell/overlay/AppAboutPanel.qml shell/switcher/SwitcherWindow.qml shell/search/SearchPanel.qml shell/launchpad/AppsCell.qml shell/desktop/DesktopIcon.qml shell/dock/Dock.qml shell/dock/StackIcon.qml shell/stages/Stages.qml; do
  grep -q 'Quickshell.iconPath(.*\(\.icon\b\|iconTheme\)' "$f" && { echo "unchecked: $f"; site_ok=0; }
done
dcheck "Search, the Switcher, the Overview, Stages, Force Quit, About, the Dock and its stacks load such icons through ThemeIcons" "$site_ok"

# ---- Part 4: the policy ----
if ! command -v gcc >/dev/null; then
  echo "SKIP: theme icon files, part 4 open log (gcc missing)"
  exit $fail
fi
gcc -shared -fPIC -O1 -o "$tmp/openlog.so" tests/security/theme_icon_files.d/openlog.c -ldl
mkcfg "$tmp/pcfg" policy_probe.qml
s=$tmp/policy
scratch "$s"
H=$s/home; U=$H/.local/share/icons
mkdir -p "$H/.icons/hicolor" "$s/data/icons/hicolor/48x48/apps"
printf '%s' "$png" | base64 -d >"$U/hicolor/48x48/apps/useronly.png"
mkfifo "$U/hicolor/index.theme" "$U/hicolor/icon-theme.cache" "$U/hicolor/48x48/apps/evil.png" "$H/.icons/hicolor/index.theme" \
  "$s/data/icons/hicolor/index.theme" "$s/data/pixmaps/evil.png"
mapfile -t e < <(shellenv "$s")
rc=0
out=$(env "${e[@]}" LD_PRELOAD="$tmp/openlog.so" OPENLOG="$tmp/policy-opens.log" timeout -k 3 30 qs -p "$tmp/pcfg" --no-color 2>&1) || rc=$?
[[ $rc == 0 && $(grep -c "probe: .* has=" <<<"$out") == 4 ]] && pass "policy: Qt's lookups finish next to FIFO theme files in every user folder" || bad "policy: lookups: rc $rc $(grep -o 'probe: .*' <<<"$out" | tr '\n' '|')"
grep -q "probe: child environment same=true" <<<"$out" && pass "policy: a child process gets the shell's environment unchanged" || bad "policy: child environment: $(grep -o 'probe: child.*' <<<"$out")"
paths=$(grep -o 'grassfield-icons: theme search paths .*' <<<"$out" | head -n 1 || true)
python3 -I - "$s" "$paths" <<'PY' && pass "policy: Qt's icon search paths hold no directory the user can change ($(sed "s|$s|\$S|g" <<<"$paths"))" || bad "policy: search paths: $paths"
import os, sys
scratch, line = sys.argv[1], sys.argv[2]
if not line.startswith("grassfield-icons: theme search paths "):
    sys.exit(1)
rest = line[len("grassfield-icons: theme search paths "):]
theme, _, fallback = rest.partition(" fallback ")
dirs = [d for d in theme.split(";") + fallback.split(";") if d and not d.startswith(":")]
def mapped_root():
    if open("/proc/self/uid_map").read().split()[:2] == ["0", "0"]:
        return -1
    return int(open("/proc/sys/kernel/overflowuid").read())
ROOT = mapped_root()
ok = bool(dirs)
for d in dirs:
    p = os.path.realpath(d)
    if p != d or p.startswith(scratch) or p.startswith(os.path.expanduser("~")):
        ok = False
    while ok:
        st = os.stat(p)
        if st.st_uid not in (0, ROOT) or st.st_uid == os.geteuid() or os.access(p, os.W_OK):
            ok = False
        if p == "/":
            break
        p = os.path.dirname(p)
sys.exit(0 if ok else 1)
PY
[[ -s $tmp/policy-opens.log ]] || bad "policy: the open log is empty (the shim did not load)"
user_opens=$(grep -E "^OPEN [0-9]+ -?[0-9]+ ($s/home/\.local/share/icons|$s/home/\.icons|$s/home/\.local/share/pixmaps|$s/data/icons|$s/data/pixmaps)(/|$)" "$tmp/policy-opens.log" || true)
[[ -z $user_opens ]] && pass "policy: the shell opened no file in the user's icon folders" || bad "policy: opens in user icon folders: $(head -n 3 <<<"$user_opens" | sed "s|$s|\$S|g")"
# The copy helper itself: under the same log, every open of a user icon file carries O_NOFOLLOW|O_NONBLOCK (or is a
# directory listing).
s=$tmp/p4-helper
scratch "$s"
mkfifo "$s/home/.local/share/icons/hicolor/48x48/apps/evil.png"
probe "$s" helper-log LD_PRELOAD="$tmp/openlog.so" OPENLOG="$tmp/helper-opens.log"
python3 -I - "$s" "$tmp/helper-opens.log" <<'PY' && pass "policy: the copy helper opens user icon files only with O_NOFOLLOW|O_NONBLOCK" || bad "policy: unsafe opens of user icon files"
import os, re, sys
scratch = sys.argv[1]
O_NONBLOCK, O_NOFOLLOW, O_DIRECTORY = os.O_NONBLOCK, os.O_NOFOLLOW, os.O_DIRECTORY
seen = bad = 0
for line in open(sys.argv[2], errors="replace"):
    m = re.match(r"OPEN (\d+) (-?\d+) (.*)$", line.rstrip("\n"))
    icon_dirs = [scratch + d for d in ("/home/.local/share/icons", "/home/.icons", "/home/.local/share/pixmaps", "/data/icons", "/data/pixmaps")]
    if not m or not any(m.group(3) == d or m.group(3).startswith(d + "/") for d in icon_dirs):
        continue
    flags = int(m.group(2))
    if flags >= 0 and flags & O_DIRECTORY:
        continue
    seen += 1
    if flags < 0 or not (flags & O_NONBLOCK and flags & O_NOFOLLOW):
        bad += 1
        print("unsafe:", line.strip().replace(scratch, "$S"))
sys.exit(0 if seen > 0 and bad == 0 else 1)
PY

# Cost: a user theme of 300 folders x 330 files; 24 names not found anywhere (the worst case: every candidate tried).
s=$tmp/cost; U=$s/home/.local/share/icons/bigtheme
mkdir -p -m 700 "$s/out"
for i in $(seq 1 300); do mkdir -p "$U/d$i/apps"; (cd "$U/d$i/apps" && touch $(seq -f "icon%g.png" 1 330)); done
python3 -I - shell/services/ThemeIcons.qml "$tmp/helper.py" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
i = src.index("readonly property string script:")
j = src.index("\n\n", i)
open(sys.argv[2], "w", encoding="utf-8").write("".join(json.loads('"' + l + '"') for l in re.findall(r'"((?:[^"\\]|\\.)*)"', src[i:j])))
PY
args=()
for i in $(seq 1 24); do args+=(name "$i" "missing$i"); done
start=$(date +%s%N)
n=$(env -i PATH="$PATH" HOME="$s/home" XDG_DATA_HOME="$s/home/.local/share" python3 -I "$tmp/helper.py" "$s/out" 8388608 16777216 134217728 "${args[@]}" | grep -c '^no' || true)
ms=$((($(date +%s%N) - start) / 1000000))
if [[ $n == 24 ]] && ((ms < 10000)); then pass "cost: 24 names looked up next to a user theme of 99k files in ${ms} ms"; else bad "cost: $n/24 answered in ${ms} ms"; fi
exit $fail
