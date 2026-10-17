#!/usr/bin/env bash
# Test for shell/launchpad/hidden-entries.sh with a temporary XDG tree under .dev/ (or $GRASSFIELD_TEST_TMP).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/hidden.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sys=$tmp/sys/applications
home=$tmp/home/applications
mkdir -p "$home" "$sys/sub"
w() { printf '[Desktop Entry]\nName=x\n%s\n[Desktop Action a]\nOnlyShowIn=Never;\n' "$2" > "$1"; }
w "$sys/only-hypr.desktop" 'OnlyShowIn=Hyprland;'        # shown
w "$sys/only-kde.desktop" 'OnlyShowIn=KDE;'              # hidden
w "$sys/only-multi.desktop" 'OnlyShowIn=KDE;Hyprland;'   # shown
w "$sys/not-hypr.desktop" 'NotShowIn=Hyprland;'          # hidden
w "$sys/not-kde.desktop" 'NotShowIn=KDE;'                # shown
w "$sys/plain.desktop" ''                                # shown
w "$sys/sub/nested.desktop" 'OnlyShowIn=KDE;'            # hidden, id sub-nested.desktop
w "$sys/shadow-a.desktop" 'OnlyShowIn=KDE;'              # the user file shows it
w "$home/shadow-a.desktop" ''
w "$sys/shadow-b.desktop" ''                             # the user file hides it
w "$home/shadow-b.desktop" 'NotShowIn=Hyprland;'
w "$sys/with
newline.desktop" 'OnlyShowIn=KDE;'                       # skipped
got=$(XDG_DATA_HOME=$tmp/home XDG_DATA_DIRS=$tmp/sys XDG_CURRENT_DESKTOP=Hyprland sh "$root/shell/launchpad/hidden-entries.sh" | sort | tr '\n' ' ')
want="not-hypr.desktop only-kde.desktop shadow-b.desktop sub-nested.desktop "
if [[ $got == "$want" ]]; then
  echo "PASS hidden-entries"
else
  echo "FAIL hidden-entries: got '$got' want '$want'"
  exit 1
fi
