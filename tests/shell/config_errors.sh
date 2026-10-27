#!/usr/bin/env bash
# ADR-0035 D-2: shell/platform/ConfigErrors.qml under the real Quickshell, offscreen, against a fake Hyprland that sends
# `configreloaded` events on a timeline while the test changes the fake `hyprctl -j configerrors` answer:
#   start ["a","b"]           → appeared ["a","b"] 0
#   reload, same answer       → nothing (the same set)
#   reload, [""] (no error)   → cleared
#   reload, five lines        → appeared, the first three, 2 more; "<eof>" escaped in the body
#   two reloads 50 ms apart while a read takes 0.5 s → one more read after it (7 reads in all), appeared ["x"] 0 once
#   reload, not JSON          → nothing
# Runs tests/shell/config_errors.d/probe.qml as a dev session. Nothing here can reach a real Hyprland:
# HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR point at the test's own directory. Prints PASS/FAIL, exits non-zero on
# failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: config_errors: Quickshell (qs) is not installed"; exit 0; }
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
tmp=$(mktemp -d "$root/.dev/config-errors.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/config-errors.XXXXXX"; })
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp"' EXIT
sig=gf-config-errors
mkdir -p "$tmp/runtime/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg" "$tmp/ce"
chmod 700 "$tmp/runtime" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/config_errors.d/probe.qml "$tmp/cfg/shell.qml"
printf '[\n\t"a",\n\t"b"\n]\n' >"$tmp/ce/answer"

cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading, time
base, ce = sys.argv[1], sys.argv[2]
def answer(c):
    data = c.recv(65536).decode(errors="replace")
    c.sendall(b"[]" if "j/" in data[:8] else b"ok")
    c.close()
def serve_requests():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket.sock"))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=answer, args=(c,), daemon=True).start()
def put(text):
    with open(os.path.join(ce, "answer.new"), "w") as f:
        f.write(text)
    os.replace(os.path.join(ce, "answer.new"), os.path.join(ce, "answer"))
def timeline(c):
    reload = lambda: c.sendall(b"configreloaded>>\n")
    time.sleep(1.5); reload()
    time.sleep(1.5); put('[\n\t""\n]\n'); reload()
    time.sleep(1.5); put('["l1 near <eof>", "l2 & x", "l3", "l4", "l5"]'); reload()
    time.sleep(1.5); open(os.path.join(ce, "slow"), "w").close(); put('["x"]'); reload(); time.sleep(0.05); reload()
    time.sleep(1.5); os.remove(os.path.join(ce, "slow")); put("Couldn't connect to the socket (4)"); reload()
def serve_events():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket2.sock"))
    s.listen(4)
    held = []
    first = True
    while True:
        c, _ = s.accept()
        held.append(c)
        if first:
            first = False
            threading.Thread(target=timeline, args=(c,), daemon=True).start()
threading.Thread(target=serve_events, daemon=True).start()
serve_requests()
PY
python3 -I "$tmp/fake.py" "$tmp/runtime/hypr/$sig" "$tmp/ce" &
fake=$!
for _ in $(seq 50); do [[ -S $tmp/runtime/hypr/$sig/.socket.sock && -S $tmp/runtime/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

out=$(env -u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" \
  GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  CE_DIR="$tmp/ce" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" timeout 60 qs -p "$tmp/cfg" --no-color 2>&1) || true
got=$(grep -o 'ce: .*' <<<"$out" || true)
want='ce: appeared ["a","b"] 0 body "a\nb"
ce: cleared
ce: appeared ["l1 near <eof>","l2 & x","l3"] 2 body "l1 near &lt;eof>\nl2 &amp; x\nl3\nand 2 more"
ce: appeared ["x"] 0 body "x"
ce: done'
desc="one notice per new set, cleared when the errors are gone, nothing for the same set or a reply that is not JSON"
check test "$got" == "$want"
desc="the shell root posts the notice with ConfigErrors' escaped body"
check grep -q 'Notifications.postInternal(qsTr("Some settings could not be applied"), noticeBody(lines, rest))' shell/shell.qml
desc="a reload during a read is read once more after it: 7 reads in all"
check test "$(cat "$tmp/ce/reads" 2>/dev/null)" == 7
if ((fail)); then
  echo "--- got:"
  echo "$got"
  echo "--- reads: $(cat "$tmp/ce/reads" 2>/dev/null)"
  echo "$out" | grep -v '^ *$' | tail -15
fi
exit $fail
