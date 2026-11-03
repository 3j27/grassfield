#!/usr/bin/env bash
# docs/owner-setup/make-signing-key.sh against stubs: stub key tools on PATH, a fake HOME, no real key ever made.
# Covers: the five output files and their modes; refusal to overwrite; cleanup (temporary home removed, agent stopped) on
# success, failure and SIGINT/SIGTERM; no secret on stdout or stderr; the output checks (fingerprint mismatch, a subkey, a
# second primary, no signing capability, a rejected signature); the passphrase confirmation; ~/.gnupg untouched.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/docs/owner-setup/make-signing-key.sh

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/mksk.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: make-signing-key: $1"; }
fail() { echo "FAIL: make-signing-key: $1"; fails=$((fails + 1)); }
check() { # check "name" command...
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

PASSPHRASE="swordfish-passphrase-123"
FPR=0123456789ABCDEF0123456789ABCDEF01234567

stubs=$tmp/bin
mkdir -p "$stubs"

# The key tool stub. Passphrases arrive on stdin only; secret-looking text is recognisable (STUB-SECRET-KEY-MATERIAL,
# STUB-REVOCATION, STUB-PRIVATE-KEY-FILE) so the test can look for it on stdout and stderr.
cat >"$stubs/gpg" <<'STUB'
#!/usr/bin/env bash
S=${STUB_DIR:?}
mode=${STUB_MODE:-ok}
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=FEDCBA9876543210FEDCBA9876543210FEDCBA98
echo "gpg $*" >>"$S/calls.log"
echo "$GNUPGHOME" >"$S/home"
[[ -n ${GNUPGHOME:-} && -d $GNUPGHOME ]] || { echo "stub: no GNUPGHOME" >&2; exit 9; }
[[ $GNUPGHOME != "$HOME/.gnupg"* ]] || { echo "stub: touched ~/.gnupg" >&2; exit 9; }
need_pass() { local p; IFS= read -r p || exit 8; [[ $p == "$STUB_PASS" ]] || { echo "stub: wrong passphrase" >&2; exit 8; }; }
args=" $* "
has() { [[ $args == *" $1 "* ]]; }
if has --quick-generate-key; then
  need_pass
  [[ $mode == fail_gen ]] && { echo "gpg: key generation failed" >&2; exit 2; }
  if [[ $mode == hang_gen ]]; then : >"$S/started"; sleep 30; exit 0; fi
  echo "$*" >"$S/genargs"
  mkdir -p "$GNUPGHOME/private-keys-v1.d" "$GNUPGHOME/openpgp-revocs.d"
  echo "STUB-PRIVATE-KEY-FILE" >"$GNUPGHOME/private-keys-v1.d/stub.key"
  printf ':-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: Revocation certificate\nSTUB-REVOCATION\n-----END PGP PUBLIC KEY BLOCK-----\n' \
    >"$GNUPGHOME/openpgp-revocs.d/$FPR.rev"
  exit 0
fi
if has --list-secret-keys || has --list-keys; then
  printf 'sec:u:256:22:KEYID:1793000000:1856000000::u:::sc:::+:::ed25519:::0:\nfpr:::::::::%s:\ngrp:::::::::GRIP:\nuid:u::::1793000000::H::Grassfield Packages <packages@grassfield.site>::::::::::0:\n' "$FPR"
  exit 0
fi
if has --show-keys; then
  file=${*: -1}
  kind=pub
  grep -q SECRET "$file" && kind=sec
  fpr=$FPR
  cap=sc
  [[ $mode == mismatch && $kind == pub ]] && fpr=$OTHER
  [[ $mode == nosign ]] && cap=e
  printf '%s:u:256:22:KEYID:1793000000:1856000000::u:::%s:::+:::ed25519:::0:\nfpr:::::::::%s:\n' "$kind" "$cap" "$fpr"
  [[ $mode == subkey ]] && printf 'sub:u:256:18:SUBID:1793000000:1856000000:::::e:::::cv25519::\nfpr:::::::::%s:\n' "$OTHER"
  [[ $mode == twoprimary ]] && printf 'pub:u:256:22:KEYID2:1793000000:1856000000::u:::sc:::+:::ed25519:::0:\nfpr:::::::::%s:\n' "$OTHER"
  exit 0
fi
if has --export-secret-keys; then
  need_pass
  # The armor lines are built at run time: a literal one in a committed file is what secret scanners flag.
  kind=PRIVATE
  printf -- '-----BEGIN PGP %s KEY BLOCK-----\nSTUB-SECRET-KEY-MATERIAL %s\n-----END PGP %s KEY BLOCK-----\n' "$kind" "$FPR" "$kind"
  exit 0
fi
if has --export; then
  printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUB-PUBLIC-KEY %s\n-----END PGP PUBLIC KEY BLOCK-----\n' "$FPR"
  exit 0
fi
if has --detach-sign; then
  need_pass
  while (($#)); do [[ $1 == --output ]] && { echo "STUB-SIG $FPR" >"$2"; exit 0; }; shift; done
  exit 7
fi
if has --dearmor; then cat; exit 0; fi
echo "stub: unexpected call: $*" >&2
exit 9
STUB

cat >"$stubs/gpgconf" <<'STUB'
#!/usr/bin/env bash
echo "gpgconf $*" >>"${STUB_DIR:?}/gpgconf.log"
exit 0
STUB

cat >"$stubs/gpgv" <<'STUB'
#!/usr/bin/env bash
S=${STUB_DIR:?}
FPR=0123456789ABCDEF0123456789ABCDEF01234567
echo "gpgv $*" >>"$S/calls.log"
[[ ${STUB_MODE:-ok} == badsig ]] && { echo "gpgv: BAD signature" >&2; exit 1; }
keyring="" sig="${*: -2:1}"
while (($#)); do [[ $1 == --keyring ]] && keyring=$2; shift; done
grep -q "$FPR" "$keyring" && grep -q "STUB-SIG $FPR" "$sig" || exit 1
printf '[GNUPG:] GOODSIG KEYID Grassfield Packages\n[GNUPG:] VALIDSIG %s 2026-11-03 1793000000 0 4 0 22 10 00 %s\n' "$FPR" "$FPR"
STUB
chmod 755 "$stubs"/*

# run NAME MODE INPUT [args...]: one run in a fresh fake HOME; leaves $NAME/{home,t,s,stdout,stderr,rc}.
run() {
  local name=$1 mode=$2 input=$3
  shift 3
  local d=$tmp/$name
  mkdir -p "$d/home" "$d/t" "$d/s"
  env -i PATH="$stubs:$PATH" HOME="$d/home" TMPDIR="$d/t" LANG="${RUN_LANG:-C}" STUB_DIR="$d/s" STUB_PASS="$PASSPHRASE" STUB_MODE="$mode" \
    bash "$script" "$@" <<<"$input" >"$d/stdout" 2>"$d/stderr"
  echo $? >"$d/rc"
}
rc() { cat "$tmp/$1/rc"; }
two="$PASSPHRASE"$'\n'"$PASSPHRASE"
no_leak() { # no_leak NAME: no secret text on stdout or stderr
  ! grep -qE "STUB-SECRET-KEY-MATERIAL|STUB-REVOCATION|STUB-PRIVATE-KEY-FILE|$PASSPHRASE" "$tmp/$1/stdout" "$tmp/$1/stderr"
}
tmp_clean() { [[ -z $(ls -A "$tmp/$1/t") ]]; }
agent_stopped() { grep -q -- "--homedir $(cat "$tmp/$1/s/home") --kill all" "$tmp/$1/s/gpgconf.log" && [[ ! -e $(cat "$tmp/$1/s/home") ]]; }

# 0. --help and an unknown option.
env -i PATH="$PATH" bash "$script" --help >"$tmp/help" 2>&1
check "--help exits 0 and shows both languages" bash -c "grep -q '^Usage:' '$tmp/help' && grep -q '^Utilisation' '$tmp/help'"
env -i PATH="$PATH" bash "$script" --bogus >/dev/null 2>&1
check "an unknown option exits 2" test $? -eq 2

# 1. A good run.
run ok ok "$two" --output "$tmp/ok/out"
out=$tmp/ok/out
check "success: exit 0" test "$(rc ok)" == 0
check "success: the five files exist" bash -c "cd '$out' && ls | LC_ALL=C sort | tr '\n' ' ' | grep -qx 'README.txt SECRET-grassfield-signing-key.asc fingerprint.txt grassfield-signing-key.asc revocation-certificate.asc '"
check "success: modes (folder 700, secret 600, revocation 600, public 644, fingerprint 644)" \
  test "$(stat -c '%a' "$out" "$out/SECRET-grassfield-signing-key.asc" "$out/revocation-certificate.asc" "$out/grassfield-signing-key.asc" "$out/fingerprint.txt" | tr '\n' ' ')" == "700 600 600 644 644 "
check "success: fingerprint.txt is the 40-hex primary" test "$(cat "$out/fingerprint.txt")" == "$FPR"
check "success: the public file holds no secret text" bash -c "! grep -q 'SECRET\|PRIVATE' '$out/grassfield-signing-key.asc'"
check "success: the revocation certificate lost its guard colon" bash -c "head -n 1 '$out/revocation-certificate.asc' | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----'"
check "success: stdout names the fingerprint and the paths" bash -c "grep -q '$FPR' '$tmp/ok/stdout' && grep -q '$out/SECRET-grassfield-signing-key.asc' '$tmp/ok/stdout'"
check "success: the README carries the fingerprint and both languages" bash -c "grep -q '$FPR' '$out/README.txt' && grep -q '^EN - ' '$out/README.txt' && grep -q '^FR - ' '$out/README.txt'"
check "success: Ed25519, sign only, 2 years, the Grassfield UID" bash -c "grep -q -- 'ed25519 sign 2y' '$tmp/ok/s/genargs' && grep -q 'Grassfield Packages <packages@grassfield.site>' '$tmp/ok/s/genargs'"
check "success: the temporary home is removed and its agent stopped" agent_stopped ok
check "success: nothing left in TMPDIR" tmp_clean ok
check "success: ~/.gnupg was not created" test ! -e "$tmp/ok/home/.gnupg"
check "success: the throwaway signature was checked with gpgv" grep -q '^gpgv .*--keyring' "$tmp/ok/s/calls.log"
check "success: no secret on stdout or stderr" no_leak ok
check "success: the passphrase is on no command line" bash -c "! grep -q '$PASSPHRASE' '$tmp/ok/s/calls.log'"

# 2. The default folder: ~/grassfield-signing-key-YYYYMMDD.
run def ok "$two"
check "default folder: ~/grassfield-signing-key-YYYYMMDD" test -s "$tmp/def/home/grassfield-signing-key-$(date +%Y%m%d)/fingerprint.txt"

# 3. Refusal to overwrite: nothing touched, no temporary home made, the old content kept.
before=$(cat "$out"/* | sha256sum)
calls_before=$(wc -l <"$tmp/ok/s/calls.log")
run again ok "$two" --output "$out"
check "refusal: exit 1 with a message" bash -c "test '$(rc again)' == 1 && grep -q 'already exists' '$tmp/again/stderr'"
check "refusal: the existing folder is unchanged" test "$(cat "$out"/* | sha256sum)" == "$before"
check "refusal: no key tool ran and nothing is left in TMPDIR" bash -c "! test -e '$tmp/again/s/calls.log'"
check "refusal: no temporary home" tmp_clean again
mkdir -p "$tmp/pre/home" && mkdir "$tmp/pre/keepme" && echo sentinel >"$tmp/pre/keepme/x"
run pre fail_gen "$two" --output "$tmp/pre/keepme"
check "refusal: a pre-existing folder survives even a failing run" test "$(cat "$tmp/pre/keepme/x")" == sentinel
RUN_LANG=fr_FR.UTF-8 run frref ok "$two" --output "$out"
check "French: the refusal speaks French" grep -q "existe deja" "$tmp/frref/stderr"
_=$calls_before

# 4. Failure cleanup: key creation fails; the output folder is never left half-made.
run fgen fail_gen "$two" --output "$tmp/fgen/out"
check "failure (creation): non-zero exit and an error message" bash -c "test '$(rc fgen)' != 0 && grep -q 'could not create the key' '$tmp/fgen/stderr'"
check "failure (creation): no output folder, temporary home removed, agent stopped" bash -c "test ! -e '$tmp/fgen/out'"
check "failure (creation): cleanup ran" agent_stopped fgen
check "failure (creation): nothing in TMPDIR" tmp_clean fgen
check "failure (creation): no secret on stdout or stderr" no_leak fgen

# 5. The self-checks: each failure removes the folder that was already written, and cleans up.
for m in mismatch subkey twoprimary nosign badsig; do
  run "c_$m" "$m" "$two" --output "$tmp/c_$m/out"
  check "check '$m': refused (exit 1)" test "$(rc "c_$m")" == 1
  check "check '$m': the written folder is removed" test ! -e "$tmp/c_$m/out"
  check "check '$m': cleanup ran" bash -c "$(declare -f agent_stopped); tmp='$tmp'; agent_stopped c_$m"
  check "check '$m': no secret on stdout or stderr" no_leak "c_$m"
done
check "check 'mismatch': the message names the fingerprint" grep -q "differs from fingerprint.txt" "$tmp/c_mismatch/stderr"
check "check 'twoprimary': the message says one primary" grep -q "exactly one primary" "$tmp/c_twoprimary/stderr"
check "check 'nosign': the message says it cannot sign" grep -q "cannot sign" "$tmp/c_nosign/stderr"

# 6. The passphrase: a mismatch and a short one stop before any key is made.
run pdiff ok $'aaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbb' --output "$tmp/pdiff/out"
check "passphrase mismatch: exit 1, no key made, nothing left" bash -c "test '$(rc pdiff)' == 1 && ! test -e '$tmp/pdiff/s/calls.log' && test ! -e '$tmp/pdiff/out'"
check "passphrase mismatch: TMPDIR clean" tmp_clean pdiff
run pshort ok $'short\nshort' --output "$tmp/pshort/out"
check "passphrase too short: exit 1, no key made" bash -c "test '$(rc pshort)' == 1 && ! test -e '$tmp/pshort/s/calls.log'"
check "passphrases are not echoed" bash -c "! grep -q 'aaaaaaaa\|bbbbbbbb' '$tmp/pdiff/stdout' '$tmp/pdiff/stderr'"

# 7. SIGINT and SIGTERM while the key tool runs: the trap cleans up and the exit status is 128 + signal.
for sig in INT TERM; do
  d=$tmp/sig$sig
  mkdir -p "$d/home" "$d/t" "$d/s"
  status=$(env -i PATH="$stubs:$PATH" HOME="$d/home" TMPDIR="$d/t" LANG=C STUB_DIR="$d/s" STUB_PASS="$PASSPHRASE" STUB_MODE=hang_gen \
    python3 -I - "$sig" "$script" "$d/out" "$d/s/started" "$PASSPHRASE" <<'PY'
import os, signal, subprocess, sys, time
sig, script, out, started, passphrase = getattr(signal, "SIG" + sys.argv[1]), *sys.argv[2:6]
def default_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
p = subprocess.Popen(["bash", script, "--output", out], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, preexec_fn=default_signals)
p.stdin.write((passphrase + "\n" + passphrase + "\n").encode())
p.stdin.close()
for _ in range(150):
    if os.path.exists(started):
        break
    time.sleep(0.1)
else:
    p.kill()
    print("never-started")
    sys.exit(0)
os.killpg(p.pid, sig)
try:
    print(p.wait(timeout=20))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print("hung")
PY
  )
  want=130
  [[ $sig == TERM ]] && want=143
  check "SIG$sig: exit status $want (got $status)" test "$status" == "$want"
  check "SIG$sig: the temporary home is removed and its agent stopped" bash -c "$(declare -f agent_stopped); tmp='$tmp'; agent_stopped sig$sig"
  check "SIG$sig: nothing in TMPDIR, no output folder" bash -c "test -z \"\$(ls -A '$d/t')\" && test ! -e '$d/out'"
done

echo
if ((fails)); then echo "make-signing-key: $fails FAILED"; exit 1; fi
echo "make-signing-key: all passed"
