#!/usr/bin/env bash
# GF-AUDIT-001 SEC-02 / GF-030 / D-12: lock coverage never disappears silently.
#   gate     packaging/systemd/sleep-lock-gate (ExecCondition of Omarchy's omarchy-sleep-lock.service) skips Omarchy's
#            unit only in the Grassfield session while grassfield-shell is up (active/running); it runs in the Omarchy
#            session and whenever grassfield-shell is starting, waiting to restart after a crash (activating/auto-restart),
#            stopped, failed or unknown (a stub systemctl answers)
#   drop-in  10-grassfield.conf uses the gate and no longer disables Omarchy's unit unconditionally
#   shell    grassfield-shell.service restarts after ANY exit (Restart=always, not on-failure), has a start limit, starts
#            Omarchy's unit when it has failed for good (OnFailure=, the fail-safe), never stops that unit (it may be
#            delaying a sleep), and cannot be restarted once the session target is gone
#   stand-in packaging/shims/omarchy-shell (what Omarchy's sleep-lock calls in this session): `lock lock` starts a
#            stopped or failed grassfield-shell again and asks it to lock; `lock status` reports secure only when Hyprland
#            lists LOCK on every monitor; every other call fails; nothing unlocks (stub systemctl, qs, hyprctl)
#   package  the PKGBUILD installs the gate where the drop-in looks for it, executable
# The runtime proof (SIGTERM / qs kill -> restarted within 3 s) is owner step L2-12 and tests/security/reload_locked.sh
# `graceful-exit` (nested). Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
pass() { echo "PASS: sleep-lock units $*"; }
bad() { echo "FAIL: sleep-lock units $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/sleep-lock-units.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- gate: a stub systemctl prints the ActiveState and SubState the case wants (or fails) ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
[ "$STUB_STATE" = "<fail>" ] && exit 1
case "$*" in
  "--user show --property=ActiveState --value grassfield-shell.service") printf '%s\n' "$STUB_STATE" ;;
  "--user show --property=SubState --value grassfield-shell.service") printf '%s\n' "$STUB_SUBSTATE" ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$tmp/bin/systemctl"
gate() { # <GRASSFIELD_SESSION or -> <ActiveState> <SubState> -> prints the gate's exit code
  local session=$1 rc=0
  if [[ $session == - ]]; then
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" STUB_SUBSTATE="$3" sh packaging/systemd/sleep-lock-gate || rc=$?
  else
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" STUB_SUBSTATE="$3" GRASSFIELD_SESSION="$session" sh packaging/systemd/sleep-lock-gate || rc=$?
  fi
  echo "$rc"
}
[[ $(gate 1 active running) == 1 ]] && pass "gate: Grassfield session, grassfield-shell active/running -> Omarchy's unit skipped" \
  || bad "gate: Grassfield session, grassfield-shell active/running -> not skipped"
# N1: after a crash the shell is activating/auto-restart, then activating/start: no Grassfield inhibitor exists then.
for pair in "activating auto-restart" "activating start" "active exited" "reloading running" "inactive dead" "failed failed" \
  "deactivating stop-sigterm" "maintenance dead" "<fail> x"; do
  read -r unit_state unit_sub <<<"$pair"
  [[ $(gate 1 "$unit_state" "$unit_sub") == 0 ]] && pass "gate: Grassfield session, grassfield-shell '$pair' -> Omarchy's unit runs" \
    || bad "gate: Grassfield session, grassfield-shell '$pair' -> skipped"
done
[[ $(gate 1 "" "") == 0 ]] && pass "gate: Grassfield session, no answer -> Omarchy's unit runs" || bad "gate: no answer -> skipped"
for session in - 0 ""; do
  [[ $(gate "$session" active running) == 0 ]] && pass "gate: not the Grassfield session (GRASSFIELD_SESSION '$session') -> Omarchy's unit runs" \
    || bad "gate: GRASSFIELD_SESSION '$session' -> skipped"
done
[[ -x packaging/systemd/sleep-lock-gate ]] && pass "gate: executable in the tree" || bad "gate: not executable"

# --- drop-in ---
dropin=packaging/systemd/omarchy-sleep-lock.service.d/10-grassfield.conf
grep -qx 'ExecCondition=/usr/lib/grassfield/sleep-lock-gate' "$dropin" && pass "drop-in: ExecCondition is the gate" || bad "drop-in: no gate"
if grep -v '^#' "$dropin" | grep -q 'ConditionEnvironment'; then bad "drop-in: still disables Omarchy's unit by environment"; else pass "drop-in: no unconditional ConditionEnvironment"; fi
grep -q '^\[Service\]' "$dropin" && pass "drop-in: [Service] section" || bad "drop-in: ExecCondition outside [Service]"

