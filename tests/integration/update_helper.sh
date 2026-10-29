#!/usr/bin/env bash
# Software Update, step 3: grassfield-update-helper, its polkit action and grassfield-update-run in a throwaway Arch
# container (ADR-0033 "Step 3", owner decision SU-M1; docs/specs/updates.md U24-U30). Never on a real machine: inside, it
# refuses to run unless it is root in a container with the repository mounted at /src and an Omarchy 4.0.4 tree at /omarchy.
#
#   tests/integration/update_helper.sh [--omarchy DIR]
#     DIR  an Omarchy 4.0.4 tree (default /usr/share/omarchy): its omarchy-migrate, omarchy-hook, omarchy-update-mise and
#          its update guard (the hook and its program) go into the test's omarchy package, unchanged
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository and the tree mounted
#   read-only; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside the container: Arch's mirrors bring the system up to date and polkit; Omarchy's public key is fetched from
# keys.openpgp.org and signed locally, as omarchy-update-keyring's bootstrap does (the helper only checks it is there).
# Then pacman's configuration names one local repository only, [gutest] (file://, made here with bsdtar and repo-add): small
# packages standing for Grassfield, the toolkit the compatibility check tracks, Omarchy (its real migration commands and
# update guard, test migrations and commands) and apps. The REAL helper, runner and policy are installed at the PKGBUILD's
# paths. Most cases run the helper as root directly, the way pkexec leaves it; real polkitd and pkexec run it for alice
# (wheel, a throwaway password, auth_admin) and refuse bob; carol runs the runner, which polkit lets through without a
# password here (a container has no agent to show the dialog; the dialog is the owner's L2). Not covered here: the
# transient systemd unit (no systemd in a container), snapper and paccache (not installed: the snapshot is `none`), the
# free-space and battery refusals (the container's / and power supplies are the host's).
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  omarchy=/usr/share/omarchy
  while (($#)); do
    case $1 in
      --omarchy) omarchy=${2:?}; shift ;;
      *) echo "usage: update_helper.sh [--omarchy DIR]" >&2; exit 2 ;;
    esac
    shift
  done
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  [[ -f $omarchy/bin/omarchy-migrate && -f $omarchy/default/libalpm/hooks/00-omarchy-update-guard.hook ]] ||
    { echo "SKIP: no Omarchy 4.0.4 tree at $omarchy (--omarchy DIR)"; exit 0; }
  args=(--rm --network host -v "$root:/src:ro" -v "$(realpath "$omarchy"):/omarchy:ro")
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && args+=(-e "$v"); done
  exec docker run "${args[@]}" "$IMAGE" bash /src/tests/integration/update_helper.sh --inside
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/pacman/grassfield-update-helper && -d /omarchy/bin ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src, /omarchy)"; exit 2; }

W=/work
mkdir -p "$W" && chmod 1777 "$W"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
as() { local u=$1; shift; runuser -u "$u" -- env HOME="/home/$u" "$@"; }
quiet() { "$@" >>"$W/log" 2>&1; }
H=/usr/lib/grassfield/grassfield-update-helper
R=/usr/lib/grassfield/grassfield-update-run
D=/run/grassfield-update
FPR=40DFB630FF42BCFFB047046CF0134EE680CAC571
newop() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
# The helper as pkexec leaves it: root, an environment of pkexec's (which it drops), no terminal, stdin and stdout a pipe.
helper() { env -i PATH=/usr/sbin:/usr/bin SHELL=/bin/bash USER=root LOGNAME=root HOME=/root PKEXEC_UID=1001 "$H" "$@" </dev/null 2>&1 | cat; return "${PIPESTATUS[0]}"; }
ver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2; }
exitfile() { tr '\n' '|' <"$D/$1.exit" 2>/dev/null; }
has() { grep -qx -- "$2" "$D/$1.exit" 2>/dev/null; }
syncsum() { sha256sum /var/lib/pacman/sync/gutest.db 2>/dev/null | cut -d' ' -f1; }
run_helper() { op=$(newop); helper run "$op" "$@" >/dev/null; rc=$?; }

