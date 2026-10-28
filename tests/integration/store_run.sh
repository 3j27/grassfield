#!/usr/bin/env bash
# Grassfield Store, step 3b1: grassfield-store-run, the script the Store starts in Omarchy's terminal (ADR-0037 b.2; spec
# A6b's grassfield-store-run part). Never on a real machine: inside, it refuses to run unless it is root in a container with
# the repository mounted at /src.
#
#   tests/integration/store_run.sh
#   Runs `docker run --rm --network none` on archlinux:base (digest pinned below) with the repository mounted read-only.
#   Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside the container: a user (`carol`) with an XDG_RUNTIME_DIR, a made-up Omarchy folder (recipes that write a marker,
# fail, sleep or leave a process running) and the Store's pins for it, the real pacman-conf and pacman (no sync database:
# pacman -Qu lists nothing) behind a wrapper at /usr/bin/pacman whose -Qu answers as /run/test/qu says (lines, a failure,
# a pause), and pacman's real db.lck. The script fixes its own PATH, so a program first in carol's PATH is never used (a
# case checks it). The script runs as carol through setpriv (one process: no watching parent between it and the test),
# with no terminal (stdin /dev/null).
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ${1:-} != --inside ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
  (($# == 0)) || { echo "usage: store_run.sh" >&2; exit 2; }
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon (this test runs only in a throwaway container)"; exit 0; }
  exec docker run --rm --network none -v "$root:/src:ro" "$IMAGE" bash /src/tests/integration/store_run.sh --inside
fi

[[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/store/grassfield-store-run ]] ||
  { echo "refused: runs only as root inside a throwaway container (/src)"; exit 2; }

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { local desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
say() { printf '\n== %s\n' "$*"; }
newop() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

R=/usr/lib/grassfield/grassfield-store-run
install -Dm755 /src/packaging/store/grassfield-store-run "$R"
useradd -m carol
as_carol() { setpriv --reuid=carol --regid=carol --init-groups -- "$@"; }
cuid=$(id -u carol)
RT=/run/user/$cuid
mkdir -p "$RT" && chown carol: "$RT" && chmod 700 "$RT"
D=$RT/grassfield/store
O=/home/carol/omarchy # the made-up Omarchy folder (OMARCHY_PATH)
M=/home/carol/marks   # what the recipes did
E=/home/carol/evil    # programs of carol's own, first in her PATH when a case asks
as_carol mkdir -p "$O/bin" "$O/install/helpers" "$M" "$E"
# pacman's -Qu as /run/test/qu says: "list" (the lines of /run/test/qu-lines, exit 0), "fail" (exit 2), "slow" (a pause in
# which the test presses Ctrl+C); anything else the real pacman.
T=/run/test
mkdir -p "$T" && chmod 755 "$T"
mv /usr/bin/pacman /usr/bin/pacman.real
cat >/usr/bin/pacman <<'PACMAN'
#!/bin/bash
if [[ ${1-} == -Qu && -s /run/test/qu ]]; then
  case $(cat /run/test/qu) in
    list) cat /run/test/qu-lines; exit 0 ;;
    fail) echo "error: failed to init transaction" >&2; exit 2 ;;
    slow) : >/run/test/qu-asked; sleep 20; exit 1 ;;
  esac
