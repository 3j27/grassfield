#!/usr/bin/env bash
# Software Update, step 5 (ADR-0033 s5, owner decision SU-M2: one password for Update Now and its migrations' sudo
# commands): grassfield-update-helper, grassfield-update-run, the migrations' sudo (/usr/lib/grassfield/update-sudo/sudo)
# and the polkit rule 49-grassfield-update.rules, with systemd as the container's manager (privileged, a cgroup2 mount),
# real dbus-broker, polkitd and pkexec. Never on a real machine: inside, it refuses to run unless it is root in a container
# with the repository mounted at /src and an Omarchy tree at /omarchy.
#
#   tests/integration/update_migrate.sh [--omarchy DIR]
#     DIR  an Omarchy 4.x tree (default /usr/share/omarchy): its omarchy-migrate goes into the test's omarchy package
#   Runs `docker run --privileged` on archlinux:base (digest pinned below) with systemd as PID 1, then the cases through
#   `docker exec`; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the
#   container's CA bundle. Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# What it shows:
#   - the channel: in grassfield-update-migrate.service (as carol, NoNewPrivileges) the sudo runs commands as root with
#     standard input, output, working folder, exit status and arguments passed through, looks a name up in root's folders
#     only, accepts Omarchy's sudo options and refuses the others; outside that unit (a plain process of carol's, another
#     unit, the unit without NoNewPrivileges, another root unit name) systemd refuses, with no dialog; the real sudo cannot
#     run in the unit; nothing of the unit is left after it;
#   - the helper, from carol's runner through pkexec: the real helper sends a migration that needs root to Omarchy's
#     terminal here, nothing installed (the container's kernel has no Yama, which it requires); a copy whose Yama path is a
#     test file holding 1 (the one change, stated) installs, runs the migration as carol with its sudo commands as root,
#     says `migrations ran`, and the runner does not run it again; a sudo command that fails leaves the migration pending
#     (`deferred migrations`); a migration that needs a person still goes to the terminal; without the rule, the trial
#     sudo fails and the run goes to the terminal, nothing installed.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  omarchy=/usr/share/omarchy
  while (($#)); do
    case $1 in
      --omarchy) omarchy=${2:?}; shift ;;
      *) echo "usage: update_migrate.sh [--omarchy DIR]" >&2; exit 2 ;;
    esac
    shift
  done
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  [[ -f $omarchy/bin/omarchy-migrate ]] || { echo "SKIP: no Omarchy tree at $omarchy (--omarchy DIR)"; exit 0; }
  args=(-d --privileged --cgroupns=private --tmpfs /run --tmpfs /tmp --network host -e container=docker
    -v "$root:/src:ro" -v "$(realpath "$omarchy"):/omarchy:ro")
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
  envs=()
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && envs+=(-e "$v"); done
  cid=$(docker run "${args[@]}" "$IMAGE" bash -c 'umount -l /sys/fs/cgroup 2>/dev/null; mount -t cgroup2 none /sys/fs/cgroup && exec /usr/lib/systemd/systemd') ||
    { echo "FAIL: the container did not start"; exit 1; }
  trap 'docker rm -f "$cid" >/dev/null 2>&1' EXIT
  for _ in $(seq 1 60); do
    state=$(docker exec "$cid" systemctl is-system-running 2>/dev/null)
    [[ $state == running || $state == degraded ]] && break
    sleep 1
  done
  [[ $state == running || $state == degraded ]] || { echo "FAIL: systemd did not come up in the container ($state)"; exit 1; }
  docker exec "${envs[@]}" "$cid" bash /src/tests/integration/update_migrate.sh --inside
  exit $?
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/pacman/grassfield-update-sudo && -d /omarchy/bin && -d /run/systemd/system ]] ||
  { echo "refused: runs only as root inside a throwaway container run by systemd (/src, /omarchy)"; exit 2; }