say "setup: Arch's mirrors, the system up to date, polkit; Omarchy's key; the real helper, runner and policy"
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm polkit python || { echo "FAIL: pacman -Syu polkit python (see $W/log)"; tail -5 "$W/log"; exit 1; }
quiet pacman -Sw --noconfirm archlinux-keyring || { echo "FAIL: the Arch keyring's package file"; exit 1; }
pacman -Q pacman polkit archlinux-keyring | tr '\n' ' '; echo
curl -fsS "https://keys.openpgp.org/vks/v1/by-fingerprint/$FPR" -o "$W/omarchy.asc" && quiet pacman-key --add "$W/omarchy.asc" &&
  quiet pacman-key --lsign-key "$FPR" || { echo "FAIL: Omarchy's public key from keys.openpgp.org (see $W/log)"; exit 1; }
install -Dm755 /src/packaging/pacman/grassfield-update-helper "$H"
install -Dm755 /src/packaging/bin/grassfield-update-run "$R"
install -Dm644 /src/packaging/pacman/org.grassfield.packages.policy /usr/share/polkit-1/actions/org.grassfield.packages.policy
useradd -m alice && useradd -m bob && useradd -m carol
usermod -aG wheel alice && echo 'alice:test-only-password' | chpasswd
mkdir -p /run/dbus && dbus-daemon --system --fork
/usr/lib/polkit-1/polkitd --no-debug >"$W/polkitd.log" 2>&1 &
# A container has no logind session, so polkit would apply allow_any (no) to everyone: alice gets what an active local
# session gets from the policy (an administrator's password); carol, whose runner has no agent to ask through, is let
# through; bob gets nothing.
cat >/etc/polkit-1/rules.d/50-grassfield-test.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id != "org.grassfield.packages.update-system") return polkit.Result.NOT_HANDLED;
  if (subject.user == "alice") return polkit.Result.AUTH_ADMIN;
  if (subject.user == "carol") return polkit.Result.YES;
  return polkit.Result.NOT_HANDLED;
});
EOF
cp /var/cache/pacman/pkg/archlinux-keyring-"$(ver archlinux-keyring)"-any.pkg.tar.zst "$W/keyring.pkg.tar.zst" ||
  { echo "FAIL: the installed archlinux-keyring's package file is not in the cache"; exit 1; }
sleep 2

