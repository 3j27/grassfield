#!/usr/bin/env bash
# Menu bridge vs. a hostile application (global menus review): a huge GetLayout reply must not take the bridge down
# repeatedly, and an application that does must not be asked again, whatever its pid.
#
# Every case starts from a fresh bridge state. Waits are on bridge state (the diagnostics Status, the log, /proc),
# never on fixed delays; the time limits below only bound a hang.
#
#   B  1500 items of 20 kB labels (~30 MB reply, under the item cap): the menu is served, VmHWM stays below the
#      unit's MemoryMax (256 MB) and RssAnon returns to near idle (malloc_trim) once the reply is processed.
#   A  40000 items (~40 MB reply, over the 2000 item cap): "oversized", exactly one GetLayout reaches the
#      application however often the window is opened again ("backoff"), same bridge process, bounded VmHWM.
#   C  the bridge is SIGKILLed by the application's first GetLayout (stand-in for the memory limit): the restarted
#      bridge refuses that application ("backoff", from the state file) and never sends a second GetLayout.
#   D  crash loop on a RE-READ: a small first layout is served, the re-read after LayoutUpdated kills the bridge.
#      The call was marked in flight, so the restarted bridge blames the application's executable: its next
#      processes (new pids, same executable) are refused without a GetLayout. At most N=1 restart; another
#      application (another executable) is unaffected.
#   E  forged or damaged state files (symlink, garbage, oversized) are ignored and removed; the bridge starts.
#   F  a second bridge instance exits without touching the live bridge's state file.
#
# Needs no compositor: a private dbus-daemon (/tmp/dbus-* socket, never the owner's bus), the bridge, tests/fixtures/huge-menu.
# Usage: tests/integration/menu_bridge_memory.sh      Exit: 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
max_kb=$((256 * 1024))
idle_limit_kb=$((20 * 1024)) # ADR-0008 budget ~20 MB (RssAnon: the Qt libraries' file-backed pages are not counted)
max_restarts=1               # case D: bridge deaths an application may cause before it is refused
fail=0
say() { printf '%s\n' "$*"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }
wait_until() { # <seconds> <command...>: polls the condition every 100 ms, bounded
  local limit=$(($1 * 10)) i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

command -v dbus-daemon >/dev/null || die "dbus-daemon is needed"
[[ -x $dev/build/grassfield-menu-bridge ]] || "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"
[[ -x $dev/build/huge-menu ]] || "$root/tests/fixtures/build.sh" huge-menu >/dev/null || die "huge-menu build failed"

work=$(mktemp -d "${TMPDIR:-/tmp}/gf-mb.XXXXXX") || die "no temp dir"
chmod 700 "$work"
sock=$work/bridge.sock
state=$sock.state
log=$work/bridge.log
((${#sock} < 100)) || die "socket path too long: $sock"
bus_pid=""
cp "$dev/build/huge-menu" "$work/other-menu" # another application: another executable, same behaviour

stop_all() {
  touch "$work/stop-supervisor"
  [[ -s $work/bridge.pid ]] && kill "$(<"$work/bridge.pid")" 2>/dev/null
  [[ -n $bus_pid ]] && kill "$bus_pid" 2>/dev/null
  rm -rf "$work"
}
trap stop_all EXIT

setsid dbus-daemon --session --nofork --print-address=1 >"$work/bus.address" 2>"$work/bus.log" </dev/null &
bus_pid=$!
wait_until 5 test -s "$work/bus.address"
bus=$(head -n 1 "$work/bus.address")
case $bus in unix:path=/tmp/dbus-*) ;; *) die "unexpected bus address '$bus'" ;; esac
say "private bus $bus (dbus-daemon pid $bus_pid)"

start_bridge() { # starts one bridge, records its pid in $work/bridge.pid, waits for its socket
  env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$sock" \
    setsid "$dev/build/grassfield-menu-bridge" >>"$log" 2>&1 </dev/null &
  echo $! >"$work/bridge.pid"
  wait_until 10 test -S "$sock"
}
cur_pid() { cat "$work/bridge.pid" 2>/dev/null; }
alive() { [[ -r /proc/$1/stat ]] && [[ $(awk '{print $3}' "/proc/$1/stat" 2>/dev/null) != Z ]]; }
bridge_up() { [[ -S $sock ]] && alive "$1"; }
not_alive() { ! alive "$1"; }
stop_bridge() { # SIGTERM, wait for the exit
  local pid
  pid=$(cur_pid)
  [[ -n $pid ]] || return 0
  kill "$pid" 2>/dev/null
  wait_until 10 not_alive "$pid"
}
fresh_bridge() { # a bridge without any remembered state and with an empty log
  touch "$work/stop-supervisor"
  stop_bridge
  rm -f "$state" "$sock" "$work/stop-supervisor"
  : >"$log"
  start_bridge
}
supervise() { # restarts the bridge each time it dies (systemd's Restart=on-failure), until $work/stop-supervisor exists
  (
    while [[ ! -e $work/stop-supervisor ]]; do
      if alive "$(cur_pid)"; then sleep 0.05; continue; fi
      start_bridge
    done
  ) &
  super=$!
}
stop_supervisor() {
  touch "$work/stop-supervisor"
  wait "$super" 2>/dev/null
}

status_field() { awk -v k="^$1:" '$0 ~ k {print $2}' "/proc/$2/status" 2>/dev/null; }
hwm_kb() { status_field VmHWM "$1"; }
anon_kb() { status_field RssAnon "$1"; }

fixture() { # <name> <args...>   (the app is the fixture; output in $work/<name>.out)
  local name=$1
  shift
  env DBUS_SESSION_BUS_ADDRESS="$bus" "${FIXTURE_EXE:-$dev/build/huge-menu}" --socket "$sock" "$@" >"$work/$name.out" 2>&1
}
getlayouts() { grep -c 'GetLayout #' "$work/$1.out"; }
replies() { grep -c "$2" "$work/$1.out"; }
logcount() { grep -c "$1" "$log"; }
anon_below() { (($(anon_kb "$1") < idle_limit_kb)); }

fresh_bridge || die "bridge did not start ($log)"
first_pid=$(cur_pid)
say "bridge pid $first_pid, idle RssAnon $(anon_kb "$first_pid") kB, VmHWM $(hwm_kb "$first_pid") kB"

say ""
say "[B] ~30 MB reply under the item cap"
fixture b --items 1500 --label-kb 20 --windows 1 --gap-ms 2000
sed 's/^/    /' "$work/b.out"
say "    VmHWM after: $(hwm_kb "$first_pid") kB (limit $max_kb kB), RssAnon right after: $(anon_kb "$first_pid") kB"
check "the menu was served" test "$(replies b 'reply menu')" -ge 1
check "bridge alive, same process" alive "$first_pid"
check "peak RSS below MemoryMax" test "$(hwm_kb "$first_pid")" -lt "$max_kb"
wait_until 30 anon_below "$first_pid"
say "    RssAnon once the reply was processed: $(anon_kb "$first_pid") kB (limit $idle_limit_kb kB)"
check "RssAnon back near idle after the large reply (malloc_trim)" anon_below "$first_pid"

say ""
say "[A] ~40 MB reply over the item cap, window opened 4 times"
fresh_bridge || die "bridge did not restart"
first_pid=$(cur_pid)
fixture a --items 40000 --label-kb 1 --windows 4 --gap-ms 5000
sed 's/^/    /' "$work/a.out"
say "    VmHWM after: $(hwm_kb "$first_pid") kB (limit $max_kb kB)"
check "refused as oversized once" test "$(replies a 'code.:.oversized')" -eq 1
check "later opens answered with backoff, no new fetch" test "$(replies a 'backoff')" -eq 3
check "exactly one GetLayout reached the application" test "$(getlayouts a)" -eq 1
check "bridge alive, same process (no restart loop)" alive "$first_pid"
check "peak RSS below MemoryMax" test "$(hwm_kb "$first_pid")" -lt "$max_kb"
wait_until 30 anon_below "$first_pid"
check "RssAnon back near idle after the oversized reply" anon_below "$first_pid"

say ""
say "[C] bridge killed during the first GetLayout, restarted"
fresh_bridge || die "bridge did not restart"
first_pid=$(cur_pid)
supervise
fixture c --items 1500 --label-kb 20 --windows 3 --gap-ms 2500 --kill-pid "$first_pid" --service org.grassfield.HugeMenuC
stop_supervisor
sed 's/^/    /' "$work/c.out"
second_pid=$(cur_pid)
say "    first bridge pid $first_pid, now $second_pid"
check "the first bridge was killed and another one runs" test -n "$second_pid" -a "$second_pid" != "$first_pid"
check "restarted bridge knows who killed its predecessor (log)" grep -q "a previous run died while a call to" "$log"
check "the application is refused after the restart (backoff)" test "$(replies c 'backoff')" -ge 1
check "exactly one GetLayout in total (no crash loop)" test "$(getlayouts c)" -eq 1

say ""
say "[D] crash loop on a re-read: small first layout, hostile LayoutUpdated re-read, new process after each death"
fresh_bridge || die "bridge did not restart"
supervise
attempts=4
for n in $(seq 1 $attempts); do
  # A new process of the same executable each time (a new pid and a new bus name).
  fixture "d$n" --items 3 --label-kb 0 --windows 1 --gap-ms 8000 --kill-pid "$(cur_pid)" --kill-on 2 --emit-updates --service "org.grassfield.HugeMenuD$n"
  say "    attempt $n: GetLayout=$(getlayouts "d$n") menu=$(replies "d$n" 'reply menu') backoff=$(replies "d$n" 'backoff')"
done
FIXTURE_EXE=$work/other-menu
fixture dother --items 3 --label-kb 0 --windows 1 --gap-ms 800 --service org.grassfield.OtherMenu
unset FIXTURE_EXE
stop_supervisor
deaths=$(($(logcount 'listening on') - 1))
say "    bridge deaths: $deaths (limit $max_restarts); log:"
grep -E "previous run died|refused|listening" "$log" | sed 's/^/      /'
check "the re-read was attempted once (first attempt got 2 GetLayout)" test "$(getlayouts d1)" -eq 2
check "the bridge died at most $max_restarts time(s)" test "$deaths" -le "$max_restarts"
check "the restarted bridge attributed the crash to the application's executable" grep -q 'previous run died while a call to "exe:.*huge-menu"' "$log"
for n in $(seq 2 $attempts); do
  check "attempt $n (new pid): refused with backoff, no GetLayout at all" test "$(replies "d$n" 'backoff')" -ge 1 -a "$(getlayouts "d$n")" -eq 0
done
check "another application (another executable) is not refused" test "$(replies dother 'reply menu')" -ge 1

say ""
say "[E] forged or damaged state files are ignored and removed"
fresh_bridge || die "bridge did not restart"
for variant in symlink garbage oversized other-boot; do
  stop_bridge
  rm -f "$state"
  case $variant in
    symlink) printf 'grassfield-menu-bridge-state 1\nboot x\n' >"$work/target" && ln -s "$work/target" "$state" ;;
    garbage) printf 'inflight exe:/x\n\000garbage' >"$state" ;;
    oversized) head -c 200000 /dev/zero | tr '\0' 'x' >"$state" ;;
    other-boot) printf 'grassfield-menu-bridge-state 1\nboot 00000000-0000-0000-0000-000000000000\ninflight exe:/usr/bin/anything\n' >"$state" ;;
  esac
  rm -f "$sock"
  : >"$log"
  start_bridge
  check "[$variant] bridge started and ignored the file" grep -q "ignored .*bridge.sock.state" "$log"
  check "[$variant] the file was replaced by a valid state" grep -q '^grassfield-menu-bridge-state 1$' "$state"
  check "[$variant] it is a regular file now, not a symlink" test ! -L "$state"
  [[ $variant != symlink ]] || check "[$variant] the link's target was not written through" test "$(wc -l <"$work/target")" -eq 2
done

say ""
say "[F] a second instance exits and leaves the live bridge's state alone"
fresh_bridge || die "bridge did not restart"
live=$(cur_pid)
before=$(sha256sum <"$state")
inode_before=$(stat -c %i "$state")
env -u GRASSFIELD_SESSION DBUS_SESSION_BUS_ADDRESS="$bus" GRASSFIELD_DEV=1 GRASSFIELD_MENU_BRIDGE_SOCKET="$sock" "$dev/build/grassfield-menu-bridge" >"$work/second.log" 2>&1 </dev/null
second_rc=$?
say "    second instance exit status $second_rc: $(tail -n 1 "$work/second.log")"
check "second instance refused to start" test "$second_rc" -ne 0
check "the live bridge still runs and listens" bridge_up "$live"
check "its state file is untouched" test "$(sha256sum <"$state")" = "$before" -a "$(stat -c %i "$state")" = "$inode_before"

say ""
if ((fail)); then say "RESULT: FAIL"; exit 1; fi
say "RESULT: PASS"
