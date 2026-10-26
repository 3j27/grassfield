#!/usr/bin/env bash
# ADR-0027: the shell's side of a display trial (shell/platform/Displays.qml) and of the input files (SessionConfig.qml),
# offscreen, against a fake Hyprland: a request
# socket that records every request and answers it ("ok", "[]" for the JSON queries), and a silent event socket. Runs
# tests/shell/displays_trial.d/trial.qml as a dev session (the trial and state files under GRASSFIELD_STATE_HOME), then checks
# that the fake saw exactly the reloads the QML counted. Nothing here can reach a real Hyprland: HYPRLAND_INSTANCE_SIGNATURE
# and XDG_RUNTIME_DIR point at the test's own directory.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
tmp=$(mktemp -d "$root/.dev/displays-trial.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/displays-trial.XXXXXX"; })
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp"' EXIT
sig=gf-displays-trial
mkdir -p "$tmp/runtime/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg"
chmod 700 "$tmp/runtime" "$tmp/cache"
# The test shell.qml next to links to every module of the real shell (qs.platform's qmldir names singletons of its siblings).
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/displays_trial.d/trial.qml "$tmp/cfg/shell.qml"

# The fake Hyprland. Python's standard library only.
cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading
base, log = sys.argv[1], sys.argv[2]
def serve_requests():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket.sock"))
    s.listen(16)
    while True:
        c, _ = s.accept()
        data = c.recv(65536).decode(errors="replace")
        with open(log, "a") as f:
            f.write(data.replace("\n", "\\n") + "\n")
        c.sendall(b"[]" if data.startswith("j/") or "j/" in data[:8] else b"ok")
        c.close()
def serve_events():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket2.sock"))
    s.listen(4)
    held = []
    while True:
        c, _ = s.accept()
        held.append(c)
threading.Thread(target=serve_events, daemon=True).start()
serve_requests()
PY
python3 -I "$tmp/fake.py" "$tmp/runtime/hypr/$sig" "$tmp/requests.log" &
fake=$!
for _ in $(seq 50); do [[ -S $tmp/runtime/hypr/$sig/.socket.sock && -S $tmp/runtime/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

# A trial a shell left behind when it stopped: the new shell must take it back at start.
printf 'trial old until %s\nv1\tdesc:GF Reference\t1920x1080@60\t0x0\t1\t0\n' "$(($(date +%s) + 60))" >"$tmp/state/display-trial.conf"

out=$(env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
res=$(grep -o 'displays-trial: .*' <<<"$out" || true)
echo "${res:-FAIL: displays-trial: no result}"
grep -q 'displays-trial: PASS' <<<"$res" || { fail=1; echo "$out" | tail -20; }
reloads=$(grep -cx 'reload' "$tmp/requests.log" 2>/dev/null || true)
if [[ $reloads == 9 ]]; then echo "PASS: displays_trial the fake Hyprland received the 9 reloads"; else echo "FAIL: displays_trial the fake Hyprland received ${reloads:-0} reloads, not 9"; fail=1; fi
if grep -qvE '^(reload|j/.*|\[\[BATCH\]\].*)$' "$tmp/requests.log"; then
  echo "FAIL: displays_trial a request other than reload or a JSON query: $(grep -vE '^(reload|j/.*|\[\[BATCH\]\].*)$' "$tmp/requests.log" | head -3)"; fail=1
else
  echo "PASS: displays_trial only reloads and JSON queries reached Hyprland"
fi
# Quickshell makes a singleton only when it is first used: the real shell must start SessionConfig itself, or the input files
# are watched only after a display trial (review of 2026-10-26). The harness above starts it with the same line.
if grep -qxF '    readonly property int sessionConfigReloads: SessionConfig.reloads' shell/shell.qml \
  && grep -qxF '    readonly property int sessionConfigReloads: SessionConfig.reloads' tests/shell/displays_trial.d/trial.qml; then
  echo "PASS: displays_trial shell.qml starts SessionConfig with the shell, as the harness does"
else
  echo "FAIL: displays_trial shell.qml (or the harness) does not start SessionConfig at start"; fail=1
fi
exit $fail
