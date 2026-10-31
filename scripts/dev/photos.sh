#!/usr/bin/env bash
# The wallpaper photographs for a dev session (ADR-0040 step 2c), as the package builds them (packaging/arch/PKGBUILD build()):
# downloads the sixteen originals of packaging/arch/wallpaper-pins.sh into .dev/cache/photos (once; a file whose SHA-1 is not
# the one Commons publishes is fetched again, then refused), shrinks them with .dev/build/grassfield-wallpaper-shrink
# (apps/wallpaper-tool/build-direct.sh --shrink) into .dev/photos and copies the list (photos.json) beside them. Settings >
# Wallpaper reads that folder in a dev session (its backend's wallpaperPhotosDir), inside .dev as the dev guard wants.
# Network: upload.wikimedia.org only. Usage: scripts/dev/photos.sh
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=packaging/arch/wallpaper-pins.sh
source "$root/packaging/arch/wallpaper-pins.sh"
cache=$root/.dev/cache/photos
out=$root/.dev/photos
tool=$root/.dev/build/grassfield-wallpaper-shrink
[[ -x $tool ]] || "$root/apps/wallpaper-tool/build-direct.sh" --shrink >/dev/null
mkdir -p "$cache" "$out"

matches() { # <sha1> <file>
  [[ -f $2 ]] && printf '%s  %s\n' "$1" "$2" | sha1sum -c --status
}

for i in "${!GF_PHOTO_IDS[@]}"; do
  id=${GF_PHOTO_IDS[i]}
  orig=$cache/$id.jpg
  if ! matches "${GF_PHOTO_SHA1[i]}" "$orig"; then
    curl -fsSL --retry 3 -A "Grassfield-dev-photos/1.0" -o "$orig.part" "${GF_PHOTO_URLS[i]}"
    mv -f "$orig.part" "$orig"
  fi
  matches "${GF_PHOTO_SHA1[i]}" "$orig" || { echo "photos.sh: $id: the download is not the file Commons describes (SHA-1)" >&2; exit 1; }
  printf '%s: %s\n' "$id" "$(LC_ALL=C.UTF-8 "$tool" --width 5120 --quality 90 --out "$out/$id.jpg" -- "$orig")"
done
cp "$root/packaging/arch/wallpaper-photos.json" "$out/photos.json"
echo "photos.sh: $(du -sh "$out" | cut -f1) in $out"
