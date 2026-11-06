#!/usr/bin/env bash
# The channel rule of ADR-0033 O15b (owner decision of 2026-11-04, the macOS model): an installed VERSION that is a prerelease
# (-betaN, -rcN), or missing, empty, unreadable or malformed, can only follow beta; a plain X.Y.Z can follow stable. Tested on
# copies of packaging/bin/grassfield-channel-set (the user's command) and packaging/pacman/grassfield-channel.sh (the root helper's
# library, whose gf_set is the real enforcement) with their paths pointed at a temporary tree; the privileged runner of the dev
# plumbing (ADR-0019) is a recording stand-in, so nothing here touches pacman, polkit or the system.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/channel-rule.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: got '$2', want '$3'"; }

T=$tmp/tree
mkdir -p "$T/usr/share/grassfield/pacman" "$T/etc/pacman.d" "$T/run" "$tmp/bin"
sed -e "s#^repository=.*#repository=$T/usr/share/grassfield/pacman/repository.conf#" \
  -e "s#^version_file=.*#version_file=$T/usr/share/grassfield/VERSION#" \
  -e "s#^pacman_conf=.*#pacman_conf=$T/etc/pacman.conf#" \
  -e "s#^include=.*#include=$T/etc/pacman.d/grassfield.conf#" "$root/packaging/bin/grassfield-channel-set" >"$tmp/channel-set"
chmod +x "$tmp/channel-set"
printf 'GRASSFIELD_REPO_BASE=https://packages.grassfield.site\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\nGRASSFIELD_SIGNING_FINGERPRINT=E4921A382C349308BAA50D2F44C31B5D862EBEFA\n' \
  >"$T/usr/share/grassfield/pacman/repository.conf"
cat >"$tmp/bin/recorder" <<'SH'
#!/bin/sh
echo "$*" >>"$CALLS"
SH
chmod +x "$tmp/bin/recorder"

run() { # args...: runs the copy as the user, in a dev session with the recording runner; sets rc and out
  : >"$tmp/calls"
  out=$(env -i PATH=/usr/bin:/bin HOME="$tmp/home" XDG_RUNTIME_DIR="$T/run" GRASSFIELD_DEV=1 GRASSFIELD_UPDATE_PKEXEC="$tmp/bin/recorder" \
    CALLS="$tmp/calls" "$tmp/channel-set" "$@" 2>&1)
  rc=$?
}
version() { # text, or - for no file
  if [[ $1 == - ]]; then rm -f "$T/usr/share/grassfield/VERSION"; else printf '%b' "$1" >"$T/usr/share/grassfield/VERSION"; fi
}
calls() { sed 's#^/usr/lib/grassfield/grassfield-channel-helper ##' "$tmp/calls" | tr '\n' '|'; }

echo "== stable is refused while the installed version is a prerelease, missing or malformed"
for v in '1.0.0-rc2\n' '1.1.0-beta3\n' '' '\n' 'unknown\n' '1.0\n' '1.0.0.1\n' '1.0.0-rc\n' '1.0.0\n1.0.0\n' '1.0.0-rc2'; do
  version "$v"
  run stable
  expect "stable refused for VERSION '$v': exit 1" "$rc" 1
  [[ $out == *"beta updates stay on while a beta version of Grassfield is installed"* ]] && pass "  and it says why" || fail "  no reason given: $out"
  expect "  and nothing was run" "$(calls)" ""
done
version -
run stable
expect "stable refused for a missing VERSION: exit 1" "$rc" 1
expect "  and nothing was run" "$(calls)" ""
mkdir "$T/usr/share/grassfield/VERSION"
run stable
expect "stable refused for an unreadable VERSION (a directory): exit 1" "$rc" 1
rmdir "$T/usr/share/grassfield/VERSION"

echo "== beta is always allowed; stable is allowed once a plain version is installed"
version '1.0.0-rc2\n'
run beta
expect "beta on a prerelease: exit 0" "$rc" 0
expect "  the helper was asked for set beta" "$(calls)" "set beta|"
version -
run beta
expect "beta with a missing VERSION: exit 0" "$rc" 0
for v in '1.0.0\n' '1.0.0' '  12.3.45 \n'; do
  version "$v"
  run stable
  expect "stable on VERSION '$v': exit 0" "$rc" 0
  expect "  the helper was asked for set stable" "$(calls)" "set stable|"
