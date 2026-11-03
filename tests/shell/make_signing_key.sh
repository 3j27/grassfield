#!/usr/bin/env bash
# docs/owner-setup/make-signing-key.sh against stubs: stub key tools on PATH, a fake HOME, no real key ever made.
# Covers: the five output files and their modes (the revocation certificate stays guarded); refusal to overwrite; the default
# folder on tmpfs and the refusal without one; cleanup (temporary home removed, agents stopped) on success, failure and
# SIGINT/SIGTERM/SIGQUIT, and a second signal during the cleanup; no secret on stdout or stderr; the output checks (fingerprint
# mismatch, a subkey, a second primary, no signing capability, a rejected signature, a public-only or foreign or unusable SECRET
# file, a signature by the wrong key); the passphrase confirmation; ~/.gnupg untouched; no core dump. Then mutants of the script:
# each one must behave differently from the script (the test is sensitive to it).
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
# STUB-REVOCATION, STUB-PRIVATE-KEY-FILE) so the test can look for it on stdout and stderr. Each home (the --homedir argument)
# has its own state: a key made there, or a secret key imported there.
cat >"$stubs/gpg" <<'STUB'
#!/usr/bin/env bash
S=${STUB_DIR:?}
mode=${STUB_MODE:-ok}
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=FEDCBA9876543210FEDCBA9876543210FEDCBA98
H=${GNUPGHOME:-}
prev=""
for a in "$@"; do [[ $prev == --homedir ]] && H=$a; prev=$a; done
echo "gpg $*" >>"$S/calls.log"
ulimit -c >"$S/ulimit"
echo "$H" >>"$S/homes"
[[ -n $H && -d $H ]] || { echo "stub: no home" >&2; exit 9; }
[[ $H != "$HOME/.gnupg"* ]] || { echo "stub: touched ~/.gnupg" >&2; exit 9; }
need_pass() { local p; IFS= read -r p || exit 8; [[ $p == "$STUB_PASS" ]] || { echo "stub: wrong passphrase" >&2; exit 8; }; }
args=" $* "
has() { [[ $args == *" $1 "* ]]; }
if has --quick-generate-key; then
  need_pass
  [[ $mode == fail_gen ]] && { echo "gpg: key generation failed" >&2; exit 2; }
  if [[ $mode == hang_gen ]]; then : >"$S/started"; sleep 30; exit 0; fi
  echo "$*" >"$S/genargs"
  mkdir -p "$H/private-keys-v1.d" "$H/openpgp-revocs.d"
  echo "STUB-PRIVATE-KEY-FILE" >"$H/private-keys-v1.d/stub.key"
  printf ':-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: Revocation certificate\nSTUB-REVOCATION\n-----END PGP PUBLIC KEY BLOCK-----\n' \
    >"$H/openpgp-revocs.d/$FPR.rev"
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
  fpr=$(grep -o '[0-9A-F]\{40\}' "$file" | head -n 1)
  fpr=${fpr:-$FPR}
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
  kind=PRIVATE
  [[ $mode == secpublic ]] && kind=PUBLIC
  fpr=$FPR
  [[ $mode == secother ]] && fpr=$OTHER
  if [[ $kind == PUBLIC ]]; then
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUB-PUBLIC-KEY %s\n-----END PGP PUBLIC KEY BLOCK-----\n' "$fpr"
  else
    # The armor lines are built at run time: a literal one in a committed file is what secret scanners flag.
    printf -- '-----BEGIN PGP %s KEY BLOCK-----\nSTUB-SECRET-KEY-MATERIAL %s\n-----END PGP %s KEY BLOCK-----\n' "$kind" "$fpr" "$kind"
  fi
  exit 0
fi
if has --export; then
  printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUB-PUBLIC-KEY %s\n-----END PGP PUBLIC KEY BLOCK-----\n' "$FPR"
  exit 0
fi
if has --import; then
  need_pass
  [[ $mode == importfail ]] && { echo "gpg: import failed" >&2; exit 2; }
  file=${*: -1}
  if grep -q STUB-SECRET-KEY-MATERIAL "$file" && [[ $mode != secbroken ]]; then
    grep -o '[0-9A-F]\{40\}' "$file" | head -n 1 >"$H/imported-secret"
  else
    : >"$H/imported-public"
  fi
  exit 0