say "the test packages"
mkdir -p "$W/pkgs" "$W/repo"
# mkpkg name version [.PKGINFO line | path=content | path:<file to copy>]...
mkpkg() {
  local name=$1 ver=$2 dir="$W/build/$1-$2" arg path
  shift 2
  rm -rf "$dir" && mkdir -p "$dir/usr/share/doc/$name"
  echo "$name $ver" >"$dir/usr/share/doc/$name/README"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s-1\npkgdesc = update helper test\nurl = https://example.invalid\n' "$name" "$name" "$ver"
    printf 'builddate = 1700000000\npackager = test\nsize = 1\narch = any\nlicense = MIT\n'
    for arg in "$@"; do [[ $arg == *' = '* ]] && printf '%s\n' "$arg"; done
  } >"$dir/.PKGINFO"
  for arg in "$@"; do
    [[ $arg == *' = '* ]] && continue
    if [[ $arg == *:* && $arg != *=* ]]; then
      path=${arg%%:*}; mkdir -p "$dir/${path%/*}"; cp "${arg#*:}" "$dir/$path"
    else
      path=${arg%%=*}; mkdir -p "$dir/${path%/*}"; printf '%s\n' "${arg#*=}" >"$dir/$path"
    fi
  done
  chmod -R a+rX "$dir"
  find "$dir/usr/share/omarchy/bin" "$dir/usr/bin" -type f -exec chmod 755 {} + 2>/dev/null
  (cd "$dir" && bsdtar --zstd -cf "$W/pkgs/$name-$ver-1-any.pkg.tar.zst" .PKGINFO usr) || { echo "FAIL: mkpkg $name"; exit 1; }
}
record() { # qt quickshell hyprland aquamarine kcoreaddons -> the content of a BUILD-DEPS
  printf 'qt6-base %s\nquickshell %s\nhyprland %s\naquamarine %s\nkcoreaddons %s' "$@"
}
mkpkg grassfield-desktop 1 "usr/share/grassfield/BUILD-DEPS=$(record 6.11.0-1 0.3.1-1 0.56.0-1 0.9.0-1 6.29.0-1)"
mkpkg grassfield-desktop 2 "usr/share/grassfield/BUILD-DEPS=$(record 6.12.0-1 0.3.1-1 0.56.0-1 0.9.0-1 6.29.0-1)"
mkpkg grassfield-desktop 3
mkpkg qt6-base 6.11.0
mkpkg qt6-base 6.12.0
mkpkg quickshell 0.3.1
mkpkg quickshell 0.3.2
mkpkg hyprland 0.56.0
mkpkg hyprland 0.56.1
mkpkg aquamarine 0.9.0
mkpkg kcoreaddons 6.29.0
mkpkg omarchy-keyring 1
mkpkg gu-app 1
mkpkg gu-app 2
mkpkg gu-app 3
mkpkg gu-app 4 "conflict = gu-other"
mkpkg gu-app 5
mkpkg gu-other 1
mkpkg gu-file 1
mkpkg gu-file 2 "usr/share/gu-stray/file=stray"
# Omarchy: its real migration and hook commands and update guard; test commands (one with sudo, one that calls it, one
# plain); test migrations (100 plain, 150 asks with gum; 200 calls the indirect command; 300 plain).
omarchy_files=(
  usr/share/omarchy/bin/omarchy-migrate:/omarchy/bin/omarchy-migrate
  usr/share/omarchy/bin/omarchy-hook:/omarchy/bin/omarchy-hook
  usr/share/omarchy/bin/omarchy-update-mise:/omarchy/bin/omarchy-update-mise
  usr/share/omarchy/bin/omarchy-update-pacman-guard:/omarchy/bin/omarchy-update-pacman-guard
  usr/bin/omarchy-update-pacman-guard:/omarchy/bin/omarchy-update-pacman-guard
  usr/share/libalpm/hooks/00-omarchy-update-guard.hook:/omarchy/default/libalpm/hooks/00-omarchy-update-guard.hook
  "usr/share/omarchy/bin/omarchy-gu-sudo=#!/bin/bash
sudo true"
  "usr/share/omarchy/bin/omarchy-gu-indirect=#!/bin/bash
omarchy-gu-sudo"
  "usr/share/omarchy/bin/omarchy-gu-plain=#!/bin/bash
echo plain"
  "usr/share/omarchy/bin/omarchy-notification-dismiss=#!/bin/bash
true"
  "usr/share/omarchy/migrations/100.sh=echo 100 >>\"\$HOME/migrations.log\""
  "usr/share/omarchy/migrations/150.sh=gum confirm 'Continue?' && echo 150 >>\"\$HOME/migrations.log\""
  "usr/share/omarchy/version=4.0.4"
)
mkpkg omarchy 1 "${omarchy_files[@]}"
mkpkg omarchy 2 "${omarchy_files[@]}" "usr/share/omarchy/migrations/200.sh=omarchy-gu-indirect"
mkpkg omarchy 3 "${omarchy_files[@]}" "usr/share/omarchy/migrations/300.sh=omarchy-gu-plain >/dev/null; echo 300 >>\"\$HOME/migrations.log\""