W=/work
mkdir -p "$W" && chmod 1777 "$W"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
quiet() { "$@" >>"$W/log" 2>&1; }
H=/usr/lib/grassfield/grassfield-update-helper
R=/usr/lib/grassfield/grassfield-update-run
SUDO=/usr/lib/grassfield/update-sudo/sudo
RULE=/usr/share/polkit-1/rules.d/49-grassfield-update.rules
D=/run/grassfield-update
FPR=40DFB630FF42BCFFB047046CF0134EE680CAC571
ver() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2; }
exitfile() { tr '\n' '|' <"$D/$1.exit" 2>/dev/null; }

say "setup: Arch's mirrors, polkit and sudo; Omarchy's key; the real helper, runner, policy, sudo for migrations and rule"
sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
quiet pacman-key --init
quiet pacman-key --populate archlinux
quiet pacman -Syu --noconfirm polkit sudo python diffutils || { echo "FAIL: pacman -Syu polkit sudo python (see $W/log)"; tail -5 "$W/log"; exit 1; }
quiet pacman -Sw --noconfirm archlinux-keyring || { echo "FAIL: the Arch keyring's package file"; exit 1; }
pacman -Q pacman polkit systemd dbus-broker sudo | tr '\n' ' '; echo
curl -fsS "https://keys.openpgp.org/vks/v1/by-fingerprint/$FPR" -o "$W/omarchy.asc" && quiet pacman-key --add "$W/omarchy.asc" &&
  quiet pacman-key --lsign-key "$FPR" || { echo "FAIL: Omarchy's public key from keys.openpgp.org (see $W/log)"; exit 1; }
install -Dm755 /src/packaging/pacman/grassfield-update-helper "$H"
install -Dm755 /src/packaging/bin/grassfield-update-run "$R"
install -Dm644 /src/packaging/pacman/org.grassfield.packages.policy /usr/share/polkit-1/actions/org.grassfield.packages.policy
install -Dm755 /src/packaging/pacman/grassfield-update-sudo "$SUDO"
install -Dm644 /src/packaging/pacman/49-grassfield-update.rules "$RULE"
useradd -m carol
uid=$(id -u carol)
# carol's runner has no agent to ask the password through in a container: polkit lets it through (the dialog is the
# owner's L2); the rule under test is the packaged one.
cat >/etc/polkit-1/rules.d/50-grassfield-test.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.grassfield.packages.update-system" && subject.user == "carol") return polkit.Result.YES;
  return polkit.Result.NOT_HANDLED;
});
EOF
systemctl restart polkit
cp /var/cache/pacman/pkg/archlinux-keyring-"$(ver archlinux-keyring)"-any.pkg.tar.zst "$W/keyring.pkg.tar.zst" ||
  { echo "FAIL: the installed archlinux-keyring's package file is not in the cache"; exit 1; }
mkdir -p "/run/user/$uid" && chown carol: "/run/user/$uid" && chmod 700 "/run/user/$uid"

