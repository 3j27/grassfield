#!/usr/bin/env bash
# Nested scenario (L1 only): the session lock survives soft reloads and shell crashes (R12, gate L1).
# Never targets the owner's session. Never types a password and never presses Return: the probe
# words typed with wtype land in the lock screen's field without being submitted (no PAM attempt).
#
# Usage: tests/security/reload_locked.sh [step...]   (default: every step, in this order)
#   setup           foot probe window in the nested session; typing reaches it while unlocked (control)
#   nowatch         touching a shell QML file does not reload the configuration (file watcher off)
#   lock            lock through IPC
#   marker-missing  remove the crash marker, soft reload  -> still locked, nothing reaches foot
#   marker-unlocked forge the marker to "unlocked", soft reload -> still locked, nothing reaches foot
#   l1              kill -9 the shell -> nothing reaches foot; restart the shell -> locked again
#   forged-crash    forge the marker to "unlocked", kill -9, restart -> the shell re-acquires the lock
#   graceful-exit   DT-21 (SEC-18): SIGTERM, then `qs kill --pid`, while locked -> Hyprland keeps LOCK, nothing
#                   reaches foot; the restarted shell is locked
#   foreign-takeover (b) a foreign locker takes over the live Grassfield lock -> still locked; it
#                   releases and exits -> Grassfield takes a fresh lock, nothing reaches foot
#   foreign-restart (a) foreign locker holding the lock + marker forged "unlocked" + shell restart ->
#                   the shell takes the lock over; the foreign locker releases -> locked by Grassfield
#   lock-desync     (c) desync held on purpose (periodic check paused by the dev hook
#                   `lock devPauseOwnershipCheck`: Hyprland unlocked, shell "locked"), then `lock lock`
#                   -> a real lock, triggered by that request
#   sleep-desync    before-sleep path (dev hook `idle devSleep`): the sleep delay ends only on a
#                   confirmed lock; during a held desync, only after the fresh lock is acquired
#   relock-confirm  forced race (R12 review #3): one stale "unlocked" answer forged by the dev hook
#                   `lock devForgeUnlockedAnswer` while the session is really locked, then `lock lock`
#                   while keys are typed -> no relock (it waits for a fresh answer, which says locked),
#                   Hyprland reports LOCK throughout, nothing reaches foot; RELOCK_RUNS runs (default 12)
#   foreign-gap     forced race (R12 review #3): FOREIGN_RUNS (default 5) foreign takeovers of the live
#                   Grassfield lock, each released while keys are typed: prints the unlocked window and
#                   the keys that reached foot during it; fails when the fresh lock is requested more than
#                   GAP_MAX_MS (default 200) after the release (fixture and shell log times), when Hyprland
#                   does not report LOCK within 1.5 s, or when a key typed after the fresh lock reaches foot.
#                   The in-window key count needs foot to be the window Hyprland refocuses: run it right
#                   after `setup lock` (shell restarts in other steps can change that; the step says so)
#   probe-cost      CPU of the shell and the nested Hyprland with the 1 s check (plain lock) and the 100 ms
#                   check (a foreign locker holding the lock over Grassfield's); fails above +5 % CPU
#   cleanup         close the foot probe window and any foreign locker (run after the default sequence)
#
# Foreign locker: tests/security/foreign_locker/ForeignLocker.qml (Quickshell WlSessionLock client,
# released over its IPC). Hyprland 0.56.2 (misc.allow_session_lock_restore = true) hands a live lock
# to the next client and tells the previous holder nothing; a release by either client unlocks the
# session. The foreign steps print "unlocked window": the time from the foreign release until Hyprland
# reports the session locked again (bounded by the shell's 1 s ownership check, docs/specs/security.md).
#
# Requires scripts/dev/nested-up.sh (the shell runs with GRASSFIELD_DEV=1, which enables the
# `lock devReload` hook). The nested session stays locked afterwards: finish with nested-down.sh.
# Exit status: 0 when every requested step passed.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host reload_locked
sig=$(cat "$dev/nested.instance" 2>/dev/null || true)
sock=$(cat "$dev/nested.wayland" 2>/dev/null || true)
main=$(cat "$dev/main.instance" 2>/dev/null || true)

