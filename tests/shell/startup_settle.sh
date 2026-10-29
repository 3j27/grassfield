#!/usr/bin/env bash
# Startup settle, store side (review of fix/startup-settle): `Settings.loaded` is the signal the Dock and the desktop wait for. With the
# REAL Settings service (tests/shell/startup_settle.d/shell.qml, a dev session under `env -i`, every directory under a mktemp -d):
#  1. no grassfield.json (a fresh account): `loaded` still becomes true;
#  2. a file with values: they are already the document's when `loaded` flips (not the defaults);
#  3. a desktop icon whose launcher file never reads (a FIFO) is hidden at first and visible after desktopIcon.loadTimeout.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/startup-settle.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
run() { # <yes|no|icon>
  rm -rf "$tmp/runtime" "$tmp/config" "$tmp/state" "$tmp/home"
  mkdir -p "$tmp/runtime" "$tmp/home" "$tmp/state" "$tmp/config" "$tmp/cfg"
  chmod 700 "$tmp/runtime"
  if [[ $1 == yes ]]; then
    printf '{"version":1,"dock":{"folders":["/tmp/settle-x"],"pinned":["foot"]}}\n' >"$tmp/config/grassfield.json"
  fi
  rm -rf "$tmp/cfg"; mkdir -p "$tmp/cfg"
  for entry in shell/*; do
    [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
  done
  if [[ $1 == icon ]]; then
    cp tests/shell/startup_settle.d/icon.qml "$tmp/cfg/shell.qml"
    rm -f "$tmp/fifo"; mkfifo "$tmp/fifo"
  else
    cp tests/shell/startup_settle.d/shell.qml "$tmp/cfg/shell.qml"
  fi
  env -i ICON_FIFO="$tmp/fifo" PATH="$PATH" HOME="$tmp/home" GRASSFIELD_DEV=1 QS_NO_RELOAD_POPUP=1 XDG_RUNTIME_DIR="$tmp/runtime" EXPECT_FILE="$1" \
    GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" QT_QPA_PLATFORM=offscreen \
    QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en timeout 60 qs -p "$tmp/cfg" --no-color 2>&1
}
for want in no yes icon; do
  out=$(run "$want") || true
  if grep -qE "startup-settle(-icon)?: PASS" <<<"$out"; then
    echo "PASS: $want"
  else
    echo "FAIL: $want"
    grep -E "startup-settle(-icon)?:|ERROR|TypeError|ReferenceError" <<<"$out" || echo "$out" | tail -20
    fail=1
  fi
done
exit $fail
