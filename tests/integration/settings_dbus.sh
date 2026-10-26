#!/usr/bin/env bash
# The Settings Wi-Fi and Bluetooth pages over D-Bus (GF-049), on a PRIVATE bus with FAKE NetworkManager and BlueZ services: the
# real code of apps/settings/src/systembus.cpp over a real D-Bus connection, nothing of the machine's network, Bluetooth or audio
# is reachable (the probe and the fakes refuse to start on anything but a private test bus).
#
#   1  the guard: the probe and the fakes refuse the real system bus and a missing GF_TEST_BUS (exit 2, before any connection)
#   2  wifi-state: radio, device, access points (the two "Home" ones, active flag, security flags), the saved Wi-Fi profile only
#   3  bt-state: adapter, powered, the paired devices (alias before name), not the unpaired one
#   4  Wi-Fi actions: radio, connect to a saved network, join an open one, a secured one is refused, disconnect, scan: each ends
#      in exactly the call the fake logged, with the arguments; the state follows
#   5  Bluetooth actions: power, connect, disconnect, likewise
#   6  failure feedback: a service's error becomes the short reason the page shows (permission, the service's own message)
#   7  dev guard: with the dev flag the state is read and every action is refused before it reaches the bus (the fake's log has
#      no new call)
#   8  a service that is not there: the reason says so
#
# Needs a private dbus-daemon (a unix socket in the test's own directory; loopback TCP with anonymous auth where sockets cannot be
# created, as in a sandbox), g++ with the Qt 6 headers, python3 + PyGObject. SKIPs (exit 0) without them. Exit: 0 PASS, 1 FAIL,
# 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }
wait_until() { # <seconds> <command...>
  local limit=$(($1 * 10)) i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

for tool in dbus-daemon python3 g++; do
  command -v "$tool" >/dev/null || { say "SKIP: settings_dbus needs $tool"; exit 0; }
done
[[ -f /usr/include/qt6/QtDBus/QDBusConnection ]] || { say "SKIP: settings_dbus needs the Qt 6 D-Bus headers"; exit 0; }
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { say "SKIP: settings_dbus needs PyGObject (gi, Gio)"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-settings-dbus.XXXXXX") || die "no temp dir"
chmod 700 "$work"
bus_pid="" nm_pid="" bz_pid=""
stop_all() {
  local p
  for p in "$nm_pid" "$bz_pid" "$bus_pid"; do
    [[ -n $p ]] && kill "$p" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf "$work"
}
trap stop_all EXIT

src=$root/apps/settings/src
g++ -std=c++17 -O1 -fPIC -Wno-sfinae-incomplete -I"$src" -I"$root/apps" -I/usr/include/qt6 -I/usr/include/qt6/QtCore -I/usr/include/qt6/QtDBus \
  "$root/tests/integration/settings_dbus/probe.cpp" "$src/systembus.cpp" "$src/systemguard.cpp" "$src/busjobs.cpp" -pthread -lQt6Core -lQt6DBus -o "$work/probe" 2>"$work/build.log" ||
  { cat "$work/build.log"; die "the probe did not build"; }

# The private bus: a unix socket in the test's own directory; else loopback TCP with anonymous authentication (a sandbox that
# forbids unix sockets): a bus that lives for this test and serves only the fakes below.
start_bus() {
  setsid dbus-daemon --session --nofork --address="unix:path=$work/bus.sock" --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
  bus_pid=$!
  if wait_until 3 test -s "$work/bus.address"; then
    bus=$(head -n 1 "$work/bus.address")
    return 0
  fi
  kill "$bus_pid" 2>/dev/null
  wait "$bus_pid" 2>/dev/null
  cat >"$work/tcp.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>tcp:host=127.0.0.1,port=0</listen>
  <auth>ANONYMOUS</auth>
  <allow_anonymous/>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
  : >"$work/bus.address"
  setsid dbus-daemon --config-file="$work/tcp.conf" --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$work/bus.address" || return 1
  bus=$(head -n 1 "$work/bus.address")
}
start_bus || die "no private bus ($work/bus.log)"
case $bus in
  unix:path=$work/bus.sock* | tcp:host=127.0.0.1,*) ;;
  *) die "unexpected bus address '$bus'" ;;
