#!/usr/bin/env bash
# grassfield-secrets-handover (ADR-0035 D-12, step 2c) against fake Secret Service peers (tests/fixtures/fake-secret-service.py)
# on a private bus of the test's own. The fakes are started the way the session starts the real ones: by D-Bus activation
# (service files in the bus's own service directory), except the notification server and a leftover ksecretd, which already
# run when the helper starts. Never the owner's bus, files or secrets: the helper runs under env -i with a scratch HOME and
# XDG directories, as a dev session (GRASSFIELD_DEV=1), where it accepts the fakes' executable as ksecretd and gnome-keyring
# (GRASSFIELD_HANDOVER_KSECRETD, GRASSFIELD_HANDOVER_KEYRING; dev plumbing, ADR-0019).
#  1 no wallet file: nothing is asked of KWallet, the marker says so
#  2 the move: every item KWallet lists moves (what libsecret clients saved, and KWallet's own entries, which kwalletd stores
#    through libsecret as org.qt.keychain), an item the keychain holds is never overwritten, one notice, the marker; the
#    unit's readiness comes before the move ends (KWallet's prompt answered after it); the helper is not dumpable
#  3 a second run: nothing at all
#  4 KWallet's question refused, or not answered in time: nothing moves, the handover ends for good ("declined") with its
#    own notice, and the next login asks nothing
#  5 KWallet's own entries alone move too
#  6 an open wallet with nothing in it: "nothing" for good; a locked one that lists nothing: not final, nothing asked
#  7 an entry of an older KWallet, which ksecretd lists only once the wallet is open, moves too (the list is read again)
#  8 an empty value is never copied; an error after a question ends the handover for good ("incomplete"), the same error
#    without a question leaves it for the next session
#  9 no default keychain yet: it is created (its own question), then filled
# 10 a leftover ksecretd holding org.freedesktop.secrets is asked to quit before readiness; one that ignores quit gets SIGTERM
#    through its pidfd
# 11 a holder that is not ksecretd is left alone and nothing moves; a genuine KWallet with a Secret Service that is not
#    gnome-keyring: nothing asked, read or written
# 12 refused outside a Grassfield session; 13 the notices in a French session (SKIP without lrelease); 14 two KWallet items
#    with the same attributes: only the newest moves; 15 the user's own kwalletrc keeps KWallet: nothing is done; 16 a dev
#    run on a bus that is not a private test bus is refused; 17 the marker goes to $STATE_DIRECTORY; 18 in a user namespace
#    that maps only the user (what systemd gives a user unit with ProtectSystem= and the like, PrivateUsers=self) the peers
#    cannot be identified and nothing is read, stopped or written: why the unit has no such option (SKIP where unprivileged
#    user namespaces are not allowed)
# 19 the real gnome-keyring (unlocked with a throwaway password, in the scratch home) as the keychain, read back through
#    libsecret (SKIP without gnome-keyring-daemon or libsecret's introspection data); 20 the real ksecretd as the leftover,
#    quitting when asked (SKIP without ksecretd)
# 21 no item, label or value in the marker or the helper's output
# Needs g++ with the Qt 6 Core and D-Bus headers (or GRASSFIELD_SECRETS_HANDOVER: a built helper), dbus-daemon, dbus-send,
# python3 with PyGObject; SKIPs without them, and when libdbus cannot reach the bus or the bus gives no ProcessFD. The real
# daemons of scenarios 19 and 20 run under env -i with the scenario's scratch HOME and XDG directories, on its private bus.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/secrets-handover.XXXXXX")
bus_pid=""
real_pids=() # the real daemons of the running scenario (19, 20)
stop_bus() {
  # dbus-daemon leads its own process group (setsid): the fakes it activated are in it too.
  [[ -n $bus_pid ]] && kill -TERM -- "-$bus_pid" 2>/dev/null
  [[ -n $bus_pid ]] && wait "$bus_pid" 2>/dev/null
  bus_pid=""
}
stop_all() { local p; for p in "${real_pids[@]}"; do kill "$p" 2>/dev/null; done; stop_bus; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }
case $tmp in *[[:space:]\&\<\>\"\'\\]*) echo "SKIP: secrets_handover: the scratch directory '$tmp' needs quoting (TMPDIR)"; exit 0 ;; esac

for tool in dbus-daemon dbus-send python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: secrets_handover needs $tool"; exit 0; }
done
python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || { echo "SKIP: secrets_handover needs PyGObject (gi, Gio)"; exit 0; }
helper=${GRASSFIELD_SECRETS_HANDOVER:-}
if [[ -z $helper ]]; then
  command -v g++ >/dev/null && pkg-config --exists Qt6DBus 2>/dev/null || { echo "SKIP: secrets_handover needs g++ and the Qt 6 D-Bus headers"; exit 0; }
  "$root/apps/secrets-handover/build-direct.sh" --out "$tmp/bin" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: the helper builds"; exit 1; }
  helper=$tmp/bin/grassfield-secrets-handover
fi
py=$(readlink -f "$(command -v python3)")
fake=$root/tests/fixtures/fake-secret-service.py

bus_conf() { # bus_conf <dir> <listen address> <auth mechanism>
  printf '%s\n' '<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">' \
    '<busconfig>' '  <type>session</type>' "  <listen>$2</listen>" "  <auth>$3</auth>"
  [[ $3 == ANONYMOUS ]] && printf '%s\n' '  <allow_anonymous/>'
  printf '%s\n' "  <servicedir>$1/services</servicedir>" '  <policy context="default">' \
    '    <allow send_destination="*" eavesdrop="true"/>' '    <allow eavesdrop="true"/>' '    <allow own="*"/>' '  </policy>' \
    '</busconfig>'
}
start_bus() { # start_bus <dir>: sets bus and bus_pid
  bus_conf "$1" "unix:path=$1/bus.sock" EXTERNAL >"$1/bus.conf"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  if wait_until 3 test -s "$1/bus.address"; then bus=$(head -n 1 "$1/bus.address"); return 0; fi
  kill "$bus_pid" 2>/dev/null; wait "$bus_pid" 2>/dev/null; bus_pid=""
  bus_conf "$1" "tcp:host=127.0.0.1,port=0" ANONYMOUS >"$1/bus.conf"
  : >"$1/bus.address"
  setsid env -i PATH="$PATH" HOME="$1" XDG_RUNTIME_DIR="$1" dbus-daemon --config-file="$1/bus.conf" --nofork --print-address=1 \
    >"$1/bus.address" 2>"$1/bus.log" </dev/null &
  bus_pid=$!
  wait_until 5 test -s "$1/bus.address" || return 1
  bus=$(head -n 1 "$1/bus.address")
}
has() { dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  "string:$1" 2>/dev/null | awk '/boolean/ {print $2}'; }
owned() { [[ $(has "$1") == true ]]; } # asked again at every try of wait_until
service() { # service <dir> <bus name> <role> [fake options]: activatable on that bus
  local d=$1 name=$2 role=$3
  shift 3
  printf '#!/bin/sh\nexport GF_TEST_BUS=1 GF_TEST_BUS_DIR=%s DBUS_SESSION_BUS_ADDRESS="$(head -n 1 %s/bus.address)"\nexec python3 -I %s %s --log %s/calls.log --store %s/store.log %s\n' \
    "$d" "$d" "$fake" "$role" "$d" "$d" "$*" >"$d/$role.sh"
  chmod 755 "$d/$role.sh"
  printf '[D-BUS Service]\nName=%s\nExec=%s/%s.sh\n' "$name" "$d" "$role" >"$d/services/$name.service"
}
running() { # running <dir> <bus name> <role> [fake options]: started now, before the helper (as the shell's notification server is)
  local d=$1 name=$2 role=$3
  shift 3
  service "$d" "$name" "$role" "$@"
  rm -f "$d/services/$name.service"
  setsid env -i PATH="$PATH" sh "$d/$role.sh" >>"$d/fakes.log" 2>&1 </dev/null &
  wait_until 5 owned "$name"
}

# One scenario: a fresh bus, a scratch home, the fakes it names; the helper as the unit runs it.
# Globals read: WALLET (yes|no), KWALLET (fake options, or "none"), KEYCHAIN (fake options, or "none"), LEFTOVER (options, or
# "none"), KSECRETD and KEYRING (the executables the helper accepts; default: the fakes' python), KWALLETRC (the user's own
# kwalletrc), NS (run the helper in a user namespace that maps only the user), DUMPCHECK (record who owns the running helper's
# /proc entries), REAL_KEYRING (the real gnome-keyring, unlocked with a throwaway password, holds org.freedesktop.secrets and
# already the example app's item), REAL_LEFTOVER (the real ksecretd, without the session's kwalletrc, holds it).
gk_py() { # gk_py seed|lookup: the real keychain of the scenario's bus, through libsecret (test values only)
  DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
import sys, gi
gi.require_version("Secret", "1")
from gi.repository import Secret
service = Secret.Service.get_sync(Secret.ServiceFlags.LOAD_COLLECTIONS, None)
example = {"xdg:schema": "org.example.App", "account": "me"}
if sys.argv[1] == "seed":
    default = Secret.Collection.for_alias_sync(service, "default", Secret.CollectionFlags.NONE, None)
    Secret.Item.create_sync(default, None, example, "Example App", Secret.Value.new("keychain-example", -1, "text/plain"),
                            Secret.ItemCreateFlags.NONE, None)
else:
    wanted = [("chromium", {"xdg:schema": "chrome_libsecret_os_crypt_password_v2", "application": "chromium"}), ("example", example),
              ("legacy", {"xdg:schema": "org.qt.keychain", "server": "Passwords", "user": "smb-share", "type": "plaintext"})]
    found = []
    for name, attributes in wanted:
        items = service.search_sync(None, attributes, Secret.SearchFlags.ALL | Secret.SearchFlags.LOAD_SECRETS, None)
        found.append("%s=%s" % (name, ",".join(sorted(i.get_secret().get_text() for i in items))))
    print(" ".join(found))' "$1"
}
run() { # run <name> [env assignments...]
  local d=$tmp/$1
  shift
  mkdir -p "$d/services" "$d/home/.config" "$d/data" "$d/state" "$d/gk" "$d/ks" "$d/run"
  chmod 700 "$d/run"
  [[ -n ${KWALLETRC:-} ]] && printf '%s\n' "$KWALLETRC" >"$d/home/.config/kwalletrc"
  : >"$d/calls.log"; : >"$d/store.log"
  [[ $WALLET == yes ]] && mkdir -p "$d/data/kwalletd" && : >"$d/data/kwalletd/kdewallet.kwl"
  # The fakes' options are split into words on purpose.
  # shellcheck disable=SC2086
  [[ $KWALLET != none ]] && service "$d" org.kde.secretservicecompat kwallet $KWALLET
  # shellcheck disable=SC2086
  [[ $KEYCHAIN != none ]] && service "$d" org.freedesktop.secrets keychain $KEYCHAIN
  if ! start_bus "$d"; then echo "bus: $(head -n 1 "$d/bus.log")" >"$d/out"; return; fi
  running "$d" org.freedesktop.Notifications notifications
  if [[ $LEFTOVER != none ]]; then
    # shellcheck disable=SC2086
    running "$d" org.freedesktop.secrets leftover $LEFTOVER
  fi
  if [[ -n ${REAL_KEYRING:-} ]]; then
    printf %s throwaway-password | env -i PATH="$PATH" HOME="$d/gk" XDG_DATA_HOME="$d/gk/data" XDG_RUNTIME_DIR="$d/run" \
      DBUS_SESSION_BUS_ADDRESS="$bus" gnome-keyring-daemon --foreground --unlock --components=secrets >"$d/gk.log" 2>&1 &
    real_pids+=($!)
    wait_until 10 owned org.freedesktop.secrets && gk_py seed >>"$d/gk.log" 2>&1
  fi
  if [[ -n ${REAL_LEFTOVER:-} ]]; then
    env -i PATH="$PATH" HOME="$d/ks" XDG_CONFIG_HOME="$d/ks/.config" XDG_DATA_HOME="$d/ks/data" XDG_RUNTIME_DIR="$d/run" \
      DBUS_SESSION_BUS_ADDRESS="$bus" QT_QPA_PLATFORM=offscreen ksecretd >"$d/ks.log" 2>&1 &
    real_pids+=($!)
    echo $! >"$d/ksecretd.pid"
    wait_until 10 owned org.freedesktop.secrets
  fi
  python3 -I -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.bind(sys.argv[1]); s.settimeout(30)
try:
    data = s.recv(64)
    open(sys.argv[2], "w").write("%s %.3f\n" % (data.decode(), time.time()))
except socket.timeout:
    pass' "$d/notify.sock" "$d/ready" &
  local listener=$!
  wait_until 3 test -S "$d/notify.sock"
  env -i PATH="$PATH" HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_DATA_HOME="$d/data" XDG_STATE_HOME="$d/state" XDG_RUNTIME_DIR="$d" \
    DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 GF_TEST_BUS_DIR="$d" QT_FORCE_STDERR_LOGGING=1 GRASSFIELD_DEV=1 GRASSFIELD_LANG=en \
    GRASSFIELD_HANDOVER_KSECRETD="${KSECRETD:-$py}" GRASSFIELD_HANDOVER_KEYRING="${KEYRING:-$py}" GRASSFIELD_HANDOVER_PROMPT_MS=8000 \
    GRASSFIELD_HANDOVER_NOTIFY_MS=3000 NOTIFY_SOCKET="$d/notify.sock" "$@" timeout 60 ${NS:+unshare --user --map-current-user} "$helper" \
    >"$d/out" 2>"$d/err" &
  local runner=$!
  if [[ -n ${DUMPCHECK:-} ]] && wait_until 10 test -s "$d/ready"; then
    # timeout runs the helper as its child; who owns /proc/<pid>: root for a process that is not dumpable.
    local child
    child=$(pgrep -P "$runner" -n 2>/dev/null) && stat -c %u "/proc/$child/status" >"$d/owner" 2>/dev/null
  fi
  wait "$runner"
  echo $? >"$d/rc"
  date +%s.%N >"$d/ended"
  sleep 0.3
  kill "$listener" 2>/dev/null; wait "$listener" 2>/dev/null
  cp "$d/state/grassfield/secrets-handover" "$d/marker" 2>/dev/null || : >"$d/marker"
  [[ -n ${REAL_KEYRING:-} ]] && gk_py lookup >"$d/lookup" 2>>"$d/gk.log"
  if [[ -n ${REAL_LEFTOVER:-} ]]; then
    kill -0 "$(cat "$d/ksecretd.pid")" 2>/dev/null && echo running >"$d/ksecretd.after" || echo exited >"$d/ksecretd.after"
    has org.freedesktop.secrets >"$d/secrets.after"
  fi
  local p
  for p in "${real_pids[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  real_pids=()
  stop_bus
}
calls() { grep -c "\"method\": \"$2\"" "$tmp/$1/calls.log"; }
role_calls() { grep -c "\"role\": \"$2\"" "$tmp/$1/calls.log"; }
created() { python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["value"] for l in open(sys.argv[1]) if l.strip()))' "$tmp/$1/store.log"; }
notified() { python3 -I -c 'import json,sys; print("|".join(json.loads(l)["notify"]["summary"] for l in open(sys.argv[1]) if "notify" in json.loads(l)))' "$tmp/$1/calls.log"; }
said() { grep -qx "grassfield-secrets-handover: $2" "$tmp/$1/out"; }
marked() { grep -qx "$2" "$tmp/$1/marker"; }

