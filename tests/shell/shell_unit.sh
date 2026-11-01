#!/usr/bin/env bash
# grassfield-shell.service: the shell loads only from the system location (GF-115), 255 stays a failure so OnFailure= still
# fires (the logout case is the sleep-lock gate, GF-081) and the resource guard is set (GF-040). Static checks of the unit and of
# every `qs`/`quickshell` ipc/kill/log caller in the shipped tree, with mutations proving the scan; `systemd-analyze verify` runs
# when the environment allows it (the Claude Code sandbox does not: then it is reported, not counted).
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
# Known limits of these scans (the cheap forms are covered, the rest is documented): an argument list split over several lines
# (a QML array with "qs", then "ipc" on the next line), a command assembled from variables or systemd specifiers (%t), and a
# path built at run time are not seen; review such a caller by hand.
# named_qs DIR...: qs/quickshell started or addressed by NAME (-c/--config grassfield), as a command line or as an array.
named_qs() {
  grep -rnIHE "(qs|quickshell)[^#]*[[:space:],\"'](-c|--config)[\"']?[[:space:]]*,?[[:space:]]*[\"']?grassfield" "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]*:[[:space:]]*(#|--|//|\*)'
}
export -f named_qs
desc="no shipped file selects the shell by name (-c/--config grassfield, command line or array): that also searches the user-writable ~/.config/quickshell"
# Only what git tracks is shipped: an untracked makepkg tree (packaging/arch/pkg, src) or a stale build is not scanned.
mapfile -t shipped < <(git -C "$root" ls-files -- apps bridges packaging config shell ui scripts/dev/gate-run.sh | sed "s|^|$root/|")
check bash -c 'out=$(named_qs "$@"); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "${shipped[@]}"
mut=${mut:-$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/shell-unit.XXXXXX")}
printf 'command: ["qs", "-c", "grassfield", "ipc"]\n' >"$mut/n1.qml"
printf "x = ['quickshell', '--config', 'grassfield']\n" >"$mut/n2.js"
printf 'exec qs -c grassfield call a b\n' >"$mut/n3"
for f in n1.qml n2.js n3; do
  desc="mutation: selecting the shell by name in $f is caught"
  check bash -c '[ -n "$(named_qs "$1")" ]' _ "$mut/$f"
done
printf '# qs -c grassfield in a comment\nqs -n -p /usr/share/grassfield/shell\n' >"$mut/n4"
desc="a comment naming the old form and a -p start are not flagged"
check bash -c '[ -z "$(named_qs "$1")" ]' _ "$mut/n4"
# bare_qs DIR...: qs/quickshell ipc|kill|log callers (any quoting, /usr/bin/ prefix) that do not select the instance by pid
# (--pid), by the system path (-p /usr/share/grassfield/shell), through bindings.lua's shell_selector (itself checked below)
# or through the hyprland-dialog stand-in's shell_dir (ADR-0035 D-3; checked below too), or grassfield-security-status's
# path, the security unit's own system path (ADR-0041 S1; checked below too).
# Comment lines are skipped. A -p with any other path, a -c name, or no selector is reported.
bare_qs() {
  grep -rnIHE "([\"']?(/usr/bin/)?(qs|quickshell)[\"']?([[:space:]]*,[[:space:]]*|[[:space:]]+)[\"']?(ipc|kill|log)[\"']?([^[:alnum:]_]|$))" "$@" 2>/dev/null |
    grep -vE '^[^:]*:[0-9]*:[[:space:]]*(#|--|//|\*)' |
    grep -vE "(--pid|[\"']--pid[\"']|(-p|[\"']-p[\"'][[:space:]]*,)[[:space:]]+[\"']?/usr/share/grassfield/shell([\"' ]|$))" | grep -v shell_selector |
    grep -vE '/packaging/session-bin/hyprland-dialog:[0-9]+:answer=\$\(timeout -k 0\.2 1 qs ipc -p "\$shell_dir" call anr report ' |
    grep -vE '/packaging/bin/grassfield-security-status:[0-9]+:(state|beat)=\$\(timeout -k 0\.2 2 qs ipc \$display -p "\$path" call security (state|heartbeat) '
}
export -f bare_qs
desc="every shipped qs ipc/kill/log caller (the whole of apps, bridges, packaging, config, shell and ui) selects an instance by the system path (-p) or by pid (--pid), never by name or bare"
check bash -c 'out=$(bare_qs "$@"); [ -z "$out" ] || { echo "$out"; exit 1; }' _ "${shipped[@]}"
# Mutation: the scan must catch a bare caller anywhere in a tree (a JS list, a QML command, a shell script, a Lua exec).
mkdir -p "$mut/shell/services" "$mut/packaging/bin" "$mut/config"
printf 'var c = ["qs", "ipc", "call", "lock", "lock"];\n' >"$mut/shell/services/X.js"
printf 'command: ["qs", "kill", "-c", "other"]\n' >"$mut/shell/services/Y.qml"
printf 'qs ipc call lock lock\n' >"$mut/packaging/bin/z"
printf "x = ['qs', 'ipc', 'call', 'a', 'b']\n" >"$mut/shell/services/S.js"
printf 'exec /usr/bin/qs ipc call lock lock\n' >"$mut/packaging/bin/u"
printf 'quickshell ipc call lock lock\n' >"$mut/packaging/bin/q"
printf 'qs ipc -p /home/someone/shell call lock lock\n' >"$mut/packaging/bin/wp"
printf 'command: ["qs", "ipc", "-p", "/tmp/x", "call", "a", "b"]\n' >"$mut/shell/services/W.qml"
printf 'hl.exec_cmd("qs ipc call lock lock")\n' >"$mut/config/w.lua"
for f in shell/services/X.js shell/services/Y.qml packaging/bin/z config/w.lua shell/services/S.js packaging/bin/u packaging/bin/q packaging/bin/wp shell/services/W.qml; do
  desc="mutation: a bare qs caller in $f is caught"
  check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/$f"
done
printf 'var c = ["qs", "ipc", "--pid", String(pid), "call", "a", "b"];\n// qs ipc call documented in a comment\nqs ipc -p /usr/share/grassfield/shell call a b\ncmd = ['qs', 'ipc', '--pid', 1]\n/usr/bin/qs ipc -p /usr/share/grassfield/shell call a b\n' >"$mut/ok.txt"
printf 'answer=$(timeout -k 0.2 1 qs ipc -p "$shell_dir" call anr report "$$"\n' >"$mut/packaging/bin/anr"
desc="mutation: the stand-in's shell_dir form anywhere but the stand-in is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/packaging/bin/anr"
printf 'state=$(timeout -k 0.2 2 qs ipc $display -p "$path" call security state 2>/dev/null)\n' >"$mut/packaging/bin/sec"
desc="mutation: the security status form anywhere but grassfield-security-status is caught"
check bash -c '[ -n "$(bare_qs "$1")" ]' _ "$mut/packaging/bin/sec"
desc="grassfield-security-status's path is the security unit's system path, set once"
check bash -c 'f=$1; [[ $(grep -c "^path=" "$f") == 1 ]] && grep -qx "path=/usr/share/grassfield/shell/security.qml" "$f"' _ "$root/packaging/bin/grassfield-security-status"
desc="a --pid caller, a -p caller and a comment are not flagged"
check bash -c '[ -z "$(bare_qs "$1")" ]' _ "$mut/ok.txt"
desc="every installed qs ipc caller (bindings, lid, sleep-lock stand-in) names the same system path as the unit"
check bash -c 'grep -q "ipc -p $1" "$2/packaging/bin/grassfield-lid" "$2/packaging/shims/omarchy-shell" && grep -q "$1" "$2/config/hypr/grassfield/bindings.lua"' _ "$SYSTEM_PATH" "$root"
desc="the hyprland-dialog stand-in's shell_dir is the system path, replaced by GRASSFIELD_SHELL_DIR only inside its dev-session gate (tests/shell/hyprland_dialog.sh runs both)"
check bash -c 'f=$1; [[ $(grep -c "shell_dir=" "$f") == 2 ]] && grep -qx "shell_dir=/usr/share/grassfield/shell" "$f" &&
  [[ $(grep -B1 -x "  shell_dir=\$GRASSFIELD_SHELL_DIR" "$f" | head -1) == "if [ \"\${GRASSFIELD_DEV:-}\" = 1 ] && [ \"\${GRASSFIELD_SESSION:-}\" != 1 ] && [ -n \"\${GRASSFIELD_SHELL_DIR:-}\" ]; then" ]]' _ "$root/packaging/session-bin/hyprland-dialog"
desc="255 stays a failure (qs exits 255 on a config error and a missing path too): no SuccessExitStatus, so OnFailure= still fires; the logout case is the sleep-lock gate (tests/security/sleep_lock_units.sh)"
check bash -c '! grep -q "^SuccessExitStatus=" "$1" && grep -q "/sleep-lock-gate" "$2/packaging/systemd/omarchy-sleep-lock.service.d/10-grassfield.conf" && grep -q "compositor is gone" "$2/packaging/systemd/sleep-lock-gate"' _ "$unit" "$root"
desc="OnFailure=omarchy-sleep-lock.service is kept for real crashes (D-12) and the restart policy is unchanged"
check bash -c 'grep -q "^OnFailure=omarchy-sleep-lock.service\( \|$\)" "$1" && grep -qx "Restart=always" "$1"' _ "$unit"
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
  elif grep -q "Failed to setup working directory\|Read-only file system\|Operation not permitted\|Failed to lookup RuntimeDirectory path" <<<"$out"; then
    echo "NOTE: systemd-analyze verify NOT VERIFIED here (environment refuses it: $(head -n1 <<<"$out"))"
  else
    echo "FAIL: systemd-analyze verify: $out"; fail=1
  fi
fi
exit "$fail"
