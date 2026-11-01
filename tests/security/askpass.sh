#!/usr/bin/env bash
# grassfield-askpass, udiskie's password command (ADR-0035 D-9, step 9c; docs/specs/system-dialogs.md section 5, SC7), on
# a private bus of the test's own: against the real grassfield-prompter with a fake shell on its socket
# (tests/fixtures/prompter-shell.py), and with no bridge holding gcr's prompter name, against a stand-in for the stock
# gcr-prompter that D-Bus activation starts (another development run of the bridge with an auto-answering fake shell: the
# helper only knows gcr's protocol, never who serves it). Never the owner's bus, disks or secrets: every process runs
# under env -i with the test's scratch directories. Test passphrases only.
#  1 refusals: wrong arguments, standard output a terminal (exit 2, nothing asked)
#  2 the shell's sheet gets a password prompt from the helper: the requester the bridge resolves ("disk" for the installed
#    /usr/lib/grassfield/grassfield-askpass, else "unidentified" with the path of the binary run), the helper's text with
#    the disk's name flattened (a line feed and a direction override in it); while it waits the helper allows no core file;
#    the installed helper run in a user and mount namespace of its own (as udiskie's unit runs it, PrivateUsers=self) is
#    still "disk" (decision 9-26, amended; SKIP for a development build or without unprivileged user namespaces)
#  3 the passphrase the shell answers is written once, followed by a newline, nothing else, exit 0 (what udiskie reads)
#  4 Cancel: exit 1, nothing written; the shell going away: exit 1, nothing written
#  5 French: the helper's text in French with the French catalog (a development run's catalog directory)
#  6 no bridge holds the name: D-Bus activation starts the stand-in for the stock prompter and the passphrase comes from it
#  7 no test passphrase in the bridge's output
# Needs g++ with the Qt 6 Core and gcr-4 headers (or GRASSFIELD_PROMPTER and GRASSFIELD_ASKPASS: built binaries), dbus-daemon,
# dbus-send, python3; SKIPs without them, when libdbus cannot reach the bus, and when this process has no cgroup of its own.
#
#   tests/security/askpass.sh              PASS / FAIL lines, exit 0 when all pass
#   tests/security/askpass.sh --mutants    also mutants of the helper's guards, which the checks must catch
set -uo pipefail
umask 077
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: askpass.sh [--mutants]" >&2; exit 2 ;;
esac
for tool in dbus-daemon dbus-send python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: askpass needs $tool"; exit 0; }
done
leaf=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup | sed 's#.*/##')
[[ -n $leaf ]] || { echo "SKIP: askpass: this process sits at the root of its cgroup tree (no unit to stand for the shell's)"; exit 0; }

pids=()
bus_pid=""
tmp=""
d=""
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n $bus_pid ]] && kill -TERM -- "-$bus_pid" 2>/dev/null
  # The activated stand-in runs in the bus's process group.
  wait 2>/dev/null
  [[ -n $tmp ]] && rm -rf "$tmp"
  [[ -n $d ]] && rm -rf "$d"
  pids=()
  bus_pid=""
  tmp=""
  d=""
}

# scenario <bridge> <askpass>: every check below; PASS/FAIL lines, 0 when all passed.
scenario() {
  scenario_body "$@"
  local rc=$?
  cleanup
  return $rc
}

