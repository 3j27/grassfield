#!/usr/bin/env bash
# Direct build of the Grassfield.I18n QML module with g++ + moc + qmltyperegistrar (no CMake needed).
# Output: .dev/build/qml/Grassfield/I18n (put .dev/build/qml on QML_IMPORT_PATH). Skipped when up to date.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build/qml/Grassfield/I18n
obj=$root/.dev/build/i18n-obj
mkdir -p "$out" "$obj"

lib=$out/libgrassfield_i18nplugin.so
if [[ -f $lib && -f $out/qmldir && -f $out/plugin.qmltypes ]]; then
  newer=$(find "$here" -maxdepth 1 \( -name '*.cpp' -o -name '*.h' \) -newer "$lib" -print -quit)
  [[ -n $newer ]] || exit 0
fi

moc=/usr/lib/qt6/moc
reg=/usr/lib/qt6/qmltyperegistrar
metatypes=/usr/lib/qt6/metatypes

qtflags=$(pkg-config --cflags Qt6Core Qt6Qml)
# shellcheck disable=SC2086
"$moc" $qtflags --output-json "$here/translator.h" -o "$obj/moc_translator.cpp"
foreign=()
for f in "$metatypes"/qt6core_*_metatypes.json "$metatypes"/qt6qml_*_metatypes.json; do
  [[ -f $f ]] && foreign+=("--foreign-types=$f")
done
"$reg" "${foreign[@]}" --generate-qmltypes="$out/plugin.qmltypes" --import-name=Grassfield.I18n \
  --major-version=1 --minor-version=0 -o "$obj/registration.cpp" "$obj/moc_translator.cpp.json"

cp "$here/plugin.cpp" "$obj/plugin.cpp"
"$moc" $qtflags -I"$here" "$obj/plugin.cpp" -o "$obj/plugin.moc"

cat > "$out/qmldir" <<'QMLDIR'
module Grassfield.I18n
plugin grassfield_i18nplugin
typeinfo plugin.qmltypes
QMLDIR

# shellcheck disable=SC2046
g++ -std=c++17 -O2 -Wall -Wextra -fPIC -shared -I"$here" -I"$obj" \
  $(pkg-config --cflags Qt6Core Qt6Qml) \
  "$here/translator.cpp" "$obj/moc_translator.cpp" "$obj/registration.cpp" "$obj/plugin.cpp" \
  $(pkg-config --libs Qt6Core Qt6Qml) -o "$lib"
echo "built $lib"
