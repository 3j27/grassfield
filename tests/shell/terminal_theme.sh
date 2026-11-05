#!/usr/bin/env bash
# grassfield-terminal-theme (ADR-0045 OC-11), offline: the real helper (packaging/bin) against fake Omarchy commands, in a dev
# session with the test stand-ins for Omarchy's shell (dev plumbing GRASSFIELD_TERMINAL_THEME_SHIMS). Nothing of Omarchy runs:
# every run gets a PATH made only of this test's folders (a "sysbin" of links to the few system tools the fakes use, none of
# them an Omarchy command, sudo, pkexec or hyprctl), never /usr/bin, /bin or /usr/share/omarchy, and an OMARCHY_PATH of fakes;
# a preflight checks that before anything runs and stops the test otherwise.
#   settings   Match Appearance off runs nothing; on, the theme of the appearance asked for (the defaults, a chosen one; a name
#              the schema refuses, a slash in it, reads as the default)
#   current    the theme already Omarchy's (any spelling omarchy-theme-current gives it) runs nothing
#   env        omarchy-theme-set gets no HYPRLAND_INSTANCE_SIGNATURE, no DCONF_PROFILE, no SUDO_ASKPASS, the OMARCHY_PATH given;
#              its PATH starts with the run's private stand-ins (pkexec, hyprctl), then the omarchy-shims, then Omarchy's bin
#              directory (a caller's PATH that put Omarchy's bin first is put back in that order; empty and relative entries
#              are dropped): its `pkexec x` gets 127 and its `hyprctl reload` 1, the system's (fake) pkexec and hyprctl are never
#              reached, its omarchy-shell calls reach the stand-in, never Omarchy's; stdin is /dev/null and it leads a process
#              session of its own
#   stubs      the private folder is made afresh each run (0700, the user's); a link there, or a folder of another owner
#              (checked when this runs as root), runs nothing, exit 1
#   hostile    an "installed" Omarchy (omarchy-theme-set, omarchy-theme-current, sudo, pkexec, hyprctl that record any call) first
#              in the caller's PATH: the fakes of OMARCHY_PATH still win and nothing installed is reached; a dev run without
#              OMARCHY_PATH, with /usr/share/omarchy, with a tree whose commands are missing (found in the installed one) or
#              links to the installed ones is refused before any command runs
#   limit      past the run limit (dev hook GRASSFIELD_TERMINAL_THEME_RUN_LIMIT) the whole process group is stopped, a child
#              that ignores SIGTERM included, and the next run is not kept waiting by the lock
#   failure    omarchy-theme-set's exit and its last line are reported, exit 1
#   missing    no Omarchy commands: nothing runs, exit 0; no stand-ins: nothing runs, exit 1
#   guard      a dev session without the stand-in variable, and a real session (GRASSFIELD_SESSION=1) that sets it, run nothing
#   lock       a run waits for the lock another run holds
#   usage      no mode, or another word: exit 2
# Run as root (a container), the helper itself refuses (checked), and the other cases run as nobody (setpriv drops the
# privileges; SKIP without setpriv). Prints "ok"/"FAIL" lines; exits 1 on any failure.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
helper=$root/packaging/bin/grassfield-terminal-theme
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/terminal-theme.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: got '$2', want '$3'"; }

# The system tools the fakes and the lock holder use, as links in a folder of this test (resolved by this shell, once).
mkdir -p "$tmp/sysbin"
for tool in sh cat cut wc sleep mkdir flock; do
  where=$(command -v "$tool") || { echo "FATAL: terminal theme: $tool not found"; exit 1; }
  ln -s "$where" "$tmp/sysbin/$tool"
done
# The PATH of every run: the fake Omarchy bin first (the helper must put it back after the stand-ins), an empty and a relative
# entry (dropped), the system tools, the system's pkexec and hyprctl stand-ins.
test_path="$tmp/omarchy/bin::.:$tmp/sysbin:$tmp/fake"

