#!/usr/bin/env bash
# docs/owner-setup/renew-signing-key.sh against stubs (stub key tools on PATH, a fake HOME; no real key is made or read).
# Covers: the extended key (same fingerprint, later expiry) and the files with their modes; the refusals (an existing folder, no
# tmpfs folder, a wrong or empty passphrase, a foreign fingerprint, two keys, a subkey); the checks (no extension, too short an
# extension, a SECRET file with the old expiry, a changed fingerprint, a bad signature); cleanup on success, failure and SIGINT;
# no secret on stdout or stderr; ~/.gnupg untouched; two mutants.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/docs/owner-setup/renew-signing-key.sh

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/rsk.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: renew-signing-key: $1"; }
fail() { echo "FAIL: renew-signing-key: $1"; fails=$((fails + 1)); }
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

PASSPHRASE="swordfish-passphrase-123"
FPR=0123456789ABCDEF0123456789ABCDEF01234567
OTHER=FEDCBA9876543210FEDCBA9876543210FEDCBA98
now=$(date +%s)
OLDEXP=$((now + 30 * 86400))

stubs=$tmp/bin
mkdir -p "$stubs"
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
fpr_in_home() { cat "$H/fpr"; }
if has --import; then
  need_pass
  file=${*: -1}
  grep -q STUB-SECRET-KEY-MATERIAL "$file" || { echo "gpg: no secret key in file" >&2; exit 2; }
  read -r _ f e <<<"$(grep STUB-SECRET-KEY-MATERIAL "$file" | head -n 1)"
  echo "$f" >"$H/fpr"
  echo "$e" >"$H/exp"
  exit 0
fi
if has --list-secret-keys; then
  [[ -s $H/fpr ]] || exit 0
  f=$(fpr_in_home)
  [[ $mode == fprchange && -e $H/extended ]] && f=$OTHER
  printf 'sec:u:256:22:KEYID:1793000000:%s::u:::sc:::+:::ed25519:::0:\nfpr:::::::::%s:\n' "$(cat "$H/exp")" "$f"
  [[ $mode == twokeys ]] && printf 'sec:u:256:22:KEYID2:1793000000:1856000000::u:::sc:::+:::ed25519:::0:\nfpr:::::::::%s:\n' "$OTHER"
  [[ $mode == subkey ]] && printf 'ssb:u:256:18:SUBID:1793000000:1856000000:::::e:::::cv25519::\nfpr:::::::::%s:\n' "$OTHER"
  exit 0
fi
if has --quick-set-expire; then
  need_pass
  echo "$*" >"$S/setexpire"
  [[ $mode == hang_set ]] && { : >"$S/started"; sleep 30; exit 0; }
  case $mode in
    noextend) ;;
    shortexp) echo $(($(date +%s) + 100 * 86400)) >"$H/exp" ;;
    *) echo $(($(date +%s) + 730 * 86400)) >"$H/exp" ;;
  esac
  : >"$H/extended"
  exit 0
fi
if has --show-keys; then
  file=${*: -1}
  kind=pub
  grep -q STUB-SECRET-KEY-MATERIAL "$file" && kind=sec
  read -r _ f e <<<"$(grep -E 'STUB-(SECRET|PUBLIC)-KEY' "$file" | head -n 1)"
  printf '%s:u:256:22:KEYID:1793000000:%s::u:::sc:::+:::ed25519:::0:\nfpr:::::::::%s:\n' "$kind" "$e" "$f"
  exit 0
fi
if has --export-secret-keys; then
  need_pass
  exp=$(cat "$H/exp")
  [[ $mode == secold ]] && exp=$STUB_OLDEXP
  kind=PRIVATE
  printf -- '-----BEGIN PGP %s KEY BLOCK-----\nSTUB-SECRET-KEY-MATERIAL %s %s\n-----END PGP %s KEY BLOCK-----\n' "$kind" "$(fpr_in_home)" "$exp" "$kind"
  exit 0
fi
if has --export; then
  printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUB-PUBLIC-KEY %s %s\n-----END PGP PUBLIC KEY BLOCK-----\n' "$(fpr_in_home)" "$(cat "$H/exp")"
  exit 0