# --- grassfield-shell.service ---
unit=packaging/systemd/grassfield-shell.service
active=$(grep -v '^#' "$unit")
grep -qx 'Restart=always' <<<"$active" && pass "shell: Restart=always (clean exits, SIGTERM and qs kill restart too)" || bad "shell: not Restart=always"
grep -q '^Restart=on-failure' <<<"$active" && bad "shell: Restart=on-failure left" || pass "shell: no Restart=on-failure"
grep -qx 'RestartSec=1' <<<"$active" && pass "shell: RestartSec=1 (gate R1: back within 3 s)" || bad "shell: RestartSec"
grep -qE '^StartLimitIntervalSec=[0-9]+$' <<<"$active" && grep -qE '^StartLimitBurst=[0-9]+$' <<<"$active" \
  && pass "shell: start limit set (a crash loop ends)" || bad "shell: no start limit"
grep -qx 'Requisite=graphical-session.target' <<<"$active" && grep -qx 'PartOf=graphical-session.target' <<<"$active" \
  && pass "shell: tied to the session target (logout is not fought)" || bad "shell: Requisite/PartOf missing"
awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^OnFailure=omarchy-sleep-lock\.service$/{found=1} END{exit !found}' "$unit" \
  && pass "shell: a shell failed for good starts Omarchy's sleep-lock (fail-safe, [Unit] OnFailure=)" || bad "shell: no OnFailure=omarchy-sleep-lock.service in [Unit]"
grep -q 'stop omarchy-sleep-lock' <<<"$active" && bad "shell: stops Omarchy's sleep-lock (could cut a sleep it is delaying)" \
  || pass "shell: never stops Omarchy's sleep-lock"
awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^StartLimit/{found=1} END{exit !found}' "$unit" \
  && pass "shell: start limit in [Unit]" || bad "shell: start limit not in [Unit]"

# --- the omarchy-shell stand-in (stub systemctl, qs and hyprctl record their calls) ---
shim=packaging/shims/omarchy-shell
mkdir -p "$tmp/sbin" "$tmp/run"
cat >"$tmp/sbin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >>"$STUB_LOG"
case "$*" in
  "--user show --property=ActiveState --value grassfield-shell.service") printf '%s\n' "$STUB_STATE" ;;
esac
exit 0
SH
cat >"$tmp/sbin/qs" <<'SH'
#!/bin/sh
echo "qs $*" >>"$STUB_LOG"
[ "$*" = "ipc -c grassfield call lock lock" ] || exit 9
[ -n "$STUB_QS" ] || exit 1
printf '%s\n' "$STUB_QS"
SH
cat >"$tmp/sbin/hyprctl" <<'SH'
#!/bin/sh
echo "hyprctl $*" >>"$STUB_LOG"
[ "$*" = "-j monitors" ] || exit 9
printf '%s\n' "$STUB_MONITORS"
SH
chmod +x "$tmp/sbin/systemctl" "$tmp/sbin/qs" "$tmp/sbin/hyprctl"
shimrun() { # <state> <qs answer> <monitors json> args... -> stdout; exit status in $shim_rc
  local state=$1 answer=$2 monitors=$3
  shift 3
  : >"$tmp/log"
  shim_rc=0
  env -i PATH="$tmp/sbin:/usr/bin:/bin" STUB_LOG="$tmp/log" STUB_STATE="$state" STUB_QS="$answer" STUB_MONITORS="$monitors" \
    XDG_RUNTIME_DIR="$tmp/run" HYPRLAND_INSTANCE_SIGNATURE="sig/1 x" timeout 15 sh "$shim" "$@" 2>/dev/null || shim_rc=$?
}
locked='[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]},{"name":"DP-1","solitaryBlockedBy":["LOCK","WINDOWED"]}]'
half='[{"name":"eDP-1","solitaryBlockedBy":["LOCK"]},{"name":"DP-1","solitaryBlockedBy":["WINDOWED"]}]'

out=$(shimrun active ok "$locked" lock lock; echo "rc=$shim_rc")
[[ $out == $'ok\nrc=0' ]] && ! grep -q "start\|reset-failed" "$tmp/log" && grep -qx "qs ipc -c grassfield call lock lock" "$tmp/log" \
  && pass "stand-in: lock lock with grassfield-shell running asks it to lock, starts nothing" || bad "stand-in: running shell: $out / $(tr '\n' ';' <"$tmp/log")"
for state in failed inactive; do
  out=$(shimrun "$state" ok "$locked" lock lock; echo "rc=$shim_rc")
  grep -qx "systemctl --user reset-failed grassfield-shell.service" "$tmp/log" && grep -qx "systemctl --user start --no-block grassfield-shell.service" "$tmp/log" \
    && grep -qx "qs ipc -c grassfield call lock lock" "$tmp/log" && [[ $out == $'ok\nrc=0' ]] \
    && pass "stand-in: lock lock with grassfield-shell $state starts it again (reset-failed, no-block) and asks it to lock" \
    || bad "stand-in: shell $state: $out / $(tr '\n' ';' <"$tmp/log")"
