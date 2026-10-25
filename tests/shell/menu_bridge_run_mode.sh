#!/usr/bin/env bash
# The menu bridge's run mode (ADR-0019, refactor slice M7), at the binary: a GRASSFIELD_DEV=1 that leaked into a
# Grassfield session (GRASSFIELD_SESSION=1) must not change anything. Before M7 the bridge took the development branch
# there, refused the session's bus and global menus stopped. The pure rule is unit-tested against the shared vectors
# (tests/unit/menu-bridge, Safety.*); this runs the built bridge itself:
#   A  leaked dev in a session: the bridge starts as a session bridge ("(session)" in its start line, the leak noted),
#      listens on the session socket ($XDG_RUNTIME_DIR/grassfield/menu-bridge.sock) and stops cleanly on SIGTERM
#   B  a development run (GRASSFIELD_SESSION unset) keeps its guards: without GRASSFIELD_MENU_BRIDGE_SOCKET it refuses
#      (exit 3)
#   C  a development run with its socket starts as one ("(development, private bus)")
#   D  neither a session nor a development run: refused (exit 3)
# SAFETY (D-Bus, R3): every bridge runs under `env -i` on a PRIVATE bus (dbus-daemon listening in this test's scratch
# directory; a guard refuses any other address) with a scratch HOME and XDG_RUNTIME_DIR; it never sees the owner's bus.
# SKIP where Unix sockets cannot be created. The bridge is built with bridges/menu-bridge/build-direct.sh when missing or
# older than its sources.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/menu-bridge-mode.XXXXXX")
bridge_pid=""
cleanup() {
  [[ -n $bridge_pid ]] && kill "$bridge_pid" 2>/dev/null
  [[ -f $tmp/bus.pid ]] && kill "$(cat "$tmp/bus.pid")" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
fail=0
check() { if [[ $2 == 1 ]]; then echo "PASS: $1"; else echo "FAIL: $1${3:+ ($3)}"; fail=1; fi; }

bin=$root/.dev/build/grassfield-menu-bridge
newest=$(find "$root/bridges/menu-bridge/src" "$root/bridges/menu-bridge/build-direct.sh" -type f -newer "$bin" 2>/dev/null | head -n1)
if [[ ! -x $bin || -n $newest ]]; then
  "$root/bridges/menu-bridge/build-direct.sh" >/dev/null 2>"$tmp/build.log" || { echo "FAIL: the bridge does not build ($(tail -n 3 "$tmp/build.log"))"; exit 1; }
fi

mkdir -m 700 "$tmp/bus" "$tmp/home" "$tmp/run"
cat >"$tmp/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:dir=$tmp/bus</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>
EOF
addr=$(env -i PATH=/usr/bin:/bin dbus-daemon --config-file="$tmp/bus.conf" --fork --print-address=1 --print-pid=3 3>"$tmp/bus.pid" 2>/dev/null || true)
if [[ -z $addr ]]; then
  rm -f "$tmp/bus.pid"
  echo "SKIP: menu bridge run mode: dbus-daemon cannot listen here (no Unix sockets in this environment): NOT VERIFIED"
  exit 0
fi
if [[ $addr != "unix:path=$tmp/bus/"* || $addr == *"/run/user/"* || (-n ${DBUS_SESSION_BUS_ADDRESS:-} && $addr == "$DBUS_SESSION_BUS_ADDRESS"*) ]]; then
  echo "FAIL: refusing a bus address outside the test's directory ($addr)"
  exit 1
fi

# The bridge with only the given variables (plus the private bus and the scratch homes): <log> <VAR=value...>
start_bridge() {
  local log=$1
  shift
  env -i PATH=/usr/bin:/bin HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" DBUS_SESSION_BUS_ADDRESS="$addr" "$@" "$bin" >"$log" 2>&1 </dev/null &
  bridge_pid=$!
}
# Waits up to 10 s for the bridge to listen or to exit: sets `state` to "listening", "exit <rc>" or "timeout". Not in a
# subshell: `wait` needs the bridge as this shell's child.
settle() {
  local i
  state=timeout
  for i in $(seq 1 100); do
    grep -q "listening on" "$1" 2>/dev/null && { state=listening; return; }
    if ! kill -0 "$bridge_pid" 2>/dev/null; then
      wait "$bridge_pid"
      state="exit $?"
      bridge_pid=""
      return
    fi
    sleep 0.1
  done
}
# SIGTERM, then sets `rc` to the bridge's exit status (0: a clean stop).
stop_bridge() {
  rc=""
  [[ -n $bridge_pid ]] || return
  kill -TERM "$bridge_pid" 2>/dev/null
  wait "$bridge_pid"
  rc=$?
  bridge_pid=""
}

# A: leaked dev in a Grassfield session.
start_bridge "$tmp/a.log" GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1
settle "$tmp/a.log"
check "A: a leaked GRASSFIELD_DEV=1 in a session: the bridge starts and listens" "$([[ $state == listening ]] && echo 1)" "$state: $(tr '\n' ' ' <"$tmp/a.log" | cut -c1-300)"
check "A: as a session bridge (\"(session)\"), not a development one" "$(grep -q "(session)" "$tmp/a.log" && ! grep -q "development" "$tmp/a.log" && echo 1)" "$(grep -a "on :" "$tmp/a.log" | head -1)"
check "A: the leak is noted, nothing refused" "$(grep -q "GRASSFIELD_DEV=1 ignored" "$tmp/a.log" && ! grep -q "refusing" "$tmp/a.log" && echo 1)"
check "A: on the session socket (\$XDG_RUNTIME_DIR/grassfield/menu-bridge.sock)" "$([[ -S $tmp/run/grassfield/menu-bridge.sock ]] && echo 1)"
if [[ -n $bridge_pid ]]; then
  stop_bridge
  check "A: stops cleanly on SIGTERM" "$([[ $rc == 0 ]] && echo 1)" "exit $rc"
fi

# B: a development run without its socket keeps its guard.
start_bridge "$tmp/b.log" GRASSFIELD_DEV=1
settle "$tmp/b.log"
check "B: a development run without GRASSFIELD_MENU_BRIDGE_SOCKET is refused (exit 3)" \
  "$([[ $state == "exit 3" ]] && grep -q "needs GRASSFIELD_MENU_BRIDGE_SOCKET" "$tmp/b.log" && echo 1)" "$state: $(tr '\n' ' ' <"$tmp/b.log" | cut -c1-200)"
stop_bridge

# C: a development run with its socket starts as one.
start_bridge "$tmp/c.log" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$tmp/run/dev.sock"
settle "$tmp/c.log"
check "C: a development run with its socket starts as one (\"(development, private bus)\")" \
  "$([[ $state == listening ]] && grep -q "(development, private bus)" "$tmp/c.log" && echo 1)" "$state: $(tr '\n' ' ' <"$tmp/c.log" | cut -c1-200)"
stop_bridge

# D: neither.
start_bridge "$tmp/d.log"
settle "$tmp/d.log"
check "D: neither a session nor a development run is refused (exit 3)" \
  "$([[ $state == "exit 3" ]] && grep -q "not in a Grassfield session" "$tmp/d.log" && echo 1)" "$state"
stop_bridge

exit "$fail"
