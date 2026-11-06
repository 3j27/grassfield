#!/usr/bin/env bash
# The staged rollout's root half (ADR-0050 1-2): the root library's wariness (drawn once, kept, redrawn when damaged; a
# link, a state folder that is a link or another user's refused on read and write), the cohort mapping at its bounds, the
# marker read (0 listed, 1 a listing without it, 2 no listing), the scriptlet's enrollment rule gf_rollout (only a file that
# is exactly one of this build's forms; plain -> cohort keeps the synced files, cohort -> plain and a cohort change keep them
# and set their time to the epoch, never delete them: GF-045 inside omarchy update; no listing or no wariness changes
# nothing), gf_migrate of a previous base (the same synced-file rule), and the templates generate.py writes. Run on a copy of
# packaging/pacman/grassfield-channel.sh whose paths point at a temporary tree; `pacman -Sl` is a stub. Nothing here touches
# pacman or the system (as root it also makes a state folder owned by another user, inside its own temporary tree).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/rollout-root.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: got '$2', want '$3'"; }

T=$tmp/tree
mkdir -p "$T/data" "$T/etc/pacman.d" "$T/db/sync" "$tmp/bin"
BASE=https://packages.grassfield.site
cat >"$T/data/r.conf" <<EOF
GRASSFIELD_REPO_BASE=$BASE
GRASSFIELD_REPO_MIRRORS=https://mirror.example.org/gf
GRASSFIELD_REPO_BASE_PREVIOUS=https://old.example.org
GRASSFIELD_SIGNING_FINGERPRINT=
EOF
: >"$T/data/k.asc"

echo "== generate.py writes the cohort templates"
python3 -I "$root/packaging/pacman/generate.py" --conf "$T/data/r.conf" --key "$T/data/k.asc" --out "$T/data/pacman" >/dev/null
expect "generate.py exit" "$?" 0
expect "stable cohort template: cohort lines for each base, then the plain lines" \
  "$(grep '^Server' "$T/data/pacman/grassfield-stable-cohort.conf" | tr '\n' '|')" \
  "Server = $BASE/stable/cohort/@COHORT@/\$arch|Server = https://mirror.example.org/gf/stable/cohort/@COHORT@/\$arch|Server = $BASE/stable/\$arch|Server = https://mirror.example.org/gf/stable/\$arch|"
expect "beta cohort template exists and requires signatures" "$(grep -c '^SigLevel = Required$' "$T/data/pacman/grassfield-beta-cohort.conf")" 1
expect "the plain template is unchanged" "$(grep '^Server' "$T/data/pacman/grassfield-stable.conf" | tr '\n' '|')" \
  "Server = $BASE/stable/\$arch|Server = https://mirror.example.org/gf/stable/\$arch|"

# The library, pointed at the tree. The pacman stub answers -Sl grassfield: with $SL's content when that file exists, with
# nothing and exit 0 when $SL.nodb exists (libalpm with no synced grassfield.db: a missing database, -Sl prints nothing),
# by failing when $SL.fail exists (pacman broken), and, when $SL.big
# exists, by writing the marker then 20000 lines itself (its own process gets any SIGPIPE).
sed -e "s#^GF_CONF=.*#GF_CONF=$T/etc/pacman.d/grassfield.conf#" -e "s#^GF_DATA=.*#GF_DATA=$T/data/pacman#" \
  -e "s#^GF_STATE_DIR=.*#GF_STATE_DIR=$T/state#" -e "s#^GF_PACMAN_CONF=.*#GF_PACMAN_CONF=$T/etc/pacman.conf#" \
  "$root/packaging/pacman/grassfield-channel.sh" >"$tmp/lib.sh"
# mktemp in /etc/pacman.d is the library's own path: point it at the tree too.
sed -i "s#/etc/pacman.d/.grassfield.conf.XXXXXX#$T/etc/pacman.d/.grassfield.conf.XXXXXX#g" "$tmp/lib.sh"
cat >"$tmp/bin/pacman" <<'SH'
#!/bin/sh
[ "$*" = "-Sl grassfield" ] || exit 1
[ -e "$SL.fail" ] && { echo "error: failed to initialize alpm library" >&2; exit 1; }
[ -e "$SL.nodb" ] && exit 0
if [ -e "$SL.big" ]; then
  echo "grassfield grassfield-rollout 1-1"
  i=0
  while [ $i -lt 20000 ]; do echo "grassfield grassfield-pkg$i 1.0-1" || exit 141; i=$((i + 1)); done
  exit 0
