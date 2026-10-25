#!/usr/bin/env bash
# Provision the composed icon theme grassfield-icons (ADR-0017, third-party GPL art) for DEV sessions only.
#
#   scripts/dev/icons.sh [--force]
#
# Fetches the two pinned upstream themes into .dev/third_party/ (git-ignored), verifies their commits, composes them
# with packaging/arch/icons-compose.py (the same composer and the same list as the package) into
# .dev/share/icons/grassfield-icons, and writes a stamp last. Never touches ~/.local/share/icons, ~/.icons or /usr.
# Idempotent: does nothing while the stamp matches the pins and the composer, list and branding inputs. Nothing is
# committed. Network: github.com over HTTPS (git fetch of one commit each), with a time limit; a linked worktree copies
# the main checkout's composed theme of the same stamp instead, without network.
# Upstream content is data: no upstream script runs (the composer reads src/, links/ and Pebble/ only).
# After this, nested-up.sh / shell-run.sh / isolated.sh select the theme through scripts/dev/devenv.sh, which falls
# back to the plain wrapper theme (Breeze, Adwaita, hicolor) when this has not run.
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# The pins (MT_PIN, MT_REPO, PB_PIN, PB_REPO) are defined once, in packaging/arch/icon-pins.sh, which the PKGBUILD sources too.
# shellcheck source=packaging/arch/icon-pins.sh
source "$root/packaging/arch/icon-pins.sh"
dev=$root/.dev
tp=$dev/third_party
icons=$dev/share/icons
theme=$icons/grassfield-icons
stamp=$icons/.grassfield-icons-stamp
force=0
[[ ${1:-} == --force ]] && force=1

# The stamp covers the pins and everything the composition reads from this repository.
inputs=$(cd "$root" && { cat packaging/arch/icons-compose.py packaging/arch/icons-apple-logos.txt packaging/arch/icons-apple-signatures.txt packaging/arch/icons-aliases.txt; find branding/icons/theme -type f | LC_ALL=C sort | xargs cat; } | sha256sum | cut -c1-16)
STAMP_VALUE="$MT_PIN-$PB_PIN-$inputs"

if [[ $force == 0 && -f $stamp && $(<"$stamp") == "$STAMP_VALUE" && -f $theme/index.theme ]]; then
  echo "icons: already composed ($STAMP_VALUE)"
  exit 0
fi

# A linked worktree copies a complete composition of the same stamp from the main checkout (reflinks on btrfs).
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
main=$(dirname "$common")
if [[ $force == 0 && $main != "$root" && -f $main/.dev/share/icons/.grassfield-icons-stamp \
      && $(<"$main/.dev/share/icons/.grassfield-icons-stamp") == "$STAMP_VALUE" && -f $main/.dev/share/icons/grassfield-icons/index.theme ]]; then
  mkdir -p "$icons"
  rm -f "$stamp"
  rm -rf -- "${theme:?}"
  cp -a --reflink=auto "$main/.dev/share/icons/grassfield-icons" "$icons/"
  printf '%s\n' "$STAMP_VALUE" > "$stamp.new" && mv "$stamp.new" "$stamp"
  echo "icons: copied the composed theme from $main/.dev/share/icons"
  exit 0
fi

fetch() { # dir repo pin
  local dir=$1 repo=$2 pin=$3 head
  mkdir -p "$dir"
  [[ -d $dir/.git ]] || git -C "$dir" init -q
  if [[ $(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true) != "$pin" ]]; then
    # Network step with a time limit (GRASSFIELD_NET_TIMEOUT seconds, default 120); no credential prompt.
    GIT_TERMINAL_PROMPT=0 timeout "${GRASSFIELD_NET_TIMEOUT:-120}" git -C "$dir" fetch -q --depth 1 "$repo" "$pin"
    git -C "$dir" checkout -q --force FETCH_HEAD
  fi
  head=$(git -C "$dir" rev-parse HEAD)
  [[ $head == "$pin" ]] || { echo "icons: fetched commit $head differs from the pin $pin" >&2; exit 1; }
  [[ -z $(git -C "$dir" status --porcelain) ]] || { echo "icons: $dir has local modifications; remove it and retry" >&2; exit 1; }
}
fetch "$tp/MacTahoe-icon-theme" "$MT_REPO" "$MT_PIN"
fetch "$tp/Pebble-Icon-Theme" "$PB_REPO" "$PB_PIN"

mkdir -p "$icons"
rm -f "$stamp"
python3 -I "$root/packaging/arch/icons-compose.py" --mactahoe "$tp/MacTahoe-icon-theme" --pebble "$tp/Pebble-Icon-Theme" \
  --branding "$root/branding/icons/theme" --list "$root/packaging/arch/icons-apple-logos.txt" --out "$theme.new"
rm -rf -- "${theme:?}"
mv "$theme.new" "$theme"
# GPL-3.0: keep the licence and the authors next to the installed theme.
cp -f "$tp/MacTahoe-icon-theme/COPYING" "$tp/MacTahoe-icon-theme/AUTHORS" "$theme/"
gtk-update-icon-cache -q "$theme" 2>/dev/null || true
printf '%s\n' "$STAMP_VALUE" > "$stamp.new" && mv "$stamp.new" "$stamp"
echo "icons: composed grassfield-icons into $icons"