as_user=()
if ((EUID == 0)); then
  out=$(env -i PATH="$tmp/sysbin" HOME="$tmp" "$helper" dark 2>&1)
  rc=$?
  expect "as root the helper refuses: exit 1" "$rc" 1
  [[ $out == "refused: run it as the desktop user, not as root" ]] && pass "  and says why" || fail "  root: $out"
  setpriv=$(command -v setpriv) || { echo "SKIP: terminal theme (running as root without setpriv)"; exit $((fails > 0)); }
  as_user=("$setpriv" --reuid=65534 --regid=65534 --clear-groups --)
fi

# The fake tree: Omarchy's bin directory (the theme commands, and an omarchy-shell that must never be reached), the test
# stand-ins, the system's pkexec and hyprctl (recorders), an "installed" Omarchy for the hostile cases (recorders), the
# settings and the runtime folder.
mkdir -p "$tmp/omarchy/bin" "$tmp/shims" "$tmp/nostand" "$tmp/fake" "$tmp/installed/bin" "$tmp/linked/bin" "$tmp/bare" \
  "$tmp/cfg" "$tmp/run" "$tmp/home" "$tmp/t"
cat >"$tmp/omarchy/bin/omarchy-theme-set" <<'SH'
#!/bin/bash
{
  echo "args=$*"
  echo "his=${HYPRLAND_INSTANCE_SIGNATURE-unset}"
  echo "dconf=${DCONF_PROFILE-unset}"
  echo "path=$PATH"
  echo "omarchy=${OMARCHY_PATH-unset}"
  echo "askpass=${SUDO_ASKPASS-unset}"
  echo "shell=$(command -v omarchy-shell)"
  echo "pkexec=$(command -v pkexec)"
  echo "hyprctl=$(command -v hyprctl)"
  if [[ -t 0 ]]; then echo "stdin=tty"; else echo "stdin=$(wc -c)"; fi
  [[ $(cut -d' ' -f6 /proc/$$/stat) == "$$" ]] && echo "leader=yes" || echo "leader=no"
} >>"$LOG"
omarchy-shell shell applyTheme x >/dev/null 2>&1 || true
# As omarchy-theme-set-browser-policy and omarchy-restart-hyprctl call them.
pkexec x 2>/dev/null
echo "pkexec-rc=$?" >>"$LOG"
hyprctl reload >/dev/null 2>&1
echo "hyprctl-rc=$?" >>"$LOG"
# A run that never ends: a background child that ignores SIGTERM, and the script ignoring it too.
if [[ -n ${SLOW:-} ]]; then
  sh -c 'trap "" TERM; echo $$ >"$CHILD"; while :; do sleep 1; done' &
  trap '' TERM
  while :; do sleep 1; done
fi
if [[ -n ${FAIL_WITH:-} ]]; then
  echo "Theme '$1' does not exist"
  exit "$FAIL_WITH"
fi
echo "some output"
printf '%s\n' "$1" >"$STATE"
SH
cat >"$tmp/omarchy/bin/omarchy-theme-current" <<'SH'
#!/bin/sh
cat "$STATE" 2>/dev/null || echo Unknown
SH
cat >"$tmp/omarchy/bin/omarchy-shell" <<'SH'
#!/bin/sh
echo "omarchy-shell $*" >>"$LOG"
SH
cat >"$tmp/shims/omarchy-shell" <<'SH'
#!/bin/sh
echo "stand-in $*" >>"$LOG"
exit 1
SH
printf '#!/bin/sh\nexit 0\n' >"$tmp/shims/omarchy-restart-shell"
# The system's pkexec and hyprctl, as found later in PATH: they must never be reached.
cat >"$tmp/fake/hyprctl" <<'SH'
#!/bin/sh
echo "real hyprctl $* his=${HYPRLAND_INSTANCE_SIGNATURE-unset}" >>"$LOG"
SH
cat >"$tmp/fake/pkexec" <<'SH'
#!/bin/sh
echo "real pkexec $*" >>"$LOG"
SH
# An installed Omarchy and its privileged tools, for the hostile cases: any call is recorded and does nothing else.
for name in omarchy-theme-set omarchy-theme-current sudo pkexec hyprctl omarchy-shell omarchy-restart-shell; do
  printf '#!/bin/sh\necho "REAL(system) %s $*" >>"$LOG"\n' "$name" >"$tmp/installed/bin/$name"
