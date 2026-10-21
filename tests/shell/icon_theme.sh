#!/usr/bin/env bash
# ADR-0017 (spike I0 turned into a test): the Grassfield session icon theme.
#  * packaging/uwsm/env-grassfield sets QT_QPA_SYSTEM_ICON_THEME and nothing else that matters;
#  * scripts/dev/devenv.sh installs the wrapper into .dev/share/icons and selects it;
#  * the wrapper's index.theme: Inherits=breeze,Adwaita,hicolor and one directory that exists once installed;
#  * Qt (QIcon::fromTheme) and GTK 3/4 resolve through the wrapper: Breeze stand-in first, then Adwaita, then hicolor;
#    the variable beats QT_QPA_PLATFORMTHEME-less defaults;
#  * with the installed Breeze and Adwaita (when present) a Breeze icon wins over Adwaita and hicolor through the wrapper.
# Fixture themes are solid-colour PNGs in a temporary XDG_DATA_DIRS. No display, no D-Bus, no dconf.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/icon-theme.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
theme=$root/branding/icons/theme/index.theme
envfile=$root/packaging/uwsm/env-grassfield

desc="wrapper index.theme inherits breeze,Adwaita,hicolor"
check grep -qx 'Inherits=breeze,Adwaita,hicolor' "$theme"
desc="wrapper index.theme lists a Directories key (GTK drops a theme without one)"
check grep -q '^Directories=scalable/apps$' "$theme"

desc="env-grassfield exports QT_QPA_SYSTEM_ICON_THEME=grassfield-icons"
check bash -c 'out=$(env -i sh -c ". \"$1\"; echo \"\$QT_QPA_SYSTEM_ICON_THEME\"") && [ "$out" = grassfield-icons ]' _ "$envfile"

# devenv.sh in a throwaway repository.
fake=$tmp/repo
mkdir -p "$fake/scripts/dev" "$fake/branding/icons/theme" "$fake/.dev/share/icons"
cp "$root/scripts/dev/devenv.sh" "$fake/scripts/dev/"
cp "$theme" "$fake/branding/icons/theme/"
git -C "$fake" init -q
env_of() { env -i PATH="$PATH" HOME=/nonexistent bash -c '. "$1"; . "$1"; env' _ "$fake/scripts/dev/devenv.sh"; }
out=$(env_of)
desc="devenv.sh selects grassfield-icons"
check grep -qx 'QT_QPA_SYSTEM_ICON_THEME=grassfield-icons' <<<"$out"
desc="devenv.sh installs the wrapper with its real scalable/apps directory"
check bash -c 'cmp -s "$1/branding/icons/theme/index.theme" "$1/.dev/share/icons/grassfield-icons/index.theme" && [ -d "$1/.dev/share/icons/grassfield-icons/scalable/apps" ]' _ "$fake"

