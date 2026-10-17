#!/usr/bin/env bash
# Direct build of grassfield-files with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-files. The dev binary reads the repository QML directory.
# Usage: apps/files/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
#        apps/files/build-direct.sh --tests             (only the FileLogic unit tests: .dev/build/files-unit-tests)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC)
# Build against the non-deprecated KF6 API only (also hides deprecated declarations in KIO headers).
kfdefs=(-DKF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00)

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" $(pkg-config --cflags Qt6Core) \
    "$root/tests/unit/files/tst_filelogic.cpp" "$root/tests/unit/files/tst_previewqueue.cpp" "$here/src/filelogic.cpp" \
    $(pkg-config --libs Qt6Core) -lgtest -lgtest_main -pthread \
    -o "$out/files-unit-tests"
  echo "built $out/files-unit-tests"
  exit 0
fi

defs=()
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_FILES_QML_DIR=\"$here/qml\"")
fi

# KDE Frameworks 6 ship CMake configs only (no pkg-config files): explicit include dirs and libraries.
kf=/usr/include/KF6
kf_includes=()
for d in KIOCore KIOGui KIOWidgets KIO KCoreAddons KService Solid; do
  kf_includes+=("-I$kf/$d")
done
kf_libs=(-lKF6KIOCore -lKF6KIOGui -lKF6KIOWidgets -lKF6CoreAddons -lKF6Service -lKF6Solid)

# QObjects with Q_OBJECT need moc.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
mocs=()
for h in foldermodel placesmodel filesapp; do
  "$moc" "${kf_includes[@]}" "$here/src/$h.h" -o "$out/moc_files_$h.cpp"
  mocs+=("$out/moc_files_$h.cpp")
done

# Compile the translation units in parallel (KIO headers are heavy), then link.
objdir=$out/files-obj
mkdir -p "$objdir"
read -r -a qt_cflags <<<"$(pkg-config --cflags Qt6Widgets Qt6Gui Qt6Qml Qt6Quick)"
read -r -a qt_libs <<<"$(pkg-config --libs Qt6Widgets Qt6Gui Qt6Qml Qt6Quick)"
sources=("$here/src/main.cpp" "$here/src/filesapp.cpp" "$here/src/foldermodel.cpp" "$here/src/placesmodel.cpp"
  "$here/src/imageproviders.cpp" "$here/src/filelogic.cpp" "${mocs[@]}")
pids=() objs=()
for src in "${sources[@]}"; do
  obj=$objdir/$(basename "${src%.cpp}").o
  objs+=("$obj")
  g++ "${cxxflags[@]}" "${kfdefs[@]}" "${defs[@]}" -I"$here/src" -I"$out" "${kf_includes[@]}" "${qt_cflags[@]}" \
    -c "$src" -o "$obj" &
  pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
[[ $status -eq 0 ]] || { echo "build-direct: compilation failed" >&2; exit 1; }
g++ "${objs[@]}" "${qt_libs[@]}" "${kf_libs[@]}" -o "$out/grassfield-files"
echo "built $out/grassfield-files"
