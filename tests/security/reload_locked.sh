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
#                   the keys that reached foot during it; fails when the window exceeds GAP_MAX_MS
#                   (default 300) or a key typed after the fresh lock reaches foot
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
shot() { "$root/scripts/dev/shot.sh" "$1-gfref" GF-REF >/dev/null && "$root/scripts/dev/shot.sh" "$1-window" WAYLAND-1; }

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

# Types a probe word (letters only, never Return) and checks that foot did not receive it.
no_leak() { # <word> <step>
  nested wtype -d 15 "$1"
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
  nested wtype -d 15 control
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
    setsid qs -p "$foreign" --no-color >"$dev/foreign-locker.log" 2>&1 </dev/null &
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
foreign_release_and_wait() { # <step>
  local t0 now first="" s
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

# Letters only (never Return), different for every run so that a leak can be attributed.
probe_word() { # <prefix> <n>
  local letters=abcdefghijklmnopqrstuvwxyz
  printf '%s%s%s' "$1" "${letters:$(($2 % 26)):1}" "${letters:$(($2 / 26 % 26)):1}"
}

# A stale "unlocked" answer (forged by the dev hook while the session is really locked) followed by `lock lock`
# must not relock: relock() releases the lock object first, and releasing the lock the compositor uses unlocks the
# session until the new lock arrives. Keys are typed across the request (every 4 ms, about 0.5 s).
step_relock_confirm() {
  local runs=${RELOCK_RUNS:-12} i from before after answer word typer unlocked s relocks=0 leaks=0 opened=0
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
    nested wtype -d 4 "$word$word$word$word$word$word$word$word$word$word$word$word" &
    typer=$!
    sleep 0.05
    answer=$(ipc lock lock)
    unlocked=0
    for _ in $(seq 1 10); do compositor_locked || unlocked=$((unlocked + 1)); sleep 0.03; done
    wait "$typer"
    sleep 0.4
    after=$(typed_bytes)
    if tail -n +"$((from + 1))" "$dev/shell.log" | grep -q "taking a fresh lock"; then relocks=$((relocks + 1)); fi
    ((after > before)) && leaks=$((leaks + 1))
    ((unlocked > 0)) && opened=$((opened + 1))
    echo "run $i: lock lock -> $answer; compositor answers without LOCK: $unlocked; bytes that reached foot: $((after - before))"
  done
  nested wtype -k Escape # empty the lock field (Escape clears it; nothing is ever submitted)
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
  local runs=${FOREIGN_RUNS:-5} max=${GAP_MAX_MS:-300} i s t0 t1 now lo hi before mid after word typer worst=0 inGap=0 late=0
  for i in $(seq 1 "$runs"); do
    s=$(wait_status locked 3) || { fail "foreign-gap run $i: precondition: status $s"; return; }
    foreign_start "foreign-gap run $i"
    sleep 1 # the takeover settles; past the 500 ms grace of the last Grassfield lock
    before=$(typed_bytes)
    word=$(probe_word gap "$i")
    nested wtype -d 4 "$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word$word" &
    typer=$!
    sleep 0.05
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
    ((hi > worst)) && worst=$hi
    inGap=$((inGap + mid - before))
    late=$((late + after - mid))
    echo "run $i: unlocked window $lo-$hi ms (after/before the release request); bytes in foot: $((mid - before)) by the fresh lock, $((after - mid)) after it"
    no_leak "after$(probe_word gap "$i")" "foreign-gap run $i (typed after the fresh lock)"
  done
  echo "foreign-gap: $runs runs: worst unlocked window $worst ms; bytes in foot during the windows $inGap, after them $late"
  if ((worst <= max)); then pass "foreign-gap: unlocked window <= $max ms in every run (worst $worst ms)"; else fail "foreign-gap: unlocked window $worst ms > $max ms"; fi
  if ((late == 0)); then pass "foreign-gap: no key typed after the fresh lock reached foot"; else fail "foreign-gap: $late bytes reached foot after the fresh lock was reported"; fi
  nested wtype -k Escape
}

# Leave nothing behind but the (locked) nested session.
step_cleanup() {
  echo "typed into foot: $(tr -c '[:alnum:]' ' ' <"$typed" 2>/dev/null)"
  dev_stop "$dev/reload-foot.pid" "probe foot" >/dev/null || true
  # A foreign locker still running (failed step): stop it; Hyprland keeps the session locked.
  dev_stop "$dev/foreign-locker.pid" "foreign locker" >/dev/null || true
}

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(setup nowatch lock marker-missing marker-unlocked l1 forged-crash foreign-takeover foreign-restart lock-desync sleep-desync relock-confirm foreign-gap cleanup)
for s in "${steps[@]}"; do
  echo "== $s"
  declare -F "step_${s//-/_}" >/dev/null || { echo "reload_locked: unknown step $s" >&2; exit 2; }
  "step_${s//-/_}"
done
exit $status