say "the channel: the migrations' sudo inside grassfield-update-migrate.service (the helper's properties)"
# The unit as the helper's migrate_unit makes it.
in_migrate() { # [property...] -- program [argument...]
  local props=(-p NoNewPrivileges=yes)
  if [[ ${1-} == --no-nnp ]]; then props=(); shift; fi
  systemd-run --unit=grassfield-update-migrate --collect --quiet --wait --pipe --service-type=exec --expand-environment=no \
    --uid=carol "${props[@]}" -p 'WorkingDirectory=~' --setenv=PATH="/usr/lib/grassfield/update-sudo:/usr/share/omarchy/bin:/usr/bin" "$@"
}
cat >"$W/channel.sh" <<'EOF'
#!/bin/bash
set -u
r() { printf '%s=%s\n' "$1" "$2"; }
r whoami "$(id -un)"
r root "$(sudo id -u)"
echo through-stdin | sudo tee /root/tee-test >/dev/null; r tee "$?"
cd /tmp && r pwd "$(sudo pwd)"
sudo sh -c 'exit 7'; r status "$?"
r as-carol "$(sudo -u carol id -un)"
r as-carol-hash "$(sudo -u "#$(id -u)" id -un)"
sudo -v; r validate "$?"
sudo -n true; r nontty "$?"
sudo -nH true; r cluster "$?"
sudo -n -l -l /usr/bin/true >/dev/null 2>&1; r list "$?"
sudo -E true 2>/dev/null; r preserve-env "$?"
sudo -i 2>/dev/null; r login-shell "$?"
sudo FOO=1 true 2>/dev/null; r assignment "$?"
r env-command "$(sudo env GU_A=1 sh -c 'echo $GU_A')"
r sudo-user "$(sudo printenv SUDO_USER)"
r root-home "$(sudo printenv HOME)"
r literal "$(sudo echo '$HOME' '%n')"
mkdir -p "$HOME/bin" && printf '#!/bin/sh\necho pwned\n' >"$HOME/bin/gu-evil" && chmod 755 "$HOME/bin/gu-evil"
PATH=$HOME/bin:$PATH sudo gu-evil >/dev/null 2>&1; r lookup "$?"
systemd-run --quiet --wait --no-ask-password --unit=run-gu-x.service true 2>/dev/null; r other-name "$?"
systemctl --no-ask-password stop polkit 2>/dev/null; r stop-polkit "$?"
/usr/bin/sudo -n true 2>/dev/null; r real-sudo "$?"
EOF
chmod 755 "$W/channel.sh"
out=$(in_migrate -- "$W/channel.sh" 2>&1)
get() { sed -n "s/^$1=//p" <<<"$out"; }
expect "the unit's processes are carol's" test "$(get whoami)" == carol
expect "sudo id -u -> 0" test "$(get root)" == 0
expect "standard input reaches the command (tee as root)" test "$(get tee):$(cat /root/tee-test 2>/dev/null):$(stat -c %U /root/tee-test 2>/dev/null)" == "0:through-stdin:root"
expect "the working folder is the caller's" test "$(get pwd)" == /tmp
expect "the command's exit status is sudo's" test "$(get status)" == 7
expect "sudo -u carol, sudo -u #uid" test "$(get as-carol):$(get as-carol-hash)" == "carol:carol"
expect "sudo -v, sudo -n, sudo -nH -> 0" test "$(get validate):$(get nontty):$(get cluster)" == "0:0:0"
expect "sudo -l lists nothing -> 1" test "$(get list)" == 1
expect "sudo -E, sudo -i, a variable before the command -> refused (1)" test "$(get preserve-env):$(get login-shell):$(get assignment)" == "1:1:1"
expect "sudo env VAR=... command works (Omarchy's form)" test "$(get env-command)" == 1
expect "SUDO_USER carol, HOME /root" test "$(get sudo-user):$(get root-home)" == "carol:/root"
expect "arguments reach the command unexpanded" test "$(get literal)" == '$HOME %n'
expect "a name is not looked up in the caller's PATH (command not found)" test "$(get lookup)" == 1
expect "another unit name from the unit -> refused" test "$(get other-name)" != 0
expect "any other unit operation from the unit -> refused (polkit still active)" test "$(get stop-polkit)" != 0 -a "$(systemctl is-active polkit)" == active
expect "the real sudo cannot run in the unit (NoNewPrivileges)" test "$(get real-sudo)" != 0
expect "nothing of the unit is left" bash -c '! systemctl is-active --quiet grassfield-update-migrate.service && test -z "$(systemctl list-units --all --plain --no-legend "grassfield-update-migrate*" "grassfield-update-root-*")"'

