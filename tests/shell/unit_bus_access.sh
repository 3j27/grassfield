#!/usr/bin/env bash
# A user unit that talks to the session bus (notify-send, busctl, gdbus, D-Bus clients) must be able to reach
# /run/user/<uid>/bus: ProtectHome=yes or tmpfs (and InaccessiblePaths over /run/user) hide that directory (systemd.exec(5):
# ProtectHome=yes makes /home, /root AND /run/user inaccessible), so the crash and low-battery notices never arrived. The
# right hardening is ProtectHome=read-only. Static: every packaged unit's ExecStart (and the script it runs) is read.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
bus_users=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

for unit in "$root"/packaging/systemd/*.service "$root"/packaging/systemd/*/*.conf; do
  [[ -f $unit ]] || continue
  name=${unit#"$root"/packaging/systemd/}
  exec_line=$(sed -n 's/^ExecStart=//p' "$unit" | head -n1)
  body=$exec_line
  prog=${exec_line%% *}
  case $prog in
    /usr/lib/grassfield/*) [[ -f $root/packaging/bin/${prog##*/} ]] && body+=$'\n'$(<"$root/packaging/bin/${prog##*/}") ;;
  esac
  if grep -qE 'notify-send|busctl|gdbus|dbus-send|org\.freedesktop\.|Gio\.|QDBus' <<<"$body"; then
    bus_users=$((bus_users + 1))
    desc="$name talks to the session bus: ProtectHome is not yes/tmpfs and /run/user is not inaccessible"
    check bash -c '! grep -qE "^ProtectHome=(yes|true|tmpfs)$|^(Inaccessible|Temporary)Paths=.*(/run/user|/run( |$))" "$1"' _ "$unit"
  fi
done

desc="the scan is not vacuous: the crash, battery and migration notifiers are among the bus users"
check test "$bus_users" -ge 3
for u in crash-watch battery-watch migrate-notify; do
  desc="grassfield-$u.service is recognised as a session bus user"
  check bash -c 'prog=$(sed -n "s/^ExecStart=//p" "$1/packaging/systemd/grassfield-$2.service" | head -n1); grep -qE "notify-send|busctl|gdbus" "$1/packaging/bin/${prog##*/}"' _ "$root" "$u"
done
desc="the crash and battery watchers use ProtectHome=read-only (as menu-bridge, migrate-notify and automount do)"
check bash -c 'grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-crash-watch.service" && grep -qx "ProtectHome=read-only" "$1/packaging/systemd/grassfield-battery-watch.service"' _ "$root"
exit "$fail"