esac
say "private bus ${bus%%,guid*} (dbus-daemon pid $bus_pid)"

penv=(env -i PATH="$PATH" HOME="$work" XDG_RUNTIME_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work")
# GF_TEST_PRELOAD (optional): a library preloaded into the probe only. In a sandbox that has no interface but lo, libdbus cannot
# resolve its loopback TCP address (it asks getaddrinfo for AI_ADDRCONFIG), so such a run preloads a getaddrinfo that drops the flag.
probe() { timeout 30 "${penv[@]}" ${GF_TEST_PRELOAD:+LD_PRELOAD=$GF_TEST_PRELOAD} "$work/probe" "$@" 2>&1; }

start_service() { # nm|bluez [--fail ...]: sets nm_pid / bz_pid
  local which=$1
  shift
  rm -f "$work/$which.ready"
  : >"$work/$which.log"
  setsid "${penv[@]}" python3 -I "$root/tests/fixtures/fake-system-service.py" "$which" --log "$work/$which.log" --ready "$work/$which.ready" "$@" >"$work/$which.err" 2>&1 </dev/null &
  if [[ $which == nm ]]; then nm_pid=$!; else bz_pid=$!; fi
  wait_until 10 test -e "$work/$which.ready" || { cat "$work/$which.err"; die "the fake $which did not start"; }
}
stop_service() { # nm|bluez
  local pid
  if [[ $1 == nm ]]; then pid=$nm_pid nm_pid=""; else pid=$bz_pid bz_pid=""; fi
  [[ -n $pid ]] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  sleep 0.3
}
# py <json> <python expression over `j`>: true when it holds
py() { python3 -I -c 'import json, sys; j = json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }
# logged <nm|bluez> <member> <path-substring> <args-substring>: the fake logged such a call
logged() {
  python3 -I -c '
import json, sys
log, member, path, args = sys.argv[1:5]
for line in open(log):
    e = json.loads(line)
    if e["member"] == member and path in e["path"] and args in e["args"]:
        sys.exit(0)
sys.exit(1)' "$work/$1.log" "$2" "$3" "$4"
}
calls() { wc -l <"$work/$1.log" | tr -d ' '; }

# Preflight: libdbus must be able to reach this bus at all (an environment that forbids unix sockets and has no loopback address
# for libdbus to resolve cannot run this test: SKIP, it says nothing about the code).
pre=$(probe wifi-state)
case $pre in
  *"not connected"*) say "SKIP: settings_dbus: this environment gives libdbus no way to a private bus (${pre%%$'\n'*})"; exit 0 ;;
esac

start_service nm
start_service bluez

say ""
say "[1] the guard"
# The refusal parses the address: only unix:path=<socket under the scratch directory> or loopback tcp pass (every entry).
refused() { # ADDRESS...: the probe and the fake service both exit non-zero on it, whatever spelling it has
  local addr=$1 rc
  env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$addr" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 2 ]] || return 1
  rm -f "$work/x.ready"
  env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$addr" timeout 10 python3 -I "$root/tests/fixtures/fake-system-service.py" nm --log "$work/x.log" --ready "$work/x.ready" >/dev/null 2>&1
  [[ $? -ne 0 && ! -e "$work/x.ready" ]]
}
out=$(env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket timeout 10 "$work/probe" wifi-state 2>&1)
rc=$?
check "the probe refuses the real system bus (exit 2: $out)" test "$rc" -eq 2
check "both refuse unix:path=/var/run/dbus/system_bus_socket" refused unix:path=/var/run/dbus/system_bus_socket
check "both refuse the same socket percent-escaped (unix:path=%2Frun%2Fdbus%2Fsystem_bus_socket)" refused 'unix:path=%2Frun%2Fdbus%2Fsystem_bus_socket'
check "both refuse a path that only starts like the scratch directory ($work/../x)" refused "unix:path=$work/../x.sock"
check "both refuse a socket next to the scratch directory (${work}x/bus)" refused "unix:path=${work}x/bus.sock"
check "both refuse an abstract socket, runtime=, systemd: and an unknown transport" bash -c '
  for a in "unix:abstract=/tmp/x" "unix:runtime=yes" "systemd:" "launchd:env=X" "nonce-tcp:host=127.0.0.1,port=1" "tcp:host=192.0.2.1,port=1" "tcp:port=1"; do
    env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$1" DBUS_SYSTEM_BUS_ADDRESS="$a" timeout 10 "$1/probe" wifi-state >/dev/null 2>&1
    [[ $? -eq 2 ]] || { echo "the probe did not refuse: $a"; exit 1; }
    rm -f "$1/x.ready"
    env -i PATH="$PATH" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$1" DBUS_SYSTEM_BUS_ADDRESS="$a" timeout 10 python3 -I "$2/tests/fixtures/fake-system-service.py" nm --log "$1/x.log" --ready "$1/x.ready" >/dev/null 2>&1
    { [[ $? -ne 0 ]] && [[ ! -e "$1/x.ready" ]]; } || { echo "the fake service did not refuse: $a"; exit 1; }
  done' _ "$work" "$root"
check "both refuse a list that hides the real bus after a private entry" refused "unix:path=$work/bus.sock;unix:path=/run/dbus/system_bus_socket"
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS_DIR="$work" DBUS_SYSTEM_BUS_ADDRESS="$bus" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run without GF_TEST_BUS=1" test "$?" -eq 2
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 DBUS_SYSTEM_BUS_ADDRESS="$bus" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run without GF_TEST_BUS_DIR" test "$?" -eq 2
env -i PATH="$PATH" HOME="$work" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$work" timeout 10 "$work/probe" wifi-state >/dev/null 2>&1
check "the probe refuses a run with no bus address" test "$?" -eq 2

say ""
say "[2] Wi-Fi state"
st=$(probe wifi-state)
check "the state is JSON of a Wi-Fi radio that is on, with the device wlan0 connected" py "$st" 'j["radio"] is True and j["device"] == {"name": "wlan0", "connected": True}'
check "three access points: Home (active, strong), Home (weak), Cafe (open)" py "$st" 'len(j["aps"]) == 3 and [a["hex"] for a in j["aps"]].count("486F6D65") == 2 and sum(a["active"] for a in j["aps"]) == 1'
check "the open network has no security flags, the others carry RSN flags" py "$st" '[a["rsn"] for a in j["aps"] if a["hex"] == "43616665"] == [0] and all(a["rsn"] == 0x188 for a in j["aps"] if a["hex"] == "486F6D65")'
check "only the Wi-Fi profile is listed (the Ethernet one is not), with its SSID" py "$st" 'j["profiles"] == [{"uuid": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "hex": "486F6D65"}]'
reads=$(calls nm)
check "reading made only read calls (no Set, no Activate, no Disconnect, no scan)" bash -c '! grep -qE "\"member\": \"(Set|ActivateConnection|AddAndActivateConnection|Disconnect|RequestScan)\"" "$1"' _ "$work/nm.log"
check "the fake saw the 5 method reads (GetDevices, GetAllAccessPoints, ListConnections, 2 x GetSettings; property reads are served by GDBus itself): $reads" test "$reads" -eq 5

say ""
say "[3] Bluetooth state"
bt=$(probe bt-state)
check "an adapter that is present and powered" py "$bt" 'j["present"] is True and j["powered"] is True'
check "the two paired devices, the alias before the name, connected as the fake says" py "$bt" 'sorted((d["mac"], d["name"], d["connected"]) for d in j["devices"]) == [("11:22:33:44:55:66", "Mouse", False), ("AA:BB:CC:DD:EE:FF", "Headphones", True)]'
check "the device that is only seen, not paired, is not listed" py "$bt" 'all(d["mac"] != "66:66:66:66:66:66" for d in j["devices"])'

say ""
say "[4] Wi-Fi actions"
out=$(probe act '{"op":"wifi.radio","on":false}')
check "radio off: ok" test "$out" = ok
check "... the fake got Set WirelessEnabled false on the NetworkManager object" logged nm Set /org/freedesktop/NetworkManager "WirelessEnabled false"
check "... and the state now says radio off with no access points listed" py "$(probe wifi-state)" 'j["radio"] is False and j["aps"] == []'
out=$(probe act '{"op":"wifi.radio","on":true}')
check "radio on: ok, and the state follows" py "$(probe wifi-state)" 'j["radio"] is True and len(j["aps"]) == 3'
out=$(probe act '{"op":"wifi.connectKnown","uuid":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"}')
check "connect to the saved network: ok" test "$out" = ok
check "... ActivateConnection(profile 1, device wlan0, \"/\")" logged nm ActivateConnection /org/freedesktop/NetworkManager "'/org/freedesktop/NetworkManager/Settings/1', objectpath '/org/freedesktop/NetworkManager/Devices/2', objectpath '/'"
before=$(calls nm)
out=$(probe act '{"op":"wifi.connectOpen","hex":"486F6D65"}')
check "a secured network is not joined from here: the reason says so" test "$out" = "failed: that network needs a password"
check "... and nothing was sent" test "$(calls nm)" -gt "$before" -a "$(grep -c AddAndActivateConnection "$work/nm.log")" -eq 0
out=$(probe act '{"op":"wifi.connectOpen","hex":"43616665"}')
check "join the open network Cafe: ok" test "$out" = ok
check "... AddAndActivateConnection with the access point Cafe, a Wi-Fi profile named Cafe and no security section" bash -c 'grep AddAndActivateConnection "$1" | grep -q "AccessPoint/3" && grep AddAndActivateConnection "$1" | grep -q "802-11-wireless" && ! grep AddAndActivateConnection "$1" | grep -q "security"' _ "$work/nm.log"
out=$(probe act '{"op":"wifi.disconnect"}')
check "disconnect: ok, Disconnect on wlan0, the state says not connected" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Disconnect reached the Wi-Fi device" logged nm Disconnect /Devices/2 ""
check "... the state says not connected" py "$(probe wifi-state)" 'j["device"]["connected"] is False and not any(a["active"] for a in j["aps"])'
out=$(probe act '{"op":"wifi.scan"}')
check "scan: ok, RequestScan on wlan0" bash -c '[[ $1 == ok ]]' _ "$out"
check "... RequestScan reached the Wi-Fi device" logged nm RequestScan /Devices/2 ""
before=$(calls nm)
out=$(probe act '{"op":"wifi.connectKnown","uuid":"not-a-uuid"}')
check "a malformed action is refused before the bus (invalid request, no call)" bash -c '[[ $1 == "failed: invalid request" && $(wc -l <"$2") -eq $3 ]]' _ "$out" "$work/nm.log" "$before"

say ""
say "[5] Bluetooth actions"
out=$(probe act '{"op":"bt.power","on":false}')
check "power off: ok, Set Powered false on the adapter, the state follows" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Set Powered false on /org/bluez/hci0" logged bluez Set /org/bluez/hci0 "Powered false"
check "... the state says not powered" py "$(probe bt-state)" 'j["powered"] is False'
probe act '{"op":"bt.power","on":true}' >/dev/null
out=$(probe act '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}')
check "connect the Mouse: ok, Connect on its object, the state follows" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Connect reached dev_11_22_33_44_55_66" logged bluez Connect /org/bluez/hci0/dev_11_22_33_44_55_66 ""
check "... the Mouse is connected now" py "$(probe bt-state)" '[d["connected"] for d in j["devices"] if d["mac"] == "11:22:33:44:55:66"] == [True]'
out=$(probe act '{"op":"bt.connect","mac":"aa:bb:cc:dd:ee:ff","connect":false}')
check "disconnect the Headphones (lower-case address): ok, Disconnect on their object" bash -c '[[ $1 == ok ]]' _ "$out"
check "... Disconnect reached dev_AA_BB_CC_DD_EE_FF" logged bluez Disconnect /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF ""
out=$(probe act '{"op":"bt.connect","mac":"01:02:03:04:05:06","connect":true}')
check "a device that is not paired: the reason says so" test "$out" = "failed: that device is no longer paired"
out=$(probe act '{"op":"bt.connect","mac":"66:66:66:66:66:66","connect":true}')
check "a device that is seen but not paired is not connected: the reason says so" test "$out" = "failed: that device is not paired yet"
check "... and no Connect reached it" bash -c '! grep -q "dev_66_66_66_66_66_66.*\"member\": \"Connect\"" "$1"' _ "$work/bluez.log"

say ""
say "[6] failure feedback"
stop_service nm
start_service nm --fail 'ActivateConnection=org.freedesktop.NetworkManager.PermissionDenied|Not authorized to control networking'
out=$(probe act '{"op":"wifi.connectKnown","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}')
check "a refused activation gives the page a reason ($out)" test "$out" = "failed: not allowed: the system refused the request"
stop_service nm
start_service nm --fail 'Disconnect=org.freedesktop.NetworkManager.Device.NotActive|The device is not active'
out=$(probe act '{"op":"wifi.disconnect"}')
check "the service's own message is the reason ($out)" test "$out" = "failed: The device is not active"
stop_service bluez
start_service bluez --fail 'Connect=org.bluez.Error.Failed|Software caused connection abort'
out=$(probe act '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}')
check "a failed Bluetooth connect gives BlueZ's message ($out)" test "$out" = "failed: Software caused connection abort"

say ""
say "[7] dev guard"
stop_service nm
stop_service bluez
start_service nm
start_service bluez
before_nm=$(calls nm)
before_bz=$(calls bluez)
out=$(probe --dev wifi-state)
check "a dev session still reads the Wi-Fi state" py "$out" 'j["radio"] is True and len(j["aps"]) == 3'
check "a dev session still reads the Bluetooth state" py "$(probe --dev bt-state)" 'len(j["devices"]) == 2'
fine=1
for op in '{"op":"wifi.radio","on":false}' '{"op":"wifi.connectKnown","uuid":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"}' '{"op":"wifi.connectOpen","hex":"43616665"}' '{"op":"wifi.disconnect"}' '{"op":"wifi.scan"}' \
  '{"op":"bt.power","on":false}' '{"op":"bt.connect","mac":"11:22:33:44:55:66","connect":true}'; do
  out=$(probe --dev act "$op")
  case $out in "failed: dev guard"*) ;; *) fine=0; say "    not refused: $op -> $out" ;; esac
