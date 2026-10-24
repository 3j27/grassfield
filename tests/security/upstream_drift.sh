#!/usr/bin/env bash
# GF-AUDIT-001 GF-031: scripts/dev/upstream-drift.sh (part of `just check`) reports when the installed Omarchy changed a
# file the security forks derive from (docs/upstream/omarchy.lock). Fixture trees only (a fake Omarchy, a fake derived
# tree, a fake lock), plus the real lock against the real installed Omarchy when it is there:
#   ok        unchanged files -> exit 0, one "ok:" line per pinned file
#   drift     an upstream file edited -> exit 1, names the file and the derived forks; a removed one -> exit 1
#   skip      no Omarchy -> SKIP, exit 0; --require -> exit 1
#   update    --update re-pins the hashes and the package line, keeps the comments; the check passes again
#   lock      a malformed line, an absolute or ".." path, an empty lock -> exit 2
#   forks     a derived file that is gone, or that no longer names its upstream file, fails; a file whose header says
#             "adapted from Omarchy" but is not pinned fails (also without Omarchy installed)
#   real      the repository's lock: attribution ok; against /usr/share/omarchy (when installed) every pinned file matches
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/scripts/dev/upstream-drift.sh
fail=0
pass() { echo "PASS: upstream drift $*"; }
bad() { echo "FAIL: upstream drift $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/upstream-drift.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

up=$tmp/omarchy
tree=$tmp/tree
mkdir -p "$up/shell/plugins/lock" "$up/bin" "$tree/shell/security/lock" "$tree/shell/security/idle" "$tree/packaging/shims"
printf 'upstream lock v1\n' >"$up/shell/plugins/lock/Service.qml"
printf '#!/bin/sh\necho sleep-lock v1\n' >"$up/bin/omarchy-system-sleep-lock"
printf '// Portions adapted from Omarchy shell/plugins/lock/Service.qml (MIT)\n' >"$tree/shell/security/lock/Lock.qml"
printf '// port of omarchy-system-sleep-lock derive_budget_ms\n' >"$tree/shell/security/idle/IdleModel.js"
printf '# answers omarchy-system-sleep-lock\n' >"$tree/packaging/shims/omarchy-shell"
lock=$tmp/omarchy.lock
write_lock() {
  {
    echo "# fixture lock"
    echo "# omarchy-package 1.0.0-1"
    echo
    echo "$(sha256sum "$up/shell/plugins/lock/Service.qml" | cut -d' ' -f1) shell/plugins/lock/Service.qml shell/security/lock/Lock.qml"
    echo "$(sha256sum "$up/bin/omarchy-system-sleep-lock" | cut -d' ' -f1) bin/omarchy-system-sleep-lock shell/security/idle/IdleModel.js,packaging/shims/omarchy-shell"
  } >"$lock"
}
write_lock
# run [args...] -> sets out and rc (fixture trees, through the script's test options).
run() {
  rc=0
  out=$(bash "$script" --omarchy "${FIX_OMARCHY:-$up}" --lock "$lock" --root "$tree" --package 9.9.9-1 "$@" 2>&1) || rc=$?
}

run
[[ $rc == 0 && $(grep -c '^ok:' <<<"$out") == 2 ]] && pass "ok: unchanged upstream files pass (2 ok lines)" || bad "ok: rc=$rc: $out"

printf 'upstream lock v2: a fix\n' >"$up/shell/plugins/lock/Service.qml"
run
[[ $rc == 1 && $out == *"shell/plugins/lock/Service.qml changed upstream"*"shell/security/lock/Lock.qml"* ]] \
  && pass "drift: an edited upstream file fails and names the fork" || bad "drift: edited file rc=$rc: $out"

run --update
[[ $rc == 0 ]] && grep -q '^# omarchy-package 9.9.9-1$' "$lock" && grep -q '^# fixture lock$' "$lock" \
  && grep -q "^$(sha256sum "$up/shell/plugins/lock/Service.qml" | cut -d' ' -f1) shell/plugins/lock/Service.qml shell/security/lock/Lock.qml$" "$lock" \
  && pass "update: --update re-pins the hash and the package line and keeps the comments" || bad "update: rc=$rc: $out; $(cat "$lock")"
run
[[ $rc == 0 ]] && pass "update: the check passes after the re-pin" || bad "update: check after re-pin rc=$rc: $out"

mv "$up/bin/omarchy-system-sleep-lock" "$tmp/moved"
run
[[ $rc == 1 && $out == *"bin/omarchy-system-sleep-lock is gone"* ]] && pass "drift: a removed upstream file fails" || bad "drift: removed file rc=$rc: $out"
run --update
[[ $rc == 1 ]] && pass "update: refuses to re-pin a removed upstream file" || bad "update: removed file re-pinned rc=$rc: $out"
mv "$tmp/moved" "$up/bin/omarchy-system-sleep-lock"

FIX_OMARCHY=$tmp/none run
[[ $rc == 0 && $out == SKIP:* ]] && pass "skip: no Omarchy installed -> SKIP, exit 0" || bad "skip: rc=$rc: $out"
FIX_OMARCHY=$tmp/none run --require
[[ $rc == 1 ]] && pass "skip: --require without Omarchy fails" || bad "skip: --require rc=$rc: $out"

cp "$lock" "$tmp/good.lock"
zero=$(printf '%064d' 0)
for case_ in "not a sha256|nothex shell/plugins/lock/Service.qml shell/security/lock/Lock.qml" \
  "absolute path|$zero /etc/passwd shell/security/lock/Lock.qml" \
  "parent path|$zero ../x shell/security/lock/Lock.qml" \
  "no derived file|$zero shell/plugins/lock/Service.qml" \
  "extra field|$zero a b c"; do
  label=${case_%%|*} broken=${case_#*|}
  { cat "$tmp/good.lock"; echo "$broken"; } >"$lock"
  run
  [[ $rc == 2 ]] && pass "lock: malformed line refused (exit 2): $label" || bad "lock: $label: '$broken' rc=$rc: $out"
done
echo "# only comments" >"$lock"
run
[[ $rc == 2 ]] && pass "lock: a lock that pins nothing is refused" || bad "lock: empty rc=$rc: $out"
cp "$tmp/good.lock" "$lock"

printf '// no attribution any more\n' >"$tree/shell/security/lock/Lock.qml"
run
[[ $rc == 1 && $out == *"no longer names its upstream file shell/plugins/lock/Service.qml"* ]] \
  && pass "forks: a fork that dropped its attribution fails" || bad "forks: lost attribution rc=$rc: $out"
FIX_OMARCHY=$tmp/none run
[[ $rc == 1 ]] && pass "forks: checked without Omarchy too" || bad "forks: without Omarchy rc=$rc: $out"
printf '// Portions adapted from Omarchy shell/plugins/lock/Service.qml (MIT)\n' >"$tree/shell/security/lock/Lock.qml"
rm "$tree/packaging/shims/omarchy-shell"
run
[[ $rc == 1 && $out == *"packaging/shims/omarchy-shell (derived from bin/omarchy-system-sleep-lock) does not exist"* ]] \
  && pass "forks: a pinned fork that is gone fails" || bad "forks: missing fork rc=$rc: $out"
printf '# answers omarchy-system-sleep-lock\n' >"$tree/packaging/shims/omarchy-shell"
mkdir -p "$tree/shell/security/polkit"
printf '// Portions Adapted from Omarchy shell/plugins/polkit/PolkitAgent.qml\n' >"$tree/shell/security/polkit/AuthAgent.qml"
run
[[ $rc == 1 && $out == *"shell/security/polkit/AuthAgent.qml says it is adapted from Omarchy but is not pinned"* ]] \
  && pass "forks: an unpinned fork fails" || bad "forks: unpinned fork rc=$rc: $out"
rm "$tree/shell/security/polkit/AuthAgent.qml"
run
[[ $rc == 0 ]] && pass "forks: back to a consistent tree" || bad "forks: rc=$rc: $out"

# Review of 395715e: read errors fail the check instead of being hidden.
if [[ $(id -u) != 0 ]]; then
  chmod 000 "$tree/shell/security/idle/IdleModel.js"
  run
  [[ $rc == 1 && $out == *"shell/security/idle/IdleModel.js cannot be read"* ]] && pass "errors: an unreadable fork fails" || bad "errors: unreadable fork rc=$rc: $out"
  chmod 644 "$tree/shell/security/idle/IdleModel.js"
  printf 'x\n' >"$tree/shell/unreadable.qml"
  chmod 000 "$tree/shell/unreadable.qml"
  run
  [[ $rc == 1 && $out == *"the scan for files adapted from Omarchy failed"* ]] && pass "errors: an unreadable file in the scanned tree fails" || bad "errors: scan rc=$rc: $out"
  chmod 644 "$tree/shell/unreadable.qml"
  rm "$tree/shell/unreadable.qml"
else
  echo "SKIP: upstream drift errors: running as root (permissions do not apply)"
fi
for opt in --omarchy --lock --root --package; do
  rc=0
  out=$(bash "$script" "$opt" 2>&1) || rc=$?
  [[ $rc == 2 ]] && pass "usage: $opt without a value is refused" || bad "usage: $opt rc=$rc: $out"
done

# Review of 395715e: no environment variable redirects the check (`just check` runs it bare). The old hooks pointing at the
# drifted fixture tree change nothing: the real check runs against the repository and /usr/share/omarchy.
printf 'drifted again\n' >"$up/shell/plugins/lock/Service.qml"
rc=0
out=$(OMARCHY_PATH=$up GRASSFIELD_UPSTREAM_LOCK=$lock GRASSFIELD_UPSTREAM_ROOT=$tree GRASSFIELD_UPSTREAM_PACKAGE=0 bash "$script" 2>&1) || rc=$?
[[ $out != *"$tmp"* ]] && pass "env: the old test variables are ignored (no fixture path in the output)" || bad "env: the variables still redirect the check: $out"

# The repository's own lock: attribution always; drift against the installed Omarchy when it is there.
rc=0
out=$(bash "$script" --omarchy "$tmp/none" 2>&1) || rc=$?
[[ $rc == 0 ]] && pass "real: the repository's forks are all pinned and attributed" || bad "real: attribution rc=$rc: $out"
if [[ -d /usr/share/omarchy ]]; then
  rc=0
  out=$(bash "$script" 2>&1) || rc=$?
  [[ $rc == 0 ]] && pass "real: the installed Omarchy matches docs/upstream/omarchy.lock" \
    || bad "real: the installed Omarchy differs from the lock (review, then scripts/dev/upstream-drift.sh --update): $out"
else
  echo "SKIP: upstream drift real: Omarchy is not installed (attribution checked above)"
fi

exit $fail
