#!/usr/bin/env bash
# A display on without a mode (the owner's rc6 report: external displays black after sleep until unplugged and plugged back;
# shell/platform/Displays.qml checkModeless, DisplaysFile.modeless and recoveryDelayMs), offscreen against a fake Hyprland:
# its `monitors` answer lists GF-REF with a mode and DP-1 enabled at 0x0 (what Hyprland reports for a monitor that answered no
# video modes) until it has received two reloads, then DP-1 at 2560x1440; it answers a reload "ok" and then sends
# `configreloaded` on the event socket, as Hyprland does. Runs tests/shell/displays_modeless.d/modeless.qml as a dev session,
# then checks that the fake saw exactly the two reloads and only reloads and JSON queries. Nothing here can reach a real
# Hyprland: HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR point at the test's own directory.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
tmp=$(mktemp -d "$root/.dev/displays-modeless.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/displays-modeless.XXXXXX"; })
# The runtime folder (the fake's sockets) under a short base: a Unix socket path holds at most 107 bytes.
rt=$(mktemp -d "${TMPDIR:-/tmp}/gf-rt.XXXXXX")
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp" "$rt"' EXIT
sig=gf-displays-modeless
mkdir -p "$rt/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg"
chmod 700 "$rt" "$tmp/cache"
# The test shell.qml next to links to every module of the real shell (qs.platform's qmldir names singletons of its siblings).
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/displays_modeless.d/modeless.qml "$tmp/cfg/shell.qml"

# The fake Hyprland. Python's standard library only.
cat >"$tmp/fake.py" <<'PY'
import json, os, socket, sys, threading, time
base, log = sys.argv[1], sys.argv[2]
lock = threading.Lock()
reloads = 0
events = []
def monitor(i, name, desc, w, h, x):
    return {"id": i, "name": name, "description": desc, "make": "GF", "model": desc, "serial": str(i + 1), "width": w,
            "height": h, "refreshRate": 60.0 if w else 0.0, "x": x, "y": 0, "activeWorkspace": {"id": i + 1, "name": str(i + 1)},
            "specialWorkspace": {"id": 0, "name": ""}, "reserved": [0, 0, 0, 0], "scale": 1.0, "transform": 0,
            "focused": i == 0, "dpmsStatus": True, "vrr": False, "disabled": False,
            "availableModes": ["%dx%d@60.00Hz" % (w, h)] if w else []}
def monitors():
    with lock:
        ready = reloads >= 2
    return json.dumps([monitor(0, "GF-REF", "Reference", 1920, 1080, 0),
                       monitor(1, "DP-1", "Desk", 2560 if ready else 0, 1440 if ready else 0, 1920)])
def answer(c):
    global reloads
    data = c.recv(65536).decode(errors="replace")
    with lock:
        with open(log, "a") as f:
            f.write(data.replace("\n", "\\n") + "\n")
        if data == "reload":
            reloads += 1
    if data == "reload":
        time.sleep(0.2)
        c.sendall(b"ok")
        c.close()
        time.sleep(0.1)
        with lock:
            for e in list(events):
                try:
                    e.sendall(b"configreloaded>>\n")
                except OSError:
                    events.remove(e)
        return
    if "monitors" in data:
        c.sendall(monitors().encode())
    else:
        c.sendall(b"[]" if data.startswith("j/") or "j/" in data[:8] else b"ok")
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
    while True:
        c, _ = s.accept()
        with lock:
            events.append(c)
        # DP-1 arriving, as Hyprland announces it (the description holds the serial, which must not reach the journal).
        threading.Timer(0.5, lambda c=c: c.sendall(b"monitoraddedv2>>1,DP-1,GF Desk SERIAL-9\n")).start()
threading.Thread(target=serve_events, daemon=True).start()
serve_requests()
PY
python3 -I "$tmp/fake.py" "$rt/hypr/$sig" "$tmp/requests.log" &
fake=$!
for _ in $(seq 50); do [[ -S $rt/hypr/$sig/.socket.sock && -S $rt/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

out=$(env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_RUNTIME_DIR="$rt" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
res=$(grep -o 'displays-modeless: .*' <<<"$out" || true)
echo "${res:-FAIL: displays-modeless: no result}"
grep -q 'displays-modeless: PASS' <<<"$res" || { fail=1; echo "$out" | tail -20; }
reloads=$(grep -cx 'reload' "$tmp/requests.log" 2>/dev/null || true)
if [[ $reloads == 2 ]]; then echo "PASS: displays_modeless the fake Hyprland received the 2 reloads"; else echo "FAIL: displays_modeless the fake Hyprland received ${reloads:-0} reloads, not 2"; fail=1; fi
if grep -qvE '^(reload|j/.*|\[\[BATCH\]\].*)$' "$tmp/requests.log"; then
  echo "FAIL: displays_modeless a request other than reload or a JSON query: $(grep -vE '^(reload|j/.*|\[\[BATCH\]\].*)$' "$tmp/requests.log" | head -3)"; fail=1
else
  echo "PASS: displays_modeless only reloads and JSON queries reached Hyprland"
fi
# The journal hears of each change of state once, never of each reload (review of 70dea8b0: a display that stays without a
# mode all night would otherwise log every minute).
blank=$(grep -c 'DP-1 is on without a mode (0x0)' <<<"$out" || true)
again=$(grep -c 'DP-1 has a mode again (after 2 reloads)' <<<"$out" || true)
noisy=$(grep -cE 'session config read again \(display without a mode\)|still has no mode' <<<"$out" || true)
if [[ $blank == 1 && $again == 1 && $noisy == 0 ]]; then
  echo "PASS: displays_modeless the journal says once that a display has no mode and once that it has one again, nothing per reload"
else
  echo "FAIL: displays_modeless journal lines: 'on without a mode' $blank (want 1), 'has a mode again (after 2 reloads)' $again (want 1), per-reload lines $noisy (want 0)"; fail=1
fi
if grep -q 'grassfield-shell: displays: added DP-1$' <<<"$out" && ! grep -q 'SERIAL-9' <<<"$out"; then
  echo "PASS: displays_modeless a display arriving is in the journal by its connector, without its serial"
else
  echo "FAIL: displays_modeless the arrival line is missing or carries the description"; fail=1
fi
exit $fail
