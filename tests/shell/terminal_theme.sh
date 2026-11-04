#!/usr/bin/env bash
# grassfield-terminal-theme (ADR-0045 OC-11), offline: the real helper (packaging/bin) against fake Omarchy commands, in a dev
# session with the test stand-ins for Omarchy's shell (dev plumbing GRASSFIELD_TERMINAL_THEME_SHIMS). Nothing of Omarchy runs.
#   settings   Match Appearance off runs nothing; on, the theme of the appearance asked for (the defaults, a chosen one; a name
#              the schema refuses, a slash in it, reads as the default)
#   current    the theme already Omarchy's (any spelling omarchy-theme-current gives it) runs nothing
#   env        omarchy-theme-set gets no HYPRLAND_INSTANCE_SIGNATURE (its `hyprctl reload` reaches nothing), no
#              DCONF_PROFILE, an OMARCHY_PATH (the packaged tree when unset), the stand-ins first in PATH then Omarchy's bin
#              directory (a caller's PATH that put Omarchy's bin first is put back in that order; empty and relative entries
#              are dropped), so its omarchy-shell calls reach the stand-in, never Omarchy's; stdin is /dev/null and it leads a
#              process session of its own
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

as_user=()
if ((EUID == 0)); then
  out=$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$helper" dark 2>&1)
  rc=$?
  expect "as root the helper refuses: exit 1" "$rc" 1
  [[ $out == "refused: run it as the desktop user, not as root" ]] && pass "  and says why" || fail "  root: $out"
  if ! command -v setpriv >/dev/null; then
    echo "SKIP: terminal theme (running as root without setpriv)"
    exit $((fails > 0))
  fi
  as_user=(setpriv --reuid=65534 --regid=65534 --clear-groups --)
fi

