#!/usr/bin/env bash
# GF-AUDIT-001 SEC-02 / GF-030 / D-12: lock coverage never disappears silently.
#   gate     packaging/systemd/sleep-lock-gate (ExecCondition of Omarchy's omarchy-sleep-lock.service) skips Omarchy's
#            unit only in the Grassfield session while grassfield-shell is active, starting or reloading; it runs in the
#            Omarchy session and whenever grassfield-shell is stopped, failed or unknown (a stub systemctl answers)
#   drop-in  10-grassfield.conf uses the gate and no longer disables Omarchy's unit unconditionally
#   shell    grassfield-shell.service restarts after ANY exit (Restart=always, not on-failure), has a start limit, stops
#            Omarchy's unit without ordering when it starts, and cannot be restarted once the session target is gone
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

# --- gate: a stub systemctl prints the state the case wants (or fails) ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/sh
[ "$*" = "--user show --property=ActiveState --value grassfield-shell.service" ] || { echo "unexpected: $*" >&2; exit 9; }
[ "$STUB_STATE" = "<fail>" ] && exit 1
printf '%s\n' "$STUB_STATE"
SH
chmod +x "$tmp/bin/systemctl"
gate() { # <GRASSFIELD_SESSION or -> <state> -> prints the gate's exit code
  local session=$1 rc=0
  if [[ $session == - ]]; then
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" sh packaging/systemd/sleep-lock-gate || rc=$?
  else
    env -i PATH="$tmp/bin:/usr/bin:/bin" STUB_STATE="$2" GRASSFIELD_SESSION="$session" sh packaging/systemd/sleep-lock-gate || rc=$?
  fi
  echo "$rc"
}
for state in active activating reloading refreshing; do
  [[ $(gate 1 "$state") == 1 ]] && pass "gate: Grassfield session, grassfield-shell $state -> Omarchy's unit skipped" \
    || bad "gate: Grassfield session, grassfield-shell $state -> not skipped"
done
for state in inactive failed deactivating maintenance "" "<fail>"; do
  [[ $(gate 1 "$state") == 0 ]] && pass "gate: Grassfield session, grassfield-shell '${state}' -> Omarchy's unit runs" \
    || bad "gate: Grassfield session, grassfield-shell '${state}' -> skipped"
done
for session in - 0 ""; do
  [[ $(gate "$session" active) == 0 ]] && pass "gate: not the Grassfield session (GRASSFIELD_SESSION '$session') -> Omarchy's unit runs" \
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
grep -qx 'ExecStartPre=-/usr/bin/systemctl --user --no-block stop omarchy-sleep-lock.service' <<<"$active" \
  && pass "shell: stops Omarchy's sleep-lock without ordering when it starts" || bad "shell: no ExecStartPre stop of Omarchy's unit"
awk '/^\[Unit\]/{u=1;next} /^\[/{u=0} u && /^StartLimit/{found=1} END{exit !found}' "$unit" \
  && pass "shell: start limit in [Unit]" || bad "shell: start limit not in [Unit]"

# --- package ---
grep -q 'install -Dm755 "$root/packaging/systemd/sleep-lock-gate" "$pkgdir/usr/lib/grassfield/sleep-lock-gate"' packaging/arch/PKGBUILD \
  && pass "package: the gate is installed where the drop-in looks for it" || bad "package: gate not installed at /usr/lib/grassfield/sleep-lock-gate"
exit $fail
