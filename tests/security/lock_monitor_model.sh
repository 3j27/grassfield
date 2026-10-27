#!/usr/bin/env bash
# Review of the lock's monitor queries (Quickshell 0.3.1 IPC, read in its source): Hyprland.refreshMonitors() from QML never
# creates a monitor object, and one sent before Hyprland answered Quickshell's own first query (`j/status`) makes Quickshell
# drop its start-up monitors query as a duplicate, so Hyprland.monitors stays empty until a monitor event: the lock's
# stranded check ended unknown, its ownership watcher had nothing to watch (no re-lock after a foreign release) and verify()
# never got an answer. Lock.qml now sends no query while that model is empty (requestMonitors). The REAL Lock singleton runs
# offscreen (tests/security/lock_monitor_model.d/probe.qml, a dev session) against:
#   no-socket    a Hyprland directory with no socket (every query fails at once, the model stays empty): Quickshell's own
#                monitors query is the only one made (its debug log counts them), the start-up check ends unknown after its
#                20 ticks (no takeover: the crash recovery marker decides) and the empty model is logged exactly once.
#                Runs everywhere, the Claude Code sandbox included.
#   slow-status  a fake Hyprland that answers `j/status` after 1.2 s and holds a monitors query that arrives before that
#                answer until 0.3 s after it (Hyprland answers queued requests in order); its one monitor lists LOCK (a
#                stranded session lock). No monitors query reaches it before the status answer; the model fills from
#                Quickshell's own query; the start-up check takes the stranded lock over; an answer about the monitor
#                created after start reaches checkOwnership (the ownership watcher attached to it).
#   no-status    a fake Hyprland that never answers `j/status`: no monitors query reaches it at all, the start-up check ends
#                unknown and the empty model is logged exactly once.
#   controls     no-socket and slow-status again on a copy of shell/security whose empty-model guard is removed (the code
#                before the fix): the lock queries an empty model, and with the slow fake the model never fills (the
#                probe fails). They prove the checks above see the bug.
# The fake needs Unix sockets: its scenarios SKIP where none can be created (the sandbox). Offscreen there is no compositor:
# a taken-over lock stays requested ("locking"), never confirmed, so the holding paths (verify, ownershipProbe,
# monitorsAdded's fresh query) are checked statically by lock_surfaces.sh and in nested by reload_locked.sh. Nothing here can
# reach a real Hyprland: HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR point at the test's own directory.
# Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
if ! command -v qs >/dev/null; then
  echo "SKIP: lock monitor model: qs missing: NOT VERIFIED"
  exit 0
fi
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/lock-monitor-model.XXXXXX")
fake=""
trap '[[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$tmp"' EXIT
ui/i18n/build-direct.sh >/dev/null
scripts/dev/i18n-build.sh >/dev/null
sig=gf-lock-monitor-model
fail=0
pass() { echo "PASS: lock monitor model $*"; }
bad() { echo "FAIL: lock monitor model $*"; fail=1; }
count() { grep -c -- "$1" <<<"$2" || true; }
monitor_queries() { grep -c 'Making request: "j/monitors"' <<<"$1" || true; } # Quickshell's debug log of every query it makes

# The fake Hyprland: a request socket that logs every request and answer in order, and a silent event socket. Python's
# standard library only.
cat >"$tmp/fake.py" <<'PY'
import json, os, socket, sys, threading, time
base, log, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()
status_answered = threading.Event()
MONITOR = {"id": 0, "name": "GF-1", "description": "GF GF-1", "make": "GF", "model": "GF-1", "serial": "", "width": 1920,
           "height": 1080, "refreshRate": 60.0, "x": 0, "y": 0, "scale": 1.0, "transform": 0, "disabled": False,
           "focused": True, "activeWorkspace": {"id": 1, "name": "1"}, "specialWorkspace": {"id": 0, "name": ""},
           "solitary": "0", "solitaryBlockedBy": ["LOCK", "WINDOWED", "CANDIDATE"], "availableModes": ["1920x1080@60.00Hz"]}
def note(line):
    with lock:
        with open(log, "a") as f:
            f.write(line + "\n")