# The fake tree: Omarchy's bin directory (the theme commands, and an omarchy-shell that must never be reached), the test
# stand-ins, a hyprctl that records what it was given, the settings and the runtime folder.
mkdir -p "$tmp/omarchy/bin" "$tmp/shims" "$tmp/nostand" "$tmp/fake" "$tmp/cfg" "$tmp/run" "$tmp/home" "$tmp/t"
cat >"$tmp/omarchy/bin/omarchy-theme-set" <<'SH'
#!/bin/bash
{
  echo "args=$*"
  echo "his=${HYPRLAND_INSTANCE_SIGNATURE-unset}"
  echo "dconf=${DCONF_PROFILE-unset}"
  echo "path=$PATH"
  echo "omarchy=${OMARCHY_PATH-unset}"
  echo "shell=$(command -v omarchy-shell)"
  if [[ -t 0 ]]; then echo "stdin=tty"; else echo "stdin=$(wc -c)"; fi
  [[ $(cut -d' ' -f6 /proc/$$/stat) == "$$" ]] && echo "leader=yes" || echo "leader=no"
} >>"$LOG"
omarchy-shell shell applyTheme x >/dev/null 2>&1 || true
hyprctl reload >/dev/null 2>&1 || true
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
cat >"$tmp/fake/hyprctl" <<'SH'
#!/bin/sh
echo "hyprctl $* his=${HYPRLAND_INSTANCE_SIGNATURE-unset}" >>"$LOG"
[ -n "${HYPRLAND_INSTANCE_SIGNATURE-}" ] || exit 1
SH
chmod +x "$tmp"/omarchy/bin/* "$tmp"/shims/* "$tmp"/fake/*
chmod 700 "$tmp/run"
((EUID == 0)) && chown -R 65534:65534 "$tmp"
chmod 755 "$tmp"

# A file written here and read or written by the helper's user (nobody when this runs as root).
put() {
  printf '%s\n' "$2" >"$1"
  ((EUID == 0)) && chown 65534:65534 "$1"
  return 0
}
settings() { put "$tmp/cfg/grassfield.json" "$1"; }
run() { # mode [VAR=value...]: the helper in a dev session with the stand-ins; sets rc and out
  local mode=$1
  shift
  put "$tmp/log" ""
  out=$(env -i PATH="$tmp/omarchy/bin::.:/usr/bin:/bin:$tmp/fake" HOME="$tmp/home" TMPDIR="$tmp/t" XDG_RUNTIME_DIR="$tmp/run" \
    GRASSFIELD_CONFIG_HOME="$tmp/cfg" OMARCHY_PATH="$tmp/omarchy" HYPRLAND_INSTANCE_SIGNATURE=grassfield-instance \
    DCONF_PROFILE=/usr/share/grassfield/dconf/profile GRASSFIELD_DEV=1 GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/shims" \
    LOG="$tmp/log" STATE="$tmp/state" "$@" "${as_user[@]}" "$helper" "$mode" 2>&1 </dev/null)
  rc=$?
}
called() { grep -c '^args=' "$tmp/log"; }
field() { sed -n "s/^$1=//p" "$tmp/log" | head -n 1; }

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
expect "PATH: the stand-ins, Omarchy's bin, then the rest (absolute entries only)" "$(field path)" "$tmp/shims:$tmp/omarchy/bin:/usr/bin:/bin:$tmp/fake"
expect "omarchy-shell resolves to the stand-in" "$(field shell)" "$tmp/shims/omarchy-shell"
grep -q '^stand-in shell applyTheme x' "$tmp/log" && pass "its shell call reached the stand-in" || fail "the stand-in was not called: $(cat "$tmp/log")"
grep -q '^omarchy-shell ' "$tmp/log" && fail "Omarchy's own omarchy-shell was reached" || pass "Omarchy's own omarchy-shell was never reached"
expect "hyprctl reload saw no instance" "$(sed -n 's/^hyprctl reload //p' "$tmp/log")" "his=unset"
expect "stdin is /dev/null" "$(field stdin)" "0"
expect "omarchy-theme-set leads a session of its own" "$(field leader)" "yes"
expect "OMARCHY_PATH passed on" "$(field omarchy)" "$tmp/omarchy"
rm -f "$tmp/state"
run dark OMARCHY_PATH=
expect "no OMARCHY_PATH: Omarchy's packaged tree, as omarchy.lua finds it" "$(field omarchy)" "/usr/share/omarchy"

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
expect "a real session ignores the stand-in variable (its own stand-ins are not installed here): exit 1" "$rc" 1
expect "  says where it looked" "$out" "refused: Grassfield's stand-ins for Omarchy's shell are not installed in /usr/lib/grassfield/omarchy-shims"
expect "  runs nothing" "$(called)" 0

echo "== lock"
rm -f "$tmp/state"
put "$tmp/log" ""
env -i PATH=/usr/bin:/bin "${as_user[@]}" sh -c "mkdir -p '$tmp/run/grassfield'; flock '$tmp/run/grassfield/terminal-theme.lock' sh -c 'sleep 2; echo released >>\"$tmp/log\"'" &
holder=$!
sleep 0.5
out=$(env -i PATH="$tmp/omarchy/bin:/usr/bin:/bin" HOME="$tmp/home" TMPDIR="$tmp/t" XDG_RUNTIME_DIR="$tmp/run" GRASSFIELD_CONFIG_HOME="$tmp/cfg" \
  OMARCHY_PATH="$tmp/omarchy" GRASSFIELD_DEV=1 GRASSFIELD_TERMINAL_THEME_SHIMS="$tmp/shims" LOG="$tmp/log" STATE="$tmp/state" \
  "${as_user[@]}" "$helper" dark 2>&1 </dev/null)
rc=$?
wait "$holder"
expect "a run waits for the lock: exit 0" "$rc" 0
expect "  and starts after the other run released it" "$(grep -E '^(released|args=)' "$tmp/log" | tr '\n' '|')" "released|args=Tokyo Night|"

echo "== usage"
for args in "" "auto" "dark extra"; do
  # shellcheck disable=SC2086
  env -i PATH=/usr/bin:/bin "${as_user[@]}" "$helper" $args >/dev/null 2>&1
  expect "usage '$args': exit 2" "$?" 2
done

if ((fails > 0)); then
  echo "terminal theme: $fails failure(s)"
  exit 1
fi
echo "terminal theme: PASS"
