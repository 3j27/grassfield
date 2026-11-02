#!/usr/bin/env bash
# ADR-0031: the shell describes the displays once Hyprland has answered (shell/platform/Displays.qml), offscreen, against a fake
# Hyprland whose `monitors` answer (two monitors) comes 400 ms after the request, later than the 120 ms publish debounce. The
# file the shell publishes must list both monitors; before the fix it was written once, empty, and never again until a monitor
# event or a config reload. Runs tests/shell/displays_publish.d/publish.qml as a dev session (no trial). The fake needs Unix
# sockets. Nothing here can reach a real Hyprland: HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR point at the test's own directory.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
tmp=$(mktemp -d "$root/.dev/displays-publish.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/displays-publish.XXXXXX"; })
# The runtime folder (the fake Hyprland's sockets) under a short base: a Unix socket path holds at most 107 bytes, and
# "$root/.dev/..." of a deep checkout went past it, so nothing could connect (as displays_trial.sh, ad044d4d).
rt=$(mktemp -d "${TMPDIR:-/tmp}/gf-rt.XXXXXX")
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp" "$rt"' EXIT
sig=gf-displays-publish
mkdir -p "$rt/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg"
chmod 700 "$rt" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/displays_publish.d/publish.qml "$tmp/cfg/shell.qml"

# The fake Hyprland. Python's standard library only.
cat >"$tmp/fake.py" <<'PY'
import json, os, socket, sys, threading, time
base, log = sys.argv[1], sys.argv[2]
lock = threading.Lock()
def mon(i, name, x):
    return {"id": i, "name": name, "description": "GF " + name, "make": "GF", "model": name, "serial": "", "width": 1920,
            "height": 1080, "physicalWidth": 500, "physicalHeight": 300, "refreshRate": 60.0, "x": x, "y": 0, "scale": 1.0,
            "transform": 0, "disabled": False, "focused": i == 0, "activeWorkspace": {"id": 1, "name": "1"},
            "availableModes": ["1920x1080@60.00Hz"]}
MONITORS = json.dumps([mon(0, "GF-1", 0), mon(1, "GF-2", 1920)]).encode()
def answer(c):
    data = c.recv(65536).decode(errors="replace")
    with lock:
        with open(log, "a") as f:
            f.write(data.replace("\n", "\\n") + "\n")
    if "monitors" in data:
        time.sleep(0.4)
        c.sendall(MONITORS)
    else:
        c.sendall(b"[]" if "j/" in data[:8] else b"ok")
    c.close()
def serve_requests():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket.sock"))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=answer, args=(c,), daemon=True).start()
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
python3 -I "$tmp/fake.py" "$rt/hypr/$sig" "$tmp/requests.log" &
fake=$!
for _ in $(seq 50); do [[ -S $rt/hypr/$sig/.socket.sock && -S $rt/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

out=$(env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_RUNTIME_DIR="$rt" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
res=$(grep -o 'displays-publish: .*' <<<"$out" || true)
echo "${res:-FAIL: displays-publish: no result}"
grep -q 'displays-publish: PASS' <<<"$res" || { fail=1; echo "$out" | tail -20; }
exit $fail