done
ln -s "$tmp/installed/bin/omarchy-theme-set" "$tmp/linked/bin/omarchy-theme-set"
ln -s "$tmp/installed/bin/omarchy-theme-current" "$tmp/linked/bin/omarchy-theme-current"
# The trees of fakes carry the helper's mark (grassfield-fake-omarchy); a checkout of Omarchy (omarchy-dev-link's) has none.
for tree in "$tmp/omarchy" "$tmp/bare" "$tmp/linked"; do : >"$tree/grassfield-fake-omarchy"; done
mkdir -p "$tmp/checkout/bin"
for name in omarchy-theme-set omarchy-theme-current; do
  printf '#!/bin/sh\necho "REAL(checkout) %s $*" >>"$LOG"\n' "$name" >"$tmp/checkout/bin/$name"
done
chmod +x "$tmp"/checkout/bin/*
chmod +x "$tmp"/omarchy/bin/* "$tmp"/shims/* "$tmp"/fake/* "$tmp"/installed/bin/*
chmod 700 "$tmp/run"
((EUID == 0)) && chown -R -h 65534:65534 "$tmp"
chmod 755 "$tmp"

# Preflight: nothing outside this test is reachable from the PATH every run gets. Every entry is a folder of this test, no
# name there is sudo, pkexec, hyprctl or an Omarchy command that resolves outside this test, and sudo is not there at all.
preflight() {
  local dir name target
  IFS=: read -r -a dirs <<<"$test_path"
  for dir in "${dirs[@]}"; do
    [[ -z $dir || $dir == . ]] && continue
    [[ $dir == "$tmp"/* ]] || { echo "FATAL: terminal theme: PATH entry $dir is outside the test"; exit 1; }
    for name in omarchy-theme-set omarchy-theme-current omarchy-shell omarchy-restart-shell sudo pkexec hyprctl; do
      [[ -e $dir/$name ]] || continue
      target=$(readlink -f "$dir/$name")
      [[ $target == "$tmp"/* && $name != sudo ]] || { echo "FATAL: terminal theme: $dir/$name reaches $target"; exit 1; }
    done
  done
  for name in sudo omarchy-theme-set omarchy-theme-current; do
    target=$(PATH="$test_path" command -v "$name")
    [[ -z $target || $(readlink -f "$target") == "$tmp"/* ]] || { echo "FATAL: terminal theme: $name is $target"; exit 1; }
  done
  [[ -z $(PATH="$test_path" command -v sudo) ]] || { echo "FATAL: terminal theme: sudo is reachable"; exit 1; }
  pass "preflight: every run's PATH holds only this test's folders; no sudo, no Omarchy command from outside the test"
}
preflight

# A file written here and read or written by the helper's user (nobody when this runs as root).
put() {
  printf '%s\n' "$2" >"$1"
  ((EUID == 0)) && chown 65534:65534 "$1"
  return 0
}
settings() { put "$tmp/cfg/grassfield.json" "$1"; }
run() { # mode [VAR=value...]: the helper in a dev session with the stand-ins and the test's PATH; sets rc and out
  local mode=$1
  shift
  put "$tmp/log" ""
  out=$(env -i PATH="$test_path" HOME="$tmp/home" TMPDIR="$tmp/t" XDG_RUNTIME_DIR="$tmp/run" \
    GRASSFIELD_CONFIG_HOME="$tmp/cfg" OMARCHY_PATH="$tmp/omarchy" HYPRLAND_INSTANCE_SIGNATURE=grassfield-instance \
    DCONF_PROFILE=/usr/share/grassfield/dconf/profile SUDO_ASKPASS=/usr/bin/true GRASSFIELD_DEV=1 \
    GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/shims" LOG="$tmp/log" STATE="$tmp/state" "$@" "${as_user[@]}" "$helper" "$mode" 2>&1 </dev/null)
  rc=$?
}
called() { grep -c '^args=' "$tmp/log"; }
field() { sed -n "s/^$1=//p" "$tmp/log" | head -n 1; }
nothing_real() { ! grep -q 'REAL(' "$tmp/log"; }

echo "== settings"
rm -f "$tmp/state"
settings '{"version": 1}'
run dark
expect "Match Appearance off (the default): exit 0" "$rc" 0
expect "  says so" "$out" "skipped: Match Appearance is off"
expect "  and runs nothing" "$(called)" 0
settings '{"version": 1, "terminal": {"matchAppearance": "true"}}'
run dark
expect "a matchAppearance that is not a boolean reads as off" "$(called)" 0
settings '{"version": 1, "terminal": {"matchAppearance": true}}'
run dark
expect "on, dark: exit 0" "$rc" 0
expect "  the dark default is applied" "$(field args)" "Tokyo Night"
expect "  and said" "$out" "applied Tokyo Night (dark)"
run light
expect "on, light: the light default" "$(field args)" "Catppuccin Latte"
settings '{"version": 1, "terminal": {"matchAppearance": true, "lightTheme": "Rose Pine", "darkTheme": "Nord"}}'
run light
expect "a chosen light theme" "$(field args)" "Rose Pine"
run dark
expect "a chosen dark theme" "$(field args)" "Nord"
settings '{"version": 1, "terminal": {"matchAppearance": true, "lightTheme": "../../etc", "darkTheme": "Nord\n"}}'
run light
expect "a name with a slash reads as the default" "$(field args)" "Catppuccin Latte"
run dark
expect "a name with a line break reads as the default" "$(field args)" "Tokyo Night"
settings 'not json'
run dark
expect "malformed grassfield.json: every key at its default (off)" "$(called)" 0

echo "== current"
settings '{"version": 1, "terminal": {"matchAppearance": true}}'
put "$tmp/state" "tokyo-night"
run dark
expect "already Omarchy's theme: exit 0" "$rc" 0
expect "  runs nothing" "$(called)" 0
expect "  and says so" "$out" "skipped: Tokyo Night is already Omarchy's theme"
put "$tmp/state" "Tokyo Night"
run dark
expect "  whatever the spelling omarchy-theme-current gives" "$(called)" 0
run light
expect "another theme current: it runs" "$(field args)" "Catppuccin Latte"
expect "  and the state is the new theme" "$(cat "$tmp/state")" "Catppuccin Latte"

echo "== env"
rm -f "$tmp/state"
run dark
expect "no HYPRLAND_INSTANCE_SIGNATURE" "$(field his)" "unset"
expect "no DCONF_PROFILE" "$(field dconf)" "unset"
expect "no SUDO_ASKPASS" "$(field askpass)" "unset"
stubs=$tmp/run/grassfield/terminal-theme-bin
expect "PATH: the run's stand-ins, the omarchy-shims, Omarchy's bin, then the rest (absolute entries only)" "$(field path)" \
  "$stubs:$tmp/shims:$tmp/omarchy/bin:$tmp/sysbin:$tmp/fake"
expect "pkexec resolves to the run's stand-in" "$(field pkexec)" "$stubs/pkexec"
expect "hyprctl resolves to the run's stand-in" "$(field hyprctl)" "$stubs/hyprctl"
expect "  'pkexec x' fails as if pkexec were absent" "$(field pkexec-rc)" "127"
expect "  'hyprctl reload' fails" "$(field hyprctl-rc)" "1"
grep -q '^real pkexec' "$tmp/log" && fail "the system's pkexec was reached" || pass "the system's pkexec was never reached"
grep -q '^real hyprctl' "$tmp/log" && fail "the system's hyprctl was reached" || pass "the system's hyprctl was never reached"
expect "the stand-in folder is the user's alone (0700)" "$(stat -c '%a %u' "$stubs")" "700 $(((EUID == 0)) && echo 65534 || id -u)"
expect "omarchy-shell resolves to the omarchy-shims stand-in" "$(field shell)" "$tmp/shims/omarchy-shell"
grep -q '^stand-in shell applyTheme x' "$tmp/log" && pass "its shell call reached the stand-in" || fail "the stand-in was not called: $(cat "$tmp/log")"
grep -q '^omarchy-shell ' "$tmp/log" && fail "Omarchy's own omarchy-shell was reached" || pass "Omarchy's own omarchy-shell was never reached"
expect "stdin is /dev/null" "$(field stdin)" "0"
expect "omarchy-theme-set leads a session of its own" "$(field leader)" "yes"
expect "OMARCHY_PATH passed on" "$(field omarchy)" "$tmp/omarchy"

echo "== stubs"
rm -f "$tmp/state"
put "$stubs/sudo" "#!/bin/sh"
run dark
expect "the folder is made afresh: a file left there is gone" "$(ls "$stubs" | tr '\n' ' ')" "hyprctl pkexec "
rm -rf "$stubs"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$stubs"
((EUID == 0)) && chown -h 65534:65534 "$stubs" "$tmp/elsewhere"
rm -f "$tmp/state"
run dark
expect "a link in its place: exit 1" "$rc" 1
expect "  says so" "$out" "refused: $stubs is not a private folder of this user (a link, or another owner)"
expect "  runs nothing" "$(called)" 0
expect "  and writes nothing where it points" "$(ls -A "$tmp/elsewhere" | wc -l)" "0"
rm -f "$stubs"
if ((EUID == 0)); then
  mkdir "$stubs"
  run dark
  expect "a folder of another owner in its place: exit 1" "$rc" 1
  expect "  says so" "$out" "refused: $stubs is not a private folder of this user (a link, or another owner)"
  expect "  runs nothing" "$(called)" 0
  rm -rf "$stubs"
else
  echo "  SKIP a folder of another owner (making one needs root)"
fi

echo "== hostile"
hostile="$tmp/installed/bin:$test_path"
rm -f "$tmp/state"
run dark PATH="$hostile"
expect "an installed Omarchy first in PATH: the fakes of OMARCHY_PATH still run (exit 0)" "$rc" 0
expect "  the fake was applied" "$(field args)" "Tokyo Night"
nothing_real && pass "  and nothing installed was reached" || fail "  something installed was reached: $(grep REAL "$tmp/log")"
refused_dev="refused: a dev session needs OMARCHY_PATH set to a tree of fakes (marked grassfield-fake-omarchy), never the installed Omarchy"
for case in "OMARCHY_PATH=" "OMARCHY_PATH=/usr/share/omarchy" "OMARCHY_PATH=/usr/share/omarchy/" "OMARCHY_PATH=relative/omarchy"; do
  rm -f "$tmp/state"
  run dark PATH="$hostile" "$case"
  expect "a dev run with $case: exit 1" "$rc" 1
  expect "  says so" "$out" "$refused_dev"
  expect "  runs nothing" "$(called)" 0
  nothing_real && pass "  and nothing installed was reached" || fail "  something installed was reached: $(grep REAL "$tmp/log")"
done
refused_where="refused: in a dev session omarchy-theme-set and omarchy-theme-current must be the fakes of OMARCHY_PATH/bin"
for tree in "$tmp/bare" "$tmp/linked"; do
  rm -f "$tmp/state"
  run dark PATH="$hostile" OMARCHY_PATH="$tree"
  expect "a dev run whose OMARCHY_PATH (${tree##*/}) has $([[ $tree == */bare ]] && echo "no commands" || echo "links to installed ones"): exit 1" "$rc" 1
  expect "  says so" "$out" "$refused_where"
  nothing_real && pass "  and nothing installed was reached" || fail "  something installed was reached: $(grep REAL "$tmp/log")"
