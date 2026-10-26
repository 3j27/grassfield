#!/usr/bin/env bash
# Re-review of 2b8e13a (minor 3): the lock screen's and the polkit sheet's strings never come from a catalog directory
# the environment picks outside a dev session. ui/i18n/translationloader.h honours GRASSFIELD_TRANSLATIONS_DIR (dev
# plumbing, ADR-0019) only when GRASSFIELD_DEV is exactly "1" and GRASSFIELD_SESSION is not "1". Offscreen, with the
# Grassfield.I18n plugin of this tree and a hostile catalog (grassfield_fr.qm translating IconMenu "Rename" to
# "HOSTILE") named by GRASSFIELD_TRANSLATIONS_DIR:
#   dev session                      -> "HOSTILE" (control: the variable works where it is meant to)
#   real session (SESSION=1, DEV=1)  -> never "HOSTILE"
#   neither variable                 -> never "HOSTILE"
# SKIP without lrelease. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
lrelease=/usr/lib/qt6/bin/lrelease
if [[ ! -x $lrelease ]]; then
  echo "SKIP: translations dir: lrelease missing: NOT VERIFIED"
  exit 0
fi
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/translations-dir.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache"
mkdir -p "$tmp/home" "$tmp/hostile" "$tmp/cfg"
ui/i18n/build-direct.sh >/dev/null
cp tests/security/translations_dir.d/probe.qml "$tmp/cfg/shell.qml"
cat >"$tmp/hostile.ts" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE TS>
<TS version="2.1" language="fr">
<context>
    <name>IconMenu</name>
    <message>
        <source>Rename</source>
        <translation>HOSTILE</translation>
    </message>
</context>
</TS>
EOF
"$lrelease" -silent "$tmp/hostile.ts" -qm "$tmp/hostile/grassfield_fr.qm"

fail=0
run() { # <label> <expect hostile|clean> env...
  local label=$1 expect=$2 out line
  shift 2
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_DEV -u GRASSFIELD_SESSION \
    HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" QT_QPA_PLATFORM=offscreen GRASSFIELD_LANG=en \
    QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_TRANSLATIONS_DIR="$tmp/hostile" "$@" \
    timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
  line=$(grep -o "translations: .*" <<<"$out" | head -n 1 || true)
  local ok=0
  case $expect in
    hostile) [[ $line == "translations: rename=HOSTILE" ]] && ok=1 ;;
    clean) [[ -n $line && $line != *HOSTILE* ]] && ok=1 ;;
  esac
  if ((ok)); then echo "PASS: translations dir $label ($line)"; else echo "FAIL: translations dir $label: ${line:-no probe line} $(grep -E 'ERROR|TypeError' <<<"$out" | head -n 2)"; fail=1; fi
}

run "control: a dev session reads the catalogs GRASSFIELD_TRANSLATIONS_DIR names" hostile GRASSFIELD_DEV=1
run "a real session (GRASSFIELD_SESSION=1, a leaked GRASSFIELD_DEV=1) ignores it" clean GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1
run "without the dev variables it is ignored" clean
run "a near-miss GRASSFIELD_DEV value is not dev" clean GRASSFIELD_DEV=true
exit $fail