done

echo "== repair falls back to beta on a prerelease, stable on a plain version"
printf '[options]\n[grassfield]\nInclude = %s/etc/pacman.d/grassfield.conf\n' "$T" >"$T/etc/pacman.conf"
rm -f "$T/etc/pacman.d/grassfield.conf"
for pair in '1.0.0-rc2\n:beta' '-:beta' 'junk\n:beta' '1.0.0\n:stable'; do
  v=${pair%:*} want=${pair##*:}
  version "$v"
  run repair
  expect "repair, include file missing, VERSION '$v': exit 0" "$rc" 0
  expect "  falls back to $want" "$(calls)" "set $want|"
done
printf 'SigLevel = Required\nServer = https://elsewhere.example/x/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
for pair in '1.0.0-rc2\n:beta' '-:beta' '1.0.0\n:stable'; do
  v=${pair%:*} want=${pair##*:}
  version "$v"
  run repair
  expect "repair, custom file, VERSION '$v': falls back to $want" "$(calls)" "set $want|"
done
rm -f "$T/etc/pacman.d/grassfield.conf"
printf '[options]\n' >"$T/etc/pacman.conf"
version '1.0.0-rc2\n'
run repair
expect "repair when off: refused, and the hint names beta on a prerelease" "$rc:$([[ $out == *'grassfield-channel-set beta sets them up'* ]] && echo hint)" "1:hint"
version '1.0.0\n'
run repair
expect "repair when off: the hint names stable on a plain version" "$rc:$([[ $out == *'grassfield-channel-set stable sets them up'* ]] && echo hint)" "1:hint"

echo "== the staged rollout's cohort form reads as its channel (ADR-0050 2)"
printf '[options]\n[grassfield]\nInclude = %s/etc/pacman.d/grassfield.conf\n' "$T" >"$T/etc/pacman.conf"
for pair in 'stable/cohort/07:stable' 'beta/cohort/19:beta' 'stable/cohort/20:custom' 'beta/cohort/7:custom' 'stable:stable'; do
  printf 'SigLevel = Required\nServer = https://packages.grassfield.site/%s/$arch\nServer = https://packages.grassfield.site/stable/$arch\n' \
    "${pair%%:*}" >"$T/etc/pacman.d/grassfield.conf"
  run
  expect "primary .../${pair%%:*}/\$arch prints ${pair##*:}" "$out" "${pair##*:}"
done
printf 'SigLevel = Required\nServer = https://old.example/beta/cohort/04/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
version '1.0.0\n'
run repair
expect "repair of another host's beta cohort form keeps beta" "$(calls)" "set beta|"
rm -f "$T/etc/pacman.d/grassfield.conf"
printf '[options]\n' >"$T/etc/pacman.conf"

echo "== the root helper's library enforces the same rule (a direct call is not a way round it)"
sed "s#^GF_VERSION_FILE=.*#GF_VERSION_FILE=$T/usr/share/grassfield/VERSION#" "$root/packaging/pacman/grassfield-channel.sh" >"$tmp/channel.sh"
allowed() { (. "$tmp/channel.sh"; gf_stable_allowed) && echo yes || echo no; }
for pair in '1.0.0\n:yes' '1.0.0-rc2\n:no' '1.1.0-beta1\n:no' '\n:no' 'x\n:no' '1.0\n:no' '1.0.0\n1.0.0\n:no' '-:no'; do
  v=${pair%:*} want=${pair##*:}
  version "$v"
  expect "gf_stable_allowed for VERSION '$v'" "$(allowed)" "$want"
done
grep -A4 '^gf_set() {' "$root/packaging/pacman/grassfield-channel.sh" | grep -q 'gf_stable_allowed' \
  && pass "gf_set calls gf_stable_allowed before any change" || fail "gf_set does not check the rule"

((fails == 0)) && { echo "PASS: channel rule"; exit 0; }
echo "FAIL: channel rule ($fails)"
exit 1
