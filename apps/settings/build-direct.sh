#!/usr/bin/env bash
# Direct build of grassfield-settings with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-settings. The dev binary reads the repository QML directory.
# Usage: apps/settings/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

if [[ ${1:-} == "--tests" ]]; then
  # The dev guard of the system sections and the wallpaper helper door (systemguard.cpp) and the Wi-Fi/Bluetooth logic over
  # D-Bus (systembus.cpp, against a canned bus: no bus needed): Qt Core and the Qt DBus types only.
  # --asan: the same with -fsanitize=address,undefined (.dev/build/settings-unit-tests-asan).
  extra=()
  suffix=""
  if [[ ${2:-} == "--asan" ]]; then
    extra=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
    suffix="-asan"
  fi
  # shellcheck disable=SC2046
  g++ -std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "${extra[@]}" -I"$here/src" -I"$here/.." $(pkg-config --cflags Qt6Core Qt6DBus) \
    "$root/tests/unit/settings/tst_systemguard.cpp" "$root/tests/unit/settings/tst_systembus.cpp" "$here/src/systemguard.cpp" "$here/src/systembus.cpp" "$here/src/busjobs.cpp" "$root/tests/unit/settings/tst_busjobs.cpp" \
    $(pkg-config --libs Qt6Core Qt6DBus) -lgtest -lgtest_main -pthread -o "$out/settings-unit-tests$suffix"
  echo "built $out/settings-unit-tests$suffix"
  exit 0
fi

defs=("-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # the one version source
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_SETTINGS_QML_DIR=\"$here/qml\"" "-DGRASSFIELD_DEV_BINDINGS=\"$root/config/hypr/grassfield/bindings.lua\"")
fi

# QObject with Q_OBJECT needs moc.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$here/src/backend.h" -o "$out/moc_backend.cpp"

# shellcheck disable=SC2046
g++ -std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "${defs[@]}" \
  -I"$here/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" \
  $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus) $(pkg-config --cflags wayland-client) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui)/QtGui -I/usr/include/qt6/QtCore/$(pkg-config --modversion Qt6Gui) \
  "$here/src/main.cpp" "$here/src/backend.cpp" "$here/src/systemguard.cpp" "$here/src/systembus.cpp" "$here/src/busjobs.cpp" "$out/moc_backend.cpp" \
  $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lwayland-client \
  -o "$out/grassfield-settings"
echo "built $out/grassfield-settings"