done
out=$(shimrun failed "" "$locked" lock lock; echo "rc=$shim_rc")
[[ $out == "rc=1" ]] && pass "stand-in: a shell that never answers -> failure (Omarchy keeps asking, then reports it)" || bad "stand-in: no answer gave '$out'"
out=$(shimrun active ok "$locked" lock status)
[[ $(jq -r '.secure' <<<"$out") == true ]] && pass "stand-in: status secure when Hyprland lists LOCK on every monitor" || bad "stand-in: status '$out' with LOCK everywhere"
out=$(shimrun active ok "$half" lock status)
[[ $(jq -r '.secure' <<<"$out") == false ]] && pass "stand-in: status not secure when one monitor lacks LOCK" || bad "stand-in: status '$out' with a monitor unlocked"
out=$(shimrun active ok "[]" lock status)
[[ $(jq -r '.secure' <<<"$out") == false ]] && pass "stand-in: status not secure without a monitor answer" || bad "stand-in: status '$out' without monitors"
[[ $(jq -r '.requested' <<<"$out") == false ]] && pass "stand-in: not requested without the crash-recovery marker" || bad "stand-in: requested '$out'"
for line in "locked" "locked sleeps=12"; do
  printf '%s\n' "$line" >"$tmp/run/grassfield-lock-sig_1_x"
  out=$(shimrun active ok "$half" lock status)
  [[ $(jq -r '.requested' <<<"$out") == true ]] && pass "stand-in: requested once the marker (LockMachine.markerName) says '$line'" || bad "stand-in: marker '$line' ignored: '$out'"
done
for line in "unlocked sleeps=12" "unlocked" "lockedx"; do
  printf '%s\n' "$line" >"$tmp/run/grassfield-lock-sig_1_x"
  out=$(shimrun active ok "$half" lock status)
  [[ $(jq -r '.requested' <<<"$out") == false ]] && pass "stand-in: not requested with the marker '$line'" || bad "stand-in: marker '$line' read as requested: '$out'"
done
for args in "lock unlock" "notifications dismissAll" "shell toggle omarchy.menu"; do
  out=$(shimrun active ok "$locked" $args; echo "rc=$shim_rc")
  [[ $out == "rc=1" ]] && ! grep -q "^qs \|systemctl --user start" "$tmp/log" && pass "stand-in: '$args' fails and does nothing" || bad "stand-in: '$args' -> $out / $(tr '\n' ';' <"$tmp/log")"
done
out=$(shimrun active ok "$locked" -q lock unlock; echo "rc=$shim_rc")
[[ $out == "rc=0" ]] && ! grep -q "^qs " "$tmp/log" && pass "stand-in: -q makes an unknown call a silent success, still doing nothing" || bad "stand-in: -q gave $out"
grep -q "unlock_and_destroy\|lock unlock\|call lock release" "$shim" && bad "stand-in: mentions an unlock call" || pass "stand-in: has no unlock path"

# --- the clamshell stand-in (N4): Omarchy's sleep-lock and wake scripts call omarchy-hyprland-monitor-clamshell; in this
# session it must hand over to grassfield-lid's own reconcile instead of Omarchy's panel switching ---
clam=packaging/shims/omarchy-hyprland-monitor-clamshell
printf '#!/bin/sh\necho "lid $*" >>"$STUB_LOG"\n' >"$tmp/sbin/grassfield-lid"
chmod +x "$tmp/sbin/grassfield-lid"
: >"$tmp/log"
env -i PATH="$tmp/sbin:/usr/bin:/bin" STUB_LOG="$tmp/log" GRASSFIELD_LID_TOOL="$tmp/sbin/grassfield-lid" sh "$clam" && rc=0 || rc=$?
[[ $rc == 0 && $(cat "$tmp/log") == "lid reconcile" ]] && pass "clamshell stand-in: runs grassfield-lid reconcile, nothing else" || bad "clamshell stand-in: rc $rc, calls '$(cat "$tmp/log")'"
env -i PATH="/usr/bin:/bin" GRASSFIELD_LID_TOOL="$tmp/none" sh "$clam" && pass "clamshell stand-in: without grassfield-lid it does nothing and succeeds" || bad "clamshell stand-in: fails without grassfield-lid"
grep -v '^#' "$clam" | grep -q "hyprctl\|monitors.lua\|toggles" && bad "clamshell stand-in: touches monitors itself" || pass "clamshell stand-in: never touches monitors itself"

# --- package ---
grep -q 'install -Dm755 "$root/packaging/systemd/sleep-lock-gate" "$pkgdir/usr/lib/grassfield/sleep-lock-gate"' packaging/arch/PKGBUILD \
  && pass "package: the gate is installed where the drop-in looks for it" || bad "package: gate not installed at /usr/lib/grassfield/sleep-lock-gate"
exit $fail
