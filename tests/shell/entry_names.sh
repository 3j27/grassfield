#!/usr/bin/env bash
# Test for shell/launchpad/entry-names.sh with a temporary XDG tree under .dev/ (or $GRASSFIELD_TEST_TMP): each entry's Name,
# GenericName, Comment and Keywords in the language given, as the Desktop Entry Specification picks them, whatever LANG says.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/entry-names.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
sys=$tmp/sys/applications
home=$tmp/home/applications
mkdir -p "$home" "$sys/sub"
fail=0
check() { # <description> <got> <want>
  if [[ $2 == "$3" ]]; then echo "PASS entry-names: $1"; else echo "FAIL entry-names: $1: got '$2' want '$3'"; fail=1; fi
}
printf '[Desktop Entry]\nName=Files\nName[fr]=Fichiers\nName[fr_CA]=Fichiers (CA)\nName[de]=Dateien\nGenericName=File Manager\nGenericName[fr]=Gestionnaire de fichiers\nComment=Browse your files\nKeywords=folder;disk;\nKeywords[fr]=dossier;disque;\n[Desktop Action window]\nName=New Window\nName[fr]=Nouvelle fenêtre\n' >"$sys/files.desktop"
printf '[Desktop Entry]\nName=Plain\nComment=Not localized\n[Desktop Action a]\nName[fr]=Action\n' >"$sys/plain.desktop"
printf '[Desktop Entry]\nName=Mod\nName[sr]=Plain sr\nName[sr@latin]=Latin sr\n' >"$sys/mod.desktop"
printf '[Desktop Entry]\r\nName = Spaced\r\nName[fr] = Avec\\sespace\\tet\\\\barre\r\n' >"$sys/crlf.desktop"
printf '[Desktop Entry]\nName=Nested\nName[fr]=Imbriquée\n' >"$sys/sub/nested.desktop"
printf '[Desktop Entry]\nName=Shadowed\nName[fr]=Système\n' >"$sys/shadow.desktop"
printf '[Desktop Entry]\nName=Shadowed\nName[fr]=Utilisateur\n' >"$home/shadow.desktop"
mkdir -p "$tmp/linked"
printf '[Desktop Entry]\nName=Linked\nName[fr]=Lié\n' >"$tmp/linked/x.desktop"
ln -s "$tmp/linked" "$sys/link"
printf '[Desktop Entry]\nName=Newline\nName[fr]=Saut\n' >"$sys/with
newline.desktop"
run() { XDG_DATA_HOME=$tmp/home XDG_DATA_DIRS=$tmp/sys LANG=en_US.UTF-8 LC_MESSAGES= sh "$root/shell/launchpad/entry-names.sh" "$@"; }
field() { # <output> <id> <field 2..5>
  awk -F '\t' -v id="$2" -v n="$3" '$1 == id { print $n; found = 1 } END { if (!found) print "(absent)" }' <<<"$1"
}
fr=$(run fr_FR)
check "fr_FR: Name[fr] whatever LANG says" "$(field "$fr" files 2)" "Fichiers"
check "fr_FR: GenericName[fr]" "$(field "$fr" files 3)" "Gestionnaire de fichiers"
check "fr_FR: Comment without a French value is the unlocalized one" "$(field "$fr" files 4)" "Browse your files"
check "fr_FR: Keywords[fr] as written" "$(field "$fr" files 5)" "dossier;disque;"
check "fr_CA: Name[fr_CA] before Name[fr]" "$(field "$(run fr_CA.UTF-8)" files 2)" "Fichiers (CA)"
check "de: Name[de]" "$(field "$(run de_DE)" files 2)" "Dateien"
check "en: the unlocalized Name (an entry localized for others)" "$(field "$(run en_US)" files 2)" "Files"
check "sr@latin: Name[sr@latin] before Name[sr]" "$(field "$(run sr_RS@latin)" mod 2)" "Latin sr"
check "sr: Name[sr], never a modifier's" "$(field "$(run sr_RS)" mod 2)" "Plain sr"
check "an entry that localizes nothing in [Desktop Entry] is not printed" "$(field "$fr" plain 2)" "(absent)"
check "a [Desktop Action] group is not read" "$(field "$fr" files 2)" "Fichiers"
check "CRLF, spaces around =, escapes decoded" "$(field "$fr" crlf 2)" 'Avec espace et\barre'
check "a subfolder's id" "$(field "$fr" sub-nested 2)" "Imbriquée"
check "XDG_DATA_HOME shadows XDG_DATA_DIRS" "$(field "$fr" shadow 2)" "Utilisateur"
check "a symlinked folder" "$(field "$fr" link-x 2)" "Lié"
check "a file name with a newline is skipped" "$(grep -c Saut <<<"$fr" || true)" "0"
check "a language that is not one: the unlocalized values" "$(field "$(run 'fr;rm')" files 2)" "Files"
check "no language: the unlocalized values" "$(field "$(run '')" files 2)" "Files"
check "every line has five tab-separated fields" "$(awk -F '\t' 'NF != 5' <<<"$fr" | wc -l | tr -d ' ')" "0"

# The real shell (services/Apps.qml on Quickshell's DesktopEntries): the Grassfield entries as shipped, LANG English, the
# shell French (GRASSFIELD_LANG). Quickshell picks the English values from LANG; the names the shell shows must be French.
if ! command -v qs >/dev/null; then
  echo "SKIP entry-names: the live check needs qs"
  exit "$fail"
fi
live=$tmp/live
mkdir -p "$live/sys/applications" "$live/home/applications" -m 700 "$live/runtime" "$live/cache"
cp "$root"/apps/{files,settings,preview,store}/org.grassfield.*.desktop "$live/sys/applications/"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME -u LC_ALL -u LC_MESSAGES -u LANGUAGE \
  LANG=en_US.UTF-8 GRASSFIELD_LANG=fr_FR GRASSFIELD_SESSION=1 QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  XDG_DATA_HOME="$live/home" XDG_DATA_DIRS="$live/sys" XDG_RUNTIME_DIR="$live/runtime" XDG_CACHE_HOME="$live/cache" \
  /usr/bin/timeout 60 qs -p "$root/tests/shell/entry_names/probe.qml" --no-color 2>&1) || true
grep -E "entry-names-live" <<<"$out" || echo "$out" | tail -20
if grep -q "entry-names-live: PASS" <<<"$out"; then echo "PASS entry-names: the shell shows the names in its language"; else echo "FAIL entry-names: live"; fail=1; fi
exit "$fail"