def answer(c):
    data = c.recv(65536).decode(errors="replace").strip()
    note("request " + data.replace("\n", "\\n"))
    if data == "j/status":
        if scenario == "no-status":
            time.sleep(3600)  # never answered
            return
        time.sleep(1.2)
        c.sendall(json.dumps({"configProvider": "lua"}).encode())
        note("answered j/status")
        status_answered.set()
    elif data == "j/monitors":
        if not status_answered.is_set() and scenario == "slow-status":
            status_answered.wait()
            time.sleep(0.3)
        c.sendall(json.dumps([MONITOR]).encode())
        note("answered j/monitors")
    else:
        c.sendall(b"[]" if data.startswith("j/") else b"ok")
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
s = socket.socket(socket.AF_UNIX)
s.bind(os.path.join(base, ".socket.sock"))
s.listen(16)
while True:
    c, _ = s.accept()
    threading.Thread(target=answer, args=(c,), daemon=True).start()
PY

# A config directory: the probe as shell.qml next to links to every module of the real shell; with "remove", shell/security
# is a copy whose empty-model guard is removed.
make_cfg() { # <dir> keep|remove
  local dir=$1 entry name
  mkdir -p "$dir"
  for entry in shell/*; do
    name=$(basename "$entry")
    if [[ $name == shell.qml ]]; then
      continue
    elif [[ $name == security && $2 == remove ]]; then
      cp -a "$root/$entry" "$dir/security"
    else
      ln -s "$root/$entry" "$dir/$name"
    fi
  done
  cp tests/security/lock_monitor_model.d/probe.qml "$dir/shell.qml"
  if [[ $2 == remove ]]; then
    python3 -I - "$dir/security/lock/Lock.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
guard = "if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {"
assert s.count(guard) == 1, "the guard is not in Lock.qml"
open(p, "w").write(s.replace(guard, "if (false) {"))
PY
  fi
}

# One run of the probe: <name> <fake scenario|none> <probe scenario> <config dir>, with its own runtime directory (and fake).
# Sets $out (Quickshell's output, its Hyprland IPC debug log included) and $requests (the fake's log).
run() {
  local name=$1 fake_scenario=$2 probe_scenario=$3 cfg=$4 work=$tmp/$1
  mkdir -p "$work/runtime/hypr/$sig" "$work/cache" "$work/home" "$work/state" "$work/config"
  chmod 700 "$work/runtime" "$work/cache"
  requests=$work/requests.log
  : >"$requests"
  if [[ $fake_scenario != none ]]; then
    python3 -I "$tmp/fake.py" "$work/runtime/hypr/$sig" "$requests" "$fake_scenario" &
    fake=$!
    for _ in $(seq 50); do [[ -S $work/runtime/hypr/$sig/.socket.sock && -S $work/runtime/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done
  fi
  out=$(env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u GRASSFIELD_SESSION -u GRASSFIELD_DEV_ALLOW_PAM \
    -u GRASSFIELD_VISUAL_FIXTURES GRASSFIELD_DEV=1 LOCK_MONITOR_SCENARIO="$probe_scenario" HOME="$work/home" \
    GRASSFIELD_STATE_HOME="$work/state" GRASSFIELD_CONFIG_HOME="$work/config" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    XDG_RUNTIME_DIR="$work/runtime" XDG_CACHE_HOME="$work/cache" QT_QPA_PLATFORM=offscreen \
    QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en GRASSFIELD_TRANSLATIONS_DIR="$root/.dev/translations" \
    timeout 60 qs -p "$cfg" --no-color --log-rules "quickshell.hyprland.ipc.debug=true" 2>&1) || true
  if [[ -n $fake ]]; then
    kill "$fake" 2>/dev/null || true
    wait "$fake" 2>/dev/null || true
    fake=""
  fi
}

# The probe's verdict and the start-up check's end on a model that stays empty (no-socket, no-status).
check_empty() { # <label>
  if grep -q "lock-monitor-model: PASS empty" <<<"$out"; then
    pass "$1: the model stays empty, the lock was neither taken nor released"
  else
    bad "$1: $(grep -E 'lock-monitor-model:|ERROR|WARN qml' <<<"$out" | head -n 5)"
  fi
  local empty
  empty=$(count "monitor model is empty" "$out")
  if [[ $empty == 1 ]]; then pass "$1: the empty model was logged exactly once"; else bad "$1: the empty model was logged $empty times, not once"; fi
  if [[ $(count "compositor lock state unknown; relying on the crash recovery marker" "$out") == 1 && $(count "taking it over" "$out") == 0 ]]; then
    pass "$1: the start-up check ended unknown, without a takeover"
  else
    bad "$1: the start-up check did not end unknown without a takeover"
  fi
}

make_cfg "$tmp/cfg" keep
make_cfg "$tmp/cfg-control" remove

run nosocket none empty "$tmp/cfg"
check_empty "no Hyprland socket"
queries=$(monitor_queries "$out")
if [[ $queries == 1 ]]; then
  pass "no Hyprland socket: Quickshell's own monitors query is the only one (the lock sent none to the empty model)"
else
  bad "no Hyprland socket: $queries monitors queries, not 1 (Quickshell's own)"
fi
run nosocket-control none empty "$tmp/cfg-control"
queries=$(monitor_queries "$out")
if ((queries > 1)); then
  pass "control: with the guard removed the lock queries the empty model ($queries monitors queries)"
else
  bad "control: with the guard removed only $queries monitors queries: the check above cannot see the bug"
fi

if ! python3 -I -c 'import socket; socket.socket(socket.AF_UNIX).close()' 2>/dev/null; then
  echo "SKIP: lock monitor model: the fake Hyprland scenarios (slow-status, no-status, their control) need Unix sockets, which cannot be created here (sandbox): NOT VERIFIED"
  exit $fail
fi

run slow slow-status slow-status "$tmp/cfg"
if grep -q "lock-monitor-model: PASS slow-status" <<<"$out"; then
  pass "slow first answer: the model fills, the stranded lock is taken over, an answer reaches checkOwnership"
else
  bad "slow first answer: $(grep -E 'lock-monitor-model:|ERROR|WARN qml' <<<"$out" | head -n 5)"
fi
status_line=$(grep -n -m1 -x 'answered j/status' "$requests" | cut -d: -f1 || true)
monitors_line=$(grep -n -m1 -x 'request j/monitors' "$requests" | cut -d: -f1 || true)
if [[ -n $status_line && -n $monitors_line ]] && ((monitors_line > status_line)); then
  pass "slow first answer: no monitors query reached Hyprland before its first answer"
else
  bad "slow first answer: monitors query at line ${monitors_line:-none}, status answer at line ${status_line:-none}: $(head -n 6 "$requests" | tr '\n' ' ')"
fi
if [[ $(count "taking it over" "$out") == 1 ]]; then pass "slow first answer: the stranded lock was taken over once"; else bad "slow first answer: no takeover logged"; fi
empty=$(count "monitor model is empty" "$out")
resumed=$(count "lock state queries resume" "$out")
if ((empty <= 1 && resumed == empty)); then
  pass "slow first answer: the empty model was logged at most once ($empty), and its filling as often ($resumed)"
else
  bad "slow first answer: the empty model was logged $empty times, its filling $resumed times"
fi

run nostatus no-status empty "$tmp/cfg"
check_empty "no first answer"
queries=$(grep -c -x 'request j/monitors' "$requests" || true)
if [[ $queries == 0 ]]; then pass "no first answer: no monitors query reached Hyprland"; else bad "no first answer: $queries monitors queries reached Hyprland"; fi

run slow-control slow-status slow-status "$tmp/cfg-control"
if grep -q "lock-monitor-model: FAIL slow-status: model-filled" <<<"$out"; then
  pass "control: with the guard removed and a slow first answer the model never fills (the bug is seen)"
else
  bad "control: with the guard removed the slow-status probe did not fail on the model: $(grep 'lock-monitor-model:' <<<"$out" || echo 'no result')"
fi
exit $fail
