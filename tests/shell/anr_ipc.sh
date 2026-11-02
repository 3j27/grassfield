#!/usr/bin/env bash
# ADR-0035 D-3 end to end without a compositor: the stand-in (packaging/session-bin/hyprland-dialog, a scratch copy whose
# stock dialog is a recorder) reports through the real `qs ipc` to the real NotResponding service, loaded by
# tests/shell/anr_ipc.d/probe.qml under the real Quickshell, offscreen, against a fake Hyprland that knows three windows:
# foot "~" (pid 4242), and foot "shared" of two processes (5000, 5001).
#   1 a hang of foot "~": the shell answers ok, marks pid 4242 (anr status), the stand-in waits and runs no dialog;
#   2 the stand-in ends (Hyprland kills it): the mark is gone within 1 s;
#   3 the stand-in sees one "shared" window (its client list is older) but the shell knows two processes: refused, the stock
#     dialog runs, nothing is marked; 3b once Hyprland announced the other window's new title (windowtitlev2), accepted;
#   4 a stand-in of another compositor (another HYPRLAND_INSTANCE_SIGNATURE): refused, stock dialog;
#   5 direct calls: a pid of 1, a missing prefix, an empty instance: "refused", nothing marked; no reason is told.
# The probe runs as a dev session (anr status is a dev hook) and the stand-in reaches it through GRASSFIELD_SHELL_DIR
# (honoured in a dev session only). Nothing here can reach a real Hyprland or shell: HYPRLAND_INSTANCE_SIGNATURE and
# XDG_RUNTIME_DIR point at the test's own directory. Prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# The caller's session must not reach the runs: from a Grassfield session the environment holds GRASSFIELD_SESSION=1 and
# Quickshell's QS_* variables (integrator review of e6ee4fb). Each run sets the ones it tests.
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | QS_*) unset "$v" ;; esac
done
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: anr_ipc: Quickshell (qs) is not installed"; exit 0; }
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
tmp=$(mktemp -d "$root/.dev/anr-ipc.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/anr-ipc.XXXXXX"; })
# The runtime folder (the fake Hyprland's sockets, qs ipc's) under a short base: a Unix socket path holds at most 107
# bytes, and "$root/.dev/..." of an agent's worktree goes past it (as displays_trial.sh, ad044d4d).
rt=$(mktemp -d "${TMPDIR:-/tmp}/gf-rt.XXXXXX")
fake="" shell="" standin=""
cleanup() {
  local p
  for p in $fake $shell $standin; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" "$rt"
}
trap cleanup EXIT
sig=gf-anr-ipc
mkdir -p "$rt/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg" "$tmp/bin" "$tmp/fake"
chmod 700 "$rt" "$tmp/cache"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/anr_ipc.d/probe.qml "$tmp/cfg/shell.qml"

client() { # address pid class title
  printf '{"address": "%s", "mapped": true, "hidden": false, "at": [0, 0], "size": [800, 600], "workspace": {"id": 1, "name": "1"}, "floating": false, "monitor": 0, "class": "%s", "title": "%s", "initialClass": "%s", "initialTitle": "%s", "pid": %s, "xwayland": false, "pinned": false, "fullscreen": 0, "fullscreenClient": 0, "grouped": [], "tags": [], "swallowing": "0x0", "focusHistoryID": 0}' \
    "$1" "$3" "$4" "$3" "$4" "$2"
}
printf '[%s, %s, %s]' "$(client 0x1 4242 foot "~")" "$(client 0x2 5000 foot shared)" "$(client 0x3 5001 foot shared)" >"$tmp/clients-shell.json"
# The stand-in's own view: one "shared" window only.
printf '[%s, %s]' "$(client 0x1 4242 foot "~")" "$(client 0x2 5000 foot shared)" >"$tmp/clients-standin.json"

cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading
base, clients_path = sys.argv[1], sys.argv[2]
held = []
def answer(c):
    data = c.recv(65536).decode(errors="replace")
    if "clients" in data:
        c.sendall(open(clients_path, "rb").read())
    elif "j/" in data[:8]:
        c.sendall(b"[]")
    else:
        # The shell's dispatches (its blur push): answered, and the connection left for the shell to close. Quickshell 0.3.2
        # on Qt 6.12 crashes when the peer closes first there (QAbstractSocketPrivate, docs/compat.md); not this test's subject.
        c.sendall(b"ok")
        held.append(c)
        return
    c.close()
def serve_requests():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket.sock"))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=answer, args=(c,), daemon=True).start()
events_held = []
def serve_events():
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, ".socket2.sock"))
    s.listen(4)
    while True:
        c, _ = s.accept()
        events_held.append(c)
def push_events():
    # Lines the test appends to the "events" file go to every connected client, as Hyprland's event socket sends them.
    path, sent = sys.argv[3], 0
    while True:
        try:
            data = open(path, "rb").read()
        except OSError:
            data = b""
        if len(data) > sent:
            for c in list(events_held):
                try:
                    c.sendall(data[sent:])
                except OSError:
                    events_held.remove(c)
            sent = len(data)
        threading.Event().wait(0.05)