# Fixture themes: breeze, Adwaita, hicolor (solid colours, named as the wrapper's Inherits).
fix() { # dir
  python3 -I - "$1" "$theme" <<'PY'
import os, struct, sys, zlib
root, wrapper = sys.argv[1], sys.argv[2]
def png(rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * 16 for _ in range(16))
    def ch(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
def theme(name, inherits, icons):
    d = os.path.join(root, "icons", name)
    os.makedirs(d + "/16x16/apps", exist_ok=True)
    idx = ["[Icon Theme]", "Name=" + name] + (["Inherits=" + inherits] if inherits else []) + \
          ["Directories=16x16/apps", "", "[16x16/apps]", "Size=16", "Type=Fixed", "Context=Applications"]
    open(d + "/index.theme", "w").write("\n".join(idx) + "\n")
    for n, rgb in icons.items():
        open(d + "/16x16/apps/" + n + ".png", "wb").write(png(rgb))
R, G, B = (255, 0, 0), (0, 255, 0), (0, 0, 255)
theme("Adwaita", "hicolor", {"both": G, "only-adw": G})
theme("hicolor", None, {"both": B, "only-hi": B})
theme("breeze", "hicolor", {"both": R, "only-br": R})
w = os.path.join(root, "icons", "grassfield-icons")
os.makedirs(w + "/scalable/apps", exist_ok=True)
open(w + "/index.theme", "w").write(open(wrapper).read())
PY
}
fix "$tmp/fx"

# Qt: compile the probe once (skipped without a compiler or Qt headers).
probe=$tmp/icon_probe
if command -v g++ >/dev/null && [[ -f /usr/include/qt6/QtGui/QIcon ]]; then
  g++ -std=c++20 -fPIC -o "$probe" "$root/tests/shell/icon_probe.cpp" -I/usr/include/qt6 -I/usr/include/qt6/QtGui -I/usr/include/qt6/QtCore -lQt6Gui -lQt6Core
  qt() { env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" QT_QPA_PLATFORM=offscreen XDG_DATA_DIRS="$1" QT_QPA_SYSTEM_ICON_THEME="${2-}" "$probe" both only-br only-adw only-hi missing; }
  out=$(qt "$tmp/fx" grassfield-icons)
  desc="Qt: theme name, Breeze first, Adwaita, then hicolor ($(tr '\n' ' ' <<<"$out"))"
  check bash -c 'grep -qx "theme=grassfield-icons" <<<"$1" && grep -qx "both=#ff0000" <<<"$1" && grep -qx "only-br=#ff0000" <<<"$1" && grep -qx "only-adw=#00ff00" <<<"$1" && grep -qx "only-hi=#0000ff" <<<"$1" && grep -qx "missing=-" <<<"$1"' _ "$out"
  out=$(qt "$tmp/fx" "")
  desc="Qt: an empty QT_QPA_SYSTEM_ICON_THEME is ignored (no theme selected)"
  check grep -qx 'theme=' <<<"$out"
else
  echo "SKIP: Qt icon resolution (g++ or Qt headers missing)"
fi

# GTK 3 and 4 (PyGObject, no display).
if python3 -c 'import gi; gi.require_version("Gtk","3.0")' 2>/dev/null && python3 -c 'import gi; gi.require_version("Gtk","4.0")' 2>/dev/null; then
  for v in 3 4; do
    gtk() { env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" GSETTINGS_BACKEND=memory python3 -I "$root/tests/shell/icon_probe_gtk.py" "$v" "$1/icons" "$2" both only-br only-adw only-hi 2>/dev/null; }
    out=$(gtk "$tmp/fx" grassfield-icons)
    desc="GTK$v: Breeze, Adwaita, hicolor ($(tr '\n' ' ' <<<"$out"))"
    check bash -c 'grep -qx "both=breeze/16x16/apps/both.png" <<<"$1" && grep -qx "only-br=breeze/16x16/apps/only-br.png" <<<"$1" && grep -qx "only-adw=Adwaita/16x16/apps/only-adw.png" <<<"$1" && grep -qx "only-hi=hicolor/16x16/apps/only-hi.png" <<<"$1"' _ "$out"
  done
else
  echo "SKIP: GTK icon resolution (PyGObject with Gtk 3 and 4 missing)"
fi


# ---- The installed themes (Omarchy ships Breeze and Adwaita): through the wrapper, an icon that Breeze has comes from
# Breeze, one that only Adwaita has comes from Adwaita, a name neither has resolves to nothing. GTK 3 and 4, no display.
if python3 -c 'import gi; gi.require_version("Gtk","3.0")' 2>/dev/null && python3 -c 'import gi; gi.require_version("Gtk","4.0")' 2>/dev/null \
   && [[ -d /usr/share/icons/breeze && -d /usr/share/icons/Adwaita ]]; then
  real=$tmp/real
  mkdir -p "$real/icons/grassfield-icons/scalable/apps"
  for t in Adwaita breeze hicolor; do ln -s "/usr/share/icons/$t" "$real/icons/$t"; done
  cp "$theme" "$real/icons/grassfield-icons/index.theme"
  for v in 3 4; do
    out=$(env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" GSETTINGS_BACKEND=memory python3 -I "$root/tests/shell/icon_probe_gtk.py" "$v" "$real/icons" grassfield-icons folder system-file-manager no-such-icon-gf 2>/dev/null)
    desc="GTK$v on the installed themes: folder from Breeze or Adwaita, never from another theme, an unknown name to nothing ($(tr '\n' ' ' <<<"$out" | cut -c1-200))"
    check bash -c 'grep -qE "^folder=(breeze|Adwaita)/" <<<"$1" && grep -qE "^system-file-manager=(breeze|Adwaita)/" <<<"$1" && grep -qx "no-such-icon-gf=-" <<<"$1"' _ "$out"
    desc="GTK$v on the installed themes: Breeze wins over Adwaita for folder"
    check grep -qE '^folder=breeze/' <<<"$out"
  done
else
  echo "SKIP: installed Breeze and Adwaita through the wrapper (PyGObject with Gtk 3 and 4, or the themes, missing)"
fi
exit "$fail"
