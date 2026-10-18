#!/usr/bin/env bash
# Direct build of grassfield-settings with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-settings. The dev binary reads the repository QML directory.
# Usage: apps/settings/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

defs=()
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_SETTINGS_QML_DIR=\"$here/qml\"" "-DGRASSFIELD_DEV_BINDINGS=\"$root/config/hypr/grassfield/bindings.lua\"")
fi

# QObject with Q_OBJECT needs moc.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$here/src/backend.h" -o "$out/moc_backend.cpp"

# shellcheck disable=SC2046
g++ -std=c++17 -O2 -Wall -Wextra -fPIC "${defs[@]}" \
  -I"$here/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" \
  $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus) \
  "$here/src/main.cpp" "$here/src/backend.cpp" "$here/src/systemguard.cpp" "$out/moc_backend.cpp" \
  $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) \
  -o "$out/grassfield-settings"
echo "built $out/grassfield-settings"
