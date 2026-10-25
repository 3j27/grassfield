#!/usr/bin/env bash
# F1 audit captures (not a regression run: no baselines). Run as a BARE command:
#   tests/visual/f1-audit.sh [--only a,b]   -> .dev/f1-audit/<name>.en.png
# Every scenario of tests/visual/scenarios plus states the suite does not capture (Dock tooltip and icon menu without
# magnification, desktop widgets and context menu, the volume overlay, more Settings panes), all in the LIGHT
# appearance at transparency 0.25: the macOS 26 reference captures (design/reference/macos) are light only.
# The banners, Search states, alerts and widget gallery come from f2c.sh (light and dark, .dev/f2c/*-f1audit-*).
# The nested session this script starts is torn down at the end (the lock scenario, last, does it).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
only="" mode=all
case ${1:-} in
  --only) only=${2:?--only needs a comma list} ;;
  # Internal: one extra state in its own process, so lib.sh's set -e applies (in run's `if` it would be ignored).
  --extra) mode=extra ;;
esac
export VISUAL_APPEARANCE=light VISUAL_LANG=en VISUAL_SHOTS=$root/.dev/f1-audit
mkdir -p "$VISUAL_SHOTS"
failed=0

want() { [[ -z $only || ,$only, == *,$1,* ]]; }

run() {
  want "$1" || return 0
  if "${@:2}" >"$VISUAL_SHOTS/log-$1.txt" 2>&1; then
    echo "ok    $1"
  else
    echo "FAIL  $1 (see .dev/f1-audit/log-$1.txt)"
    failed=$((failed + 1))
  fi
}

# extra NAME: one of the states below, in a subshell with the visual helpers. Started as `f1-audit.sh --extra NAME`.
extra() {
  (
    # shellcheck source=lib.sh
    source "$here/lib.sh"
    vs_session
    vs_reset
    case $1 in
      dock-tooltip)
        # A real pointer on tile 1 (Apps): the IPC hover drives magnification only, and parking the pointer would hide
        # the tooltip again.
        vs_ipc dock magnify 1.0 false
        read -r x y < <(vs_ipc dock centre 1 GF-REF)
        vs_pointer abs "${x%.*}" "${y%.*}"
        VS_NOPARK=1 VS_SETTLE=1.5 vs_capture dock-tooltip ;;
      dock-menu)
        # Tile 0 (Files): the Apps tile (1) has no menu, a secondary click there only shows its tooltip.
        read -r x y < <(vs_ipc dock centre 0 GF-REF)
        vs_pointer abs "${x%.*}" "${y%.*}" sleep 300 rclick
        VS_NOPARK=1 vs_capture dock-menu ;;
      widgets)
        vs_ipc widgets addDesktop clock small GF-REF
        vs_ipc widgets addDesktop calendar small GF-REF
        vs_ipc widgets addDesktop system medium GF-REF
        VS_SETTLE=2 vs_capture widgets
        vs_ipc widgets clearDesktop ;;
      desktop-menu)
        vs_pointer abs 900 520 sleep 300 rclick
        VS_NOPARK=1 vs_capture desktop-menu
        "$VS_ROOT/scripts/dev/keys.sh" -k Escape ;;
      osd)
        vs_ipc osd display volume 0.5 false
        VS_NOPARK=1 VS_SETTLE=0.3 vs_capture osd ;;
      settings-*)
        vs_spawn "$VS_DEV/build/grassfield-settings" "--section=${1#settings-}"
        vs_wait_clients 1
        vs_sleep 2
        vs_capture "$1" ;;
      *) echo "f1-audit: unknown extra $1" >&2; exit 2 ;;
    esac
  )
}

if [[ $mode == extra ]]; then
  extra "${2:?--extra needs a name}"
  exit
fi

extras="dock-tooltip dock-menu widgets desktop-menu osd settings-desktop settings-notifications settings-wifi settings-about"
known=" $(cd "$here/scenarios" && ls -- *.sh | sed 's/\.sh$//' | tr '\n' ' ')$extras f2c-banners f2c-search f2c-alerts f2c-gallery "
for n in ${only//,/ }; do
  [[ $known == *" $n "* ]] || { echo "f1-audit: unknown name $n (known:$known)" >&2; exit 2; }
done

for f in "$here"/scenarios/*.sh; do
  n=$(basename "$f" .sh)
  [[ $n == lock ]] && continue
  run "$n" "$f"
done
for n in $extras; do
  run "$n" "$here/f1-audit.sh" --extra "$n"
done
for s in banners search alerts gallery; do
  run "f2c-$s" "$here/f2c.sh" "$s" f1audit
done
# Last: a locked nested session cannot be unlocked; the scenario tears the session down.
run lock "$here/scenarios/lock.sh"
"$root/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true

echo "captures: $VISUAL_SHOTS (and .dev/f2c/*-f1audit-*); failed: $failed"
exit $(( failed > 0 ))