threading.Thread(target=serve_events, daemon=True).start()
threading.Thread(target=push_events, daemon=True).start()
serve_requests()
PY
: >"$tmp/events"
python3 -I "$tmp/fake.py" "$rt/hypr/$sig" "$tmp/clients-shell.json" "$tmp/events" &
fake=$!
for _ in $(seq 50); do [[ -S $rt/hypr/$sig/.socket.sock && -S $rt/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

base_env=(-u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST
  GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig"
  XDG_RUNTIME_DIR="$rt" XDG_CACHE_HOME="$tmp/cache")
env "${base_env[@]}" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  timeout 120 qs -p "$tmp/cfg" --no-color >"$tmp/shell.log" 2>&1 &
shell=$!
for _ in $(seq 150); do grep -q 'anr-probe: ready' "$tmp/shell.log" && break; sleep 0.1; done
if ! grep -q 'anr-probe: ready 3 marks 0' "$tmp/shell.log"; then
  echo "FAIL: anr_ipc: the probe shell did not come up with Hyprland's three windows"
  tail -20 "$tmp/shell.log"
  exit 1
fi
ipc() { env "${base_env[@]}" timeout 5 qs ipc -p "$tmp/cfg" call anr "$@" 2>&1; }
marks() { ipc status | python3 -I -c 'import json, sys; print(" ".join(str(m["pid"]) for m in json.load(sys.stdin)))'; }

# The stand-in: the stock dialog is a recorder; its hyprctl prints the stand-in's view.
sed "s|^stock=/usr/bin/hyprland-dialog\$|stock=$tmp/fake/stock|" packaging/session-bin/hyprland-dialog >"$tmp/bin/hyprland-dialog"
chmod +x "$tmp/bin/hyprland-dialog"
printf '#!/bin/sh\nprintf "%%s\\n" "$$" >"%s/stock.ran"\n' "$tmp" >"$tmp/fake/stock"
printf '#!/bin/sh\n[ "$1 $2" = "-j clients" ] && cat "%s/clients-standin.json"\n' "$tmp" >"$tmp/fake/hyprctl"
chmod +x "$tmp/fake/stock" "$tmp/fake/hyprctl"
hang() { # title [instance]: runs the stand-in for an English ANR call of foot <title>; sets `standin`
  rm -f "$tmp/stock.ran"
  env "${base_env[@]}" GRASSFIELD_SHELL_DIR="$tmp/cfg" HYPRLAND_INSTANCE_SIGNATURE="${2:-$sig}" PATH="$tmp/bin:$tmp/fake:$PATH" \
    "$tmp/bin/hyprland-dialog" --title "Application Not Responding" \
    --text "$(printf 'An application %s - foot is not responding.\nWhat do you want to do with it?' "$1")" \
    --buttons "Terminate;Wait" >"$tmp/standin.out" 2>&1 &
  standin=$!
}
ended_within() { local i; for ((i = 0; i < $2 * 20; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done; return 1; }

# 1-2.
hang "~"
sleep 1.5
desc="1 a hang of foot \"~\": the shell marks pid 4242"
check test "$(marks)" == 4242
desc="1 the stand-in waits, silent, and ran no dialog"
check bash -c 'kill -0 "$1" && [[ ! -s $2/standin.out && ! -e $2/stock.ran ]]' _ "$standin" "$tmp"
kill -KILL "$standin"
wait "$standin" 2>/dev/null || true
gone_within_1s() { local i; for ((i = 0; i < 20; i++)); do [[ -z $(marks) ]] && return 0; sleep 0.05; done; return 1; }
desc="2 the stand-in ends: the mark is gone within 1 s"
check gone_within_1s

# 3.
hang shared
desc="3 a window the shell knows under two processes: refused, the stock dialog runs with the stand-in's pid"
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; [[ $(cat "$2/stock.ran" 2>/dev/null) == "$1" ]]' _ "$standin" "$tmp"
desc="3 nothing is marked"
check test -z "$(marks)"

# 3b. The other process's window is renamed, as Hyprland does it: its client list changes and it sends windowtitlev2 (the
# shell reads the live title, and Compositor re-reads the list on that event). The "shared" window is now one process's
# and the report is accepted.
printf '[%s, %s, %s]' "$(client 0x1 4242 foot "~")" "$(client 0x2 5000 foot shared)" "$(client 0x3 5001 foot renamed)" >"$tmp/clients-shell.json.new"
mv "$tmp/clients-shell.json.new" "$tmp/clients-shell.json"
printf 'windowtitlev2>>3,renamed\n' >>"$tmp/events"
sleep 0.5
hang shared
sleep 1.5
desc="3b once Hyprland renamed the other process's window: the same report is accepted, pid 5000 marked"
check test "$(marks)" == 5000
kill -KILL "$standin"
wait "$standin" 2>/dev/null || true
gone_within_1s || true

# 4.
hang "~" other-instance
desc="4 another compositor's stand-in: refused, the stock dialog runs"
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; [[ $(cat "$2/stock.ran" 2>/dev/null) == "$1" ]]' _ "$standin" "$tmp"
desc="4 nothing is marked"
check test -z "$(marks)"

# 5.
desc="5 direct calls with a pid of 1, a missing prefix or an empty instance: \"refused\" with no reason, nothing marked"
check bash -c '[[ $("$@" 99999 1 c:foot "t:~" "i:$0") == refused && $("$@" 99999 4242 foot "t:~" "i:$0") == refused &&
  $("$@" 99999 4242 c:foot "t:~" "i:") == refused ]]' "$sig" env "${base_env[@]}" timeout 5 qs ipc -p "$tmp/cfg" call anr report
desc="5 nothing is marked"
check test -z "$(marks)"

if ((fail)); then tail -20 "$tmp/shell.log"; fi
exit $fail
