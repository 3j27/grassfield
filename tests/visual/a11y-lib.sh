#!/usr/bin/env bash
# Accessibility for the visual scripts (source it after lib.sh): an AT-SPI bus for the nested session's PRIVATE bus, and
# a11y_find, which finds a control of an app by its accessible role and name (tests/visual/a11y-find.py).
#
# The dev bus activates nothing (scripts/dev/dev-bus.conf: no service folder), so org.a11y.Bus is not there: a11y_start runs
# at-spi-bus-launcher itself as a client of that bus, in its own process group, with a runtime folder, HOME and GSettings
# backend of its own (its accessibility bus socket goes in a fresh /tmp/gf-a11y-* folder, short enough for a Unix socket
# path like the private bus's own, never the owner's $XDG_RUNTIME_DIR/at-spi), and a11y_stop ends that group and removes the
# folder. Apps expose their tree when started with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 (vs_spawn env ...).

a11y_pid=""
a11y_start_time=none
a11y_run=""

a11y_bus() { cat "$VS_DEV/bus.address"; }

# The private bus has an org.a11y.Bus owner.
a11y_ready() {
  dbus-send --bus="$(a11y_bus)" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.a11y.Bus 2>/dev/null | grep -q "boolean true"
}

a11y_start() {
  local launcher=/usr/lib/at-spi-bus-launcher bus i
  [[ -x $launcher ]] || { echo "a11y: $launcher is not installed (at-spi2-core)" >&2; return 1; }
  bus=$(a11y_bus)
  case $bus in unix:path=/tmp/dbus-*) ;; *) echo "a11y: refusing bus '$bus' (not the nested private bus)" >&2; return 1 ;; esac
  a11y_ready && return 0
  a11y_run=$(mktemp -d /tmp/gf-a11y-XXXXXX) || return 1
  mkdir -p "$a11y_run/home"
  env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS="$bus" XDG_RUNTIME_DIR="$a11y_run" \
    HOME="$a11y_run/home" GSETTINGS_BACKEND=memory setsid "$launcher" --launch-immediately >"$VS_STATE/a11y-launcher.log" 2>&1 </dev/null &
  a11y_pid=$!
  a11y_start_time=$(dev_start_time "$a11y_pid" 2>/dev/null || echo none)
  for i in $(seq 1 50); do a11y_ready && return 0; sleep 0.1; done
  echo "a11y: at-spi-bus-launcher did not take org.a11y.Bus (see $VS_STATE/a11y-launcher.log)" >&2
  return 1
}

# Ends the launcher's process group (its accessibility bus and registry), only while the pid is still the one started here.
a11y_stop() {
  if [[ -n $a11y_pid && $(dev_start_time "$a11y_pid" 2>/dev/null) == "$a11y_start_time" ]] && dev_may_signal "$a11y_pid"; then
    kill -- "-$a11y_pid" 2>/dev/null
    wait "$a11y_pid" 2>/dev/null
  fi
  a11y_pid=""
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