fi
exec /usr/bin/pacman.real "$@"
PACMAN
chmod 755 /usr/bin/pacman
qu() { printf '%s\n' "$1" >"$T/qu"; }
recipe() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$O/bin/$1"
  chmod 755 "$O/bin/$1"
  chown carol: "$O/bin/$1"
}
recipe omarchy-install-game 'source "$OMARCHY_PATH/install/helpers/game.sh"; echo "installed $*" >>"$HOME/marks/game"'
recipe omarchy-remove-game 'echo removed >>"$HOME/marks/game"'
recipe omarchy-install-broken 'echo half >>"$HOME/marks/broken"; exit 7'
recipe omarchy-install-slow 'echo started >"$HOME/marks/slow"; sleep 20; echo finished >>"$HOME/marks/slow"'
recipe omarchy-install-daemon 'setsid sleep 30 </dev/null >/dev/null 2>&1 & echo started >"$HOME/marks/daemon"'
recipe omarchy-install-unpinned 'echo ran >"$HOME/marks/unpinned"'
recipe omarchy-install-path 'omarchy-game-helper; echo ran >>"$HOME/marks/path"'
recipe omarchy-game-helper 'echo pinned >>"$HOME/marks/helper"'
printf 'true\n' >"$O/install/helpers/game.sh" && chown carol: "$O/install/helpers/game.sh"
# The Store's pins of an operation: every pinned file, "<sha256>  <path>" (the catalog's pins, ADR-0037 g).
pins() { # op [extra lines]
  (cd "$O" && sha256sum bin/omarchy-install-game bin/omarchy-remove-game bin/omarchy-install-broken bin/omarchy-install-slow \
    bin/omarchy-install-daemon bin/omarchy-install-path bin/omarchy-game-helper install/helpers/game.sh) >"$D/$1.pins"
  (($# > 1)) && printf '%s\n' "${@:2}" >>"$D/$1.pins"
  chown carol: "$D/$1.pins" && chmod 600 "$D/$1.pins"
}
as_carol mkdir -p "$D"
# The script as carol, as in her terminal: her environment, OMARCHY_PATH, her PATH ($cpath) and what $extra adds.
cpath=/usr/bin
extra=()
run() { # op deadline kind recipe [args]
  as_carol env -i HOME=/home/carol USER=carol PATH="$cpath" XDG_RUNTIME_DIR="$RT" OMARCHY_PATH="$O" "${extra[@]}" \
    "$R" "$@" </dev/null >>/tmp/run.out 2>&1
}
soon() { echo $(($(date +%s) + 60)); }
exitfile() { cat "$D/$1.exit" 2>/dev/null; }
# Who holds Omarchy's update lock, read as carol (the container's root may not read another user's descriptors).
holders() { as_carol find /proc/[0-9]*/fd -lname "$RT/omarchy-update.lock" 2>/dev/null | cut -d/ -f3 | sort -u | tr '\n' ' '; }

say "usage: the tokens of ADR-0037 e.5 only"
for args in "" "x" "$(newop) $(soon) setup" "0123 $(soon) setup omarchy-install-game" "$(newop) soon setup omarchy-install-game" \
  "$(newop) $(soon) aur omarchy-install-game" "$(newop) $(soon) setup omarchy-game" "$(newop) $(soon) setup omarchy-install-Game" \
  "$(newop) $(soon) setup omarchy-install-game A" "$(newop) $(soon) setup omarchy-install-game -x" \
  "$(newop) $(soon) setup omarchy-install-game a b c d e" "$(newop) $(soon) setup /tmp/omarchy-install-game"; do
  # shellcheck disable=SC2086 # the cases are word lists
  run $args; rc=$?
  expect "refused: '${args:0:60}' -> exit 2" test "$rc" == 2
done
op=$(newop)
run "$op" "$(soon)" setup "omarchy-install-game;id"; rc=$?
expect "a recipe with a shell character -> exit 2" test "$rc" == 2
run "$op" "$(soon)" setup omarchy-install-game "$(printf 'one\nid')"; rc=$?
expect "an argument with a line feed -> exit 2" test "$rc" == 2
rc=$(as_carol env -i HOME=/home/carol PATH=/usr/bin OMARCHY_PATH="$O" "$R" "$op" "$(soon)" setup omarchy-install-game </dev/null >/dev/null 2>&1; echo $?)
expect "no XDG_RUNTIME_DIR -> exit 2" test "$rc" == 2
rc=$(env -i HOME=/root PATH=/usr/bin XDG_RUNTIME_DIR=/run/user/0 OMARCHY_PATH="$O" "$R" "$op" "$(soon)" setup omarchy-install-game \
  </dev/null 2>/tmp/root.err; echo $?)
expect "run as root -> exit 2, says why" bash -c "test $rc == 2 && grep -q 'never as root' /tmp/root.err"
expect "nothing ran, no file written" bash -c "test ! -e $M/game && test -z \"\$(ls $D)\" && test ! -e /run/user/0/grassfield"

say "a run: the recipe, its files, the lock held while it runs"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game one two; rc=$?
expect "install omarchy-install-game one two -> exit 0, the recipe ran with its arguments" bash -c "test $rc == 0 && grep -qx 'installed one two' $M/game"
expect "  the exit file says 0; the started file a pid and a start time" bash -c "test '$(exitfile "$op")' == 0 && grep -Eq '^[0-9]+ [0-9]+$' $D/$op.started"
expect "  $D is carol's, 0700; its files 0600" test "$(stat -c %U:%a "$D"):$(stat -c %a "$D/$op.exit")" == "carol:700:600"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "the same operation id again -> exit 2, nothing ran again" bash -c "test $rc == 2 && test \$(wc -l <$M/game) == 1"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-remove-game; rc=$?
expect "a removal recipe -> exit 0" bash -c "test $rc == 0 && tail -1 $M/game | grep -qx removed"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-broken; rc=$?
expect "the recipe fails (exit 7) -> exit 1, the exit file says 1" test "$rc:$(exitfile "$op")" == "1:1"
op=$(newop); pins "$op"
# Its own process group, as a terminal's foreground job: with job control off, a background job would ignore SIGINT.
set -m
run "$op" "$(soon)" setup omarchy-install-slow &
set +m
for _ in $(seq 40); do grep -q started "$M/slow" 2>/dev/null && break; sleep 0.25; done
spid=$(cut -d' ' -f1 "$D/$op.started" 2>/dev/null)
held=yes
as_carol flock -n "$RT/omarchy-update.lock" true && held=no
expect "while the recipe runs, Omarchy's update lock is held, by the script only ($(holders))" test "$held:$(holders)" == "yes:$spid "
op2=$(newop); pins "$op2"
run "$op2" "$(soon)" setup omarchy-install-game; rc=$?
expect "  another run meanwhile -> exit 3 (busy), its recipe not run" test "$rc:$(exitfile "$op2")" == "3:3"
# Ctrl+C in the terminal: SIGINT to its foreground process group (the script and the recipe).
kill -INT -- "-$(ps -o pgid= "$spid" | tr -d ' ')"
wait
expect "Ctrl+C -> exit file 130, the recipe stopped" bash -c "test '$(exitfile "$op")' == 130 && ! grep -q finished $M/slow"
expect "  the lock is free once it ended" as_carol flock -n "$RT/omarchy-update.lock" true
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-daemon; rc=$?
sleep 0.5
expect "a recipe that leaves a process running -> exit 0, the process holds no lock ($(holders))" \
  bash -c "test $rc == 0 && pgrep -u carol -x sleep >/dev/null && test -z '$(holders)'"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "  the next run is not busy -> exit 0" test "$rc" == 0
pkill -u carol -x sleep

say "refusals before the recipe"
op=$(newop); pins "$op"
run "$op" $(($(date +%s) - 1)) setup omarchy-install-game; rc=$?
expect "past the deadline -> exit 6, exit file 6, no started file" bash -c "test $rc:$(exitfile "$op") == 6:6 && test ! -e $D/$op.started"
op=$(newop); pins "$op"
as_carol flock "$RT/omarchy-update.lock" sleep 5 &
sleep 0.5
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
wait
expect "Omarchy's update lock held (omarchy update running) -> exit 3" test "$rc:$(exitfile "$op")" == "3:3"
touch /var/lib/pacman/db.lck
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman's db.lck there -> exit 3" test "$rc:$(exitfile "$op")" == "3:3"
rm -f /var/lib/pacman/db.lck
qu list
printf 'linux 6.17.1-1 -> 6.17.4-1\ngame-data 1-1 -> 2-1 [ignored]\n' >"$T/qu-lines"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu lists linux -> exit 4" test "$rc:$(exitfile "$op")" == "4:4"
printf 'game-data 1-1 -> 2-1 [ignored]\n' >"$T/qu-lines"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu lists only an [ignored] package -> exit 0" test "$rc" == 0
lines_before=$(wc -l <"$M/game")
qu fail
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "pacman -Qu fails (exit 2) -> exit 1, not run" bash -c "test $rc:$(exitfile "$op") == 1:1 && test \$(wc -l <$M/game) == $lines_before"
# Ctrl+C while pacman -Qu runs (the second checks): the script's group, as above.
qu slow
op=$(newop); pins "$op"
set -m
run "$op" "$(soon)" setup omarchy-install-game &
set +m
for _ in $(seq 40); do [[ -e $T/qu-asked ]] && break; sleep 0.25; done
spid=$(cut -d' ' -f1 "$D/$op.started" 2>/dev/null)
kill -INT -- "-$(ps -o pgid= "$spid" | tr -d ' ')"
wait
expect "Ctrl+C during the checks -> exit file 130, the recipe not run" \
  bash -c "test '$(exitfile "$op")' == 130 && test \$(wc -l <$M/game) == $lines_before && grep -q 'Stopped: nothing was run' /tmp/run.out"
rm -f "$T/qu" "$T/qu-asked"
op=$(newop)
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "no pins file -> exit 5" test "$rc:$(exitfile "$op")" == "5:5"
op=$(newop); pins "$op" "not a pin line"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins line that does not parse -> exit 5" test "$rc" == 5
op=$(newop); pins "$op" "$(cd "$O" && sha256sum bin/omarchy-install-game | cut -d' ' -f1)  bin/../bin/omarchy-install-game"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pinned path with '..' (its hash right) -> exit 5" test "$rc" == 5
op=$(newop); pins "$op"
echo '# changed by an update' >>"$O/install/helpers/game.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a file the recipe sources differs from its pin -> exit 5, the message names it" \
  bash -c "test $rc == 5 && grep -q 'install/helpers/game.sh differs' /tmp/run.out"
sed -i '$d' "$O/install/helpers/game.sh"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-unpinned; rc=$?
expect "a recipe the pins do not name -> exit 5, not run" bash -c "test $rc == 5 && test ! -e $M/unpinned"
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-missing; rc=$?
expect "a recipe Omarchy does not have -> exit 5" test "$rc" == 5
op=$(newop) other=$(newop); pins "$other"
ln -s "$D/$other.pins" "$D/$op.pins" && chown -h carol: "$D/$op.pins"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins file that is a link (to good pins) -> exit 5" test "$rc" == 5
op=$(newop); pins "$op"
chown root: "$D/$op.pins" && chmod 644 "$D/$op.pins"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pins file someone else owns -> exit 5" test "$rc" == 5
op=$(newop); pins "$op" "$(printf '%064d' 0)  install/helpers/gone.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "a pinned file Omarchy does not have -> exit 5, the message names it" \
  bash -c "test $rc == 5 && grep -q 'install/helpers/gone.sh differs' /tmp/run.out"
expect "none of the refused runs ran the recipe" test "$(wc -l <"$M/game")" == "$lines_before"

say "the caller's environment does not choose the programs"
# carol's own programs first in her PATH: a helper the recipe calls by name, and a sha256sum that answers game.sh's
# pinned hash whatever game.sh holds (the real one for any other file).
printf '#!/bin/bash\necho evil >>"$HOME/marks/helper"\n' >"$E/omarchy-game-helper"
good=$(sha256sum "$O/install/helpers/game.sh" | cut -d' ' -f1)
printf '#!/bin/bash\n/usr/bin/sha256sum "$@" | sed -E "s|^[0-9a-f]{64}(  .*/game\\.sh)$|%s\\1|"\n' "$good" >"$E/sha256sum"
printf 'echo sourced >>"$HOME/marks/bashenv"\n' >"$E/env.sh"
chmod 755 "$E"/* && chown carol: "$E"/*
cpath=$E:/usr/bin
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-path; rc=$?
expect "a command the recipe names is Omarchy's, not the one first in the caller's PATH" \
  bash -c "test $rc == 0 && test \"\$(cat $M/helper)\" == pinned"
op=$(newop); pins "$op"
echo '# changed by an update' >>"$O/install/helpers/game.sh"
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "the script's own sha256sum is the system's: a changed file is still refused -> exit 5" test "$rc" == 5
sed -i '$d' "$O/install/helpers/game.sh"
cpath=/usr/bin
extra=(BASH_ENV="$E/env.sh" "BASH_FUNC_omarchy-game-helper%%=() { echo function >>\"\$HOME/marks/helper\"; }")
op=$(newop); pins "$op"
run "$op" "$(soon)" setup omarchy-install-path; rc=$?
extra=()
expect "BASH_ENV and an exported function do not reach the recipe" \
  bash -c "test $rc == 0 && test ! -e $M/bashenv && test \"\$(sort -u $M/helper)\" == pinned"
# Its folder a link to another of carol's folders: refused before chmod reaches that folder.
mv "$D" "$D.kept"
as_carol mkdir -m 755 /home/carol/elsewhere
as_carol ln -s /home/carol/elsewhere "$D"
op=$(newop)
run "$op" "$(soon)" setup omarchy-install-game; rc=$?
expect "its folder a link -> exit 2, the linked folder's mode unchanged" test "$rc:$(stat -c %a /home/carol/elsewhere)" == "2:755"
rm "$D" && mv "$D.kept" "$D"

say "result"
if ((fails)); then echo "$fails FAIL"; tail -20 /tmp/run.out; exit 1; fi
echo "all PASS"