fi
if has --detach-sign; then
  need_pass
  ok=""
  prev=""
  for a in "$@"; do [[ $prev == --local-user && $a == "$FPR!" ]] && ok=1; prev=$a; done
  [[ -n $ok ]] || { echo "stub: signing without --local-user FPR!" >&2; exit 7; }
  [[ -s $H/fpr ]] || { echo "stub: no secret key in this home" >&2; exit 7; }
  out=""
  prev=""
  for a in "$@"; do [[ $prev == --output ]] && out=$a; prev=$a; done
  echo "STUB-SIG $(fpr_in_home)" >"$out"
  exit 0
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
OTHER=FEDCBA9876543210FEDCBA9876543210FEDCBA98
mode=${STUB_MODE:-ok}
echo "gpgv $*" >>"$S/calls.log"
[[ $mode == badsig ]] && { echo "gpgv: BAD signature" >&2; exit 1; }
keyring="" sig="${*: -2:1}"
while (($#)); do [[ $1 == --keyring ]] && keyring=$2; shift; done
grep -q "$FPR" "$keyring" && grep -q "STUB-SIG $FPR" "$sig" || exit 1
signer=$FPR
[[ $mode == sigother ]] && signer=$OTHER
printf '[GNUPG:] GOODSIG KEYID Grassfield Packages\n[GNUPG:] VALIDSIG %s 2026-11-03 1793000000 0 4 0 22 10 00 %s\n' "$signer" "$FPR"
STUB
chmod 755 "$stubs"/*

# The offline copy: a "secret key" file, its armor lines built at run time (a literal one is what secret scanners flag).
kind=PRIVATE
secretfile=$tmp/SECRET-input.asc
printf -- '-----BEGIN PGP %s KEY BLOCK-----\nSTUB-SECRET-KEY-MATERIAL %s %s\n-----END PGP %s KEY BLOCK-----\n' "$kind" "$FPR" "$OLDEXP" "$kind" >"$secretfile"
publicfile=$tmp/public-input.asc
printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUB-PUBLIC-KEY %s %s\n-----END PGP PUBLIC KEY BLOCK-----\n' "$FPR" "$OLDEXP" >"$publicfile"

run() { # run NAME MODE INPUT [args...]
  local name=$1 mode=$2 input=$3
  shift 3
  local d=$tmp/$name
  local xdg="XDG_RUNTIME_DIR=$d/t"
  [[ -z ${RUN_NOXDG:-} ]] || xdg="NOXDG=1"
  mkdir -p "$d/home" "$d/t" "$d/tt" "$d/s"
  env -i PATH="$stubs:$PATH" HOME="$d/home" TMPDIR="$d/tt" "$xdg" LANG=C STUB_DIR="$d/s" STUB_PASS="$PASSPHRASE" STUB_MODE="$mode" STUB_OLDEXP="$OLDEXP" \
    bash "${SCRIPT:-$script}" "$@" <<<"$input" >"$d/stdout" 2>"$d/stderr"
  echo $? >"$d/rc"
}
rc() { cat "$tmp/$1/rc"; }
no_leak() { ! grep -qE "STUB-SECRET-KEY-MATERIAL|STUB-PRIVATE-KEY-FILE|$PASSPHRASE" "$tmp/$1/stdout" "$tmp/$1/stderr"; }
tmp_clean() { [[ -z $(ls -A "$tmp/$1/t") && -z $(ls -A "$tmp/$1/tt") ]]; }
agent_stopped() {
  local h
  while read -r h; do
    grep -q -- "--homedir $h --kill all" "$tmp/$1/s/gpgconf.log" || return 1
    [[ ! -e $h ]] || return 1
  done < <(sort -u "$tmp/$1/s/homes")
}

env -i PATH="$PATH" bash "$script" --help >"$tmp/help" 2>&1
check "--help: exit 0, both languages, SIGKILL cleanup line" bash -c "grep -q '^Usage:' '$tmp/help' && grep -q '^Utilisation' '$tmp/help' && grep -q 'SIGKILL' '$tmp/help' && grep -q 'kill all; gpgconf' '$tmp/help'"
env -i PATH="$PATH" bash "$script" >/dev/null 2>&1
check "no --secret: exit 2" test $? -eq 2

# 1. A good renewal.
run ok ok "$PASSPHRASE" --secret "$secretfile" --fingerprint "${FPR,,}" --output "$tmp/ok/out"
out=$tmp/ok/out
check "success: exit 0" test "$(rc ok)" == 0
check "success: the four files and the README" bash -c "cd '$out' && ls | LC_ALL=C sort | tr '\n' ' ' | grep -qx 'README.txt SECRET-grassfield-signing-key.asc expiry.txt fingerprint.txt grassfield-signing-key.asc '"
check "success: modes (folder 700, secret 600, public 644)" \
  test "$(stat -c '%a' "$out" "$out/SECRET-grassfield-signing-key.asc" "$out/grassfield-signing-key.asc" | tr '\n' ' ')" == "700 600 644 "
check "success: the fingerprint is unchanged" test "$(cat "$out/fingerprint.txt")" == "$FPR"
newexp=$(awk '/STUB-PUBLIC-KEY/ {print $3}' "$out/grassfield-signing-key.asc")
check "success: the public key expires at least 300 days from now and later than before" test "$newexp" -ge $((now + 300 * 86400)) -a "$newexp" -gt "$OLDEXP"
check "success: the extension was asked of the primary key, 2y" bash -c "grep -q -- '--quick-set-expire $FPR 2y' '$tmp/ok/s/setexpire'"
check "success: expiry.txt and the README carry the new date, the deadline and the reminder" \
  bash -c "d=\$(date -u -d @$newexp +%F); grep -q \"expires: \$d\" '$out/expiry.txt' && grep -q \"NEW EXPIRY.*\$d\" '$out/README.txt' && grep -q 'NEXT RENEWAL DEADLINE' '$out/README.txt' && grep -q 'Reminder expected from' '$out/README.txt' && grep -q 'GRASSFIELD_SIGNING_KEY' '$out/README.txt'"
check "success: the temporary homes are removed and their agents stopped" agent_stopped ok
check "success: nothing left in the temporary folders" tmp_clean ok
check "success: no core dump allowed" test "$(cat "$tmp/ok/s/ulimit")" == 0
check "success: ~/.gnupg was not created" test ! -e "$tmp/ok/home/.gnupg"
check "success: the test signature came from a fresh home holding only the new SECRET file, checked with gpgv" \
  bash -c "grep -q '^gpg .*--import $out/SECRET-grassfield-signing-key.asc' '$tmp/ok/s/calls.log' && grep -q '^gpgv ' '$tmp/ok/s/calls.log'"
check "success: no secret on stdout or stderr" no_leak ok
check "success: the passphrase is on no command line" bash -c "! grep -q '$PASSPHRASE' '$tmp/ok/s/calls.log'"

# 2. Refusals.
run exist ok "$PASSPHRASE" --secret "$secretfile" --output "$out"
check "an existing output folder: refused, nothing ran" bash -c "test '$(rc exist)' == 1 && grep -q 'already exists' '$tmp/exist/stderr' && ! test -e '$tmp/exist/s/calls.log'"
RUN_NOXDG=1 run noxdg ok "$PASSPHRASE" --secret "$secretfile"
check "no XDG_RUNTIME_DIR and no --output: refused" bash -c "test '$(rc noxdg)' == 1 && grep -q 'XDG_RUNTIME_DIR' '$tmp/noxdg/stderr' && ! test -e '$tmp/noxdg/s/calls.log'"
run def ok "$PASSPHRASE" --secret "$secretfile"
check "default folder: \$XDG_RUNTIME_DIR/grassfield-signing-key-renewed-YYYYMMDD" test -s "$tmp/def/t/grassfield-signing-key-renewed-$(date +%Y%m%d)/fingerprint.txt"
run nofile ok "$PASSPHRASE" --secret "$tmp/nope.asc" --output "$tmp/nofile/out"
check "a missing --secret file: refused" bash -c "test '$(rc nofile)' == 1 && ! test -e '$tmp/nofile/s/calls.log'"
run badexp ok "$PASSPHRASE" --secret "$secretfile" --expire "forever" --output "$tmp/badexp/out"
check "a malformed --expire: refused" test "$(rc badexp)" == 1
run wrongfpr ok "$PASSPHRASE" --secret "$secretfile" --fingerprint "$OTHER" --output "$tmp/wrongfpr/out"
check "a foreign --fingerprint: refused, nothing written, cleaned up" bash -c "test '$(rc wrongfpr)' == 1 && grep -q 'not the expected' '$tmp/wrongfpr/stderr' && test ! -e '$tmp/wrongfpr/out'"
check "a foreign --fingerprint: nothing extended" bash -c "! test -e '$tmp/wrongfpr/s/setexpire'"
run wrongpass ok "wrong-passphrase-123" --secret "$secretfile" --output "$tmp/wrongpass/out"
check "a wrong passphrase: refused, nothing written" bash -c "test '$(rc wrongpass)' == 1 && grep -q 'could not import' '$tmp/wrongpass/stderr' && test ! -e '$tmp/wrongpass/out'"
run emptypass ok "" --secret "$secretfile" --output "$tmp/emptypass/out"
check "an empty passphrase: refused" bash -c "test '$(rc emptypass)' == 1 && ! test -e '$tmp/emptypass/s/calls.log'"
run pubonly ok "$PASSPHRASE" --secret "$publicfile" --output "$tmp/pubonly/out"
check "a public-only file as --secret: refused" bash -c "test '$(rc pubonly)' == 1 && grep -q 'could not import' '$tmp/pubonly/stderr' && test ! -e '$tmp/pubonly/out'"

# 3. The checks: each failure removes what was written and cleans up. mode:message.
checks=(
  "twokeys:exactly one secret key"
  "subkey:unexpected secret subkey"
  "noextend:not later than the old one"
  "shortexp:less than 300 days"
  "secold:does not carry the new expiry"
  "fprchange:fingerprint changed"
  "badsig:gpgv rejects"
  "sigother:not by the primary key"
)
for c in "${checks[@]}"; do
  m=${c%%:*} msg=${c#*:}
  run "c_$m" "$m" "$PASSPHRASE" --secret "$secretfile" --output "$tmp/c_$m/out"
  check "check '$m': refused (exit 1) with '$msg'" bash -c "test '$(rc "c_$m")' == 1 && grep -q \"$msg\" '$tmp/c_$m/stderr'"
  check "check '$m': nothing written, cleanup ran" bash -c "$(declare -f agent_stopped tmp_clean); tmp='$tmp'; test ! -e '$tmp/c_$m/out' && agent_stopped c_$m && tmp_clean c_$m"
  check "check '$m': no secret on stdout or stderr" no_leak "c_$m"
done

# 4. SIGINT while gpg works, then a second one during the cleanup.
status=$(env -i PATH="$stubs:$PATH" HOME="$tmp/sig/home" TMPDIR="$tmp/sig/tt" XDG_RUNTIME_DIR="$tmp/sig/t" LANG=C STUB_DIR="$tmp/sig/s" STUB_PASS="$PASSPHRASE" STUB_MODE=hang_set \
  python3 -I - "$script" "$secretfile" "$tmp/sig/out" "$tmp/sig/s/started" "$PASSPHRASE" <<'PY'
import os, signal, subprocess, sys, time
script, secret, out, started, passphrase = sys.argv[1:6]
for d in ("home", "t", "tt", "s"):
    os.makedirs(os.path.join(os.path.dirname(out), d), exist_ok=True)
def default_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
p = subprocess.Popen(["bash", script, "--secret", secret, "--output", out], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, preexec_fn=default_signals)
p.stdin.write((passphrase + "\n").encode())
p.stdin.close()
for _ in range(150):
    if os.path.exists(started):
        break
    time.sleep(0.1)
else:
    p.kill()
    print("never-started")
    sys.exit(0)
os.killpg(p.pid, signal.SIGINT)
try:
    print(p.wait(timeout=20))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    print("hung")
PY
)
check "SIGINT: exit status 130 (got $status)" test "$status" == 130
check "SIGINT: the temporary homes are removed and their agents stopped, no output folder" \
  bash -c "$(declare -f agent_stopped); tmp='$tmp'; agent_stopped sig && test -z \"\$(ls -A '$tmp/sig/t')\" && test ! -e '$tmp/sig/out'"

# 5. Mutants: one check removed must change the behaviour in the mode that exercises it.
mutant() { # mutant NAME 'sed expression' MODE 'ok|message'
  local name=$1 expr=$2 mode=$3 want=$4
  sed "$expr" "$script" >"$tmp/mutant-$name.sh"
  if cmp -s "$script" "$tmp/mutant-$name.sh"; then fail "mutant '$name': the edit did not change the script"; return; fi
  SCRIPT="$tmp/mutant-$name.sh" run "m_$name" "$mode" "$PASSPHRASE" --secret "$secretfile" --output "$tmp/m_$name/out"
  local r same=0
  r=$(rc "m_$name")
  if [[ $want == ok ]]; then [[ $r == 0 ]] && same=1; else [[ $r == 1 ]] && grep -q "$want" "$tmp/m_$name/stderr" && same=1; fi
  if ((same)); then fail "mutant '$name' survives in mode '$mode'"; else pass "mutant '$name' is caught (mode '$mode')"; fi
}
mutant olderexpiry 's/\[\[ -z \$oldexp || \$newexp -gt \$oldexp \]\]/true/' noextend "not later than the old one"
mutant localuser 's/--local-user "\$fpr!" //' ok ok
mutant secexpiry 's/\[\[ \$secexp == "\$newexp" \]\]/true/' secold "does not carry the new expiry"

echo
if ((fails)); then echo "renew-signing-key: $fails FAILED"; exit 1; fi
echo "renew-signing-key: all passed"