done
# Counter-review of ADR-0045, LOW-3: an Omarchy checkout named by OMARCHY_PATH (no mark), and the stand-ins variable pointed at
# a folder of real commands (it holds omarchy-shell and omarchy-restart-shell), are refused before anything runs.
rm -f "$tmp/state"
run dark PATH="$hostile" OMARCHY_PATH="$tmp/checkout"
expect "a dev run whose OMARCHY_PATH is an unmarked checkout: exit 1" "$rc" 1
expect "  says so" "$out" "$refused_dev"
nothing_real && pass "  and nothing of it was reached" || fail "  something real was reached: $(grep REAL "$tmp/log")"
rm -f "$tmp/state"
run dark PATH="$hostile" GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/installed/bin"
expect "a dev run whose stand-ins are a folder of real commands: exit 1" "$rc" 1
expect "  says so" "$out" "$refused_where"
nothing_real && pass "  and nothing installed was reached" || fail "  something installed was reached: $(grep REAL "$tmp/log")"

echo "== limit"
rm -f "$tmp/state" "$tmp/child"
put "$tmp/child" ""
start=$SECONDS
run dark SLOW=1 CHILD="$tmp/child" GRASSFIELD_TERMINAL_THEME_RUN_LIMIT=1
took=$((SECONDS - start))
expect "a run past the limit: exit 1" "$rc" 1
expect "  says so" "$out" "failed: omarchy-theme-set did not finish within 1 seconds (omarchy-theme-set exit 124)"
child=$(cat "$tmp/child")
[[ -n $child ]] && pass "  its child started ($child)" || fail "  its child did not start"
[[ -n $child ]] && ! kill -0 "$child" 2>/dev/null && pass "  and the child that ignores SIGTERM is gone (SIGKILL to the group)" \
  || fail "  the child $child is still running"
