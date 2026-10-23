#!/usr/bin/env bash
# ADR-0017: the composer on the REAL pinned upstream themes (provisioned by scripts/dev/icons.sh into
# .dev/third_party, of this checkout or of the main checkout when this is a linked worktree). SKIPs when they are absent
# (no network needed here). Checks, on the composed tree: every listed logo file and every file of its name gone from its
# layer, zero dangling links, folder -> Pebble, org.gnome.Software -> Pebble's bag, org.gnome.Calendar -> MacTahoe,
# and prints where org.gnome.Nautilus comes from, the per-layer counts and the total size.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
main=$(dirname "$common")
tp=""
for c in "$root" "$main"; do
  if [[ -d $c/.dev/third_party/MacTahoe-icon-theme/src && -d $c/.dev/third_party/Pebble-Icon-Theme/Pebble ]]; then tp=$c/.dev/third_party; break; fi
done
if [[ -z $tp ]]; then echo "SKIP: real pins not provisioned (run scripts/dev/icons.sh)"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/icons-real.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
out=$tmp/icons/grassfield-icons
desc="the upstream checkouts are at the pinned commits"
check bash -ec '[ "$(git -C "$1/MacTahoe-icon-theme" rev-parse HEAD)" = 839848b9a8a38a92a6936e30c4abe35cc6f2546d ] && [ "$(git -C "$1/Pebble-Icon-Theme" rev-parse HEAD)" = 185da58c2f4caf3c2a038aa0869fd2772acc0933 ]' _ "$tp"
log=$(python3 -I "$root/packaging/arch/icons-compose.py" --mactahoe "$tp/MacTahoe-icon-theme" --pebble "$tp/Pebble-Icon-Theme" \
  --branding "$root/branding/icons/theme" --list "$root/packaging/arch/icons-apple-logos.txt" --out "$out" 2>&1) && rc=0 || rc=$?
echo "$log" | sed 's/^/    /'
desc="the composer succeeds on the real pins (exit $rc)"
check test "$rc" = 0
[[ $rc == 0 ]] || exit 1

# Every listed file: gone from its layer, with every other file or link of its name.
bad=""
while read -r entry kind; do
  layer=${entry%%:*} rel=${entry#*:}
  [[ $kind == appstore ]] && continue
  base=${rel##*/}; name=${base%.*}
  if [[ $layer == mactahoe ]]; then dir=$out/base; else dir=$out/extra; fi
  if [[ -n $(find "$dir" \( -name "$name.svg" -o -name "$name.png" \) -print -quit) ]]; then bad+=" $layer:$name"; fi
done < <(sed 's/#.*//' "$root/packaging/arch/icons-apple-logos.txt" | awk 'NF')
desc="every listed logo name is gone from its layer (files and links)${bad:+ (left:$bad)}"
check test -z "$bad"
desc="zero dangling links, no absolute link, no icon-theme.cache"
check bash -ec 'cd "$1"; [ -z "$(find . -xtype l -print -quit)" ] && [ -z "$(find . -type l -lname "/*" -print -quit)" ] && [ -z "$(find . -name icon-theme.cache -print -quit)" ]' _ "$out"
desc="index.theme: Hidden=true, Inherits=breeze,Adwaita,hicolor, Directories, no forbidden word"
check bash -ec 'grep -qx "Hidden=true" "$1" && grep -qx "Inherits=breeze,Adwaita,hicolor" "$1" && grep -q "^Directories=" "$1" && ! grep -qiE "mac|osx|apple|tahoe" "$1"' _ "$out/index.theme"

where() { # name -> layer directory of the first file or link of that name (by size order not implied)
  find "$out" \( -name "$1.svg" -o -name "$1.png" \) -printf '%P\n' | sort | tr '\n' ' '
}
for n in folder org.gnome.Software org.gnome.Calendar org.gnome.Nautilus; do echo "    $n: $(where "$n")"; done
desc="folder: Pebble at every size, no MacTahoe file"
check bash -ec 'cd "$1"; [ -z "$(find base -name "folder.svg" -o -name "folder.png")" ] && [ -f extra/scalable/places/folder.svg ] && [ -e extra/16x16/places/folder.png ]' _ "$out"
desc="org.gnome.Software resolves to Pebble's bag"
check bash -ec 'cd "$1"; [ "$(readlink -f extra/scalable/apps/org.gnome.Software.svg)" = "$(readlink -f extra/scalable/apps/softwarecenter.svg)" ] && [ -z "$(find base -name "org.gnome.Software.svg" -o -name softwarecenter.svg)" ]' _ "$out"
desc="org.gnome.Calendar is MacTahoe's"
check bash -ec 'cd "$1"; [ -e base/apps/scalable/org.gnome.Calendar.svg ] && [ -z "$(find extra -name "org.gnome.Calendar.svg")" ]' _ "$out"

# GTK 3 and 4 on the composed real theme (Breeze and Adwaita from the system as parents).
if python3 -c 'import gi; gi.require_version("Gtk","3.0")' 2>/dev/null && python3 -c 'import gi; gi.require_version("Gtk","4.0")' 2>/dev/null; then
  for t in Adwaita breeze hicolor; do [[ -d /usr/share/icons/$t ]] && ln -s "/usr/share/icons/$t" "$tmp/icons/$t"; done
  for v in 3 4; do
    for s in 16 128; do
      g=$(env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" GSETTINGS_BACKEND=memory GF_ICON_SIZE=$s python3 -I "$root/tests/shell/icon_probe_gtk.py" "$v" "$tmp/icons" grassfield-icons folder org.gnome.Software org.gnome.Calendar org.gnome.Nautilus 2>/dev/null)
      echo "    GTK$v $s px: $(tr '\n' ' ' <<<"$g")"
      desc="GTK$v at $s px: folder and org.gnome.Software from Pebble, org.gnome.Calendar from MacTahoe"
      check bash -ec 'grep -qE "^folder=grassfield-icons/extra/" <<<"$1" && grep -qE "^org.gnome.Software=grassfield-icons/extra/" <<<"$1" && grep -qE "^org.gnome.Calendar=grassfield-icons/base/" <<<"$1"' _ "$g"
    done
  done
else
  echo "SKIP: GTK resolution on the real theme (PyGObject with Gtk 3 and 4 missing)"
fi
exit "$fail"