done
check "in a dev session every action is refused by the guard" test "$fine" -eq 1
check "... and none of them reached either bus service: only reads in the logs" bash -c '! grep -qE "\"member\": \"(Set|ActivateConnection|AddAndActivateConnection|Disconnect|RequestScan|Connect)\"" "$1" "$2"' _ "$work/nm.log" "$work/bluez.log"

say ""
say "[8] a service that is not there"
stop_service nm
stop_service bluez
out=$(probe wifi-state)
check "no NetworkManager: the reason says the service is not running ($out)" test "$out" = "failed: the service is not running"
out=$(probe bt-state)
check "no BlueZ: likewise ($out)" test "$out" = "failed: the service is not running"
out=$(probe act '{"op":"wifi.radio","on":false}')
check "an action on a service that is not there fails with that reason ($out)" test "$out" = "failed: the service is not running"

say ""
say "[9] the window closes while a service is slow"
start_service bluez --slow Connect=5
start=$SECONDS
out=$(probe close-midjob)
rc=$?
check "no callback after the close, the destructor does not wait for the service, the stuck job is abandoned ($out)" test "$rc" -eq 0
check "... and the process is gone long before the service answers (took $((SECONDS - start)) s of its 5 s)" test "$((SECONDS - start))" -lt 4
stop_service bluez

say ""
if ((fail)); then say "FAIL"; else say "PASS"; fi
exit "$fail"
