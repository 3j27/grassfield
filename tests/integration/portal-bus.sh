# shellcheck shell=bash
# A private D-Bus session bus for the portal tests (ADR-0035 D-4, D-8), sourced by tests/integration/portal_settings.sh and
# tests/integration/portal_filechooser.sh: its own configuration and service directory, never the owner's bus. The sourcing
# script sets `tmp` and traps EXIT to stop_bus; it reads `bus` (the address) and `bus_pid` after start_bus.
bus_pid="" frontend_pid=""

wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

stop_bus() {
  [[ -n $frontend_pid ]] && kill "$frontend_pid" 2>/dev/null && wait "$frontend_pid" 2>/dev/null
  frontend_pid=""
  # dbus-daemon leads its own process group (setsid): the services it activated are in it too.
  [[ -n $bus_pid ]] && kill -TERM -- "-$bus_pid" 2>/dev/null
  [[ -n $bus_pid ]] && wait "$bus_pid" 2>/dev/null
  bus_pid=""
}

bus_conf() { # bus_conf <dir> <listen address> <auth mechanism>
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>$2</listen>" "  <auth>$3</auth>"
  [[ $3 == ANONYMOUS ]] && printf '%s\n' '  <allow_anonymous/>'
  printf '%s\n' "  <servicedir>$1/services</servicedir>" '  <policy context="default">' \
    '    <allow send_destination="*" eavesdrop="true"/>' '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' \
    '</busconfig>'
}

start_bus() { # start_bus <dir>: sets bus and bus_pid; a unix socket, or loopback tcp where the sandbox refuses one
  bus_conf "$1" "unix:path=$1/bus.sock" EXTERNAL >"$1/bus.conf"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  if wait_until 3 test -s "$1/bus.address"; then bus=$(head -n 1 "$1/bus.address"); return 0; fi
  kill "$bus_pid" 2>/dev/null; wait "$bus_pid" 2>/dev/null; bus_pid=""
  bus_conf "$1" "tcp:host=127.0.0.1,port=0" ANONYMOUS >"$1/bus.conf"
  : >"$1/bus.address"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$1/bus.address" || return 1
  bus=$(head -n 1 "$1/bus.address")
}

has() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
import sys
from gi.repository import Gio, GLib
c = Gio.bus_get_sync(Gio.BusType.SESSION)
print(c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                  GLib.Variant("(s)", (sys.argv[1],)), None, Gio.DBusCallFlags.NONE, 3000, None).unpack()[0])' "$1" 2>/dev/null; }
owned() { [[ $(has "$1") == True ]]; }
unowned() { ! owned "$1"; }

start_service() { DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
import sys
from gi.repository import Gio, GLib
Gio.bus_get_sync(Gio.BusType.SESSION).call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "StartServiceByName", GLib.Variant("(su)", (sys.argv[1], 0)), None, Gio.DBusCallFlags.NONE, 5000, None)' "$1"; }