[[ -n $sig && -n $sock ]] || { echo "reload_locked: no nested instance (run scripts/dev/nested-up.sh)" >&2; exit 2; }
[[ $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || { echo "reload_locked: refusing the main instance" >&2; exit 2; }
[[ $sock != "${WAYLAND_DISPLAY:-}" ]] || { echo "reload_locked: refusing the main Wayland socket" >&2; exit 2; }
[[ -n ${XDG_RUNTIME_DIR:-} ]] || { echo "reload_locked: XDG_RUNTIME_DIR unset" >&2; exit 2; }
# Wayland clients (foot, wtype, the foreign locker) must only reach the nested socket: it has to be
# the one Hyprland lists for the nested instance, and never the owner's (read-only `hyprctl instances`).
instances=$(hyprctl instances -j 2>/dev/null)
[[ -n $main && $(jq -r --arg s "$main" '.[] | select(.instance == $s) | .wl_socket' <<<"$instances") != "$sock" ]] \
  || { echo "reload_locked: refusing: no owner instance record, or its socket is the nested one" >&2; exit 2; }
[[ $(jq -r --arg s "$sig" '.[] | select(.instance == $s) | .wl_socket' <<<"$instances") == "$sock" ]] \
  || { echo "reload_locked: refusing: $sock is not the nested instance's socket" >&2; exit 2; }

marker=$XDG_RUNTIME_DIR/grassfield-lock-${sig//[^A-Za-z0-9_.-]/_}
typed=$dev/reload-typed.txt
foreign=$root/tests/security/foreign_locker/ForeignLocker.qml
status=0

nested() { env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" "$@"; }
ipc() { nested qs ipc -p "$root/shell" call "$@" 2>/dev/null; }
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
# Captures are evidence only (no check reads them), so each has a deadline and a missing one is a note. grim waits for
# the output's next frame: GF-REF (headless) draws on its own, WAYLAND-1 only while the owner's compositor draws the
# nested window (an integrator run hung here before the l1 kill, as lock_privacy.sh once did for 25 min).
shot() {
  timeout -k 2 10 "$root/scripts/dev/shot.sh" "$1-gfref" GF-REF >/dev/null 2>&1 ||
    echo "NOTE no GF-REF capture for $1 within 10 s"
  timeout -k 2 10 "$root/scripts/dev/shot.sh" "$1-window" WAYLAND-1 >/dev/null 2>&1 ||
    echo "NOTE no WAYLAND-1 capture for $1 within 10 s (is the nested window shown on the owner's screen?)"
}

# Read-only compositor view of the lock: Hyprland lists LOCK in solitaryBlockedBy while a session lock
# is held, including one whose client died.
compositor_lock() {
  nested hyprctl -j monitors 2>/dev/null | jq -c '[.[] | {name, blockedBy: (.solitaryBlockedBy // [])}]'
}

wait_status() { # <expected> <seconds>
  local want=$1 tries=$(($2 * 4)) got=""
  for _ in $(seq 1 "$tries"); do
    got=$(ipc lock status)
    [[ $got == "$want" ]] && { echo "$got"; return 0; }
    sleep 0.25
  done
  echo "${got:-no-answer}"
  return 1
}

# SAFETY (R12 review #3 MAJOR): every probe this script types is letters only. A Return/newline/Enter in a probe that
# reaches the lock's password field submits it to PAM and counts a faillock failure against the owner's real account.
# type_letters is the ONLY typing path; it refuses anything but [a-z0-9] (letters and digits never submit; a step name
# may carry a digit, e.g. "deadl1"), and the shell suppresses PAM in dev anyway (GRASSFIELD_DEV without
# GRASSFIELD_DEV_ALLOW_PAM). press_key only allows keys that never submit (Escape).
type_letters() { # <delay ms> <word>: exactly two arguments, both validated; no option ever passes through
  [[ $# -eq 2 && $1 =~ ^[0-9]{1,3}$ && $2 =~ ^[a-z0-9]+$ ]] \
    || { echo "FATAL type_letters: refusing arguments '$*' (want: <delay ms> <[a-z0-9] word>)" >&2; abort_run "a refused probe"; }
  nested wtype -d "$1" "$2"
}
press_key() { # Escape: exactly one argument, and only Escape
  [[ $# -eq 1 && $1 == Escape ]] || { echo "FATAL press_key: refusing '$*' (only Escape is allowed; it never submits)" >&2; abort_run "a disallowed key"; }
  nested wtype -k Escape
}
# Types a letters-only word in the background (sets $typer). Validated synchronously first, so a bad probe aborts before
# anything is typed.
bg_type() { # <word>: exactly one [a-z0-9] argument
  [[ $# -eq 1 && $1 =~ ^[a-z0-9]+$ ]] || { echo "FATAL bg_type: refusing arguments '$*' (want one [a-z0-9] word)" >&2; abort_run "a refused probe"; }
  nested wtype -d 4 "$1" &
  typer=$!
}

# All PAM attempts this run could ever cause, over EVERY instance log of this tree's shell (tests/security/pam_audit.sh:
# restarts overwrite .dev/shell.log, so the per-instance Quickshell logs are the record). "(submit)" is a real PAM call
# (must never happen); "PAM submit suppressed" means a key reached the lock field (the shell blocked PAM; still a
# defect). Counted against a baseline taken when the run starts, so older attempts in exited instances are not re-counted.
# shellcheck source=pam_audit.sh
. "$root/tests/security/pam_audit.sh"
read -r pam_base_instances pam_base_submits pam_base_suppressed < <(pam_counts)
pam_new() { # "<new submits> <new suppressed>" since the run started
  local n s x
  read -r n s x < <(pam_counts)
  echo "$((s - pam_base_submits)) $((x - pam_base_suppressed))"
}

# Stop the whole run the moment a probe could have touched PAM: stop the nested session and exit non-zero, loudly.
abort_run() { # <why>
  local s x
  read -r s x < <(pam_new)
  echo "" >&2
  echo "ABORT ($1): new PAM submits=$s, new suppressed submits=$x since the run started. Stopping the nested session." >&2
  "$root/scripts/dev/nested-down.sh" >&2 2>&1 || true
  exit 4
}

# Called before the loop and after every step: fail closed on the first sign a key reached the lock field.
assert_no_pam() { # <when>
  local s x
  read -r s x < <(pam_new)
  if ((s > 0 || x > 0)); then
    abort_run "$1"
  fi
}

# Types a probe word (letters only, never Return) and checks that foot did not receive it.
no_leak() { # <word> <step>
  type_letters 15 "$1"
  sleep 0.7
  if grep -q "$1" "$typed" 2>/dev/null; then fail "$2: typed text reached the foot window ($1)"; else pass "$2: nothing reached the foot window"; fi
}

# Only a record that still matches its process (scripts/dev/pidfile.sh): a stale PID may name an owner process.
shell_pid() { dev_live_pid "$dev/shell.pid"; }

step_setup() {
  : >"$typed"
  # New windows open on the monitor under the pointer: put it on the deterministic GF-REF output.
  "$root/scripts/dev/pointer.sh" output GF-REF abs 960 540 >/dev/null
  # Raw mode: every key reaches cat at once, no Return needed.
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    setsid "$root/scripts/dev/isolated.sh" foot --app-id=gf-reload-probe -- sh -c 'stty raw -echo; exec cat >"$1"' sh "$typed" >/dev/null 2>&1 </dev/null &
  dev_record_pid "$dev/reload-foot.pid" "$!"
  local geo=""
  for _ in $(seq 1 40); do
    geo=$(nested hyprctl -j clients 2>/dev/null | jq -r '.[] | select(.class == "gf-reload-probe") | "\(.monitor) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
    [[ -n $geo ]] && break
    sleep 0.25
  done
  [[ -n $geo ]] || { fail "setup: the foot probe window did not appear"; return; }
  local mon x y w h name mx my
  read -r mon x y w h <<<"$geo"
  read -r name mx my < <(nested hyprctl -j monitors | jq -r --argjson m "$mon" '.[] | select(.id == $m) | "\(.name) \(.x) \(.y)"')
  # Focus it with a click (focus follows the pointer; no state-changing hyprctl).
  "$root/scripts/dev/pointer.sh" output "$name" abs $((x - mx + w / 2)) $((y - my + h / 2)) sleep 200 click >/dev/null
  sleep 0.5
  type_letters 15 control
  sleep 0.7
  if grep -q control "$typed"; then pass "setup: typing reaches the foot window on $name while unlocked (control)"; else fail "setup: control text did not reach foot; leak checks are meaningless"; fi
}

step_nowatch() {
  local before after
  before=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  touch "$root/shell/security/lock/LockView.qml"
  sleep 3
  after=$(grep -c "Reloading configuration" "$dev/shell.log" 2>/dev/null)
  if [[ $before == "$after" ]]; then pass "nowatch: a touched QML file did not reload the shell"; else fail "nowatch: the shell reloaded after a file change"; fi
}

step_lock() {
  echo "lock lock -> $(ipc lock lock)"
  local s
  if s=$(wait_status locked 10); then pass "lock: status $s"; else fail "lock: status $s"; fi
  echo "marker: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot reload-locked
}

reload_case() { # <name> <marker action>
  local name=$1 s
  case $2 in
    remove) rm -f "$marker" ;;
    unlocked) printf 'unlocked\n' >"$marker" ;;
  esac
  echo "marker before reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "lock devReload -> $(ipc lock devReload)"
  sleep 3
  if s=$(wait_status locked 5); then pass "$name: status after reload $s"; else fail "$name: status after reload $s"; fi
  echo "marker after reload: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  echo "compositor: $(compositor_lock)"
  shot "reload-$name"
  no_leak "leak${name//-/}" "$name"
}

step_marker_missing() { reload_case marker-missing remove; }
step_marker_unlocked() { reload_case marker-unlocked unlocked; }

crash_and_restart() { # <name> <wait seconds>
  local name=$1 pid s
  pid=$(shell_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || { fail "$name: shell not running"; return; }
  dev_may_signal "$pid" || { fail "$name: refusing to signal PID $pid"; return; }
  kill -9 "$pid"
  sleep 1.5
  echo "compositor after kill -9: $(compositor_lock)"
  shot "$name-dead"
  no_leak "dead${name//-/}" "$name (shell dead)"
  "$root/scripts/dev/shell-run.sh"
  if s=$(wait_status locked "$2"); then pass "$name: restarted shell status $s"; else fail "$name: restarted shell status $s"; fi
  shot "$name-restarted"
  no_leak "back${name//-/}" "$name (restarted)"
}

step_l1() { crash_and_restart l1 10; }

# DT-21 / SEC-18 (GF-029): a GRACEFUL exit while locked must leave the session locked. (a) SIGTERM (Quickshell has no
# SIGTERM handler: the process ends at once); (b) `qs kill --pid` (IPC kill: the engine is torn down and WlSessionLock's
# lock object sends ext_session_lock_v1.destroy, never unlock_and_destroy; Hyprland 0.56.2 then keeps the session
# locked). After each: Hyprland lists LOCK on every monitor, nothing typed reaches foot, the restarted shell is locked.
graceful_case() { # <term|qskill>
  local how=$1 pid s
  s=$(wait_status locked 5) || { fail "graceful-exit ($how): precondition: status $s (run the lock step first)"; return; }
  pid=$(shell_pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null || { fail "graceful-exit ($how): shell not running"; return; }
  dev_may_signal "$pid" || { fail "graceful-exit ($how): refusing to signal PID $pid"; return; }
  case $how in
    term) kill -TERM "$pid" ;;
    qskill) echo "qs kill -> $(qs kill --pid "$pid" 2>&1 | tr '\n' ' ')" ;;
  esac
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then fail "graceful-exit ($how): the shell did not exit within 5 s"; return; fi
  sleep 0.5
  echo "compositor after the $how exit: $(compositor_lock)"
  if compositor_locked; then pass "graceful-exit ($how): Hyprland still reports LOCK on every monitor"; else fail "graceful-exit ($how): the session is UNLOCKED after a graceful exit (SEC-18: re-rate MEDIUM)"; fi
  shot "graceful-$how-dead"
  no_leak "graceful${how}" "graceful-exit ($how, shell gone)"
  "$root/scripts/dev/shell-run.sh"
  if s=$(wait_status locked 15); then pass "graceful-exit ($how): restarted shell status $s"; else fail "graceful-exit ($how): restarted shell status $s"; fi
  no_leak "gracefulback${how}" "graceful-exit ($how, restarted)"
}

step_graceful_exit() {
  graceful_case term
  graceful_case qskill
}

step_forged_crash() {
  printf 'unlocked\n' >"$marker"
  echo "marker forged: $(cat "$marker")"
  crash_and_restart forged-crash 15
}

# --- Foreign locker (R12 re-review: a lock taken over and released by another client) ---

foreign_ipc() { nested qs ipc -p "$foreign" call foreign "$@" 2>/dev/null; }

# All monitors list LOCK (read-only hyprctl query of the nested instance).
compositor_locked() {
  nested hyprctl -j monitors 2>/dev/null | jq -e 'length > 0 and all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null)' >/dev/null
}

foreign_start() { # <step>: start the foreign locker; it takes the session lock over
  # Nested socket and instance only (checked at the top); the fixture refuses anything else itself.
  env WAYLAND_DISPLAY="$sock" HYPRLAND_INSTANCE_SIGNATURE="$sig" GRASSFIELD_FOREIGN_LOCKER=1 \
    setsid "$root/tests/security/foreign_locker/run.sh" --no-color >"$dev/foreign-locker.log" 2>&1 </dev/null &
  dev_record_pid "$dev/foreign-locker.pid" "$!"
  local got=""
  for _ in $(seq 1 40); do
    got=$(foreign_ipc status)
    [[ $got == "locked secure" ]] && break
    sleep 0.25
  done
  if [[ $got == "locked secure" ]]; then pass "$1: the foreign locker holds the session lock"; else fail "$1: foreign locker status '${got:-no-answer}'"; fi
}

foreign_wait_exit() { # <step>: the foreign locker exits after its release
  for _ in $(seq 1 20); do dev_live_pid "$dev/foreign-locker.pid" >/dev/null || break; sleep 0.1; done
  if dev_live_pid "$dev/foreign-locker.pid" >/dev/null; then fail "$1: the foreign locker did not exit"; else pass "$1: the foreign locker exited"; rm -f "$dev/foreign-locker.pid" "$dev/foreign-locker.pid.start"; fi
}

# Releases the foreign lock, then measures how long Hyprland reports the session unlocked before the
# shell's fresh lock: prints "unlocked window". Fails if the session is not locked by Grassfield
# (status locked + LOCK on every monitor) within 3 s, or if the foreign locker does not exit.
# Release -> fresh lock request (ms) from the fixture's release epoch and the first "taking a fresh lock" in the shell
# log after line <from>; empty when either is missing.
relock_reaction_ms() { # <shell.log line count before the release>
  local released relocked
  released=$(grep -o "unlocking on request at [0-9]*" "$dev/foreign-locker.log" | tail -n 1 | grep -o "[0-9]*$")
  relocked=$(tail -n +"$(($1 + 1))" "$dev/shell.log" | grep -m1 "taking a fresh lock" | cut -c1-23)
  [[ -n $released && -n $relocked ]] && echo $(($(date -d "$relocked" +%s%3N) - released))
}

# The shell is in the suspected state now (100 ms check): its last suspicion line says so.
suspected_now() { grep -E "takeover suspected \(|no takeover suspected" "$dev/shell.log" | tail -n 1 | grep -q "takeover suspected ("; }

last_react=""
foreign_release_and_wait() { # <step>
  local t0 now first="" s from
  from=$(wc -l <"$dev/shell.log")
  t0=${EPOCHREALTIME/./}
  echo "foreign unlock -> $(foreign_ipc unlock)"
  for _ in $(seq 1 60); do
    if compositor_locked; then
      now=${EPOCHREALTIME/./}
      first=$(((now - t0) / 1000))
      break
    fi
    sleep 0.05
  done
  if [[ -n $first ]]; then echo "unlocked window: <= ${first} ms (foreign release -> Hyprland reports LOCK again)"; fi
  if [[ -n $first ]] && s=$(wait_status locked 3); then pass "$1: locked again by Grassfield after the foreign release (status $s)"; else fail "$1: not re-locked after the foreign release (status ${s:-?}, compositor $(compositor_lock))"; fi
  foreign_wait_exit "$1"
  echo "compositor: $(compositor_lock)"
  grep "grassfield-lock: the session is unlocked although" "$dev/shell.log" | tail -n 1
  last_react=$(relock_reaction_ms "$from")
  echo "$1: foreign release -> fresh lock request ${last_react:-?} ms (fixture and shell logs)"
}

# Fails when the last foreign release took more than <max> ms to get a fresh lock (the 100 ms check must catch it).
assert_react() { # <step> <max ms>
  if [[ -n $last_react ]] && ((last_react <= $2)); then pass "$1: fresh lock requested $last_react ms after the foreign release (<= $2)"; else fail "$1: fresh lock requested ${last_react:-?} ms after the foreign release (> $2 ms or not measured)"; fi
}

step_foreign_takeover() {
  local s
  s=$(ipc lock status)
  [[ $s == locked ]] || { fail "foreign-takeover: precondition: status $s (run the lock step first)"; return; }
  foreign_start foreign-takeover
  if s=$(wait_status locked 1); then pass "foreign-takeover: status while the foreign locker holds the lock: $s"; else fail "foreign-takeover: status $s"; fi
  if compositor_locked; then pass "foreign-takeover: Hyprland reports the session locked"; else fail "foreign-takeover: compositor $(compositor_lock)"; fi
  shot foreign-takeover-held
  no_leak heldforeign "foreign-takeover (foreign locker holds the lock)"
  foreign_release_and_wait foreign-takeover
  assert_react foreign-takeover "${FOREIGN_MAX_MS:-150}"
  shot foreign-takeover-relocked
  no_leak afterforeign "foreign-takeover (after the foreign release)"
}

step_foreign_restart() {
  local s
  foreign_start foreign-restart
  printf 'unlocked\n' >"$marker"
  echo "marker forged: $(cat "$marker")"
  "$root/scripts/dev/shell-run.sh"
  if s=$(wait_status locked 15); then pass "foreign-restart: restarted shell status $s (took the foreign-held lock over)"; else fail "foreign-restart: restarted shell status $s"; fi
  grep "this shell did not take" "$dev/shell.log" | tail -n 1
  echo "foreign locker: $(foreign_ipc status)"
  no_leak restartforeign "foreign-restart (foreign locker present, shell restarted)"
  foreign_release_and_wait foreign-restart
  # The inherited lock keeps the 100 ms check even when a Grassfield surface holds the keyboard (R12 counter-review of
  # 620f08c: ending it on keyboard focus brought back the ~1 s window): the fresh lock must follow within 150 ms.
  assert_react foreign-restart "${FOREIGN_MAX_MS:-150}"
  echo "marker: $(cat "$marker" 2>/dev/null || echo '<missing>')"
  shot foreign-restart-relocked
  no_leak afterrestart "foreign-restart (after the foreign release)"
}

# Holds the pre-fix desync on purpose (positive control): the periodic ownership check is paused
# (dev hook, 10 s), the foreign locker takes the live lock over and releases it. Hyprland then
# reports the session unlocked while the shell still says "locked". Nothing is typed meanwhile.
desync_from=0
make_desync() { # <step>
  foreign_start "$1"
  echo "lock devPauseOwnershipCheck -> $(ipc lock devPauseOwnershipCheck)"
  desync_from=$(wc -l <"$dev/shell.log")
  echo "foreign unlock -> $(foreign_ipc unlock)"
  foreign_wait_exit "$1"
  sleep 0.3
  local s
  s=$(ipc lock status)
  if ! compositor_locked && [[ $s == locked ]]; then
    pass "$1: desync held (control): Hyprland reports the session unlocked, shell status $s"
  else
    fail "$1: desync not reproduced (status $s, compositor $(compositor_lock))"
  fi
}

# The fresh lock must be triggered by <request> (logged before the re-lock), not by the paused check.
check_triggered_by() { # <step> <request log pattern>
  local order
  order=$(tail -n +"$((desync_from + 1))" "$dev/shell.log" | grep -o -E "$2|taking a fresh lock" | head -n 2 | tr '\n' '|')
  if [[ $order == *"|taking a fresh lock|" && $order != "taking a fresh lock|"* ]]; then
    pass "$1: the fresh lock followed the request ($order)"
  else
    fail "$1: order '$order'"
  fi
}

step_lock_desync() {
  local s answer
  make_desync lock-desync
  answer=$(ipc lock lock)
  echo "lock lock during the desync -> $answer"
  for _ in $(seq 1 60); do compositor_locked && break; sleep 0.05; done
  if compositor_locked && s=$(wait_status locked 3); then pass "lock-desync: real lock after lock lock (status $s, compositor $(compositor_lock))"; else fail "lock-desync: status ${s:-?}, compositor $(compositor_lock)"; fi
  check_triggered_by lock-desync "lock requested \(ipc\) while locked"
  tail -n +"$((desync_from + 1))" "$dev/shell.log" | grep -E "grassfield-lock"
  shot lock-desync
  no_leak afterdesync "lock-desync"
}

# Before-sleep path (dev hook `idle devSleep`; no logind, no real inhibitor in nested): the sleep
# delay may only end on a confirmed lock. Control (really locked), then right after a desync, where
# "ready for sleep" must follow the fresh lock's "locking -> locked (acquired)".
sleep_new=""
sleep_wait() { # <name> <shell.log line count before>: sets sleep_new (log lines since), checks the ready line
  local ready=""
  for _ in $(seq 1 40); do
    sleep_new=$(tail -n +"$(($2 + 1))" "$dev/shell.log")
    ready=$(grep -m1 "grassfield-idle: ready for sleep" <<<"$sleep_new")
    [[ -n $ready ]] && break
    sleep 0.1
  done
  grep -E "grassfield-lock|grassfield-idle" <<<"$sleep_new"
  echo "idle devSleep after -> $(ipc idle devSleep after)"
  if [[ $ready == *"(locked, lock confirmed)"* ]]; then pass "$1: the sleep delay ended on a confirmed lock"; else fail "$1: '${ready:-no ready line}'"; fi
}

step_sleep_desync() {
  local from order
  from=$(wc -l <"$dev/shell.log")
  echo "idle devSleep before -> $(ipc idle devSleep before)"
  sleep_wait sleep-control "$from"
  make_desync sleep-desync
  echo "idle devSleep before -> $(ipc idle devSleep before)"
  sleep_wait sleep-desync "$desync_from"
  check_triggered_by sleep-desync "lock requested \(sleep\) while locked"
  order=$(grep -o -E "taking a fresh lock|locking -> locked \(acquired\)|ready for sleep" <<<"$sleep_new" | head -n 3 | tr '\n' '|')
  if [[ $order == "taking a fresh lock|locking -> locked (acquired)|ready for sleep|" ]]; then
    pass "sleep-desync: the sleep delay ended only after the fresh lock was acquired"
  else
    fail "sleep-desync: order '$order'"
  fi
  if compositor_locked; then pass "sleep-desync: Hyprland reports the session locked"; else fail "sleep-desync: compositor $(compositor_lock)"; fi
  no_leak aftersleep "sleep-desync"
}

# --- Forced races (R12 review #3) ---

typed_bytes() { stat -c %s "$typed" 2>/dev/null || echo 0; }

# "locked" (every monitor lists LOCK), "unlocked" (a valid answer where one does not) or "unknown: <answer>" (hyprctl
# failed or answered no monitor: proves nothing either way).
compositor_state() {
  local out
  out=$(nested hyprctl -j monitors 2>/dev/null)
  jq -er 'if type == "array" and length > 0 then (if all(.[]; (.solitaryBlockedBy // []) | index("LOCK") != null) then "locked" else "unlocked: " + tojson end) else "unknown" end' <<<"$out" 2>/dev/null \
    || echo "unknown: ${out:0:80}"
}

# Letters only (never Return), different for every run so that a leak can be attributed.
probe_word() { # <prefix> <n>
  local letters=abcdefghijklmnopqrstuvwxyz
  printf '%s%s%s' "$1" "${letters:$(($2 % 26)):1}" "${letters:$(($2 / 26 % 26)):1}"
}

# A stale "unlocked" answer (forged by the dev hook while the session is really locked) followed by `lock lock`
# must not relock: relock() releases the lock object first, and releasing the lock the compositor uses unlocks the
# session until the new lock arrives. Keys are typed across the request (every 4 ms, about 0.5 s).
step_relock_confirm() {
  local runs=${RELOCK_RUNS:-12} i from before after answer word typer unlocked unknown state s relocks=0 leaks=0 opened=0
  s=$(ipc lock status)
  [[ $s == locked ]] || { fail "relock-confirm: precondition: status $s (run the lock step first)"; return; }
  for i in $(seq 1 "$runs"); do
    wait_status locked 3 >/dev/null || { fail "relock-confirm run $i: status $(ipc lock status)"; continue; }
    sleep 0.6 # past the 500 ms grace of a lock just acquired
    from=$(wc -l <"$dev/shell.log")
    before=$(typed_bytes)
    ipc lock devPauseOwnershipCheck >/dev/null
    answer=$(ipc lock devForgeUnlockedAnswer)
    [[ $answer == forged ]] || { fail "relock-confirm run $i: devForgeUnlockedAnswer -> '${answer:-no-answer}'"; continue; }
    word=$(probe_word relock "$i")
    bg_type "$word$word$word$word$word$word$word$word$word$word$word$word"
    sleep 0.05
    answer=$(ipc lock lock)
    unlocked=0 unknown=0
    for _ in $(seq 1 10); do
      state=$(compositor_state)
      case $state in
        locked) ;;
        unlocked*) unlocked=$((unlocked + 1)); echo "  $state" ;;
        *) unknown=$((unknown + 1)); echo "  $state" ;;
      esac
      sleep 0.03
    done
    wait "$typer"
    sleep 0.4
    after=$(typed_bytes)
    if tail -n +"$((from + 1))" "$dev/shell.log" | grep -q "taking a fresh lock"; then relocks=$((relocks + 1)); fi
    ((after > before)) && leaks=$((leaks + 1))
    ((unlocked > 0)) && opened=$((opened + 1))
    echo "run $i: lock lock -> $answer; compositor answers without LOCK: $unlocked (no valid answer: $unknown); bytes that reached foot: $((after - before))"
  done
  press_key Escape # empty the lock field (Escape clears it; nothing is ever submitted)
  # The last dev pause (10 s) ends before the next step relies on the periodic check.
  for _ in $(seq 1 120); do
    tail -n +"$((from + 1))" "$dev/shell.log" | grep -q "dev pause of the lock ownership check ended" && break
    sleep 0.1
  done
  echo "relock-confirm: $runs runs: relocks $relocks, runs with a key in foot $leaks, runs with an unlocked compositor answer $opened"
  if ((relocks == 0)); then pass "relock-confirm: no relock without a confirming answer ($runs runs)"; else fail "relock-confirm: relocked on an unconfirmed answer in $relocks of $runs runs"; fi
  if ((leaks == 0)); then pass "relock-confirm: nothing reached the foot window ($runs runs)"; else fail "relock-confirm: keys reached the foot window in $leaks of $runs runs"; fi
  if ((opened == 0)) && compositor_locked; then pass "relock-confirm: Hyprland reported LOCK throughout"; else fail "relock-confirm: Hyprland reported the session unlocked in $opened runs"; fi
}

# A foreign locker takes the live Grassfield lock over and releases it while keys are typed (every 4 ms): measures the
# unlocked window (foreign release -> Hyprland reports LOCK again) and the keys that reached foot during it.
step_foreign_gap() {
  local runs=${FOREIGN_RUNS:-5} max=${GAP_MAX_MS:-200} i s t0 t1 now lo hi before mid after word typer from released relocked react worst=0 polled=0 inGap=0 late=0
  for i in $(seq 1 "$runs"); do
    s=$(wait_status locked 3) || { fail "foreign-gap run $i: precondition: status $s"; return; }
    foreign_start "foreign-gap run $i"
    sleep 1 # the takeover settles; past the 500 ms grace of the last Grassfield lock
    before=$(typed_bytes)
    word=$(probe_word gap "$i")
    bg_type "$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word"
    sleep 0.05
    from=$(wc -l <"$dev/shell.log")
    t0=${EPOCHREALTIME/./}
    foreign_ipc unlock >/dev/null
    t1=${EPOCHREALTIME/./}
    lo="" hi=""
    for _ in $(seq 1 300); do
      if compositor_locked; then now=${EPOCHREALTIME/./}; lo=$(((now - t1) / 1000)); hi=$(((now - t0) / 1000)); break; fi
      sleep 0.005
    done
    mid=$(typed_bytes)
    wait "$typer"
    sleep 0.3
    after=$(typed_bytes)
    foreign_wait_exit "foreign-gap run $i"
    if [[ -z $hi ]]; then fail "foreign-gap run $i: Hyprland did not report LOCK again within 3 s"; continue; fi
    # Precise window: the fixture logs the epoch ms of its release, the shell log the time of its fresh lock request.
    react=""
    released=$(grep -o "unlocking on request at [0-9]*" "$dev/foreign-locker.log" | tail -n 1 | grep -o "[0-9]*$")
    relocked=$(tail -n +"$((from + 1))" "$dev/shell.log" | grep -m1 "taking a fresh lock" | cut -c1-23)
    [[ -n $released && -n $relocked ]] && react=$(($(date -d "$relocked" +%s%3N) - released))
    if [[ -z $react ]]; then fail "foreign-gap run $i: no release time or no fresh lock in the logs"; continue; fi
    ((react > worst)) && worst=$react
    ((lo > polled)) && polled=$lo
    inGap=$((inGap + mid - before))
    late=$((late + after - mid))
    echo "run $i: foreign release -> fresh lock request ${react:-?} ms (shell log); -> LOCK seen by polling $lo ms after the release request returned ($hi ms before it was sent); bytes in foot: $((mid - before)) by then, $((after - mid)) after"
    no_leak "after$(probe_word gap "$i")" "foreign-gap run $i (typed after the fresh lock)"
  done
  echo "foreign-gap: $runs runs: worst release -> fresh lock request $worst ms (LOCK seen by polling within $polled ms, hyprctl and jq time included); bytes in foot during the windows $inGap, after them $late"
  if ((worst <= max)); then pass "foreign-gap: fresh lock requested <= $max ms after every foreign release (worst $worst ms)"; else fail "foreign-gap: fresh lock requested $worst ms after a foreign release (> $max ms)"; fi
  if ((polled <= 1500)); then pass "foreign-gap: Hyprland reported LOCK again within $polled ms of each release request"; else fail "foreign-gap: Hyprland reported LOCK again only after $polled ms"; fi
  # Bytes counted after the LOCK poll can still be keys typed inside the window (the poll costs tens of ms and foot ->
  # cat -> file adds lag): informational. The hard check is each run's probe typed after the fresh lock (no_leak above).
  echo "foreign-gap: bytes counted after the LOCK poll: $late (keys typed inside the window can land late; see the per-run probes)"
  # Leak control: Hyprland refocuses the window under the pointer when a foreign locker releases; foot only receives keys
  # in the window when it is that window (true right after `setup`; shell restarts in earlier steps can change it).
  ((inGap > 0)) || echo "foreign-gap: NOTE no key reached foot during any window: foot did not get the focus Hyprland restores, so the in-window count proves nothing in this run (run setup lock foreign-gap)"
  press_key Escape
}

# CPU time of a process in clock ticks (utime + stime: /proc/<pid>/stat fields 14 and 15; field 2 may hold spaces).
cpu_ticks() { # <pid>
  local stat rest
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || { echo 0; return; }
  rest=${stat##*) }
  local -a f
  read -ra f <<<"$rest"
  echo $((f[11] + f[12]))
}

cpu_percent() { # <seconds> <pid>...: CPU % of each process over the interval, space separated
  local secs=$1 hz i out=""
  shift
  local -a a=() b=()
  hz=$(getconf CLK_TCK)
  for i in "$@"; do a+=("$(cpu_ticks "$i")"); done
  sleep "$secs"
  for i in "$@"; do b+=("$(cpu_ticks "$i")"); done
  for i in "${!a[@]}"; do out+=$(awk -v d=$((b[i] - a[i])) -v hz="$hz" -v s="$secs" 'BEGIN { printf " %.1f", 100 * d / hz / s }'); done
  echo "${out# }"
}

# Cost of the 100 ms ownership check while a takeover is suspected (a foreign locker holds the lock over Grassfield's),
# against the 1 s check of a plain lock: CPU of the shell and of the nested Hyprland over PROBE_COST_SECONDS (10).
step_probe_cost() {
  local secs=${PROBE_COST_SECONDS:-10} shellPid hyprPid plain held s from extra
  shellPid=$(dev_live_pid "$dev/shell.pid") && hyprPid=$(dev_live_pid "$dev/nested.pid") || { fail "probe-cost: no live shell or compositor record"; return; }
  s=$(wait_status locked 3) || { fail "probe-cost: precondition: status $s"; return; }
  sleep 1.5
  # A lock inherited at start (or one whose surface has no keyboard) already runs the 100 ms check: then there is no
  # 1 s baseline to compare with, and the comparison is informational (not a failure).
  local plainState="check every 1 s"
  suspected_now && plainState="already suspected: check every 100 ms (no 1 s baseline)"
  plain=$(cpu_percent "$secs" "$shellPid" "$hyprPid")
  foreign_start probe-cost
  sleep 1
  if suspected_now; then pass "probe-cost: takeover suspected while the foreign locker holds the lock"; else fail "probe-cost: no takeover suspected after the foreign takeover"; fi
  held=$(cpu_percent "$secs" "$shellPid" "$hyprPid")
  foreign_release_and_wait probe-cost
  echo "probe-cost: CPU % over $secs s (shell nested-Hyprland): plain lock ($plainState): $plain; foreign locker holding, check every 100 ms: $held"
  extra=$(awk -v a="$plain" -v b="$held" 'BEGIN { split(a, x, " "); split(b, y, " "); printf "%.1f", (y[1] + y[2]) - (x[1] + x[2]) }')
  if awk -v e="$extra" 'BEGIN { exit !(e < 5) }'; then pass "probe-cost: the suspected-takeover check adds $extra % CPU (< 5)"; else fail "probe-cost: the suspected-takeover check adds $extra % CPU"; fi
  # Absolute bound, whatever the baseline was: shell + nested Hyprland under 10 % CPU with the 100 ms check.
  if awk -v b="$held" 'BEGIN { split(b, y, " "); exit !(y[1] + y[2] < 10) }'; then pass "probe-cost: shell + Hyprland stay under 10 % CPU with the 100 ms check ($held)"; else fail "probe-cost: shell + Hyprland at $held % CPU with the 100 ms check"; fi
}

rss_mb() { awk '/^VmRSS:/ { printf "%.1f", $2 / 1024 }' "/proc/$1/status" 2>/dev/null; }

# Memory of the shell while the 100 ms ownership check runs (a foreign locker holds the lock over Grassfield's) for
# PROBE_MEMORY_SECONDS (default 600), RSS every 15 s. The JS heap makes a sawtooth (garbage builds up, a collection drops
# it), so two numbers: the garbage rate (sum of the rises, MB/min; what the per-probe allocation costs) and the retained
# growth (lowest RSS of the last third minus lowest of the middle third: a leak raises the post-collection floor).
# Fails when the retained growth reaches PROBE_MEMORY_MAX_RETAINED_MB (default 5). Not in the default sequence (10 min).
step_probe_memory() {
  local secs=${PROBE_MEMORY_SECONDS:-600} maxRetained=${PROBE_MEMORY_MAX_RETAINED_MB:-5} shellPid s from t0 now series="" stats rate retained
  shellPid=$(dev_live_pid "$dev/shell.pid") || { fail "probe-memory: no live shell record"; return; }
  s=$(wait_status locked 3) || { fail "probe-memory: precondition: status $s"; return; }
  from=$(wc -l <"$dev/shell.log")
  foreign_start probe-memory
  sleep 1
  if ! tail -n +"$((from + 1))" "$dev/shell.log" | grep -q "takeover suspected"; then
    [[ $(ipc lock status) == locked ]] && echo "probe-memory: (the shell was already in the suspected state)"
  fi
  t0=$SECONDS
  while ((SECONDS - t0 <= secs)); do
    now=$((SECONDS - t0))
    series+="$now $(rss_mb "$shellPid")"$'\n'
    sleep 15
  done
  foreign_release_and_wait probe-memory
  echo "probe-memory: shell RSS (s MB):"
  printf '%s' "$series" | awk '{ printf "  %4d s  %7.1f MB\n", $1, $2 }'
  stats=$(printf '%s' "$series" | awk -v secs="$secs" '
    { t[NR] = $1; m[NR] = $2 }
    END {
      up = 0; mid = 1e9; last = 1e9; lo = 1e9; hi = 0
      for (i = 1; i <= NR; i++) {
        if (i > 1 && m[i] > m[i - 1]) up += m[i] - m[i - 1]
        if (t[i] >= secs / 3 && t[i] < 2 * secs / 3 && m[i] < mid) mid = m[i]
        if (t[i] >= 2 * secs / 3 && m[i] < last) last = m[i]
        if (m[i] < lo) lo = m[i]; if (m[i] > hi) hi = m[i]
      }
      printf "%.1f %.1f %.1f %.1f", up / (t[NR] / 60), last - mid, lo, hi
    }')
  read -r rate retained lo hi <<<"$stats"
  echo "probe-memory: over $secs s: garbage rate $rate MB/min (sum of rises), retained growth $retained MB (floor of the last third minus floor of the middle third), RSS $lo-$hi MB"
  if awk -v r="$retained" -v m="$maxRetained" 'BEGIN { exit !(r < m) }'; then pass "probe-memory: no retained growth with the 100 ms check ($retained MB < $maxRetained)"; else fail "probe-memory: the post-collection floor grew $retained MB with the 100 ms check"; fi
}

# Leave nothing behind but the (locked) nested session.
step_cleanup() {
  echo "typed into foot: $(tr -c '[:alnum:]' ' ' <"$typed" 2>/dev/null)"
  dev_stop "$dev/reload-foot.pid" "probe foot" >/dev/null || true
  # A foreign locker still running (failed step): stop it; Hyprland keeps the session locked.
  dev_stop "$dev/foreign-locker.pid" "foreign locker" >/dev/null || true
}

# PAM attempt audit across EVERY shell instance this tree started (restarts overwrite $dev/shell.log, so read the
# Quickshell per-instance logs too). Must be 0: a real submit would count a faillock failure on the owner's account.
step_pam_audit() {
  local n s x new_s new_x
  read -r n s x < <(pam_counts)
  read -r new_s new_x < <(pam_new)
  echo "pam-audit: this run: $((n - pam_base_instances)) new shell instance(s); PAM submits $new_s; suppressed submits $new_x (all $n instance logs of this tree: submits $s, suppressed $x)"
  if ((new_s == 0)); then pass "pam-audit: no password was submitted to PAM during this run"; else fail "pam-audit: $new_s PAM submit(s) during this run: a faillock failure may have been counted on the real account"; fi
  ((new_x == 0)) || fail "pam-audit: $new_x key sequence(s) submitted the lock field (blocked by the dev PAM suppression, still a test defect)"
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup nowatch lock relock-confirm foreign-gap probe-cost marker-missing marker-unlocked l1 forged-crash graceful-exit foreign-takeover foreign-restart lock-desync sleep-desync cleanup pam-audit)
assert_no_pam "before the run"
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "reload_locked: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
  [[ $s == pam-audit ]] || assert_no_pam "after step $s"
done
exit $status