# Preflight: libdbus reaches a private bus, and the bus hands out ProcessFD (the helper identifies its peers by it).
mkdir -p "$tmp/pre/services"
if ! start_bus "$tmp/pre"; then
  desc="a private bus starts [$(head -n 1 "$tmp/pre/bus.log")]"; check false; exit 1
fi
if ! pre=$(dbus-send --bus="$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId 2>&1); then
  echo "SKIP: secrets_handover: this environment gives libdbus no way to a private bus (${pre%%$'\n'*})"; exit 0
fi
pfd=$(DBUS_SESSION_BUS_ADDRESS=$bus python3 -I -c '
from gi.repository import Gio, GLib
c = Gio.bus_get_sync(Gio.BusType.SESSION)
r = c.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionCredentials",
                GLib.Variant("(s)", (c.get_unique_name(),)), None, Gio.DBusCallFlags.NONE, 5000, None)
print("ProcessFD" in r.unpack()[0])' 2>&1)
stop_bus
if [[ $pfd != True ]]; then echo "SKIP: secrets_handover: this bus gives no ProcessFD ($pfd)"; exit 0; fi

# 1 --------------------------------------------------------------------------------------------------------------------
WALLET=no KWALLET="" KEYCHAIN="" LEFTOVER=none run nowallet
desc="1 no wallet file: nothing moved, the marker says 'nothing' [$(cat "$tmp/nowallet/out")]"
check bash -c "$(declare -f said marked); tmp=\$1; said nowallet 'nothing moved=0 kept=0 skipped=0' && marked nowallet 'nothing moved=0 kept=0 skipped=0'" _ "$tmp"
desc="1 ... and neither KWallet nor the keychain was started or asked anything"
check test "$(role_calls nowallet kwallet)$(role_calls nowallet keychain)" = 00

# 2 --------------------------------------------------------------------------------------------------------------------
DUMPCHECK=1 WALLET=yes KWALLET="--locked --delay 1.5" KEYCHAIN="" LEFTOVER=none run move
desc="2 the move: two items moved, one kept [$(cat "$tmp/move/out")]"
check said move "moved moved=2 kept=1 skipped=0"
desc="2 the keychain received Chromium's key and KWallet's own entry (org.qt.keychain); the item it held is not overwritten [$(created move)]"
check test "$(created move)" = "kwallet-chromium-key kwallet-legacy"
desc="2 KWallet was unlocked through its own prompt (it was locked), and read only for the items that moved"
check test "$(calls move Unlock) $(calls move GetSecret)" = "1 2"
desc="2 one notice, in the session's words [$(notified move)]"
check bash -c '[[ $1 == "Saved passwords moved" ]] && grep -q "\"app\": \"Grassfield\"" "$2/calls.log"' _ "$(notified move)" "$tmp/move"
desc="2 the marker: moved, with counts only"
check marked move "moved moved=2 kept=1 skipped=0"
desc="2 readiness came before the move ended (KWallet's question was answered 1.5 s after it)"
check bash -c 'read -r msg at <"$1/ready" && [[ $msg == READY=1 ]] && awk -v a="$at" -v e="$(cat "$1/ended")" "BEGIN { exit !(e - a > 1.0) }"' _ "$tmp/move"
if [[ $(id -u) != 0 ]]; then
  desc="2 the helper is not dumpable: its /proc entries are root's while it runs [owner $(cat "$tmp/move/owner" 2>/dev/null)]"
  check test "$(cat "$tmp/move/owner" 2>/dev/null)" = 0
else
  echo "SKIP: secrets_handover: run as root, /proc entries are root's anyway (the helper's PR_SET_DUMPABLE not checked)"
fi

# 3 --------------------------------------------------------------------------------------------------------------------
mkdir -p "$tmp/again/state/grassfield"; cp "$tmp/move/marker" "$tmp/again/state/grassfield/secrets-handover"
WALLET=yes KWALLET="--locked" KEYCHAIN="" LEFTOVER=none run again
desc="3 a second run (the marker exists): nothing is started or asked"
check bash -c '[[ ! -s $1/calls.log || $(grep -vc "\"role\": \"notifications\"" "$1/calls.log") == 0 ]]' _ "$tmp/again"
desc="3 ... and says so [$(cat "$tmp/again/out")]"
check said again "done moved=0 kept=0 skipped=0"

# 4 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--locked --answer dismiss" KEYCHAIN="" LEFTOVER=none run refused
desc="4 KWallet's question refused: nothing created, the handover ends for good ('declined') [$(cat "$tmp/refused/out")]"
check bash -c "$(declare -f said marked); tmp=\$1; said refused 'declined moved=0 kept=1 skipped=0' && marked refused 'declined moved=0 kept=1 skipped=0' && [[ ! -s \$1/refused/store.log ]]" _ "$tmp"
desc="4 ... with its own notice, once [$(notified refused)]"
check test "$(notified refused)" = "Saved passwords not moved"
mkdir -p "$tmp/refused2/state/grassfield"; cp "$tmp/refused/marker" "$tmp/refused2/state/grassfield/secrets-handover"
WALLET=yes KWALLET="--locked --answer dismiss" KEYCHAIN="" LEFTOVER=none run refused2
desc="4 ... and the next login asks nothing again"
check test "$(calls refused2 Unlock)$(notified refused2)" = 0
WALLET=yes KWALLET="--locked --delay 3" KEYCHAIN="" LEFTOVER=none run unanswered GRASSFIELD_HANDOVER_PROMPT_MS=1000
desc="4 a question not answered in time is dismissed and counts as refused [$(cat "$tmp/unanswered/out")]"
check bash -c "$(declare -f said marked); tmp=\$1; said unanswered 'declined moved=0 kept=1 skipped=0' && [[ \$(grep -c '\"method\": \"Dismiss\"' \$1/unanswered/calls.log) == 1 && ! -s \$1/unanswered/store.log ]]" _ "$tmp"

# 5 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--locked --only-legacy" KEYCHAIN="" LEFTOVER=none run legacy
desc="5 KWallet's own entries, as kwalletd stores them (org.qt.keychain), move too [$(created legacy); $(cat "$tmp/legacy/out")]"
check bash -c '[[ $1 == kwallet-legacy ]] && grep -qx "grassfield-secrets-handover: moved moved=1 kept=0 skipped=0" "$2/out"' _ "$(created legacy)" "$tmp/legacy"

# 6 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--empty" KEYCHAIN="" LEFTOVER=none run empty
desc="6 an open wallet with nothing in it: 'nothing' for good, KWallet never unlocked, the keychain never started"
check bash -c '[[ $(grep -c "\"method\": \"Unlock\"" "$1/calls.log") == 0 && $(grep -c "\"role\": \"keychain\"" "$1/calls.log") == 0 ]] && grep -qx "nothing moved=0 kept=0 skipped=0" "$1/marker"' _ "$tmp/empty"
WALLET=yes KWALLET="--empty --locked" KEYCHAIN="" LEFTOVER=none run emptylocked
desc="6 a locked wallet that lists nothing: not final (deferred, no marker), nothing asked [$(cat "$tmp/emptylocked/out")]"
check bash -c '[[ ! -s $1/marker && $(grep -c "\"method\": \"Unlock\"" "$1/calls.log") == 0 ]] && grep -qx "grassfield-secrets-handover: deferred moved=0 kept=0 skipped=0" "$1/out"' _ "$tmp/emptylocked"

# 7 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--locked --old-entry" KEYCHAIN="" LEFTOVER=none run oldentry
desc="7 an entry of an older KWallet, listed only once the wallet is open, moves too [$(created oldentry)]"
check bash -c '[[ $1 == "kwallet-chromium-key kwallet-legacy kwallet-old-entry" ]] && grep -qx "grassfield-secrets-handover: moved moved=3 kept=1 skipped=0" "$2/out"' _ "$(created oldentry)" "$tmp/oldentry"

# 8 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--empty-value" KEYCHAIN="" LEFTOVER=none run emptyvalue
desc="8 an item whose value is empty is never copied (a bad copy would never be replaced) [$(created emptyvalue); $(cat "$tmp/emptyvalue/out")]"
check bash -c '[[ $1 == kwallet-legacy ]] && grep -qx "grassfield-secrets-handover: moved moved=1 kept=1 skipped=1" "$2/out"' _ "$(created emptyvalue)" "$tmp/emptyvalue"

WALLET=yes KWALLET="--locked --fail-get" KEYCHAIN="" LEFTOVER=none run failasked
desc="8 an error after KWallet's question ends the handover for good ('incomplete'): the question never comes back [$(cat "$tmp/failasked/out")]"
check bash -c 'grep -qx "incomplete moved=0 kept=1 skipped=0" "$1/marker" && [[ ! -s $1/store.log ]]' _ "$tmp/failasked"
WALLET=yes KWALLET="--fail-get" KEYCHAIN="" LEFTOVER=none run failunasked
desc="8 the same error without a question: no marker, the next session tries again [$(cat "$tmp/failunasked/out")]"
check bash -c '[[ ! -s $1/marker && ! -s $1/store.log ]] && grep -qx "grassfield-secrets-handover: deferred moved=0 kept=1 skipped=0" "$1/out"' _ "$tmp/failunasked"

# 9 --------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="" KEYCHAIN="--no-default" LEFTOVER=none run newkeychain
desc="9 no default keychain yet: it is created through its own prompt, then every item moves [$(created newkeychain)]"
check bash -c '[[ $(grep -c "\"method\": \"CreateCollection\"" "$1/calls.log") == 1 ]] && grep -qx "grassfield-secrets-handover: moved moved=3 kept=0 skipped=0" "$1/out"' _ "$tmp/newkeychain"

# 10 -------------------------------------------------------------------------------------------------------------------
WALLET=no KWALLET="" KEYCHAIN="" LEFTOVER="" run leftover
desc="10 a leftover ksecretd is asked to quit (KDBusService's /MainApplication quit), quits, and the Secret Service is free before readiness"
check bash -c '[[ $(grep -c "\"method\": \"quit\"" "$1/calls.log") == 1 && $(grep -c "\"method\": \"SIGTERM\"" "$1/calls.log") == 0 && -s $1/ready ]] && grep -q "ksecretd quit; the Secret Service is free" "$1/err"' _ "$tmp/leftover"
WALLET=no KWALLET="" KEYCHAIN="" LEFTOVER="--ignore-quit" run stubborn
desc="10 one that ignores quit gets SIGTERM through its pidfd, and the name is free before readiness"
check bash -c '[[ $(grep -c "\"method\": \"quit\"" "$1/calls.log") == 1 && $(grep -c "\"method\": \"SIGTERM\"" "$1/calls.log") == 1 && -s $1/ready ]] && grep -q "ksecretd stopped (SIGTERM); the Secret Service is free" "$1/err"' _ "$tmp/stubborn"

# 11 -------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="" KEYCHAIN="" LEFTOVER="" KSECRETD=/usr/bin/env KEYRING=/usr/bin/env run stranger
desc="11 a holder that is not the expected program is left alone: no quit, and nothing is read from KWallet nor written"
check bash -c '[[ $(grep -c "\"method\": \"quit\"" "$1/calls.log") == 0 && $(grep -c "\"method\": \"GetSecret\"" "$1/calls.log") == 0 && ! -s $1/store.log ]] && grep -q "^grassfield-secrets-handover: deferred" "$1/out"' _ "$tmp/stranger"
WALLET=yes KWALLET="--locked" KEYCHAIN="" LEFTOVER=none KEYRING=/usr/bin/env run strangerkeychain
desc="11 a genuine KWallet and a Secret Service that is not gnome-keyring: nothing asked, read or written, no marker [$(cat "$tmp/strangerkeychain/out")]"
check bash -c '[[ $(grep -c "\"method\": \"Unlock\"" "$1/calls.log") == 0 && $(grep -c "\"method\": \"GetSecret\"" "$1/calls.log") == 0 && $(grep -c "\"method\": \"CreateItem\"" "$1/calls.log") == 0 && ! -s $1/store.log && ! -s $1/marker ]] && grep -q "^grassfield-secrets-handover: deferred" "$1/out" && grep -q "not held by gnome-keyring" "$1/err"' _ "$tmp/strangerkeychain"
desc="11 ... and not one call reaches that Secret Service: no search either, nothing of KWallet's is shown to it [$(grep -c '"role": "keychain"' "$tmp/strangerkeychain/calls.log")]"
check test "$(grep -c '"role": "keychain"' "$tmp/strangerkeychain/calls.log")" = 0

# 12 -------------------------------------------------------------------------------------------------------------------
out=$(env -i PATH="$PATH" HOME="$tmp" "$helper" 2>&1); rc=$?
desc="12 refused outside a Grassfield session (exit 2) [$rc: $out]"
check bash -c '[[ $1 == 2 && $2 == *"refused: not a Grassfield session"* ]]' _ "$rc" "$out"

# 13 -------------------------------------------------------------------------------------------------------------------
lrelease=/usr/lib/qt6/bin/lrelease
mkdir -p "$tmp/qm"
if [[ -x $lrelease ]] && "$lrelease" -silent "$root/translations/grassfield_fr.ts" -qm "$tmp/qm/grassfield_fr.qm" >/dev/null 2>&1; then
  WALLET=yes KWALLET="" KEYCHAIN="" LEFTOVER=none run french GRASSFIELD_LANG=fr GRASSFIELD_TRANSLATIONS_DIR="$tmp/qm"
  desc="13 in a French session the notice is French [$(notified french)]"
  check test "$(notified french)" = "Mots de passe enregistrés déplacés"
  WALLET=yes KWALLET="--locked --answer dismiss" KEYCHAIN="" LEFTOVER=none run frenchdeclined GRASSFIELD_LANG=fr GRASSFIELD_TRANSLATIONS_DIR="$tmp/qm"
  desc="13 ... and so is the notice of a refused question [$(notified frenchdeclined)]"
  check test "$(notified frenchdeclined)" = "Mots de passe enregistrés non déplacés"
else
  echo "SKIP: secrets_handover: lrelease missing (the French notices not checked)"
fi

# 14 -------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="--duplicate" KEYCHAIN="" LEFTOVER=none run duplicate
desc="14 two KWallet items with the same attributes (an older wallet listed first): only the newest moves [$(created duplicate); $(cat "$tmp/duplicate/out")]"
check bash -c '[[ $2 == "kwallet-chromium-key kwallet-legacy" ]] && grep -qx "grassfield-secrets-handover: moved moved=2 kept=2 skipped=0" "$1/out"' _ "$tmp/duplicate" "$(created duplicate)"

# 15 -------------------------------------------------------------------------------------------------------------------
KWALLETRC=$'[org.freedesktop.secrets]\napiEnabled[$i]=true' WALLET=yes KWALLET="" KEYCHAIN="" LEFTOVER="" run userchoice
desc="15 the user's own kwalletrc keeps KWallet as the Secret Service: no quit, nothing asked, no marker, ready at once"
check bash -c '[[ ! -s $1/calls.log && ! -s $1/marker && -s $1/ready ]] && grep -q "left alone" "$1/out"' _ "$tmp/userchoice"
unset KWALLETRC

# 16 -------------------------------------------------------------------------------------------------------------------
WALLET=yes KWALLET="" KEYCHAIN="" LEFTOVER="" run devbus GF_TEST_BUS=0
desc="16 a dev run on a bus that is not a private test bus is refused (exit 2) before anything is asked [$(cat "$tmp/devbus/rc")]"
check bash -c '[[ $(cat "$1/rc") == 2 && ! -s $1/calls.log ]] && grep -q "refused: a dev session runs it only on a private test bus" "$1/err"' _ "$tmp/devbus"

# 17 -------------------------------------------------------------------------------------------------------------------
WALLET=no KWALLET="" KEYCHAIN="" LEFTOVER=none run statedir STATE_DIRECTORY="$tmp/statedir/unit-state"
desc="17 the marker goes to the unit's \$STATE_DIRECTORY (the directory systemd made for it, mode 0700)"
check bash -c 'grep -qx "nothing moved=0 kept=0 skipped=0" "$1/unit-state/secrets-handover" && [[ ! -e $1/state/grassfield/secrets-handover ]]' _ "$tmp/statedir"

# 18 -------------------------------------------------------------------------------------------------------------------
if unshare --user --map-current-user true 2>/dev/null; then
  NS=1 WALLET=yes KWALLET="" KEYCHAIN="" LEFTOVER="" run userns
  desc="18 in a user namespace like PrivateUsers=self no peer is identified: no quit, nothing read or written, deferred"
  check bash -c '[[ $(grep -c "\"method\": \"quit\"" "$1/calls.log") == 0 && $(grep -c "\"method\": \"GetSecret\"" "$1/calls.log") == 0 && ! -s $1/store.log && ! -s $1/marker ]] && grep -q "^grassfield-secrets-handover: deferred" "$1/out"' _ "$tmp/userns"
else
  echo "SKIP: secrets_handover: no unprivileged user namespace here (scenario 18, the unit's reason to have no namespace option)"
fi

# 19 -------------------------------------------------------------------------------------------------------------------
if command -v gnome-keyring-daemon >/dev/null && python3 -I -c 'import gi; gi.require_version("Secret", "1")' 2>/dev/null; then
  REAL_KEYRING=1 WALLET=yes KWALLET="--locked" KEYCHAIN=none LEFTOVER=none KEYRING=/usr/bin/gnome-keyring-daemon run realkeyring
  desc="19 the real gnome-keyring as the keychain: what moved is found there through libsecret, its own item unchanged [$(cat "$tmp/realkeyring/lookup" 2>/dev/null); $(cat "$tmp/realkeyring/out")]"
  check bash -c '[[ $(cat "$1/lookup") == "chromium=kwallet-chromium-key example=keychain-example legacy=kwallet-legacy" ]] && grep -qx "grassfield-secrets-handover: moved moved=2 kept=1 skipped=0" "$1/out"' _ "$tmp/realkeyring"
else
  echo "SKIP: secrets_handover: gnome-keyring-daemon or libsecret's introspection data (Secret-1) missing (scenario 19, the real keychain)"
fi

# 20 -------------------------------------------------------------------------------------------------------------------
if [[ -x /usr/bin/ksecretd ]]; then
  REAL_LEFTOVER=1 WALLET=no KWALLET="" KEYCHAIN="" LEFTOVER=none KSECRETD=/usr/bin/ksecretd run realleftover
  desc="20 the real ksecretd holding the Secret Service quits when asked: the name is free before readiness [$(cat "$tmp/realleftover/ksecretd.after" 2>/dev/null), owned $(cat "$tmp/realleftover/secrets.after" 2>/dev/null)]"
  check bash -c '[[ $(cat "$1/ksecretd.after") == exited && $(cat "$1/secrets.after") == false && -s $1/ready ]] && grep -q "ksecretd quit; the Secret Service is free" "$1/err"' _ "$tmp/realleftover"
else
  echo "SKIP: secrets_handover: /usr/bin/ksecretd missing (scenario 20, the real leftover)"
fi

# 21 -------------------------------------------------------------------------------------------------------------------
desc="21 no item, label or value in any marker or in the helper's output"
check bash -c '! grep -rlE "kwallet-|keychain-example|Chromium|chromium|Example App|smb-share|old-site|xdg:schema|throwaway" "$1"/*/marker "$1"/*/out "$1"/*/err' _ "$tmp"

exit "$fail"