((took <= 15)) && pass "  within the limit and the grace ($took s)" || fail "  it took $took s"
rm -f "$tmp/state"
start=$SECONDS
run dark
expect "  the next run is not kept waiting: exit 0" "$rc" 0
(((SECONDS - start) <= 5)) && pass "  and it started at once" || fail "  it waited $((SECONDS - start)) s"

echo "== failure"
rm -f "$tmp/state"
run dark FAIL_WITH=3
expect "omarchy-theme-set fails: exit 1" "$rc" 1
expect "  its last line and exit are reported" "$out" "failed: Theme 'Tokyo Night' does not exist (omarchy-theme-set exit 3)"

echo "== missing"
mv "$tmp/omarchy/bin/omarchy-theme-current" "$tmp/omarchy/current.off"
run dark
expect "no omarchy-theme-current: exit 0" "$rc" 0
expect "  says so" "$out" "skipped: Omarchy's theme commands are not installed"
expect "  runs nothing" "$(called)" 0
mv "$tmp/omarchy/current.off" "$tmp/omarchy/bin/omarchy-theme-current"
run dark GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/nostand"
expect "no stand-ins: exit 1" "$rc" 1
expect "  says so" "$out" "refused: Grassfield's stand-ins for Omarchy's shell are not installed in $tmp/nostand"
expect "  runs nothing" "$(called)" 0

