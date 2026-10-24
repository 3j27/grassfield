#!/usr/bin/env bash
# grassfield-shell.service: the shell loads only from the system location (GF-115), a normal session end is not a failure
# (GF-081) and the resource guard is set (GF-040). Static checks of the unit and of every `qs` caller; `systemd-analyze
# verify` runs when the environment allows it (the Claude Code sandbox does not: then it is reported, not counted).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
unit=$root/packaging/systemd/grassfield-shell.service
SYSTEM_PATH=/usr/share/grassfield/shell
fail=0
mut=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-unit.XXXXXX")
trap 'rm -rf "$mut"' EXIT
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
exec_line=$(grep -E '^ExecStart=' "$unit")

desc="ExecStart loads the shell by path from $SYSTEM_PATH (qs -n -p), never by name"
check test "$exec_line" = "ExecStart=/usr/bin/qs -n -p $SYSTEM_PATH"
desc="no shipped file selects the shell by name (-c/--config grassfield): that also searches the user-writable ~/.config/quickshell"
check bash -c '! grep -rnIE "qs[[:space:]]+((ipc|log|kill)[[:space:]]+)?(-c|--config)[[:space:]]+grassfield" "$@" | grep -vE "^[^:]*:[0-9]*:[[:space:]]*(#|--|//)"' _ \
  "$root/apps" "$root/bridges" "$root/packaging" "$root/config" "$root/shell" "$root/ui" "$root/scripts/dev/gate-run.sh"
# bare_qs DIR...: qs ipc/kill/log callers that name neither the system path (-p) nor a pid (--pid). Comment lines are skipped.
bare_qs() {
  grep -rnIHE '("qs", *"(ipc|kill|log)"|\bqs[[:space:]]+(ipc|kill|log)\b)' "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]*:[[:space:]]*(#|--|//|\*)' | grep -vE '(-p |--pid|"--pid"|"-p")' | grep -v shell_selector
}
export -f bare_qs
desc="every shipped qs ipc/kill/log caller (the whole of apps, bridges, packaging, config, shell and ui) selects an instance by the system path (-p) or by pid (--pid), never by name or bare"
check bash -c 'out=$(bare_qs "$@"); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "$root/apps" "$root/bridges" "$root/packaging" "$root/config" "$root/shell" "$root/ui"
# Mutation: the scan must catch a bare caller anywhere in a tree (a JS list, a QML command, a shell script, a Lua exec).
mkdir -p "$mut/shell/services" "$mut/packaging/bin" "$mut/config"
printf 'var c = ["qs", "ipc", "call", "lock", "lock"];\n' >"$mut/shell/services/X.js"
printf 'command: ["qs", "kill", "-c", "other"]\n' >"$mut/shell/services/Y.qml"
printf 'qs ipc call lock lock\n' >"$mut/packaging/bin/z"
printf 'hl.exec_cmd("qs ipc call lock lock")\n' >"$mut/config/w.lua"
for f in shell/services/X.js shell/services/Y.qml packaging/bin/z config/w.lua; do
  desc="mutation: a bare qs caller in $f is caught"
  check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/$f"
done
printf 'var c = ["qs", "ipc", "--pid", String(pid), "call", "a", "b"];\n// qs ipc call documented in a comment\nqs ipc -p /usr/share/grassfield/shell call a b\n' >"$mut/ok.txt"
desc="a --pid caller, a -p caller and a comment are not flagged"
check bash -c '[ -z "$(bare_qs "$1")" ]' _ "$mut/ok.txt"
desc="every installed qs ipc caller (bindings, lid, sleep-lock stand-in) names the same system path as the unit"
check bash -c 'grep -q "ipc -p $1" "$2/packaging/bin/grassfield-lid" "$2/packaging/shims/omarchy-shell" && grep -q "$1" "$2/config/hypr/grassfield/bindings.lua"' _ "$SYSTEM_PATH" "$root"
desc="255 stays a failure (qs exits 255 on a config error and a missing path too): no SuccessExitStatus, so OnFailure= still fires; the logout case is the sleep-lock gate (tests/security/sleep_lock_units.sh)"
check bash -c '! grep -q "^SuccessExitStatus=" "$1" && grep -q "/sleep-lock-gate" "$2/packaging/systemd/omarchy-sleep-lock.service.d/10-grassfield.conf" && grep -q "compositor is gone" "$2/packaging/systemd/sleep-lock-gate"' _ "$unit" "$root"
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
