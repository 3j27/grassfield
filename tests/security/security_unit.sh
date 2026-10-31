#!/usr/bin/env bash
# ADR-0041 step 1, S1 (the owner's SQ-1 B): the security process runs beside the UI and hosts nothing moved yet. Static
# (data layer): the root shell/security.qml (a root of its own next to shell.qml, imports only QtQuick, Quickshell and
# Quickshell.Io, never reloads on a file change, one IpcHandler `security` with `state` and `heartbeat`, instantiates
# ShellRoot and IpcHandler only and names no loader, process, URL opener or security module: tests/security/root_check.py
# reads it as the engine does, comments stripped and the file joined, with a selftest of planted mutants),
# grassfield-security.service (loads that root by path from the system tree, the same cleared environment as the UI's
# unit, Restart=always with a start limit a loop reaches, session-only, no NoNewPrivileges for the helpers of S2/S3, memory
# guards from the measurement and the UI unit's CPU quota), the autostart (started just before
# the shell, --no-block), the PKGBUILD, grassfield-security-status (read-only, calls the target by the unit's path), and the
# IPC surface table. qmllint parses the root when it is installed. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
check() { if "$@"; then echo "PASS: security unit $desc"; else echo "FAIL: security unit $desc"; fail=1; fi; }
qml=shell/security.qml
unit=packaging/systemd/grassfield-security.service
ui=packaging/systemd/grassfield-shell.service
helper=packaging/bin/grassfield-security-status

desc="root: a root of its own next to shell.qml"
check bash -c '[[ -f "$1" && -f shell/shell.qml ]]' _ "$qml"
desc="root: read as the engine reads it (comments stripped, the file joined, imports wherever they stand): imports QtQuick, Quickshell and Quickshell.Io only, instantiates ShellRoot and IpcHandler only, names no loader, process, URL opener, Qt. or qs. name, regex literal, template string or security module"
check python3 -I tests/security/root_check.py "$qml"
desc="root check selftest: the root passes and each planted mutant (a next-line brace, a comment before the brace, an indented or tab import, a singleton's property, execDetached, openUrlExternally, Process, callLater, a Loader, a file import, a regex literal, a template string, a dynamic import, a Component, eval) is refused"
check python3 -I tests/security/root_check.py --selftest "$qml"
desc="root: never reloads on a file change (settings.watchFiles: false)"
check grep -qE '^\s*settings\.watchFiles: false' "$qml"
desc="root: one IpcHandler, target security, functions state and heartbeat, and nothing else that answers IPC"
check bash -c '[[ $(grep -c "IpcHandler {" "$1") == 1 ]] && grep -qE "^\s*target: \"security\"" "$1" && grep -qE "^\s*function state\(\): string" "$1" && grep -qE "^\s*function heartbeat\(\): string" "$1" && [[ $(grep -cE "^\s*function " "$1") == 2 ]]' _ "$qml"
desc="root: logs its ready line for the start-time measurement"
check grep -q 'grassfield-security: ready' "$qml"
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  desc="root: qmllint parses it (unknown-module warnings aside)"
  check bash -c '/usr/lib/qt6/bin/qmllint "$1" 2>&1 | grep -v -i -E "warning" | grep -qi "error" && exit 1; exit 0' _ "$qml"
else
  echo "NOTE: security unit root: qmllint not installed here (syntax NOT VERIFIED by this run)"
fi

desc="unit: loads the root by its path in the system tree (GF-115), no -c, with -n"
check grep -qx 'ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell/security.qml' "$unit"
desc="unit: the same cleared environment as the UI's unit (both UnsetEnvironment= lines identical, the same Environment=)"
check bash -c '[[ "$(grep "^UnsetEnvironment=" "$1")" == "$(grep "^UnsetEnvironment=" "$2")" && "$(grep "^Environment=" "$1")" == "$(grep "^Environment=" "$2")" ]]' _ "$unit" "$ui"
desc="unit: Restart=always, RestartSec=1, a start limit a loop reaches (5 in 300 s), session-only, part of and requiring the session target"
check bash -c 'grep -qx "Restart=always" "$1" && grep -qx "RestartSec=1" "$1" && grep -qx "StartLimitIntervalSec=300" "$1" && grep -qx "StartLimitBurst=5" "$1" && grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "PartOf=graphical-session.target" "$1" && grep -qx "Requisite=graphical-session.target" "$1" && grep -qx "Slice=session.slice" "$1"' _ "$unit"
desc="unit: no NoNewPrivileges, ProtectSystem or sandbox that would break unix_chkpwd and polkit-agent-helper-1 (S2, S3), as the UI's unit"
check bash -c '! grep -qE "^(NoNewPrivileges|ProtectSystem|ProtectHome|PrivateUsers|SystemCallFilter|CapabilityBoundingSet)=" "$1"' _ "$unit"
desc="unit: no OnFailure= yet (S2 moves the sleep lock here with the inhibitor); memory guards from the measurement (157 MB nested: MemoryHigh at least twice it, MemoryMax above MemoryHigh); CPUQuota at least a whole core, as the UI unit's"
check bash -c '! grep -q "^OnFailure=" "$1" && high=$(sed -nE "s/^MemoryHigh=([0-9]+)M$/\1/p" "$1") && max=$(sed -nE "s/^MemoryMax=([0-9]+)M$/\1/p" "$1") && cpu=$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$1") && [[ -n $high && -n $max && -n $cpu ]] && ((high >= 314 && max > high && cpu >= 100)) && [[ $cpu == "$(sed -nE "s/^CPUQuota=([0-9]+)%$/\1/p" "$2")" ]] && grep -q "157 MB" "$1"' _ "$unit" "$ui"
desc="autostart: started just before the shell, without waiting for it (--no-block), and the shell still starts if it failed"
check bash -c 'grep -q "systemctl --user start --no-block grassfield-security.service; systemctl --user start grassfield-shell.service" "$1"' _ config/hypr/grassfield/autostart.lua
desc="package: the unit is installed with the session units; the root ships with the shell tree; the helper from packaging/bin"
check bash -c 'grep -q "for unit in .*security" "$1" && grep -q "cp -a --no-preserve=ownership \"\$root/shell\" \"\$pkgdir/usr/share/grassfield/shell\"" "$1"' _ packaging/arch/PKGBUILD
desc="helper: read-only, calls the target by the unit's path with Quickshell's option variables cleared, never start, stop, kill or unlock"
check bash -c '[[ -x "$1" ]] && grep -q "unset QS_CONFIG_PATH QS_CONFIG_NAME QS_MANIFEST" "$1" && grep -q "call security state" "$1" && grep -q "call security heartbeat" "$1" && ! grep -v "^#" "$1" | grep -qE "systemctl --user (start|stop|kill|restart|reset-failed)|unlock|kill "' _ "$helper"
desc="helper: works from a TTY: --any-display when WAYLAND_DISPLAY is not set (the instance is on another display connection), never inside the session"
check bash -c 'grep -q "\[ -n \"\${WAYLAND_DISPLAY:-}\" \] || display=\"--any-display\"" "$1" && [[ $(grep -c "qs ipc \$display -p" "$1") == 2 ]]' _ "$helper"
desc="IPC surface: the table lists target security with state and heartbeat as actions with their caller (tests/security/ipc_inventory.sh holds it to the code)"
check grep -qE '^\| security \| state, heartbeat \| action \|' docs/specs/security.md
desc="restart limits: the unit passes the lifetime model (a 10 s loop ends at its limit: 5 x (1 + 10) = 55 <= 300)"
check python3 -I tests/shell/unit_restart_limits.py "$unit"
exit "$fail"
