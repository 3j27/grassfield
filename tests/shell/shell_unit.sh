#!/usr/bin/env bash
# grassfield-shell.service: the shell loads only from the system location (GF-115), a normal session end is not a failure
# (GF-081) and the resource guard is set (GF-040). Static checks of the unit and of every `qs` caller; `systemd-analyze
# verify` runs when the environment allows it (the Claude Code sandbox does not: then it is reported, not counted).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unit=$root/packaging/systemd/grassfield-shell.service
SYSTEM_PATH=/usr/share/grassfield/shell
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
exec_line=$(grep -E '^ExecStart=' "$unit")

desc="ExecStart loads the shell by path from $SYSTEM_PATH (qs -n -p), never by name"
check test "$exec_line" = "ExecStart=/usr/bin/qs -n -p $SYSTEM_PATH"
desc="no installed caller selects the shell by name (-c grassfield): that also searches the user-writable ~/.config/quickshell"
check bash -c '! grep -rnE "qs[[:space:]]+(ipc|log|kill)?[[:space:]]*-c[[:space:]]+grassfield" "$@" | grep -vE "^[^:]*:[0-9]*:[[:space:]]*(#|--)"' _ \
  "$unit" "$root/packaging/bin" "$root/packaging/shims" "$root/packaging/uwsm" "$root/packaging/sddm" "$root/config"
desc="every installed qs ipc caller (bindings, lid, sleep-lock stand-in) names the same system path as the unit"
check bash -c 'grep -q "ipc -p $1" "$2/packaging/bin/grassfield-lid" "$2/packaging/shims/omarchy-shell" && grep -q "$1" "$2/config/hypr/grassfield/bindings.lua"' _ "$SYSTEM_PATH" "$root"
desc="SuccessExitStatus=255: a session end (compositor gone first) leaves the unit inactive, not failed, and does not fire OnFailure"
check grep -qx 'SuccessExitStatus=255' "$unit"
desc="OnFailure=omarchy-sleep-lock.service is kept for real crashes (D-12) and the restart policy is unchanged"
check bash -c 'grep -qx "OnFailure=omarchy-sleep-lock.service" "$1" && grep -qx "Restart=always" "$1"' _ "$unit"
desc="resource guard: MemoryHigh=1536M, MemoryMax=3G, CPUQuota=150% (GF-040, ADR-0006 amendment)"
check bash -c 'grep -qx "MemoryHigh=1536M" "$1" && grep -qx "MemoryMax=3G" "$1" && grep -qx "CPUQuota=150%" "$1"' _ "$unit"
desc="the soft memory limit stays below the hard one and above the P2 gate (608 MB)"
check python3 -I -c '
import re,sys
t=open(sys.argv[1]).read()
def mb(k):
    v=re.search("^"+k+"=(\\d+)([MG])$",t,re.M); return int(v[1])*(1024 if v[2]=="G" else 1)
assert 608 < mb("MemoryHigh") < mb("MemoryMax")' "$unit"
if command -v systemd-analyze >/dev/null; then
  if out=$(systemd-analyze --user verify "$unit" 2>&1); then
    echo "PASS: systemd-analyze verify accepts the unit"
  elif grep -q "Failed to setup working directory\|Read-only file system\|Operation not permitted" <<<"$out"; then
    echo "NOTE: systemd-analyze verify NOT VERIFIED here (environment refuses it: $(head -n1 <<<"$out"))"
  else
    echo "FAIL: systemd-analyze verify: $out"; fail=1
  fi
fi
exit "$fail"
