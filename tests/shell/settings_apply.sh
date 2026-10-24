#!/usr/bin/env bash
# Settings apply end to end with the REAL unit environment (owner's real session, 2026-10-20: "nothing I change in
# Settings applies"). Runs tests/shell/settings_apply.d/apply.qml offscreen with the environment of
# packaging/systemd/grassfield-shell.service (QS_DISABLE_FILE_WATCHER=1, QS_NO_RELOAD_POPUP=1, GRASSFIELD_SESSION=1,
# no GRASSFIELD_DEV or GRASSFIELD_CONFIG_HOME) on a fresh account whose config directory does not exist yet. Each key
# of docs/specs/ui.md is written the way grassfield-settings writes it and the real Settings singleton must show it.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/settings-apply.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/home"
chmod 700 "$tmp/runtime" "$tmp/cache"
# The test shell.qml next to links to every module of the real shell (qs.services needs its siblings).
mkdir -p "$tmp/cfg"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/settings_apply.d/apply.qml "$tmp/cfg/shell.qml"
# $tmp/xdg stays absent: the shell must cope with a config directory that does not exist at start.
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u GRASSFIELD_CONFIG_HOME -u DISPLAY \
  QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 GRASSFIELD_SESSION=1 \
  HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
  timeout 150 qs -p "$tmp/cfg" --no-color 2>&1) || true
if grep -q "settings-apply: PASS" <<<"$out"; then
  grep "settings-apply:" <<<"$out"
  exit 0
fi
grep -E "settings-apply:|ERROR|WARN qml" <<<"$out" || echo "$out"
echo "FAIL: tests/shell/settings_apply.sh"
exit 1