say "the channel refuses everything else"
out=$(runuser -u carol -- "$SUDO" id -u 2>&1); rc=$?
expect "carol outside the unit: sudo -> refused, no dialog ($rc)" test "$rc:$(grep -c '^0$' <<<"$out")" == "1:0"
out=$(systemd-run --unit=gu-other --collect --quiet --wait --pipe --uid=carol -p NoNewPrivileges=yes "$SUDO" id -u 2>&1); rc=$?
expect "carol in another unit -> refused" test "$rc" != 0
out=$(in_migrate --no-nnp -- "$SUDO" id -u 2>&1); rc=$?
expect "the unit's name without NoNewPrivileges -> refused" test "$rc" != 0
rm -f /root/tee-test

say "the test packages"
mkdir -p "$W/pkgs" "$W/repo"
# mkpkg name version [.PKGINFO line | path=content | path:<file to copy> | path-><link target>]... (update_helper.sh's)
mkpkg() {
  local name=$1 ver=$2 dir="$W/build/$1-$2" arg path
  shift 2
  rm -rf "$dir" && mkdir -p "$dir/usr/share/doc/$name"
  echo "$name $ver" >"$dir/usr/share/doc/$name/README"
  {
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s-1\npkgdesc = update migrate test\nurl = https://example.invalid\n' "$name" "$name" "$ver"
    printf 'builddate = 1700000000\npackager = test\nsize = 1\narch = any\nlicense = MIT\n'
    for arg in "$@"; do [[ $arg == *' = '* ]] && printf '%s\n' "$arg"; done
  } >"$dir/.PKGINFO"
  for arg in "$@"; do
    [[ $arg == *' = '* ]] && continue
    if [[ $arg == *'->'* && $arg != *=* ]]; then
      path=${arg%%->*}; mkdir -p "$dir/${path%/*}"; ln -s "${arg#*->}" "$dir/$path"
    elif [[ $arg == *:* && $arg != *=* ]]; then
      path=${arg%%:*}; mkdir -p "$dir/${path%/*}"; cp "${arg#*:}" "$dir/$path"
    else
      path=${arg%%=*}; mkdir -p "$dir/${path%/*}"; printf '%s\n' "${arg#*=}" >"$dir/$path"
    fi
  done
  chmod -R a+rX "$dir"
  find "$dir/usr/share/omarchy/bin" "$dir/usr/bin" -type f -exec chmod 755 {} + 2>/dev/null
  (cd "$dir" && bsdtar --zstd -cf "$W/pkgs/$name-$ver-1-any.pkg.tar.zst" .PKGINFO usr) || { echo "FAIL: mkpkg $name"; exit 1; }
}
mkpkg grassfield-desktop 1 "usr/share/grassfield/BUILD-DEPS=qt6-base 6.11.0-1"
mkpkg qt6-base 6.11.0
mkpkg omarchy-keyring 1
omarchy_commands=()
printf '#!/bin/bash\nsudo true\n' >"$W/omarchy-gu-sudo"
printf '#!/bin/bash\nomarchy-gu-sudo\n' >"$W/omarchy-gu-indirect"
printf '#!/bin/bash\ntrue\n' >"$W/omarchy-notification-dismiss"
for command in omarchy-gu-sudo omarchy-gu-indirect omarchy-notification-dismiss; do
  omarchy_commands+=("usr/bin/$command:$W/$command" "usr/share/omarchy/bin/$command->/usr/bin/$command")
done
omarchy_commands+=("usr/bin/omarchy-migrate:/omarchy/bin/omarchy-migrate" "usr/share/omarchy/bin/omarchy-migrate->/usr/bin/omarchy-migrate")
base_files=("usr/share/omarchy/version=4.0.4" "${omarchy_commands[@]}" "usr/share/omarchy/migrations/100.sh=echo 100 >>\"\$HOME/migrations.log\"")
# 700: needs root (sudo, and a command that calls it), writes on both sides and records its session.
m700='echo 700 >>"$HOME/migrations.log"; echo carol-side >"$HOME/su-m2-user"; echo root-side | sudo tee /root/su-m2-root >/dev/null; sudo install -m 644 /dev/null /etc/su-m2-marker; omarchy-gu-indirect; echo "${WAYLAND_DISPLAY-} ${HYPRLAND_INSTANCE_SIGNATURE-}" >"$HOME/su-m2-session"'
mkpkg omarchy 1 "${base_files[@]}"
mkpkg omarchy 2 "${base_files[@]}" "usr/share/omarchy/migrations/700.sh=$m700"
mkpkg omarchy 3 "${base_files[@]}" "usr/share/omarchy/migrations/700.sh=$m700" "usr/share/omarchy/migrations/750.sh=sudo false"
mkpkg omarchy 4 "${base_files[@]}" "usr/share/omarchy/migrations/700.sh=$m700" "usr/share/omarchy/migrations/750.sh=sudo false" \
  "usr/share/omarchy/migrations/800.sh=gum confirm 'Continue?'"
