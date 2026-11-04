#!/usr/bin/env bash
# Nested pass (L1) for deleting an app (ADR-0045 D1): the launcher's delete badge and Files' Move to Trash only HAND the app to
# the Store, whose own alert is the one confirmation. Real launcher, real Files, real Store (.dev/build/grassfield-store), on a
# made-up computer: a fake pacman that knows Kdenlive (its plan takes four more packages) and GParted, and a fake pkexec that only
# writes its arguments to a log and exits 126 (cancelled): nothing is ever installed or removed, and the log must stay empty.
#
# Proof, in this order: long press -> the real `grassfield-store --removable` answers (badges) -> the badge hands Kdenlive over ->
# the Store's alert is in front, with the Store's name, the icon and the plan's packages -> Cancel removes nothing; the same from
# Files (Move to Trash). Captures in .dev/shots/uninstall-store-*.png.
#
# Starts and stops its own nested session (scripts/dev/nested-up.sh --ref-scale 1.25) with the Store's fixture in the environment:
# run it BARE, with no nested session up. Requires .dev/build/grassfield-store and .dev/build/grassfield-files.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
fx=$dev/uninstall-fixture
case $fx in "$root"/.dev/uninstall-fixture) ;; *) echo "FAIL: unsafe fixture path"; exit 1 ;; esac
store=$dev/build/grassfield-store
files=$dev/build/grassfield-files
[[ -x $store && -x $files ]] || { echo "FAIL: build the Store and Files first (apps/store/build-direct.sh, apps/files/build-direct.sh)"; exit 1; }
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
ipc() { "$root/tests/visual/ipc.sh" "$@"; }
st() { ipc apps status | jq -r "$1"; }
keys=$root/scripts/dev/keys.sh
pointer=$root/scripts/dev/pointer.sh
shot() { "$root/scripts/dev/shot.sh" "uninstall-store-$1" >/dev/null && echo "shot .dev/shots/uninstall-store-$1.png"; }

# ---- the made-up computer
rm -rf -- "$fx"
mkdir -p "$fx"/{bin,applications,omarchy/install,swcatalog/xml}
cat >"$fx/bin/pacman" <<'EOF'
#!/bin/sh
case "$1" in
  -Sl) printf '%s\n' 'extra kdenlive 26.08.2-2 [installed]' 'extra gparted 1.7.0-1 [installed]' ;;
  -Qqe) printf '%s\n' kdenlive gparted ;;
  -Qqm) exit 0 ;;
  -Qq) printf '%s\n' grassfield-desktop kdenlive gparted ;;
  -Qi) printf '%s\n' 'Name            : grassfield-desktop' 'Optional Deps   : None' ;;
  -Qu) exit 1 ;;
  -Qo) shift; [ "$1" = -- ] && shift
       for f in "$@"; do case $f in
         */org.kde.kdenlive.desktop) echo "$f is owned by kdenlive 26.08.2-2" ;;
         */gparted.desktop) echo "$f is owned by gparted 1.7.0-1" ;;
       esac; done ;;
  -Rs) case "$*" in
         *kdenlive*) printf '%s\n' 'kdenlive 26.08.2-2' 'mlt 7.34.0-1' 'opentimelineio 0.17.0-3' 'qt6-speech 6.12.0-1' 'qt6-networkauth 6.12.0-1' ;;
         *gparted*) echo 'gparted 1.7.0-1' ;;
         *) exit 1 ;;
       esac ;;
  -Si) exit 1 ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "$@" >>"%s/pkexec.log"\nexit 126\n' "$fx" >"$fx/bin/pkexec"
printf '#!/bin/sh\nexit 1\n' >"$fx/bin/pacman-conf"
chmod +x "$fx/bin/pacman" "$fx/bin/pkexec" "$fx/bin/pacman-conf"
for id in org.kde.kdenlive gparted; do
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\n' "$id" >"$fx/applications/$id.desktop"
done
printf 'btop\n' >"$fx/omarchy/install/omarchy-base.packages"
printf '\n' >"$fx/omarchy/install/omarchy-other.packages"
: >"$fx/pkexec.log"