# publish package-file... : [gutest] holds exactly these (and the installed Arch keyring, which --needed skips).
publish() {
  rm -f "$W/repo"/*
  cp "$W/keyring.pkg.tar.zst" "$W/repo/archlinux-keyring-$(ver archlinux-keyring)-any.pkg.tar.zst"
  local p
  for p in "$@"; do cp "$W/pkgs/$p-1-any.pkg.tar.zst" "$W/repo/"; done
  quiet repo-add -q "$W/repo/gutest.db.tar.gz" "$W/repo"/*.pkg.tar.zst
  touch -d "@$(( $(date +%s) + ${publish_n:=0} ))" "$W/repo/gutest.db.tar.gz" "$W/repo/gutest.db"
  publish_n=$((publish_n + 1))
}
base=(grassfield-desktop-1 qt6-base-6.11.0 quickshell-0.3.1 hyprland-0.56.0 aquamarine-0.9.0 kcoreaddons-6.29.0
  omarchy-keyring-1 omarchy-1 gu-app-1 gu-other-1 gu-file-1)
publish "${base[@]}"
cat >/etc/pacman.conf <<EOF
[options]
Architecture = auto
CheckSpace
DownloadUser = alpm
DisableSandbox
HoldPkg = pacman glibc
[gutest]
SigLevel = Optional TrustAll
Server = file://$W/repo
EOF
quiet pacman -Syy
quiet pacman -S --noconfirm grassfield-desktop qt6-base quickshell hyprland aquamarine kcoreaddons omarchy-keyring omarchy gu-app gu-other gu-file ||
  { echo "FAIL: installing the base set (see $W/log)"; tail -5 "$W/log"; exit 1; }
expect "the base set installed (omarchy 1, grassfield-desktop 1, qt6-base 6.11.0)" test "$(ver omarchy):$(ver grassfield-desktop):$(ver qt6-base)" == "1-1:1-1:6.11.0-1"
expect "Omarchy's update guard is installed (its hook and program)" test -f /usr/share/libalpm/hooks/00-omarchy-update-guard.hook

say "policy"
pk=$(pkaction --verbose --action-id org.grassfield.packages.update-system 2>&1)
expect "pkaction: implicit any no, inactive no, active auth_admin (never kept)" bash -c "grep -q 'implicit any: *no' <<<\"\$1\" && grep -q 'implicit inactive: *no' <<<\"\$1\" && grep -q 'implicit active: *auth_admin\$' <<<\"\$1\"" _ "$pk"
expect "pkaction: the program is the helper" grep -q "org.freedesktop.policykit.exec.path -> $H" <<<"$pk"

say "usage and privilege"
helper >/dev/null; rc=$?; expect "no argument -> exit 2" test "$rc" == 2
helper install "$(newop)" >/dev/null; rc=$?; expect "a verb other than run -> exit 2" test "$rc" == 2
helper run 0123 >/dev/null; rc=$?; expect "a short operation id -> exit 2" test "$rc" == 2
helper run "$(newop | tr a-f A-F)" >/dev/null; rc=$?; expect "an upper-case operation id -> exit 2" test "$rc" == 2
for bad in 100 x.sh '../1.sh' '1.sh;true' "$(printf '%021d' 1).sh"; do
  helper run "$(newop)" "$bad" >/dev/null; rc=$?; expect "a bad migration name ($bad) -> exit 2" test "$rc" == 2
done
names=(); for i in $(seq 1 65); do names+=("$i.sh"); done
helper run "$(newop)" "${names[@]}" >/dev/null; rc=$?; expect "65 migration names -> exit 2" test "$rc" == 2
expect "a refused argument vector writes nothing" test "$(find "$D" -type f 2>/dev/null | wc -l)" == 0
out=$(as alice "$H" run "$(newop)" 2>&1); rc=$?
expect "the helper run by a user without pkexec -> exit 2, no message on its pipe" test "$rc:$out" == "2:"

say "up to date, and what it writes"
sum=$(syncsum)
run_helper
expect "nothing to update -> exit 0, packages 0" test "$rc:$(exitfile "$op")" == "0:0|packages 0|"
expect "$D is root's, 0755; the log 0644; last names the operation" test "$(stat -c %u:%a "$D"):$(stat -c %a "$D/$op.log"):$(cat "$D/last")" == "0:755:644:$op"
expect "the started file: a pid and a start time" grep -Eq '^[0-9]+ [0-9]+$' "$D/$op.started"
expect "the system's sync database is untouched (the plan came from a copy)" test "$(syncsum)" == "$sum"
expect "no temporary folder is left" test -z "$(find "$D" -mindepth 1 -maxdepth 1 -type d)"
helper run "$op" >/dev/null; rc=$?
expect "the same operation id again -> exit 2, its exit file unchanged" test "$rc:$(exitfile "$op")" == "2:0|packages 0|"
# A hostile environment reaches nothing: BASH_ENV, a PATH with a fake pacman.
mkdir -p "$W/evil" && printf '#!/bin/bash\ntouch %s/evil-ran\n' "$W" >"$W/evil/pacman" && chmod 755 "$W/evil/pacman"
printf 'touch %s/bashenv-ran\n' "$W" >"$W/evil.sh"
op=$(newop); env BASH_ENV="$W/evil.sh" PATH="$W/evil:/usr/bin" "$H" run "$op" </dev/null >/dev/null 2>&1; rc=$?
expect "a hostile environment (BASH_ENV, PATH) is dropped -> exit 0, neither ran" test "$rc:$(ls "$W"/evil-ran "$W"/bashenv-ran 2>/dev/null | wc -l)" == "0:0"

say "busy, keyring"
touch /var/lib/pacman/db.lck; run_helper; rm -f /var/lib/pacman/db.lck
expect "pacman's db.lck present -> exit 3" test "$rc:$(exitfile "$op")" == "3:3|"
(flock -x 8; sleep 5) 8<"$D/helper.lock" & sleep 0.5; run_helper; wait $!
expect "another run holds the helper's lock -> exit 3" test "$rc" == 3
expect "helper.lock is root's, 0600" test "$(stat -c %u:%a "$D/helper.lock")" == "0:600"
publish "${base[@]/gu-app-1/gu-app-2}"
quiet pacman -Rdd --noconfirm omarchy-keyring; run_helper
expect "omarchy-keyring not installed -> exit 7, needs keyring, gu-app stays 1" test "$rc:$(exitfile "$op"):$(ver gu-app)" == "7:7|needs keyring|:1-1"
quiet pacman -S --noconfirm omarchy-keyring
quiet pacman-key --delete "$FPR"; run_helper
expect "Omarchy's key not in pacman's keyring -> exit 7, needs keyring" test "$rc:$(exitfile "$op")" == "7:7|needs keyring|"
quiet pacman-key --add "$W/omarchy.asc"; quiet pacman-key --lsign-key "$FPR"

say "Omarchy's guard, then an update through the helper"
quiet pacman -Sy
LC_ALL=C pacman -Su --noconfirm >"$W/guard.out" 2>&1; rc=$?
expect "a plain pacman -Su is stopped by Omarchy's guard (exit $rc), gu-app stays 1" bash -c "test $rc != 0 && grep -q 'Woah partner' $W/guard.out && test '$(ver gu-app)' == 1-1"
run_helper
expect "gu-app 1 -> 2 through the helper -> exit 0, installed" test "$rc:$(ver gu-app)" == "0:2-1"
expect "  its exit file: packages 1, snapshot none, restart kernel (the container runs no packaged kernel)" test "$(exitfile "$op")" == "0|snapshot none|packages 1|restart kernel|"
expect "  Omarchy's guard ran and let it through (OMARCHY_UPDATE_PACMAN=1)" grep -q 'Checking Omarchy update entrypoint' "$D/$op.log"
expect "  the log holds pacman's output; the progress ends at finishing" bash -c "grep -q '^upgrading gu-app' $D/$op.log && test \"\$(cat $D/$op.progress)\" == finishing"

say "the compatibility check (s3.4)"
sum=$(syncsum)
publish "${base[@]/qt6-base-6.11.0/qt6-base-6.12.0}"; run_helper
expect "qt6-base 6.11 -> 6.12 for a Grassfield built with 6.11 -> exit 6, incompatible qt6-base" test "$rc:$(exitfile "$op")" == "6:6|incompatible qt6-base|"
expect "  nothing changed: qt6-base 6.11.0, the system's sync database as before" test "$(ver qt6-base):$(syncsum)" == "6.11.0-1:$sum"
publish "${base[@]/qt6-base-6.11.0/qt6-base-6.12.0}" grassfield-desktop-2; run_helper
expect "with a Grassfield build for 6.12 in the repository -> exit 0, both in one transaction" test "$rc:$(ver qt6-base):$(ver grassfield-desktop)" == "0:6.12.0-1:2-1"
expect "  restart toolkit, log out for Grassfield" bash -c "grep -qx 'restart toolkit' $D/$op.exit && grep -qx 'logout grassfield' $D/$op.exit"
expect "  the record installed is the new build's" grep -q '^qt6-base 6.12.0-1$' /usr/share/grassfield/BUILD-DEPS
cur=(grassfield-desktop-2 qt6-base-6.12.0 quickshell-0.3.1 hyprland-0.56.0 aquamarine-0.9.0 kcoreaddons-6.29.0 omarchy-keyring-1 omarchy-1 gu-app-2 gu-other-1 gu-file-1)
publish "${cur[@]/hyprland-0.56.0/hyprland-0.56.1}"; run_helper
expect "hyprland 0.56.0 -> 0.56.1 (major.minor unchanged) -> exit 0, restart hyprland" bash -c "test $rc:$(ver hyprland) == 0:0.56.1-1 && grep -qx 'restart hyprland' $D/$op.exit"
cur=("${cur[@]/hyprland-0.56.0/hyprland-0.56.1}")
publish "${cur[@]/quickshell-0.3.1/quickshell-0.3.2}"; run_helper
expect "quickshell 0.3.1 -> 0.3.2 (compared whole) -> exit 6, incompatible quickshell" test "$rc:$(exitfile "$op"):$(ver quickshell)" == "6:6|incompatible quickshell|:0.3.1-1"
publish "${cur[@]/grassfield-desktop-2/grassfield-desktop-3}"; run_helper
expect "a Grassfield build without BUILD-DEPS -> exit 6 for every tracked package, not installed" bash -c "test $rc:$(ver grassfield-desktop) == 6:2-1 && test \$(grep -c '^incompatible ' $D/$op.exit) == 5"

say "Omarchy's migrations (s3.6)"
publish "${cur[@]/omarchy-1/omarchy-2}"; run_helper
expect "omarchy 2 adds a migration that calls a command that calls sudo -> exit 7, needs migration 200, not installed" test "$rc:$(exitfile "$op"):$(ver omarchy)" == "7:7|needs migration 200|:1-1"
publish "${cur[@]/omarchy-1/omarchy-3}"; run_helper 100.sh
expect "omarchy 3 adds a plain migration, 100 named pending -> exit 0, omarchy 3" test "$rc:$(ver omarchy)" == "0:3-1"
expect "  the log names the migrations scanned" grep -q 'none needs a person: .*300.sh' "$D/$op.log"
cur=("${cur[@]/omarchy-1/omarchy-3}")
publish "${cur[@]/gu-app-2/gu-app-3}"; run_helper 150.sh
expect "150 (gum) named pending by the runner -> exit 7, needs migration 150, gu-app stays 2" test "$rc:$(exitfile "$op"):$(ver gu-app)" == "7:7|needs migration 150|:2-1"
run_helper; expect "  without it -> exit 0, gu-app 3" test "$rc:$(ver gu-app)" == "0:3-1"
cur=("${cur[@]/gu-app-2/gu-app-3}")

say "conflicts pacman finds inside the transaction (s3.3)"
publish "${cur[@]/gu-app-3/gu-app-4}"; run_helper
expect "gu-app 4 conflicts with the installed gu-other -> exit 7, needs conflict, nothing installed" test "$rc:$(exitfile "$op" | cut -d'|' -f1,3):$(ver gu-app):$(ver gu-other)" == "7:7|needs conflict:3-1:1-1"
mkdir -p /usr/share/gu-stray && echo mine >/usr/share/gu-stray/file
publish "${cur[@]/gu-file-1/gu-file-2}"; run_helper
expect "gu-file 2 brings a file no package owns -> exit 7, needs conflict, gu-file stays 1, the file kept" test "$rc:$(ver gu-file):$(cat /usr/share/gu-stray/file)" == "7:1-1:mine"
rm -rf /usr/share/gu-stray
run_helper; expect "  once the file is gone -> exit 0" test "$rc:$(ver gu-file)" == "0:2-1"
cur=("${cur[@]/gu-file-1/gu-file-2}")

say "the 16 newest operations are kept"
publish "${cur[@]}"
for _ in $(seq 1 17); do run_helper; done
expect "17 more runs -> 16 started files" test "$(find "$D" -maxdepth 1 -name '*.started' | wc -l)" == 16

say "through pkexec: alice's password each time, bob refused"
cat >"$W/drive.py" <<'PY'
# Runs one command in a pseudo-terminal as the user; answers each "Password:" prompt; prints the transcript and the count.
import os, pty, sys, time, select
user, password, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("runuser", ["runuser", "-u", user, "--", "bash", "-c", cmd])
out, prompts, deadline = b"", 0, time.time() + 600
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        continue
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if out.count(b"Password:") > prompts:
        prompts = out.count(b"Password:")
        os.write(fd, password.encode() + b"\n")
_, status = os.waitpid(pid, 0)
print(out.decode(errors="replace").replace("\r", ""))
print("password prompts: %d, exit %d" % (prompts, os.waitstatus_to_exitcode(status)))
PY
publish "${cur[@]/gu-app-3/gu-app-5}"
op1=$(newop) op2=$(newop)
python3 -I "$W/drive.py" alice test-only-password "pkexec $H run $op1; echo rc=\$?; pkexec $H run $op2; echo rc=\$?" >"$W/pk.out" 2>&1
codes=$(grep -o 'rc=[0-9]*' "$W/pk.out" | tr '\n' ' ')
expect "two runs, two password prompts (auth_admin, never kept)" grep -q '^password prompts: 2,' "$W/pk.out"
expect "gu-app 5 installed by the first, the second up to date ($codes)" test "$codes:$(ver gu-app):$(exitfile "$op2")" == "rc=0 rc=0 :5-1:0|packages 0|"
cur=("${cur[@]/gu-app-3/gu-app-5}")
python3 -I "$W/drive.py" alice wrong-password "pkexec $H run $(newop); echo rc=\$?" >"$W/pk-wrong.out" 2>&1
expect "a wrong password -> pkexec exit 127" grep -q 'rc=127' "$W/pk-wrong.out"
out=$(as bob pkexec "$H" run "$(newop)" </dev/null 2>&1); rc=$?
expect "bob (no rule, no session) -> pkexec refuses (exit $rc)" test "$rc" == 126 -o "$rc" == 127

say "grassfield-update-run as carol (s3.1)"
uid=$(id -u carol)
mkdir -p "/run/user/$uid" && chown carol: "/run/user/$uid" && chmod 700 "/run/user/$uid"
runner() { runuser -u carol -- env -i HOME=/home/carol USER=carol XDG_RUNTIME_DIR="/run/user/$uid" PATH=/usr/bin LANG=C.UTF-8 "$R" "$@" </dev/null >/dev/null 2>&1; }
state() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["phase"], d["result"], d["restart"], ",".join(d["deferred"]))' "/run/user/$uid/grassfield/software-update-run.json" 2>&1; }
out=$(runuser -u carol -- env -i HOME=/home/carol XDG_RUNTIME_DIR="/run/user/$uid" "$R" extra 2>&1); rc=$?
expect "an argument -> exit 2" test "$rc" == 2
out=$("$R" 2>&1); rc=$?; expect "as root -> exit 2" test "$rc" == 2
publish "${cur[@]/gu-app-5/gu-app-1}"   # nothing newer: up to date
runner; expect "nothing newer -> done up-to-date" test "$(state)" == "done up-to-date  "
expect "its state file is carol's, 0600 in a 0700 folder" test "$(stat -c %U:%a "/run/user/$uid/grassfield"):$(stat -c %U:%a "/run/user/$uid/grassfield/software-update-run.json")" == "carol:700:carol:600"
mkpkg gu-app 6; publish "${cur[@]/gu-app-5/gu-app-6}"
runner; st=$(state)
expect "carol has 100, 150 and 300 pending; 150 asks (gum) -> done terminal, gu-app stays 5 ($st)" test "$st:$(ver gu-app)" == "done terminal  :5-1"
mkdir -p /home/carol/.local/state/omarchy/migrations && touch /home/carol/.local/state/omarchy/migrations/150.sh && chown -R carol: /home/carol/.local
runner; st=$(state)
expect "150 done before -> done, restart (the container's kernel rule), gu-app 6 ($st)" test "${st% *}:$(ver gu-app)" == "done done restart:6-1"
expect "  omarchy-migrate ran 100 and 300 as carol, without a terminal" bash -c "test \"\$(sort /home/carol/migrations.log | tr '\n' ' ')\" == '100 300 ' && test -f /home/carol/.local/state/omarchy/migrations/300.sh && test \$(stat -c %U /home/carol/migrations.log) == carol"
as carol flock -x "/run/user/$uid/omarchy-update.lock" sleep 4 & sleep 0.5; runner; wait $!
expect "Omarchy's update lock held -> done busy" test "$(state)" == "done busy  "

echo
echo "update_helper: $fails failure(s)"
((fails == 0))