echo "== guard"
run dark GRASSFIELD_TERMINAL_THEME_SHIMS=
expect "a dev session without the stand-in variable: exit 1" "$rc" 1
expect "  runs nothing" "$(called)" 0
run dark GRASSFIELD_SESSION=1
expect "a real session that sets the stand-in variable: exit 1" "$rc" 1
expect "  says so" "$out" "refused: GRASSFIELD_TERMINAL_THEME_SHIMS is test plumbing, honoured only in a dev session"
expect "  runs nothing" "$(called)" 0

echo "== lock"
rm -f "$tmp/state"
put "$tmp/log" ""
env -i PATH="$tmp/sysbin" "${as_user[@]}" sh -c "mkdir -p '$tmp/run/grassfield'; flock '$tmp/run/grassfield/terminal-theme.lock' sh -c 'sleep 2; echo released >>\"$tmp/log\"'" &
holder=$!
sleep 0.5
out=$(env -i PATH="$test_path" HOME="$tmp/home" TMPDIR="$tmp/t" XDG_RUNTIME_DIR="$tmp/run" GRASSFIELD_CONFIG_HOME="$tmp/cfg" \
  OMARCHY_PATH="$tmp/omarchy" GRASSFIELD_DEV=1 GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/shims" LOG="$tmp/log" STATE="$tmp/state" \
  "${as_user[@]}" "$helper" dark 2>&1 </dev/null)
rc=$?
wait "$holder"
expect "a run waits for the lock: exit 0" "$rc" 0
expect "  and starts after the other run released it" "$(grep -E '^(released|args=)' "$tmp/log" | tr '\n' '|')" "released|args=Tokyo Night|"

echo "== usage"
for args in "" "auto" "dark extra"; do
  # shellcheck disable=SC2086
  env -i PATH="$tmp/sysbin" "${as_user[@]}" "$helper" $args >/dev/null 2>&1
  expect "usage '$args': exit 2" "$?" 2
done

if ((fails > 0)); then
  echo "terminal theme: $fails failure(s)"
  exit 1
fi
echo "terminal theme: PASS"