# The Store's dev plumbing (ADR-0019), inherited by every process of the nested session.
export GRASSFIELD_STORE_FIXTURE=$fx GRASSFIELD_STORE_PKEXEC=$fx/bin/pkexec GRASSFIELD_STORE_OFFLINE=1
unset GRASSFIELD_STORE_CATALOG_URL

stop_all() {
  pkill -f "$store" 2>/dev/null
  pkill -f "$files" 2>/dev/null
  "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1
}
trap stop_all EXIT
"$root/scripts/dev/nested-up.sh" --ref-scale 1.25 >/dev/null || { echo "FAIL: nested-up"; exit 1; }
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
for _ in $(seq 1 60); do dev_nested_target "$dev" 2>/dev/null && ipc apps status >/dev/null 2>&1 && break; sleep 1; done
dev_nested_target "$dev" || { echo "FAIL: no nested session"; exit 1; }
sleep 8

# ---- the launcher: long press, the real answer, the badge
"$pointer" output GF-REF abs 960 540 sleep 200 click >/dev/null; sleep 0.5
ipc apps open >/dev/null; sleep 2
[[ $(st .open) == true ]]; check "the Apps panel is open" $?
mapfile -t ids < <(ipc apps status | jq -r '.visible[]')
printf '%s\n' "${ids[@]}" | grep -qx org.kde.kdenlive; check "Kdenlive is listed" $?
[[ $(st .editing) == false ]]; check "the icons are still" $?
# A press held on the first icon (the panel's first cell, 62 pt icon at 1.25: logical 423, 350).
"$pointer" output GF-REF abs 423 350 sleep 200 down sleep 1200 up >/dev/null
for _ in $(seq 1 40); do [[ $(st .editing) == true && $(st .removable) -gt 0 ]] && break; sleep 1; done
[[ $(st .editing) == true ]]; check "a held press makes the icons jiggle" $?
n=$(st .removable)
((n >= 1)); check "the real Store answered: $n app(s) removable" $?
shot 1-launcher-badges
[[ $(ipc apps ask org.kde.kdenlive) == "handed over" ]]; check "the badge hands Kdenlive over" $?
# The Store starts, plans, and shows ITS alert; wait for it.
sleep 12
shot 2-store-alert-from-launcher
[[ ! -s $fx/pkexec.log ]]; check "nothing was authorised: pkexec was never called" $?
"$keys" -k Escape; sleep 1.5
shot 3-after-escape
[[ ! -s $fx/pkexec.log ]]; check "Escape (Cancel) removed nothing" $?
pkill -f "$store" 2>/dev/null; sleep 1

# ---- Files: Move to Trash on Kdenlive
ipc apps close >/dev/null; sleep 0.5
iso=files-uninstall-store
work=$dev/isolated/$iso
rm -rf -- "$work"
mkdir -p "$work"/{home,config,cache,state,data}
env -u DISPLAY WAYLAND_DISPLAY="$DEV_NESTED_SOCK" GRASSFIELD_FILES_NO_LAUNCH=1 QML_IMPORT_PATH="$root/ui" QT_QPA_PLATFORM=wayland \
  setsid "$root/scripts/dev/isolated.sh" --name "$iso" -- "$files" "grassfield-apps:/" >"$dev/files-uninstall-store.log" 2>&1 </dev/null &
sleep 14
shot 4-files-grid
echo "files grid captured; set KX KY (logical) from .dev/shots/uninstall-store-4-files-grid.png"
kx=${KX:-0}
ky=${KY:-0}
if ((kx > 0)); then
  "$pointer" output GF-REF abs "$kx" "$ky" sleep 100 click sleep 300 rclick >/dev/null; sleep 1
  shot 5-files-menu
  "$keys" -k Escape; sleep 0.5
  "$keys" -M ctrl -k BackSpace -m ctrl
  sleep 14
  shot 6-store-alert-from-files
  [[ ! -s $fx/pkexec.log ]]; check "nothing was authorised from Files either" $?
  "$keys" -k Escape; sleep 1.5
  shot 7-files-after-escape
  [[ ! -s $fx/pkexec.log ]]; check "Escape in the Store removed nothing" $?
fi
exit $fails
