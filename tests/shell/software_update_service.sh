#!/usr/bin/env bash
# Software Update's shell service (ADR-0033 d; docs/specs/updates.md U4, U10, U20, A9) under the real Quickshell, offscreen,
# with a fake checker: the steps of tests/shell/software_update_service/probe.qml, then from here the IPC target `update`
# (`update check bogus` refused, `update check user` runs a check) and software-update.json's mode (0600, folder 0700);
# then stale.qml: a stored `update-running` is checked as soon as the service reads it.
# A dev session (GRASSFIELD_UPDATE_CHECK_CMD is dev plumbing, ADR-0019) whose state is the test's own directory; nothing here
# reaches pacman, a network or a real shell. Prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | QS_*) unset "$v" ;; esac
done
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: software_update_service: Quickshell (qs) is not installed"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/swupdate.XXXXXX")
probe=""
cleanup() {
  [[ -n $probe ]] && kill "$probe" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/fake" "$tmp/state" "$tmp/config" "$tmp/home" "$tmp/cache"
mkdir -p -m 700 "$tmp/runtime"
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

# The fake checker: one answer per run, from $FAKE (see probe.qml).
cat >"$tmp/fake/checker" <<'SH'
#!/bin/sh
waiter=0
for a in "$@"; do [ "$a" = --after-update-lock ] && waiter=1; done
printf 'args=|%s| cache=%s\n' "$*" "$XDG_CACHE_HOME" >>"$FAKE/calls"
if [ "$waiter" = 1 ]; then
  while [ -e "$FAKE/hang-waiter" ]; do sleep 0.1; done
  cat "$FAKE/answer-waiter"
  exit 0
fi
while [ -e "$FAKE/hang" ]; do sleep 0.1; done
if [ -e "$FAKE/junk" ]; then echo "Traceback (most recent call last):"; exit 1; fi
cat "$FAKE/answer"
SH
chmod +x "$tmp/fake/checker"

out="$tmp/out.txt"
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 \
  GRASSFIELD_UPDATE_CHECK_CMD="$tmp/fake/checker" FAKE="$tmp/fake" \
  GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" HOME="$tmp/home" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" \
  XDG_CACHE_HOME="$tmp/cache" timeout 120 qs -p "$root/tests/shell/software_update_service/probe.qml" --no-color >"$out" 2>&1 &
probe=$!

# Step k: once the probe is ready, the IPC target from outside, as Settings and the shim reach it.
for _ in $(seq 1 600); do
  grep -q "software-update-service: ipc-ready" "$out" && break
  kill -0 "$probe" 2>/dev/null || break
  sleep 0.1
done
# The same display-less environment as the probe's (in a Wayland session qs ipc would look for an instance on that display).
ipc() { env -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS \
  XDG_RUNTIME_DIR="$tmp/runtime" timeout 10 qs ipc -p "$root/tests/shell/software_update_service/probe.qml" call update check "$1" 2>&1; }
if grep -q "software-update-service: ipc-ready" "$out"; then
  desc="IPC: update check bogus -> refused (only the origins user and omarchy)"
  check test "$(ipc bogus)" == refused
  desc="IPC: update check user -> ok"
  check test "$(ipc user)" == ok
else
  echo "FAIL: the probe never got ready for the IPC step"
  fail=1
fi
wait "$probe" || true
probe=""
grep -E "qml: (ok|BAD) |software-update-service: (PASS|FAIL)|software update:" "$out" | sed 's/^/   /' || true
desc="the service's steps (probe.qml)"
check grep -q "software-update-service: PASS" "$out"
f="$tmp/state/software-update.json"
desc="software-update.json is the user's alone: mode 600 in a folder of mode 700"
check test "$(stat -c %a "$f" 2>/dev/null):$(stat -c %a "$tmp/state" 2>/dev/null)" == "600:700"
desc="a dev session watches its own run folder (mode 700), never the session's runtime folder (ADR-0019 UPDATE_RUN_DIR)"
check test "$(stat -c %a "$tmp/state/update-run" 2>/dev/null):$([[ -e $tmp/runtime/grassfield ]] && echo made)" == "700:"
python3 -I "$root/tests/ci/qml_warnings.py" <"$out" || { echo "FAIL: QML runtime warnings"; fail=1; }

# A stored update-running whose waiter did not survive the session: checked at once when the service reads the file.
mkdir -p "$tmp/fake2" && mkdir -p -m 700 "$tmp/state2"
cp "$tmp/fake/checker" "$tmp/fake2/checker"
printf '{"version":1,"state":"update-running","checkedAt":"2026-10-28T01:00:00Z","announced":[]}\n' >"$tmp/state2/software-update.json"
chmod 600 "$tmp/state2/software-update.json"
printf '{"version":1,"state":"up-to-date","channel":"stable","checkedAt":"2026-10-28T09:00:00Z","grassfield":{"installed":"1.0.1-1","available":null},"omarchy":{"installed":"4.0.6-1","available":null},"others":0,"otherPackages":[]}\n' >"$tmp/fake2/answer"
out2="$tmp/out2.txt"
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 \
  GRASSFIELD_UPDATE_CHECK_CMD="$tmp/fake2/checker" FAKE="$tmp/fake2" \
  GRASSFIELD_STATE_HOME="$tmp/state2" GRASSFIELD_CONFIG_HOME="$tmp/config" HOME="$tmp/home" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" \
  XDG_CACHE_HOME="$tmp/cache" timeout 60 qs -p "$root/tests/shell/software_update_service/stale.qml" --no-color >"$out2" 2>&1 || true
grep -E "software-update-stale: (PASS|FAIL)" "$out2" | sed 's/^/   /' || true
desc="a stored update-running is checked when the service starts (its waiter did not survive)"
check grep -q "software-update-stale: PASS" "$out2"
python3 -I "$root/tests/ci/qml_warnings.py" <"$out2" || { echo "FAIL: QML runtime warnings (stale)"; fail=1; }
((fail == 0))
