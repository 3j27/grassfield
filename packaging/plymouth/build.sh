#!/usr/bin/env bash
# Renders Grassfield's Plymouth theme (ADR-0042) into DIR: grassfield.plymouth and the PNG images Plymouth's two-step module
# reads (watermark.png: the Grassfield mark, white; entry.png, bullet.png, lock.png, box.png: the password prompt;
# throbber-NNNN.png: a ring of dots). lock.png, box.png, entry.png and bullet.png are the ones two-step needs to draw at all
# (without them plymouthd shows its text view: safe for the prompt, but the theme would be dead). Every image is drawn here as SVG and rendered by rsvg-convert (librsvg, a makedepend). The mark is the
# owner's (all rights reserved, branding/LICENSES.md): branding/icons/symbolic/grassfield-logo-full.svg rendered as is, its
# black fill drawn white as the shell tints the symbolic mark; the drawing is not changed.
#   packaging/plymouth/build.sh --out DIR
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=""
while (($#)); do
  case $1 in
    --out) out=$2; shift 2 ;;
    *) echo "usage: build.sh --out DIR" >&2; exit 2 ;;
  esac
done
[[ -n $out ]] || { echo "usage: build.sh --out DIR" >&2; exit 2; }
command -v rsvg-convert >/dev/null || { echo "plymouth: rsvg-convert (librsvg) is missing" >&2; exit 1; }
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT

render() { # <width> <height> <svg> <png>
  rsvg-convert -w "$1" -h "$2" -o "$4" "$3"
}

# The mark, white on transparent, 112 px.
sed 's/fill="#000"/fill="#FFFFFF"/' "$root/branding/icons/symbolic/grassfield-logo-full.svg" > "$work/mark.svg"
grep -q 'fill="#FFFFFF"' "$work/mark.svg" || { echo "plymouth: the mark's fill was not found" >&2; exit 1; }
render 112 112 "$work/mark.svg" "$out/watermark.png"

# The password entry: the lock screen's dark frosted inset (shadow at 0.45, a white ring at 0.7), 260 x 36.
cat > "$work/entry.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="260" height="36" viewBox="0 0 260 36"><rect x="0.75" y="0.75" width="258.5" height="34.5" rx="17.25" fill="#000" fill-opacity="0.45" stroke="#FFF" stroke-opacity="0.7" stroke-width="1.5"/></svg>
SVG
render 260 36 "$work/entry.svg" "$out/entry.png"

# The prompt's box behind the lock and the entry: transparent (the prompt has no backdrop of its own), 340 x 72.
cat > "$work/box.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="340" height="72" viewBox="0 0 340 72"><rect width="340" height="72" fill="#000" fill-opacity="0"/></svg>
SVG
render 340 72 "$work/box.svg" "$out/box.png"

# A bullet of the typed password, white, 10 px.
cat > "$work/bullet.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#FFF"/></svg>
SVG
render 10 10 "$work/bullet.svg" "$out/bullet.png"

# The lock beside the entry: a closed padlock, white, 24 px (drawn here).
cat > "$work/lock.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M8 10V7.5a4 4 0 0 1 8 0V10" fill="none" stroke="#FFF" stroke-width="2" stroke-linecap="round"/><rect x="5" y="10" width="14" height="10" rx="2.5" fill="#FFF"/></svg>
SVG
render 24 24 "$work/lock.svg" "$out/lock.png"

# The throbber: twelve frames of eight dots in a ring, one bright dot going round, 32 px.
for i in $(seq 0 11); do
  python3 -I - "$i" > "$work/t.svg" <<'PY'
import math, sys
i = int(sys.argv[1])
dots = []
for k in range(8):
    a = 2 * math.pi * k / 8 - math.pi / 2
    x, y = 16 + 11 * math.cos(a), 16 + 11 * math.sin(a)
    on = (k == (i * 8 // 12) % 8)
    dots.append('<circle cx="%.2f" cy="%.2f" r="2.6" fill="#FFF" fill-opacity="%s"/>' % (x, y, "1" if on else "0.35"))
print('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">' + "".join(dots) + "</svg>")
PY
  render 32 32 "$work/t.svg" "$out/$(printf 'throbber-%04d.png' $((i + 1)))"
done

install -m644 "$here/grassfield.plymouth" "$out/grassfield.plymouth"
echo "plymouth: $(find "$out" -name '*.png' | wc -l) images in $out"