scenario_body() {
  local bridge=$1 askpass=$2 fail=0
  tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/askpass.XXXXXX")
  d=$(mktemp -d /tmp/gfa.XXXXXX)
  check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
  wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

  mkdir -p "$d/services" "$d/run"
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>unix:path=$d/bus.sock</listen>" '  <auth>EXTERNAL</auth>' \
    "  <servicedir>$d/services</servicedir>" '  <policy context="default">' '    <allow send_destination="*" eavesdrop="true"/>' \
    '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' '</busconfig>' >"$d/bus.conf"
  setsid env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" dbus-daemon --config-file="$d/bus.conf" --nofork --print-address=1 \
    >"$d/bus.address" 2>"$d/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$d/bus.address" || { echo "SKIP: askpass: no private dbus-daemon"; return 0; }
  local bus
  bus=$(head -n 1 "$d/bus.address")
  dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId >/dev/null 2>&1 \
    || { echo "SKIP: askpass: libdbus cannot reach the private bus"; return 0; }
  local run_env=(env -i PATH="$PATH" HOME="$d" XDG_RUNTIME_DIR="$d/run" DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" LC_ALL=C.UTF-8)
  local sock=$d/run/grassfield/prompter.sock shell_py=$root/tests/fixtures/prompter-shell.py

  shell_up() { # <tag> <socket>
    mkfifo "$d/$1.cmd"
    python3 -I "$shell_py" --socket "$2" --log "$d/$1.shell" --commands "$d/$1.cmd" </dev/null >/dev/null 2>&1 &
    pids+=("$!")
    wait_until 5 grep -q '^#connect' "$d/$1.shell" 2>/dev/null
  }
  say() { timeout 5 bash -c 'printf "%s\n" "$2" >"$1"' _ "$d/$1.cmd" "$2"; }
  prompts() { grep -c '"type":"prompt"' "$d/$1.shell" 2>/dev/null; }
  last_prompt() { grep '"type":"prompt"' "$d/$1.shell" | tail -n 1 | python3 -I -c "import json,sys; m=json.loads(sys.stdin.read()); r=m['requester']; t=m['texts']; print($2)"; }
  # ask <tag> <disk> [env...]: the helper in the background, its output in $d/<tag>.out (stdout) and .err; pid in ask_pid.
  ask() {
    local tag=$1 disk=$2
    shift 2
    ( "${run_env[@]}" "$@" "$askpass" udiskie "$disk" >"$d/$tag.out" 2>"$d/$tag.err"; echo $? >"$d/$tag.rc" ) &
    ask_pid=$!
    pids+=("$ask_pid")
  }

  # --- 1 refusals ----------------------------------------------------------------------------------------------------
  "${run_env[@]}" "$askpass" >"$tmp/u1.out" 2>&1 </dev/null
  local r1=$?
  "${run_env[@]}" "$askpass" udiskie >"$tmp/u2.out" 2>&1 </dev/null
  local r2=$?
  "${run_env[@]}" "$askpass" other /dev/sdz1 >"$tmp/u3.out" 2>&1 </dev/null
  local r3=$?
  desc="wrong arguments: exit 2 (no disk, another mode)"
  check test "$r1/$r2/$r3" = 2/2/2
  desc="standard output a terminal: exit 2, refused before anything is asked"
  check python3 -I - "$askpass" "${run_env[@]:2}" <<'PY'
import os, pty, subprocess, sys
master, slave = pty.openpty()
env = dict(a.split("=", 1) for a in sys.argv[2:])
p = subprocess.run([sys.argv[1], "udiskie", "/dev/sdz1"], stdout=slave, stderr=subprocess.PIPE, env=env, timeout=10)
os.close(slave)
sys.exit(0 if p.returncode == 2 and b"terminal" in p.stderr else 1)
PY

  # --- 2, 3 through the bridge and the shell -------------------------------------------------------------------------
  "${run_env[@]}" GRASSFIELD_DEV=1 "$bridge" --socket "$sock" --peer-unit "$leaf" >"$d/bridge.log" 2>&1 &
  pids+=("$!")
  wait_until 5 test -S "$sock" || { echo "FAIL: the bridge listens"; return 1; }
  shell_up s "$sock"
  say s hello
  wait_until 5 grep -q '"state":"owned"' "$d/s.shell"
  local rlo n
  rlo=$(printf '\xe2\x80\xae')
  n=$(prompts s)
  ask a1 "/dev/sdz1
${rlo}gnp.exe"
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  local expected_role=unidentified expected_path
  expected_path=$(readlink -f "$askpass")
  if [[ $expected_path == /usr/lib/grassfield/grassfield-askpass && $(stat -c %u "$expected_path") == 0 ]]; then expected_role=disk; fi
  desc="the sheet gets a password prompt from the helper, its requester resolved by the bridge ($expected_role)"
  check test "$(last_prompt s '"|".join(str(x) for x in (m["kind"], r["role"], r["onBehalf"], r["path"]))')" \
    = "password|$expected_role|$([[ $expected_role == disk ]] && echo True || echo False)|$expected_path"
  desc="...with the helper's text: the disk's name flattened in a fixed sentence, Grassfield's title and button label"
  # shellcheck disable=SC1111 # the sentence's own typographic quotes
  check test "$(last_prompt s '"|".join((t["title"], t["message"], t["continue"], str(m["choice"])))')" \
    = "Encrypted Disk|Enter a password to unlock the disk “/dev/sdz1 gnp.exe”.|Unlock|None"
  local apid
  apid=$(pgrep -f -n "grassfield-askpass udiskie /dev/sdz1" || true)
  desc="...and while it waits the helper allows no core file"
  check bash -c '[[ -n $1 ]] && grep -Eq "^Max core file size +0 +0 " /proc/$1/limits' _ "$apid"
  say s "answer last ok luks pass 1"
  wait_until 10 test -s "$d/a1.rc"
  desc="the passphrase the shell answers is written once with a newline, nothing else, exit 0"
  check bash -c '[[ $(cat "$1") == 0 ]] && printf "luks pass 1\n" | cmp -s - "$2"' _ "$d/a1.rc" "$d/a1.out"
  desc="...and never to standard error"
  check bash -c '! grep -q "luks pass" "$1"' _ "$d/a1.err"
  # In a user unit, ProtectSystem=, ProtectHome= and PrivateTmp= make systemd set up a user namespace that maps the user
  # only (PrivateUsers=self), then a mount namespace (decision 9-26, amended); unshare makes the same two.
  local ns=(unshare --user --mount --map-user="$(id -u)" --map-group="$(id -g)" --)
  if [[ $expected_role == disk ]] && "${ns[@]}" true 2>/dev/null; then
    n=$(prompts s)
    ask a6 /dev/sdz6 "${ns[@]}"
    wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
    desc="the installed helper in a user and mount namespace of its own (udiskie's sandbox) is still \"disk\", on someone's behalf"
    check test "$(last_prompt s '"|".join(str(x) for x in (r["role"], r["onBehalf"], r["path"]))')" = "disk|True|$expected_path"
    say s "answer last cancel"
    wait_until 10 test -s "$d/a6.rc"
  elif [[ $expected_role == disk ]]; then
    echo "SKIP: askpass in namespaces of its own: no unprivileged user and mount namespace here"
  else
    echo "SKIP: askpass in namespaces of its own: a development build (only the installed helper is \"disk\")"
  fi

  # --- 4 cancel, the shell gone ----------------------------------------------------------------------------------------
  n=$(prompts s)
  ask a2 /dev/sdz2
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  say s "answer last cancel"
  wait_until 10 test -s "$d/a2.rc"
  desc="Cancel: exit 1, nothing written (udiskie leaves the disk locked)"
  check bash -c '[[ $(cat "$1") == 1 && ! -s $2 ]]' _ "$d/a2.rc" "$d/a2.out"
  n=$(prompts s)
  ask a3 /dev/sdz3
  wait_until 10 bash -c '[[ $(grep -c "\"type\":\"prompt\"" "$1") -gt $2 ]]' _ "$d/s.shell" "$n"
  say s close
  wait_until 10 test -s "$d/a3.rc"
  desc="the shell goes while the helper waits: exit 1, nothing written"
  check bash -c '[[ $(cat "$1") == 1 && ! -s $2 ]]' _ "$d/a3.rc" "$d/a3.out"

  # --- 5 French ---------------------------------------------------------------------------------------------------------
  if [[ -x /usr/lib/qt6/bin/lrelease ]]; then
    mkdir -p "$tmp/qm"
    /usr/lib/qt6/bin/lrelease -silent "$root/translations/grassfield_fr.ts" -qm "$tmp/qm/grassfield_fr.qm" >/dev/null 2>&1
    shell_up f "$sock"
    say f hello
    wait_until 5 grep -q '"state":"owned"' "$d/f.shell"
    ask a4 /dev/sdz4 GRASSFIELD_DEV=1 GRASSFIELD_TRANSLATIONS_DIR="$tmp/qm" GRASSFIELD_LANG=fr
    wait_until 10 grep -q '"type":"prompt"' "$d/f.shell"
    desc="French: the helper's text in French"
    check test "$(last_prompt f '"|".join((t["title"], t["message"], t["continue"]))')" \
      = "Disque chiffré|Saisissez un mot de passe pour déverrouiller le disque « /dev/sdz4 ».|Déverrouiller"
    say f "answer last cancel"
    wait_until 10 test -s "$d/a4.rc"
    say f close
  else
    echo "SKIP: askpass French: no lrelease"
  fi
  wait_until 5 bash -c '[[ -z $(dbus-send --bus="$1" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.gnome.keyring.SystemPrompter 2>/dev/null) ]]' _ "$bus"

  # --- 6 no bridge holds the name: the stock prompter's stand-in, activated ------------------------------------------------
  {
    printf '#!/bin/sh\n'
    printf 'export PATH=%q HOME=%q XDG_RUNTIME_DIR=%q DBUS_SESSION_BUS_ADDRESS=%q GF_TEST_BUS=1 GF_TEST_BUS_DIR=%q LC_ALL=C.UTF-8 GRASSFIELD_DEV=1\n' \
      "$PATH" "$d" "$d/run" "$bus" "$d"
    printf '%q --socket %q --peer-unit %q >%q 2>&1 &\n' "$bridge" "$d/run/grassfield/stock.sock" "$leaf" "$d/stock.log"
    printf 'i=0; while [ ! -S %q ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done\n' "$d/run/grassfield/stock.sock"
    printf 'exec python3 -I %q --socket %q --log %q --auto-answer stock-pass-5\n' "$shell_py" "$d/run/grassfield/stock.sock" "$d/stock.shell"
  } >"$d/stock-prompter.sh"
  chmod 700 "$d/stock-prompter.sh"
  printf '[D-BUS Service]\nName=org.gnome.keyring.SystemPrompter\nExec=%s\n' "$d/stock-prompter.sh" >"$d/services/org.gnome.keyring.SystemPrompter.service"
  dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1
  ask a5 /dev/sdz5
  wait_until 30 test -s "$d/a5.rc"
  desc="no bridge holds gcr's prompter name: D-Bus activation starts the stand-in and its passphrase is written, exit 0"
  check bash -c '[[ $(cat "$1") == 0 ]] && printf "stock-pass-5\n" | cmp -s - "$2"' _ "$d/a5.rc" "$d/a5.out"
  pkill -f "$d/run/grassfield/stock.sock" 2>/dev/null

  # --- 7 nothing secret in the journal ----------------------------------------------------------------------------------
  desc="no test passphrase in the bridge's output"
  check bash -c '! grep -q -e "luks pass" -e stock-pass "$1"' _ "$d/bridge.log"
  return $fail
}

tmpb=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/askpass-bin.XXXXXX")
trap 'cleanup; rm -rf "$tmpb"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bridge=${GRASSFIELD_PROMPTER:-}
askpass=${GRASSFIELD_ASKPASS:-}
if [[ -z $bridge || -z $askpass ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6Core gcr-4 2>/dev/null || { echo "SKIP: askpass needs g++, Qt 6 Core and gcr-4"; exit 0; }
  "$root/bridges/prompter/build-direct.sh" --out "$tmpb/bin" >"$tmpb/build.log" 2>&1 || { cat "$tmpb/build.log"; echo "FAIL: the bridge and the helper build"; exit 1; }
  bridge=${bridge:-$tmpb/bin/grassfield-prompter}
  askpass=${askpass:-$tmpb/bin/grassfield-askpass}
fi
scenario "$bridge" "$askpass"
rc=$?

if ((mutants)); then
  while IFS= read -r spec; do
    [[ -n $spec ]] || continue
    IFS='#' read -r -a f <<<"$spec"
    name=${f[0]}
    m=$tmpb/mut
    rm -rf "$m"
    mkdir -p "$m/bridges" "$m/apps" "$m/ui/i18n"
    cp -a "$root/bridges/prompter" "$m/bridges/"
    cp "$root/apps/runmode.h" "$root/apps/testbus.h" "$m/apps/"
    cp "$root/ui/i18n/translationloader.h" "$m/ui/i18n/"
    cp "$root/VERSION" "$m/"
    git -C "$m" init -q
    if ! python3 -I - "$m/bridges/prompter/src/${f[1]}" "${f[2]}" "${f[3]}" <<'PY'; then echo "MUTANT $name: NOT APPLIED"; rc=1; continue; fi
import sys
p, a, b = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
s = open(p).read()
if s.count(a) != 1:
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
PY
    "$m/bridges/prompter/build-direct.sh" --out "$m/bin" >"$m/build.log" 2>&1 || { echo "MUTANT $name: DOES NOT BUILD"; rc=1; continue; }
    if scenario "$bridge" "$m/bin/grassfield-askpass" >"$m/run.log" 2>&1; then echo "MUTANT $name: NOT CAUGHT"; rc=1; else echo "MUTANT $name: CAUGHT ($(grep -c '^FAIL' "$m/run.log") failing)"; fi
  done <<'EOF_MUTANTS'
writes-to-a-terminal#askpass.cpp#    if (::isatty(STDOUT_FILENO)) {#    if (false) {
cancel-exits-0#askpass.cpp#    int status = kCancelled;#    int status = kUnlocked;
no-newline#askpass.cpp#, 1))#, 0))
core-files-allowed#askpass.cpp#    ::setrlimit(RLIMIT_CORE, &noCore);#    ;
EOF_MUTANTS
fi
((rc == 0)) && echo "PASS: askpass" || echo "FAIL: askpass"
exit "$rc"
