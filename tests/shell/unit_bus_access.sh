#!/usr/bin/env bash
# A user unit that talks to the session bus (notify-send, busctl, gdbus, D-Bus clients) must be able to reach
# /run/user/<uid>/bus: ProtectHome=yes (also true, 1, on) or tmpfs, TemporaryFileSystem= and InaccessiblePaths= over /run/user
# or /run hide that directory (systemd.exec(5): ProtectHome=yes makes /home, /root AND /run/user inaccessible), so the crash and
# low-battery notices never arrived. The right hardening is ProtectHome=read-only. Static: every packaged unit's ExecStart (and
# the script it runs) is read. The detector is proven by mutation below: each hiding setting, added to a copy of a bus user,
# must be caught.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/unit-bus.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
bus_users=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
# Compiled bus clients (no script to read): named here.
BINARY_BUS_UNITS="grassfield-menu-bridge.service"

# hides_bus FILE: true when the unit hides /run/user (and so the session bus socket).
hides_bus() {
  grep -qiE '^[[:space:]]*ProtectHome[[:space:]]*=[[:space:]]*(yes|true|1|on|tmpfs)[[:space:]]*$' "$1" ||
    grep -qiE '^[[:space:]]*(TemporaryFileSystem|InaccessiblePaths|InaccessibleDirectories)[[:space:]]*=[[:space:]]*([^#]*[[:space:]:-])?/run(/user)?(/[^[:space:]:]*)?(:[^[:space:]]*)?([[:space:]]|$)' "$1"
}

for unit in "$root"/packaging/systemd/*.service "$root"/packaging/systemd/*/*.conf; do
  [[ -f $unit ]] || continue
  name=${unit#"$root"/packaging/systemd/}
  exec_line=$(sed -n 's/^ExecStart=//p' "$unit" | head -n1)
  body=$exec_line
  prog=${exec_line%% *}
  case $prog in
    /usr/lib/grassfield/*) [[ -f $root/packaging/bin/${prog##*/} ]] && body+=$'\n'$(<"$root/packaging/bin/${prog##*/}") ;;
  esac
  is_bus=0
  grep -qE 'notify-send|busctl|gdbus|dbus-send|org\.freedesktop\.|Gio\.|QDBus' <<<"$body" && is_bus=1
  [[ " $BINARY_BUS_UNITS " == *" $(basename "$unit") "* ]] && is_bus=1
  if ((is_bus)); then
    bus_users=$((bus_users + 1))
    desc="$name talks to the session bus: nothing in it hides /run/user (ProtectHome yes/true/1/on/tmpfs, TemporaryFileSystem=, InaccessiblePaths=)"
    if hides_bus "$unit"; then echo "FAIL: $desc"; fail=1; else echo "PASS: $desc"; fi
  fi
done

desc="the scan is not vacuous: the crash, battery and migration notifiers and the menu bridge are among the bus users"
check test "$bus_users" -ge 4
for u in crash-watch battery-watch migrate-notify; do
  desc="grassfield-$u.service is recognised as a session bus user"
  check bash -c 'prog=$(sed -n "s/^ExecStart=//p" "$1/packaging/systemd/grassfield-$2.service" | head -n1); grep -qE "notify-send|busctl|gdbus" "$1/packaging/bin/${prog##*/}"' _ "$root" "$u"
done
desc="the crash and battery watchers use ProtectHome=read-only (as menu-bridge, migrate-notify and automount do)"
check bash -c 'grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-crash-watch.service" && grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-battery-watch.service"' _ "$root"

# ---- mutation: the detector catches every way of hiding /run/user, and none of the safe settings ----
mutant() { # <line>: a copy of the crash watcher with the line added
  cp "$root/packaging/systemd/grassfield-crash-watch.service" "$tmp/m.service"
  sed -i '/^ProtectHome=/d' "$tmp/m.service"
  printf '%s\n' "$1" >>"$tmp/m.service"
}
for line in 'ProtectHome=yes' 'ProtectHome=true' 'ProtectHome=1' 'ProtectHome=on' 'ProtectHome=tmpfs' 'ProtectHome = yes' 'ProtectHome=YES' \
  'TemporaryFileSystem=/run/user' 'TemporaryFileSystem=/run' 'TemporaryFileSystem=/run/user:ro' 'InaccessiblePaths=/run/user' 'InaccessiblePaths=-/run/user' \
  'InaccessiblePaths=/run' 'InaccessiblePaths=/proc /run/user/1000'; do
  mutant "$line"
  desc="mutation: '$line' on a bus user is caught"
  if hides_bus "$tmp/m.service"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
done
for line in 'ProtectHome=read-only' 'ProtectHome=no' 'ProtectHome=0' 'InaccessiblePaths=/proc' 'TemporaryFileSystem=/var'; do
  mutant "$line"
  desc="safe setting '$line' is not flagged"
  if hides_bus "$tmp/m.service"; then echo "FAIL: $desc"; fail=1; else echo "PASS: $desc"; fi
done
# The menu bridge (a compiled client) is covered: the same mutation on it is caught through the scan's own list.
cp "$root/packaging/systemd/grassfield-menu-bridge.service" "$tmp/b.service"
sed -i 's/^ProtectHome=read-only/ProtectHome=yes/' "$tmp/b.service"
desc="mutation: ProtectHome=yes on grassfield-menu-bridge.service is caught, and the bridge is in the bus list"
if hides_bus "$tmp/b.service" && [[ " $BINARY_BUS_UNITS " == *" grassfield-menu-bridge.service "* ]]; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
exit "$fail"