fi
[ -f "$SL" ] && { cat "$SL"; exit 0; }
exit 1
SH
chmod +x "$tmp/bin/pacman"
export SL=$tmp/sl
lib() { # a function call in a subshell with the library loaded (GF_DBPATH is the tree's)
  (
    PATH=$tmp/bin:/usr/bin:/bin
    GF_PROG=test
    set -uo pipefail # as gf_start sets them
    . "$tmp/lib.sh"
    gf_load() { GF_BASE=$BASE GF_FPR='' GF_PREVIOUS=(https://old.example.org); }
    gf_load
    GF_DBPATH=$T/db
    "$@"
  )
}
primary() { lib gf_primary; }
# pacman's synced [grassfield] files, as pacman leaves them after a sync (a recent time).
synced() { rm -f "$T/db/sync/"grassfield.*; touch "$T/db/sync/grassfield.db" "$T/db/sync/grassfield.db.sig" "$T/db/sync/grassfield.files"; }
# What became of them: dropped (any one missing), refetch (all kept, their time the epoch: the next sync downloads the
# database and its signature again), kept (all kept as they were).
syncstate() {
  local f t out=kept
  for f in grassfield.db grassfield.db.sig grassfield.files; do
    [[ -f $T/db/sync/$f ]] || { echo dropped; return; }
    t=$(stat -c %Y "$T/db/sync/$f")
    if ((t == 0)); then out=refetch; elif [[ $out == refetch ]]; then out=mixed; fi
  done
  echo "$out"
}
conf() { cp "$T/data/pacman/grassfield-$1.conf" "$T/etc/pacman.d/grassfield.conf"; }
marker() { rm -f "$SL.fail" "$SL.big" "$SL.nodb"; printf 'grassfield grassfield-desktop 1.0.1-1 [installed]\ngrassfield grassfield-rollout 1-%s\n' "${1:-1}" >"$SL"; }
nomarker() { rm -f "$SL.fail" "$SL.big" "$SL.nodb"; printf 'grassfield grassfield-desktop 1.0.1-1 [installed]\n' >"$SL"; }

echo "== wariness: drawn once, kept, mapped to a cohort"
rm -rf "$T/state"
w1=$(lib gf_wariness)
expect "drawn: an integer below 2^32" "$([[ $w1 =~ ^[0-9]+$ ]] && ((w1 < 4294967296)) && echo ok)" ok
expect "stored root-only (0600) in its folder (0755)" "$(stat -c %a "$T/state/rollout-wariness"):$(stat -c %a "$T/state")" "600:755"
expect "kept: the second read is the same" "$(lib gf_wariness)" "$w1"
for pair in 0:00 214748364:00 214748365:01 2147483647:09 2147483648:10 4080218931:18 4080218932:19 4294967295:19; do
  printf '%s\n' "${pair%%:*}" >"$T/state/rollout-wariness"
  expect "cohort of ${pair%%:*}" "$(lib gf_cohort)" "${pair##*:}"
done
for bad in "" "x" "4294967296" "-1" "12345678901" "1 2"; do
  printf '%s\n' "$bad" >"$T/state/rollout-wariness"
  w=$(lib gf_wariness)
  expect "a damaged value '$bad' is drawn again and stored" "$([[ $w =~ ^[0-9]+$ ]] && ((w < 4294967296)) && [[ $(cat "$T/state/rollout-wariness") == "$w" ]] && echo ok)" ok
done
rm -f "$T/state/rollout-wariness"
printf '7\n' >"$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$T/state/rollout-wariness"
out=$(lib gf_wariness 2>/dev/null)
expect "a link to a valid file in its place is refused (exit 1), neither read nor written" \
  "$?:$out:$(cat "$tmp/elsewhere")" "1::7"
rm -f "$T/state/rollout-wariness"
# The folder itself: a link to a folder holding a valid wariness, and a folder another user owns, are refused on read too.
rm -rf "$T/state" "$tmp/otherstate"
mkdir -p "$tmp/otherstate"
printf '2147483648\n' >"$tmp/otherstate/rollout-wariness"
ln -s "$tmp/otherstate" "$T/state"
out=$(lib gf_wariness 2>/dev/null)
expect "the state folder a link: refused on read (exit 1, nothing printed)" "$?:$out" "1:"
lib gf_forget_wariness 2>/dev/null
expect "  and gf_forget_wariness deletes nothing through it" "$?:$(cat "$tmp/otherstate/rollout-wariness")" "1:2147483648"
rm -f "$T/state"
if ((EUID == 0)); then
  mkdir -p "$T/state"
  printf '2147483648\n' >"$T/state/rollout-wariness"
  chown 65534 "$T/state"
  out=$(lib gf_wariness 2>/dev/null)
  expect "the state folder owned by another user: refused on read (exit 1)" "$?:$out" "1:"
  chown 0 "$T/state"
else
  pass "SKIP the state folder owned by another user (needs root to make one)"
fi
rm -rf "$T/state"
mkdir -p "$T/state"
printf '5\n' >"$T/state/rollout-wariness"
: >"$T/state/.rollout-wariness.abc123"
lib gf_forget_wariness
expect "forget: the file, a left temporary file and the empty folder go" "$?:$([[ -e $T/state ]] && echo left || echo gone)" "0:gone"
lib gf_forget_wariness
expect "forget with nothing left: exit 0" "$?" 0

echo "== gf_cohort_of reads only this build's cohort form"
expect "cohort form" "$(lib gf_cohort_of "$BASE/stable/cohort/07/\$arch" "$BASE/stable")" 07
lib gf_cohort_of "$BASE/stable/cohort/20/\$arch" "$BASE/stable" >/dev/null
expect "cohort 20 is out of range" "$?" 1
lib gf_cohort_of "$BASE/stable/cohort/7/\$arch" "$BASE/stable" >/dev/null
expect "one digit is not the form" "$?" 1
lib gf_cohort_of "$BASE/beta/cohort/07/\$arch" "$BASE/stable" >/dev/null
expect "another channel is not this one's" "$?" 1
lib gf_cohort_of "$BASE/stable/cohort/07/x86_64" "$BASE/stable" >/dev/null
expect "not pacman's \$arch" "$?" 1

echo "== gf_rollout_advertised: 0 marker, 1 a listing without it, 2 no listing"
marker
lib gf_rollout_advertised
expect "marker 1-1 listed" "$?" 0
marker 0
lib gf_rollout_advertised
expect "marker 1-0 (pkgrel 0) is not the marker" "$?" 1
printf 'grassfield grassfield-rollout 2-1\n' >"$SL"
lib gf_rollout_advertised
expect "marker of another scheme (2-1)" "$?" 1
touch "$SL.nodb"
lib gf_rollout_advertised
expect "no synced database (pacman prints nothing, exit 0): no listing" "$?" 2
rm -f "$SL.nodb"
touch "$SL.fail"
lib gf_rollout_advertised
expect "pacman fails" "$?" 2
rm -f "$SL.fail"
touch "$SL.big"
lib gf_rollout_advertised
expect "a long listing written by pacman's own process, marker first: read whole, no SIGPIPE under pipefail" "$?" 0
rm -f "$SL.big"

echo "== gf_rollout: enrollment at the scriptlet's upgrade"
rm -rf "$T/state"
mkdir -p "$T/state"
printf '2147483648\n' >"$T/state/rollout-wariness" # cohort 10
conf stable
synced
nomarker
lib gf_rollout
expect "no marker, plain: the plain form stays, synced files kept" "$(primary):$(syncstate)" "$BASE/stable/\$arch:kept"
marker
lib gf_rollout
expect "marker: plain -> the cohort form with this machine's cohort; the synced files kept, marked for a new download" \
  "$(primary):$(syncstate)" "$BASE/stable/cohort/10/\$arch:refetch"
expect "the mirror's cohort line, then the plain lines" "$(grep -c '^Server' "$T/etc/pacman.d/grassfield.conf"):$(grep -c '@COHORT@' "$T/etc/pacman.d/grassfield.conf")" "4:0"
expect "the file is 0644" "$(stat -c %a "$T/etc/pacman.d/grassfield.conf")" 644
synced
lib gf_rollout
expect "already in its cohort: untouched, synced files kept" "$(primary):$(syncstate)" "$BASE/stable/cohort/10/\$arch:kept"
touch "$SL.fail"
lib gf_rollout
expect "cohort form, pacman cannot list the database: the cohort form stays, synced files kept" "$(primary):$(syncstate)" \
  "$BASE/stable/cohort/10/\$arch:kept"
rm -f "$SL.fail"
touch "$SL.nodb"
lib gf_rollout
expect "cohort form, no synced database yet (an empty listing): the cohort form stays" "$(primary)" "$BASE/stable/cohort/10/\$arch"
rm -f "$SL.nodb"
marker
rm -rf "$T/state"
: >"$T/state" # a file where the folder should be: the wariness can be neither read nor made
lib gf_rollout 2>/dev/null
expect "cohort form, marker, no wariness possible (its folder a file): the file stays as it is" "$(primary):$(syncstate)" \
  "$BASE/stable/cohort/10/\$arch:kept"
rm -f "$T/state"
mkdir -p "$T/state"
printf '0\n' >"$T/state/rollout-wariness"
lib gf_rollout
expect "another cohort (a new wariness): rewritten, synced files kept and marked for a new download" \
  "$(primary):$(syncstate)" "$BASE/stable/cohort/00/\$arch:refetch"
synced
nomarker
lib gf_rollout
expect "the marker withdrawn (a listing without it): back to the plain form, synced files marked for a new download" \
  "$(primary):$(syncstate)" "$BASE/stable/\$arch:refetch"
conf beta
marker 3
lib gf_rollout
expect "beta enrolls in beta's cohort path" "$(primary)" "$BASE/beta/cohort/00/\$arch"
printf '# a comment\n\n%s\n' "$(cat "$T/etc/pacman.d/grassfield.conf")" >"$T/etc/pacman.d/grassfield.conf"
nomarker
lib gf_rollout
expect "comments and blank lines added by hand: still this build's form (back to plain)" "$(primary)" "$BASE/beta/\$arch"
printf 'SigLevel = Required\nServer = https://elsewhere.example/x/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
synced
marker
lib gf_rollout
expect "a custom file is left alone" "$(primary):$(syncstate)" "https://elsewhere.example/x/\$arch:kept"
conf stable
printf 'Server = https://admin.example/local/$arch\n' >>"$T/etc/pacman.d/grassfield.conf"
before=$(cat "$T/etc/pacman.d/grassfield.conf")
lib gf_rollout
expect "the plain form with a Server line an administrator added: left exactly as it is" \
  "$([[ $(cat "$T/etc/pacman.d/grassfield.conf") == "$before" ]] && echo same || echo rewritten):$(syncstate)" "same:kept"
conf stable
sed -i 's/^SigLevel = Required$/SigLevel = Never/' "$T/etc/pacman.d/grassfield.conf"
lib gf_rollout
expect "the plain form with its SigLevel changed: left alone" "$(primary):$(grep -c 'SigLevel = Never' "$T/etc/pacman.d/grassfield.conf")" "$BASE/stable/\$arch:1"
conf stable
lib gf_write_cohort stable 10
printf 'Server = https://admin.example/local/$arch\n' >>"$T/etc/pacman.d/grassfield.conf"
nomarker
lib gf_rollout
expect "the cohort form with an added Server line, marker withdrawn: left alone" "$(primary):$(grep -c admin.example "$T/etc/pacman.d/grassfield.conf")" \
  "$BASE/stable/cohort/10/\$arch:1"
rm -f "$T/etc/pacman.d/grassfield.conf"
lib gf_rollout
expect "no file (off): nothing written" "$([[ -e $T/etc/pacman.d/grassfield.conf ]] && echo written || echo none)" none

echo "== gf_migrate: a previous base's cohort form goes to this build's plain form, the synced files kept"
printf 'SigLevel = Required\nServer = https://old.example.org/beta/cohort/04/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
synced
lib gf_migrate
expect "migrated to this base's plain beta; synced files kept and marked for a new download" "$(primary):$(syncstate)" \
  "$BASE/beta/\$arch:refetch"
printf 'SigLevel = Required\nServer = https://old.example.org/stable/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
synced
lib gf_migrate
expect "a previous base's plain form: the same" "$(primary):$(syncstate)" "$BASE/stable/\$arch:refetch"
synced
rm -f "$T/db/sync/grassfield.files"
ln -s "$tmp/elsewhere" "$T/db/sync/grassfield.files"
touch -d '2026-01-01' "$tmp/elsewhere"
printf 'SigLevel = Required\nServer = https://old.example.org/stable/$arch\n' >"$T/etc/pacman.d/grassfield.conf"
lib gf_migrate
expect "a link among the synced files is not followed" "$(stat -c %Y "$tmp/elsewhere")" "$(date -d '2026-01-01' +%s)"
rm -f "$T/db/sync/grassfield.files"

echo "== the scriptlet runs gf_rollout after gf_migrate, and remove forgets the wariness; nothing in them deletes synced files"
grep -A3 '^  1:upgrade)' "$root/packaging/pacman/grassfield-channel-scriptlet" | tr -d ' ' | tr '\n' '|' | grep -q 'gf_migrate|gf_rollout' &&
  pass "upgrade: gf_migrate then gf_rollout" || fail "upgrade does not run gf_rollout after gf_migrate"
grep -A3 '^  1:remove)' "$root/packaging/pacman/grassfield-channel-scriptlet" | grep -q 'gf_forget_wariness' &&
  pass "remove: gf_forget_wariness" || fail "remove keeps the wariness"
body=$(lib declare -f gf_refetch_synced)
[[ $body == *"touch -h -c -d @0 --"* ]] && pass "gf_refetch_synced touches with -h (never through a link)" ||
  fail "gf_refetch_synced's touch may follow a link"
for fn in gf_migrate gf_rollout; do
  body=$(lib declare -f "$fn")
  [[ $body != *gf_drop_synced* ]] && pass "$fn never calls gf_drop_synced (it runs inside omarchy update: GF-045)" ||
    fail "$fn deletes the synced files inside the transaction"
done
grep -q 'gf_rollout\|gf_cohort\|gf_wariness' "$root/packaging/pacman/grassfield-channel-helper" &&
  fail "the polkit helper enrolls (only the scriptlet may)" || pass "the polkit helper does not enroll"

((fails == 0)) && { echo "PASS: staged rollout (root)"; exit 0; }
echo "FAIL: staged rollout (root) ($fails)"
exit 1
