#!/usr/bin/env bash
# Build ui/i18n with CMake (the build packaging/arch/PKGBUILD uses), install it into a temp prefix under
# .dev/ and run tests/shell/i18n_live against the INSTALLED module: the plugin .so must be a loadable Qt
# plugin and the catalogs must be installed. Prints "i18n-cmake: PASS" and exits 0, else exits 1.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
build=$root/.dev/i18n-cmake
dest=$root/.dev/i18n-cmake-install
rm -rf "$dest"
cmake -S ui/i18n -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null
cmake --build "$build" >/dev/null
DESTDIR="$dest" cmake --install "$build" >/dev/null
mod=$dest/usr/lib/qt6/qml/Grassfield/I18n
[[ -f $mod/qmldir && -f $mod/libgrassfield_i18nplugin.so ]] || { echo "FAIL: i18n-cmake: module not installed in $mod"; exit 1; }
# The backing library is static: nothing but the plugin may be needed at run time.
if ldd "$mod/libgrassfield_i18nplugin.so" | grep -q 'libgrassfield_i18n\.so'; then
  echo "FAIL: i18n-cmake: plugin links a shared backing library that is not installed"; exit 1
fi
[[ -f $dest/usr/share/grassfield/translations/grassfield_fr.qm ]] || { echo "FAIL: i18n-cmake: catalogs not installed"; exit 1; }
tmp=$(mktemp -d "$root/.dev/i18n-cmake-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u QT_QPA_PLATFORMTHEME QT_QPA_PLATFORM=offscreen \
  QML_IMPORT_PATH="$dest/usr/lib/qt6/qml" GRASSFIELD_TRANSLATIONS_DIR="$dest/usr/share/grassfield/translations" GRASSFIELD_LANG=en \
  XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" timeout 60 qs -p tests/shell/i18n_live --no-color 2>&1) \
  || { echo "$out"; echo "FAIL: i18n-cmake: i18n_live"; exit 1; }
grep -q "i18n-live: PASS" <<<"$out" || { echo "$out"; echo "FAIL: i18n-cmake: i18n_live did not pass"; exit 1; }
echo "i18n-cmake: PASS (installed module $mod)"