fi
if has --detach-sign; then
  need_pass
  ok=""
  prev=""
  for a in "$@"; do [[ $prev == --local-user && $a == "$FPR!" ]] && ok=1; prev=$a; done
  [[ -n $ok ]] || { echo "stub: signing without --local-user FPR!" >&2; exit 7; }
  if [[ -s $H/imported-secret ]]; then signer=$(cat "$H/imported-secret")
  elif [[ -e $H/private-keys-v1.d/stub.key ]]; then signer=$FPR
  else echo "stub: no secret key in this home" >&2; exit 7; fi
  out=""
  prev=""
  for a in "$@"; do [[ $prev == --output ]] && out=$a; prev=$a; done
  echo "STUB-SIG $signer" >"$out"
  exit 0
fi
if has --dearmor; then cat; exit 0; fi
echo "stub: unexpected call: $*" >&2
exit 9
STUB

cat >"$stubs/gpgconf" <<'STUB'
#!/usr/bin/env bash
echo "gpgconf $*" >>"${STUB_DIR:?}/gpgconf.log"
[[ -z ${STUB_GPGCONF_SLEEP:-} ]] || sleep "$STUB_GPGCONF_SLEEP"
exit 0
STUB

cat >"$stubs/gpgv" <<'STUB'
#!/usr/bin/env bash
S=${STUB_DIR:?}
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=FEDCBA9876543210FEDCBA9876543210FEDCBA98
mode=${STUB_MODE:-ok}
echo "gpgv $*" >>"$S/calls.log"
[[ $mode == badsig ]] && { echo "gpgv: BAD signature" >&2; exit 1; }
keyring="" sig="${*: -2:1}"
while (($#)); do [[ $1 == --keyring ]] && keyring=$2; shift; done
grep -q "$FPR" "$keyring" && grep -q "STUB-SIG $FPR" "$sig" || exit 1
signer=$FPR primary=$FPR
[[ $mode == sigsub ]] && signer=$OTHER
[[ $mode == sigprim ]] && primary=$OTHER
[[ $mode == sigother ]] && signer=$OTHER primary=$OTHER
printf '[GNUPG:] GOODSIG KEYID Grassfield Packages\n[GNUPG:] VALIDSIG %s 2026-11-03 1793000000 0 4 0 22 10 00 %s\n' "$signer" "$primary"
STUB
chmod 755 "$stubs"/*

# run NAME MODE INPUT [args...]: one run in a fresh fake HOME; leaves $NAME/{home,t,s,stdout,stderr,rc}. XDG_RUNTIME_DIR is
# $NAME/t (the tmpfs stand-in, where the temporary folder goes) unless RUN_NOXDG is set; SCRIPT overrides the script (mutants).
run() {
  local name=$1 mode=$2 input=$3
  shift 3
  local d=$tmp/$name
  local xdg="XDG_RUNTIME_DIR=$d/t"
  [[ -z ${RUN_NOXDG:-} ]] || xdg="NOXDG=1"
  mkdir -p "$d/home" "$d/t" "$d/tt" "$d/s"
  env -i PATH="$stubs:$PATH" HOME="$d/home" TMPDIR="$d/tt" "$xdg" LANG="${RUN_LANG:-C}" STUB_DIR="$d/s" STUB_PASS="$PASSPHRASE" STUB_MODE="$mode" \
    bash "${SCRIPT:-$script}" "$@" <<<"$input" >"$d/stdout" 2>"$d/stderr"
  echo $? >"$d/rc"
}
rc() { cat "$tmp/$1/rc"; }
two="$PASSPHRASE"$'\n'"$PASSPHRASE"
no_leak() { # no_leak NAME: no secret text on stdout or stderr
  ! grep -qE "STUB-SECRET-KEY-MATERIAL|STUB-REVOCATION|STUB-PRIVATE-KEY-FILE|$PASSPHRASE" "$tmp/$1/stdout" "$tmp/$1/stderr"
}
tmp_clean() { [[ -z $(ls -A "$tmp/$1/t") && -z $(ls -A "$tmp/$1/tt") ]]; }
agent_stopped() { # every home the key tool saw was stopped with gpgconf and is gone
  local h
  while read -r h; do
    grep -q -- "--homedir $h --kill all" "$tmp/$1/s/gpgconf.log" || return 1
    [[ ! -e $h ]] || return 1
  done < <(sort -u "$tmp/$1/s/homes")
}

# 0. --help and an unknown option.
env -i PATH="$PATH" bash "$script" --help >"$tmp/help" 2>&1
check "--help exits 0 and shows both languages" bash -c "grep -q '^Usage:' '$tmp/help' && grep -q '^Utilisation' '$tmp/help'"
check "--help documents SIGKILL and its one-line cleanup" bash -c "grep -q 'SIGKILL' '$tmp/help' && grep -q 'gpgconf --homedir \"\$d/gnupg\" --kill all' '$tmp/help'"
check "--help names the tmpfs default folder" grep -q 'XDG_RUNTIME_DIR/grassfield-signing-key' "$tmp/help"
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
check "success: the revocation certificate stays GUARDED (leading colon kept)" bash -c "head -n 1 '$out/revocation-certificate.asc' | grep -qx -- ':-----BEGIN PGP PUBLIC KEY BLOCK-----'"
check "success: stdout names the fingerprint, the paths and the dates" bash -c "grep -q '$FPR' '$tmp/ok/stdout' && grep -q '$out/SECRET-grassfield-signing-key.asc' '$tmp/ok/stdout' && grep -q 'Expires 2028-10-24; renew before 2028-04-24' '$tmp/ok/stdout'"
check "success: the README has the fingerprint, both languages, the expiry, the deadline and the reminder" \
  bash -c "grep -q '$FPR' '$out/README.txt' && grep -q '^EN - ' '$out/README.txt' && grep -q '^FR - ' '$out/README.txt' && grep -q 'EXPIRES / EXPIRE LE : 2028-10-24' '$out/README.txt' && grep -q 'DEADLINE.*2028-04-24' '$out/README.txt' && grep -q 'Reminder expected from.*2028-01-24' '$out/README.txt'"
check "success: the README explains un-guarding, offline copies and the SIGKILL cleanup" \
  bash -c "grep -q \"sed 's/^://'\" '$out/README.txt' && grep -q 'two offline media' '$out/README.txt' && grep -q 'gpgconf --homedir' '$out/README.txt' && grep -q 'shred on btrfs' '$out/README.txt'"
check "success: Ed25519, sign only, 2 years, the Grassfield UID" bash -c "grep -q -- 'ed25519 sign 2y' '$tmp/ok/s/genargs' && grep -q 'Grassfield Packages <packages@grassfield.site>' '$tmp/ok/s/genargs'"
check "success: the temporary homes are removed and their agents stopped" agent_stopped ok
check "success: the temporary folder was under XDG_RUNTIME_DIR and is gone" bash -c "grep -q '$tmp/ok/t/grassfield-key' '$tmp/ok/s/homes' && test -z \"\$(ls -A '$tmp/ok/t')\""
check "success: TMPDIR untouched too" tmp_clean ok
check "success: no core dump allowed (ulimit -c 0 when the key tool runs)" test "$(cat "$tmp/ok/s/ulimit")" == 0
check "success: ~/.gnupg was not created" test ! -e "$tmp/ok/home/.gnupg"
check "success: the test signature was made in a fresh home that imported only the SECRET file, and checked with gpgv" \
  bash -c "grep -q '^gpg .*--import $out/SECRET-grassfield-signing-key.asc' '$tmp/ok/s/calls.log' && grep -q '^gpgv .*--keyring' '$tmp/ok/s/calls.log' && test \$(sort -u '$tmp/ok/s/homes' | wc -l) -ge 2"
check "success: the stage-two warning matches the filesystem" bash -c "fs=\$(stat -f -c %T '$out'); if [[ \$fs == tmpfs ]]; then ! grep -q WARNING '$tmp/ok/stderr'; else grep -q WARNING '$tmp/ok/stderr'; fi"
check "success: no secret on stdout or stderr" no_leak ok
check "success: the passphrase is on no command line" bash -c "! grep -q '$PASSPHRASE' '$tmp/ok/s/calls.log'"

# 2. The default folder: $XDG_RUNTIME_DIR/grassfield-signing-key-YYYYMMDD; without a tmpfs folder, it asks for --output.
run def ok "$two"
check "default folder: \$XDG_RUNTIME_DIR/grassfield-signing-key-YYYYMMDD" test -s "$tmp/def/t/grassfield-signing-key-$(date +%Y%m%d)/fingerprint.txt"
check "default folder: nothing under HOME or TMPDIR" bash -c "test -z \"\$(ls -A '$tmp/def/home')\" && test -z \"\$(ls -A '$tmp/def/tt')\""
RUN_NOXDG=1 run noxdg ok "$two"
check "no XDG_RUNTIME_DIR and no --output: refused, nothing written, no key tool ran" \
  bash -c "test '$(rc noxdg)' == 1 && grep -q 'XDG_RUNTIME_DIR' '$tmp/noxdg/stderr' && test -z \"\$(ls -A '$tmp/noxdg/home')\" && ! test -e '$tmp/noxdg/s/calls.log'"
RUN_NOXDG=1 run noxdg2 ok "$two" --output "$tmp/noxdg2/out"
check "without XDG_RUNTIME_DIR, an explicit --output still works (TMPDIR for the temporary folder)" test "$(rc noxdg2)" == 0 -a -s "$tmp/noxdg2/out/fingerprint.txt"

# 3. Refusal to overwrite: nothing touched, no temporary home made, the old content kept.
before=$(cat "$out"/* | sha256sum)
run again ok "$two" --output "$out"
check "refusal: exit 1 with a message" bash -c "test '$(rc again)' == 1 && grep -q 'already exists' '$tmp/again/stderr'"
check "refusal: the existing folder is unchanged" test "$(cat "$out"/* | sha256sum)" == "$before"
check "refusal: no key tool ran and nothing is left in the temporary folders" bash -c "! test -e '$tmp/again/s/calls.log'"
check "refusal: no temporary home" tmp_clean again
mkdir -p "$tmp/pre/home" && mkdir "$tmp/pre/keepme" && echo sentinel >"$tmp/pre/keepme/x"
run pre fail_gen "$two" --output "$tmp/pre/keepme"
check "refusal: a pre-existing folder survives even a failing run" test "$(cat "$tmp/pre/keepme/x")" == sentinel
RUN_LANG=fr_FR.UTF-8 run frref ok "$two" --output "$out"
check "French: the refusal speaks French" grep -q "existe deja" "$tmp/frref/stderr"

# 4. Failure cleanup: key creation fails; the output folder is never left half-made.
run fgen fail_gen "$two" --output "$tmp/fgen/out"
check "failure (creation): non-zero exit and an error message" bash -c "test '$(rc fgen)' != 0 && grep -q 'could not create the key' '$tmp/fgen/stderr'"
check "failure (creation): no output folder" test ! -e "$tmp/fgen/out"
check "failure (creation): cleanup ran" agent_stopped fgen
check "failure (creation): nothing in the temporary folders" tmp_clean fgen
check "failure (creation): no secret on stdout or stderr" no_leak fgen

# 5. The self-checks: each failure removes the folder that was already written, and cleans up. mode:message.
checks=(
  "mismatch:differs from fingerprint.txt"
  "subkey:unexpected subkey"
  "twoprimary:exactly one primary"
  "nosign:cannot sign"
  "badsig:gpgv rejects"
  "secpublic:no sec record"
  "secother:not the public key's twin"
  "secbroken:test signature failed"
  "importfail:cannot be imported"
  "sigsub:not by the primary key"
  "sigprim:not by the primary key"
  "sigother:not by the primary key"
)
for c in "${checks[@]}"; do
  m=${c%%:*} msg=${c#*:}
  run "c_$m" "$m" "$two" --output "$tmp/c_$m/out"
  check "check '$m': refused (exit 1) with '$msg'" bash -c "test '$(rc "c_$m")' == 1 && grep -q \"$msg\" '$tmp/c_$m/stderr'"
  check "check '$m': the written folder is removed" test ! -e "$tmp/c_$m/out"
  check "check '$m': cleanup ran, nothing left" bash -c "$(declare -f agent_stopped tmp_clean); tmp='$tmp'; agent_stopped c_$m && tmp_clean c_$m"
  check "check '$m': no secret on stdout or stderr" no_leak "c_$m"
done

# 6. The passphrase: a mismatch and a short one stop before any key is made.
run pdiff ok $'aaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbb' --output "$tmp/pdiff/out"
check "passphrase mismatch: exit 1, no key made, nothing left" bash -c "test '$(rc pdiff)' == 1 && ! test -e '$tmp/pdiff/s/calls.log' && test ! -e '$tmp/pdiff/out'"
check "passphrase mismatch: temporary folders clean" tmp_clean pdiff
run pshort ok $'short\nshort' --output "$tmp/pshort/out"
check "passphrase too short: exit 1, no key made" bash -c "test '$(rc pshort)' == 1 && ! test -e '$tmp/pshort/s/calls.log'"
check "passphrases are not echoed" bash -c "! grep -q 'aaaaaaaa\|bbbbbbbb' '$tmp/pdiff/stdout' '$tmp/pdiff/stderr'"

# 7. SIGINT, SIGTERM and SIGQUIT while the key tool runs: the trap cleans up and the exit status is 128 + signal. A second
# SIGINT while the cleanup runs (the agent stop is slowed down) does not abort it.
drive() { # drive NAME SIGNAL TIMES: the script in its own session; the signal goes to its group TIMES times
  local d=$tmp/$1
  mkdir -p "$d/home" "$d/t" "$d/tt" "$d/s"
  env -i PATH="$stubs:$PATH" HOME="$d/home" TMPDIR="$d/tt" XDG_RUNTIME_DIR="$d/t" LANG=C STUB_DIR="$d/s" STUB_PASS="$PASSPHRASE" STUB_MODE=hang_gen \
    STUB_GPGCONF_SLEEP="${3:+1}" python3 -I - "$2" "${SCRIPT:-$script}" "$d/out" "$d/s/started" "$PASSPHRASE" "${3:-1}" <<'PY'
import os, signal, subprocess, sys, time
sig, script, out, started, passphrase, times = getattr(signal, "SIG" + sys.argv[1]), *sys.argv[2:6], int(sys.argv[6])
def default_signals():
    for s in (signal.SIGINT, signal.SIGQUIT):
        signal.signal(s, signal.SIG_DFL)
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
for n in range(times):
    if n:
        time.sleep(0.4)
    try:
        os.killpg(p.pid, sig)
    except ProcessLookupError:
        pass
try:
    print(p.wait(timeout=20))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print("hung")
PY
}
for sig in INT TERM QUIT; do
  status=$(drive "sig$sig" "$sig" "")
  want=130
  [[ $sig == TERM ]] && want=143
  [[ $sig == QUIT ]] && want=131
  check "SIG$sig: exit status $want (got $status)" test "$status" == "$want"
  d=$tmp/sig$sig
  check "SIG$sig: the temporary homes are removed and their agents stopped" bash -c "$(declare -f agent_stopped); tmp='$tmp'; agent_stopped sig$sig"
  check "SIG$sig: nothing in the temporary folders, no output folder" bash -c "test -z \"\$(ls -A '$d/t')\" && test -z \"\$(ls -A '$d/tt')\" && test ! -e '$d/out'"
done
status=$(drive sigtwice INT 2)
check "a second SIGINT during the cleanup does not abort it: exit 130 (got $status)" test "$status" == 130
check "a second SIGINT during the cleanup: the temporary folder is still removed" bash -c "test -z \"\$(ls -A '$tmp/sigtwice/t')\" && test ! -e '$tmp/sigtwice/out'"

# 8. Mutants: the script with one check removed must behave differently from the script, in the mode that exercises that check
# (so that each check is really tested). "ok" means the script succeeds in that mode, otherwise it fails with the message.
mutant() { # mutant NAME 'sed expression' MODE 'ok|message'
  local name=$1 expr=$2 mode=$3 want=$4
  sed "$expr" "$script" >"$tmp/mutant-$name.sh"
  if cmp -s "$script" "$tmp/mutant-$name.sh"; then fail "mutant '$name': the edit did not change the script"; return; fi
  SCRIPT="$tmp/mutant-$name.sh" run "m_$name" "$mode" "$two" --output "$tmp/m_$name/out"
  local r
  r=$(rc "m_$name")
  local same=0
  if [[ $want == ok ]]; then [[ $r == 0 ]] && same=1; else [[ $r == 1 ]] && grep -q "$want" "$tmp/m_$name/stderr" && same=1; fi
  if ((same)); then fail "mutant '$name' survives: it behaves like the script in mode '$mode'"; else pass "mutant '$name' is caught (mode '$mode')"; fi
}
mutant secfpr 's/\[\[ \$secfpr == "\$pubfpr" \]\]/true/' secother "not the public key's twin"
mutant secpublic 's/\$1 == "sec" { f = 1 }/{ f = 1 }/' secpublic "no sec record"
mutant freshhome 's/^gpgv_ --detach-sign/gpgs --detach-sign/' secbroken "test signature failed"
mutant validsig_all 's/\$3 == f && \$NF == f/1/' sigother "not by the primary key"
mutant validsig_nf 's/ && \$NF == f//' sigprim "not by the primary key"
mutant validsig_3 's/\$3 == f && //' sigsub "not by the primary key"
mutant localuser 's/--local-user "\$fpr!" //' ok ok
mutant guardstripped 's/^cp -- "\$revsrc" "\$rev"/sed "s,^:,," "$revsrc" >"$rev"/' ok ok
sed "/^  trap '' INT TERM QUIT HUP/d" "$script" >"$tmp/mutant-noignore.sh"
check "mutant 'noignore': the edit changed the script" bash -c "! cmp -s '$script' '$tmp/mutant-noignore.sh'"
status=$(SCRIPT="$tmp/mutant-noignore.sh" drive m_noignore INT 2)
check "mutant 'noignore' is caught: a second SIGINT then aborts the cleanup (got $status)" \
  bash -c "! { test '$status' == 130 && test -z \"\$(ls -A '$tmp/m_noignore/t')\"; }"

echo
if ((fails)); then echo "make-signing-key: $fails FAILED"; exit 1; fi
echo "make-signing-key: all passed"
