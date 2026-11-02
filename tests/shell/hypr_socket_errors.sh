#!/usr/bin/env bash
# ADR-0041 step 2c (incident I-1 as a regression, step 7's row): the shell's request sockets to Hyprland on their error
# paths, offscreen, on the installed Quickshell. Quickshell 0.3.2's Socket::onSocketError deleted its socket after emitting
# `error` with no null check, and a handler that closed the socket from inside the signal made the shell crash about 5 s
# after every start (the owner's session, 2026-10-29); the three handlers defer their work now and tests/ci/socket_errors.py
# keeps that rule in the source. This runs the real SessionConfig (its reload socket is the family's pattern) against a fake
# Hyprland instance whose request socket is first missing (a connect error), then hangs up without an answer, then answers,
# then stays silent past the answer bound and hangs up late: every request is judged exactly once (answered(ticket, ok)) and
# Quickshell is still up at the end (exit 0, "hypr-socket-errors: PASS"; a crash is its exit code). In the rc-channel gate
# (scripts/gates/rc-toolkit.sh) this runs on the rc channel's Quickshell: the r7 proof of I-1 as a container case.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. SKIP without Quickshell.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: hypr_socket_errors: Quickshell (qs) is not installed"; exit 0; }
fail=0
tmp=$(mktemp -d "$root/.dev/hypr-socket-errors.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/hypr-socket-errors.XXXXXX"; })
# The runtime folder (the fake Hyprland's sockets) under a short base: a Unix socket path holds at most 107 bytes, and
# "$root/.dev/..." of a deep checkout went past it, so nothing could connect (integrator, 2026-11-02).
rt=$(mktemp -d "${TMPDIR:-/tmp}/gf-rt.XXXXXX")
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp" "$rt"' EXIT
sig=gf-socket-errors
mkdir -p "$rt/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg"
chmod 700 "$rt" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/hypr_socket_errors.d/probe.qml "$tmp/cfg/shell.qml"
ui/i18n/build-direct.sh >/dev/null

# The fake Hyprland (Python's standard library only): the event socket from the start (Quickshell's Hyprland singleton
# connects to it), the request socket only once the probe wrote `go` (before that a request meets no socket at all). The
# probe writes it to Mode.stateDir, which is GRASSFIELD_STATE_HOME here: "$tmp/state/go" (the first version waited for it in
# the instance directory, so the request socket never came: the integrator's follow-up on #104). Only `reload` requests are
# the probe's: anything else (a JSON query of Quickshell's Hyprland module) gets "[]" and is not counted. The reloads, in
# order: the first is closed without an answer (a peer that hangs up), the second answers "ok", the third is held silent for
# 2.5 s, past the probe's 1 s answer bound, then closed (a late hang-up on a socket judged already).
cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading, time
base, log, go = sys.argv[1], sys.argv[2], sys.argv[3]
count = 0
lock = threading.Lock()
def note(what):
    with open(log, "a") as f:
        f.write(what + "\n")
def handle(c):
    global count
    data = c.recv(65536)
    if not data.startswith(b"reload"):
        c.sendall(b"[]"); c.close(); return
    with lock:
        count += 1
        n = count
    if n == 1:
        c.close(); note("1 hangup")
    elif n == 2:
        c.sendall(b"ok"); c.close(); note("2 answered")
    else:
        time.sleep(2.5); c.close(); note("%d late" % n)
def serve_requests():
    while not os.path.exists(go):
        time.sleep(0.05)
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket.sock"))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
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
python3 -I "$tmp/fake.py" "$rt/hypr/$sig" "$tmp/connections.log" "$tmp/state/go" &
fake=$!
for _ in $(seq 50); do [[ -S $rt/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

out=$(env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_RUNTIME_DIR="$rt" XDG_CACHE_HOME="$tmp/cache" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1)
rc=$?
res=$(grep -o 'hypr-socket-errors: .*' <<<"$out" || true)
echo "${res:-FAIL: hypr-socket-errors: no result}"
grep -q 'hypr-socket-errors: PASS' <<<"$res" || { fail=1; echo "$out" | tail -20; }
if ((rc == 0)); then echo "PASS: hypr_socket_errors Quickshell exited 0 (no crash on the error paths)"
else echo "FAIL: hypr_socket_errors Quickshell exited $rc (139 is a crash, 124 a hang)"; fail=1; fi
seen=$(paste -sd';' "$tmp/connections.log" 2>/dev/null || true)
if [[ $seen == "1 hangup;2 answered;3 late" ]]; then echo "PASS: hypr_socket_errors the fake saw the three connections in order (hang-up, answer, late hang-up)"
else echo "FAIL: hypr_socket_errors the fake saw '$seen', not '1 hangup;2 answered;3 late'"; fail=1; fi
exit $fail
