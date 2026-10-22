#!/usr/bin/env bash
# The status area's StatusNotifierItem host (shell/menubar/TrayHost.qml, Quickshell SystemTray) end to end, offscreen, on a
# PRIVATE session bus: tests/shell/tray_host.d/host.qml starts test items (tests/fixtures/status-item.py) and checks the slots
# (same id twice, Passive hidden, status change, a dead item), the SNI calls and the DBusMenu rows and click.
# The StatusNotifierWatcher is owned by the shell under test, so this must never run on the owner's bus: the script starts
# its own dbus-daemon and refuses to continue unless the address is in the temp directory.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v dbus-daemon >/dev/null || { echo "SKIP: tests/integration/tray_host.sh (dbus-daemon not installed)"; exit 0; }
python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { echo "SKIP: tests/integration/tray_host.sh (python3 gi not installed)"; exit 0; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gf-tray.XXXXXX")
bus_pid=""
cleanup() {
  [[ -z $bus_pid ]] || kill "$bus_pid" 2>/dev/null || true
  pkill -f "status-item.py --log $tmp" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/home" "$tmp/cfg"
chmod 700 "$tmp/runtime" "$tmp/cache" "$tmp"
setsid dbus-daemon --session --nofork --print-address=1 >"$tmp/bus.address" 2>"$tmp/bus.log" </dev/null &
bus_pid=$!
for _ in $(seq 1 50); do [[ -s $tmp/bus.address ]] && break; sleep 0.1; done
bus=$(head -n 1 "$tmp/bus.address")
case $bus in
  unix:path=/run/user/*) echo "FAIL: refusing the owner's bus $bus"; exit 1 ;;
  unix:*) ;;
  *) echo "FAIL: no private bus ($bus)"; cat "$tmp/bus.log"; exit 1 ;;
esac
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/tray_host.d/host.qml "$tmp/cfg/shell.qml"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u GRASSFIELD_SESSION \
  DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_PRIVATE_BUS=1 GF_TEST_DIR="$tmp" GF_FIXTURE="$root/tests/fixtures/status-item.py" \
  HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
  GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
  timeout 90 qs -p "$tmp/cfg" --no-color 2>&1) || true
if grep -q "tray-test: PASS" <<<"$out"; then
  grep -E "tray-test: (ok|PASS)" <<<"$out"
  echo "PASS: tests/integration/tray_host.sh"
  exit 0
fi
grep -E "tray-test:|ERROR|WARN qml" <<<"$out" || echo "$out"
echo "FAIL: tests/integration/tray_host.sh"
exit 1