mkpkg omarchy 5 "${base_files[@]}" "usr/share/omarchy/migrations/700.sh=$m700" "usr/share/omarchy/migrations/750.sh=sudo false" \
  "usr/share/omarchy/migrations/740.sh=sudo touch /root/su-m2-740"
publish() {
  rm -f "$W/repo"/*
  cp "$W/keyring.pkg.tar.zst" "$W/repo/archlinux-keyring-$(ver archlinux-keyring)-any.pkg.tar.zst"
  local p
  for p in "$@"; do cp "$W/pkgs/$p-1-any.pkg.tar.zst" "$W/repo/"; done
  quiet repo-add -q "$W/repo/gutest.db.tar.gz" "$W/repo"/*.pkg.tar.zst
  touch -d "@$(( $(date +%s) + ${publish_n:=0} ))" "$W/repo/gutest.db.tar.gz" "$W/repo/gutest.db"
  publish_n=$((publish_n + 1))
}
base=(grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-1)
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
quiet pacman -S --noconfirm grassfield-desktop qt6-base omarchy-keyring omarchy || { echo "FAIL: installing the base set (see $W/log)"; exit 1; }
# carol has run 100 already (Omarchy's marker).
mkdir -p /home/carol/.local/state/omarchy/migrations && touch /home/carol/.local/state/omarchy/migrations/100.sh
chown -R carol: /home/carol/.local
expect "the base set installed (omarchy 1)" test "$(ver omarchy)" == 1-1

say "the helper, from carol's runner (pkexec, the unit grassfield-update.service)"
runner() {
  runuser -u carol -- env -i HOME=/home/carol USER=carol XDG_RUNTIME_DIR="/run/user/$uid" PATH=/usr/bin LANG=C.UTF-8 \
    WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=gu_test_123 "$R" </dev/null >/dev/null 2>&1
}
# phase, result, and whether migrations are deferred (a container has no running kernel's package and only test
# repositories: the restart and `aur` that follow from that are not this test's).
state() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["phase"], s["result"], "migrations" if "migrations" in s["deferred"] else "-")' \
  "/run/user/$uid/grassfield/software-update-run.json" 2>/dev/null; }
last() { cat "$D/last" 2>/dev/null; }

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-2
runner; op=$(last)
expect "the real helper: no Yama in this kernel -> done terminal, needs migration 700, omarchy stays 1 ($(state))" \
  test "$(state):$(exitfile "$op"):$(ver omarchy)" == "done terminal -:7|needs migration 700|:1-1"
expect "  its log says why (Yama), and that the person was carol's uid" bash -c "grep -q 'Yama does not keep' '$D/$op.log'"
expect "  it ran in grassfield-update.service" bash -c "! grep -q 'no systemd unit' '$D/$op.log'"
expect "  nothing of the migration ran" test ! -e /root/su-m2-root -a ! -e /home/carol/su-m2-user

say "the helper with Yama's value in a test file (a copy whose GU_YAMA is /run/gu-yama: the one change)"
echo 1 >/run/gu-yama
sed 's|^GU_YAMA=/proc/sys/kernel/yama/ptrace_scope$|GU_YAMA=/run/gu-yama|' /src/packaging/pacman/grassfield-update-helper >"$H"
expect "  the copy differs from the helper by that line only" test "$(diff /src/packaging/pacman/grassfield-update-helper "$H" | grep -c '^[<>]')" == 2
runner; op=$(last)
expect "omarchy 2 (700 needs root) -> done done, omarchy 2 installed, migrations ran ($(state))" \
  test "$(state):$(ver omarchy):$(grep -cx 'migrations ran' "$D/$op.exit")" == "done done -:2-1:1"
expect "  700's sudo commands ran as root (tee, install)" test "$(cat /root/su-m2-root 2>/dev/null):$(stat -c %U /etc/su-m2-marker 2>/dev/null)" == "root-side:root"
expect "  700 ran as carol (its file is carol's), once, and is marked done in carol's state" \
  test "$(stat -c %U /home/carol/su-m2-user 2>/dev/null):$(grep -c 700 /home/carol/migrations.log):$(test -f /home/carol/.local/state/omarchy/migrations/700.sh && echo marked)" == "carol:1:marked"
expect "  700 had carol's session values (Wayland display, Hyprland instance)" test "$(cat /home/carol/su-m2-session 2>/dev/null)" == "wayland-1 gu_test_123"
expect "  the log has the migration's output and says SU-M2" bash -c "grep -q 'Running migration (700)' '$D/$op.log' && grep -q 'SU-M2' '$D/$op.log'"
expect "  nothing of the migrations' unit or its root units is left" \
  test -z "$(systemctl list-units --all --plain --no-legend 'grassfield-update-migrate*' 'grassfield-update-root-*')"

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-3
runner; op=$(last)
expect "omarchy 3 (750: sudo false) -> done done with deferred migrations, omarchy 3 installed ($(state))" \
  test "$(state):$(ver omarchy):$(grep -cx 'migrations ran' "$D/$op.exit")" == "done done migrations:3-1:1"
expect "  750 stays pending for carol" test ! -f /home/carol/.local/state/omarchy/migrations/750.sh

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-4
runner; op=$(last)
expect "omarchy 4 (800 asks with gum) -> done terminal, needs migration 800 and 750, omarchy stays 3 ($(state))" \
  test "$(state):$(ver omarchy):$(exitfile "$op")" == "done terminal -:3-1:7|needs migration 800|needs migration 750|"

publish grassfield-desktop-1 qt6-base-6.11.0 omarchy-keyring-1 omarchy-5
cp "$RULE" "$W/rule.saved"
echo '// emptied by the test' >"$RULE"
sleep 2   # polkitd reloads its rules when a file changes
runner; op=$(last)
expect "a rule that grants nothing: the trial sudo fails -> done terminal, needs migration 750 and 740, omarchy stays 3 ($(state))" \
  test "$(state):$(ver omarchy):$(exitfile "$op")" == "done terminal -:3-1:7|needs migration 750|needs migration 740|"
expect "  its log says the trial failed; 740 did not run" bash -c "grep -q 'the trial sudo through the migrations. unit failed' '$D/$op.log' && test ! -e /root/su-m2-740"
rm -f "$RULE"
runner; op=$(last)
expect "no rule installed -> done terminal, omarchy stays 3 ($(state))" test "$(state):$(ver omarchy)" == "done terminal -:3-1"
expect "  its log says the sudo for migrations is not installed" grep -q "sudo for migrations is not installed" "$D/$op.log"
cp "$W/rule.saved" "$RULE"
sleep 2
runner; op=$(last)
expect "the rule back: omarchy 5 installed, 740 (before 750) ran its sudo, 750 still fails (deferred) ($(state))" \
  test "$(state):$(ver omarchy):$(test -e /root/su-m2-740 && echo ran)" == "done done migrations:5-1:ran"

echo
if ((fails)); then echo "update_migrate: $fails FAIL"; exit 1; fi
echo "update_migrate: all PASS"
