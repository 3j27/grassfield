#!/usr/bin/env bash
# Keyboard layout names in the shell's language (capture defect 10): shell/platform/layout-names.py against a catalog of the
# test's own (built with msgfmt in a scratch locale directory, GRASSFIELD_XKB_LOCALEDIR), then the same helper through
# platform/InputSource.qml in tests/shell/input_source_names.d/body.qml (offscreen, a dev session). The system catalog is
# checked too, where it is installed (xkeyboard-config ships it): "English (US)" must not stay English in French.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
check() { # <description> <got> <want>
  if [[ $2 == "$3" ]]; then echo "PASS input_source_names: $1"; else echo "FAIL input_source_names: $1: got '$2' want '$3'"; fail=1; fi
}
if ! command -v msgfmt >/dev/null; then
  echo "SKIP input_source_names: msgfmt (gettext) is not installed"
  exit 0
fi
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/input-source-names.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
loc=$tmp/locale
mkdir -p "$loc/fr/LC_MESSAGES" "$loc/de/LC_MESSAGES" "$tmp/runtime" "$tmp/cache" "$tmp/cfg"
chmod 700 "$tmp/runtime" "$tmp/cache"
cat >"$tmp/fr.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
"Language: fr\n"

msgid "English (US)"
msgstr "Anglais (US)"

msgid "German"
msgstr "Allemand"

msgid "Zzz Test Layout"
msgstr "Couche de test"
EOF
msgfmt -o "$loc/fr/LC_MESSAGES/xkeyboard-config-2.mo" "$tmp/fr.po"
# The older domain name holds one more name: both are read, the newer one first.
cat >"$tmp/fr-old.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"
"Language: fr\n"

msgid "Polish"
msgstr "Polonais"
EOF
msgfmt -o "$loc/fr/LC_MESSAGES/xkeyboard-config.mo" "$tmp/fr-old.po"

helper=shell/platform/layout-names.py
run() { env -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_XKB_LOCALEDIR=$loc python3 -I "$helper" "$@" | paste -sd'|'; }
check "fr: translated names, in order" "$(run fr 'English (US)' 'German')" "Anglais (US)|Allemand"
check "fr_FR.UTF-8 falls back to fr" "$(run fr_FR.UTF-8 'German')" "Allemand"
check "the older domain is read too" "$(run fr 'Polish')" "Polonais"
check "an unknown name stays as it is" "$(run fr 'Klingon (X)')" "Klingon (X)"
check "English is untouched" "$(run en 'English (US)')" "English (US)"
check "a language without a catalog is untouched" "$(run de 'German')" "German"
check "a malformed language is untouched" "$(run 'fr;rm -rf' 'German')" "German"
check "no language" "$(run '' 'German')" "German"
check "no name prints nothing" "$(run fr)" ""
check "a name with a newline is one line" "$(run fr $'German\nx')" "German x"

# The catalog directory of a test is honoured in a development session only (review MINOR 4).
check "a test catalog is ignored outside a dev session" "$(env -u GRASSFIELD_SESSION -u GRASSFIELD_DEV GRASSFIELD_XKB_LOCALEDIR=$loc python3 -I "$helper" fr "Zzz Test Layout")" "Zzz Test Layout"
check "the test catalog is read in a dev session" "$(run fr "Zzz Test Layout")" "Couche de test"
check "a test catalog is ignored in a real session" "$(env GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1 GRASSFIELD_XKB_LOCALEDIR=$loc python3 -I "$helper" fr "Zzz Test Layout")" "Zzz Test Layout"
# A catalog that does not parse never crashes the helper: the names as given (a truncated file raises struct.error, not OSError).
mkdir -p "$tmp/bad/fr/LC_MESSAGES"
head -c 30 "$loc/fr/LC_MESSAGES/xkeyboard-config-2.mo" >"$tmp/bad/fr/LC_MESSAGES/xkeyboard-config-2.mo"
printf 'not a catalog at all' >"$tmp/bad/fr/LC_MESSAGES/xkeyboard-config.mo"
bad=$(env -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_XKB_LOCALEDIR=$tmp/bad python3 -I "$helper" fr "Zzz Test Layout" 2>&1); rc=$?
check "a truncated or garbage catalog gives the names as given (exit $rc)" "$bad|$rc" "Zzz Test Layout|0"

# The system catalog, where it is installed.
if [[ -f /usr/share/locale/fr/LC_MESSAGES/xkeyboard-config-2.mo || -f /usr/share/locale/fr/LC_MESSAGES/xkeyboard-config.mo ]]; then
  sys=$(python3 -I "$helper" fr_FR 'English (US)' 'French (AZERTY)' | paste -sd'|')
  check "system catalog: English (US), French (AZERTY)" "$sys" "Anglais (US)|Français (AZERTY)"
else
  echo "SKIP input_source_names: no French xkeyboard-config catalog installed"
fi

# Through InputSource.qml.
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/input_source_names.d/body.qml "$tmp/cfg/shell.qml"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_XKB_LOCALEDIR="$loc" GRASSFIELD_LANG=en \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1 || true)
echo "$out" | grep -E "PASS|FAIL" || { echo "$out"; fail=1; }
grep -q FAIL <<<"$out" && fail=1

# A helper that blocks (a catalog that is a FIFO nobody writes) is stopped by the timeout and the English name is shown.
mkdir -p "$tmp/hang/fr/LC_MESSAGES" "$tmp/cfg2"
mkfifo "$tmp/hang/fr/LC_MESSAGES/xkeyboard-config-2.mo"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg2/$(basename "$entry")"
done
cp tests/shell/input_source_names.d/hang.qml "$tmp/cfg2/shell.qml"
out2=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_SESSION GRASSFIELD_DEV=1 GRASSFIELD_XKB_LOCALEDIR="$tmp/hang" GRASSFIELD_LANG=en \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" timeout 60 qs -p "$tmp/cfg2" --no-color 2>&1 || true)
echo "$out2" | grep -E "PASS|FAIL" || { echo "$out2"; fail=1; }
grep -q FAIL <<<"$out2" && fail=1
exit $fail
