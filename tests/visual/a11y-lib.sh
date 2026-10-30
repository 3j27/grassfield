#!/usr/bin/env bash
# Accessibility for the visual scripts (source it after lib.sh): an AT-SPI bus for the nested session's PRIVATE bus, and
# a11y_find, which finds a control of an app by its accessible role and name (tests/visual/a11y-find.py).
#
# The dev bus activates nothing (scripts/dev/dev-bus.conf: no service folder), so org.a11y.Bus is not there: a11y_start runs
# at-spi-bus-launcher itself as a client of that bus, then at-spi2-registryd (the accessibility bus would ask systemd to
# start it, and that fails: "unit failed"), each in its own process group, with a runtime folder, HOME and GSettings backend
# of their own (the accessibility bus socket goes in a fresh /tmp/gf-a11y-* folder, short enough for a Unix socket path like
# the private bus's own, never the owner's $XDG_RUNTIME_DIR/at-spi). a11y_stop ends both groups and removes the folder.
# Apps expose their tree when started with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (vs_spawn env ...).

a11y_pid=""
a11y_start_time=none
a11y_reg_pid=""
a11y_reg_start_time=none
a11y_run=""

a11y_bus() { cat "$VS_DEV/bus.address"; }

# a11y_owned BUS NAME: the name has an owner on that bus.
a11y_owned() {
  dbus-send --bus="$1" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner "string:$2" 2>/dev/null | grep -q "boolean true"
}
a11y_ready() { a11y_owned "$(a11y_bus)" org.a11y.Bus; }
# The accessibility bus's address (org.a11y.Bus GetAddress on the private bus).
a11y_address() {
  dbus-send --bus="$(a11y_bus)" --print-reply=literal --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null | tr -d ' '
}
a11y_registry_ready() {
  local address
  address=$(a11y_address)
  [[ -n $address ]] && a11y_owned "$address" org.a11y.atspi.Registry
}

# a11y_spawn LOG PROGRAM [ARGS...]: a helper on the private bus, in its own session, with this file's runtime folder.
a11y_spawn() {
  local log=$1
  shift
  env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS="$(a11y_bus)" XDG_RUNTIME_DIR="$a11y_run" \
    HOME="$a11y_run/home" GSETTINGS_BACKEND=memory setsid "$@" >"$log" 2>&1 </dev/null &
}

a11y_start() {
  local launcher=/usr/lib/at-spi-bus-launcher registry=/usr/lib/at-spi2-registryd bus i
  [[ -x $launcher && -x $registry ]] || { echo "a11y: $launcher or $registry is not installed (at-spi2-core)" >&2; return 1; }
  bus=$(a11y_bus)
  case $bus in unix:path=/tmp/dbus-*) ;; *) echo "a11y: refusing bus '$bus' (not the nested private bus)" >&2; return 1 ;; esac
  a11y_registry_ready && return 0
  a11y_run=$(mktemp -d /tmp/gf-a11y-XXXXXX) || return 1
  mkdir -p "$a11y_run/home"
  if ! a11y_ready; then
    a11y_spawn "$VS_STATE/a11y-launcher.log" "$launcher" --launch-immediately
    a11y_pid=$!
    a11y_start_time=$(dev_start_time "$a11y_pid" 2>/dev/null || echo none)
    for i in $(seq 1 50); do a11y_ready && break; sleep 0.1; done
    a11y_ready || { echo "a11y: at-spi-bus-launcher did not take org.a11y.Bus (see $VS_STATE/a11y-launcher.log)" >&2; return 1; }
  fi
  a11y_spawn "$VS_STATE/a11y-registryd.log" "$registry"
  a11y_reg_pid=$!
  a11y_reg_start_time=$(dev_start_time "$a11y_reg_pid" 2>/dev/null || echo none)
  for i in $(seq 1 50); do a11y_registry_ready && return 0; sleep 0.1; done
  echo "a11y: at-spi2-registryd did not take org.a11y.atspi.Registry (see $VS_STATE/a11y-registryd.log)" >&2
  return 1
}

# a11y_end PID START: ends that process group, only while the pid is still the process started here.
a11y_end() {
  if [[ -n $1 && $(dev_start_time "$1" 2>/dev/null) == "$2" ]] && dev_may_signal "$1"; then
    # Never a failure for the caller: lib.sh sets errexit, and wait returns the signal's status (143).
    kill -- "-$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
  fi
  return 0
}

a11y_stop() {
  a11y_end "$a11y_reg_pid" "$a11y_reg_start_time"
  a11y_end "$a11y_pid" "$a11y_start_time"
  a11y_reg_pid="" a11y_pid=""
  case $a11y_run in /tmp/gf-a11y-??????) rm -rf -- "$a11y_run" ;; esac
  a11y_run=""
  return 0
}

# a11y_find PID ROLE-REGEX NAME-REGEX [--state S]... [--press] [--wait SECONDS]: one JSON line, exit 0 when found.
a11y_find() {
  local pid=$1 role=$2 name=$3
  shift 3
  env DBUS_SESSION_BUS_ADDRESS="$(a11y_bus)" python3 -I "$VS_HERE/a11y-find.py" --pid "$pid" --role "$role" --name "$name" "$@"
}
