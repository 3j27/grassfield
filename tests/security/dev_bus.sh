#!/usr/bin/env bash
# The dev session's private bus starts nothing of the machine (security counter-review of f9e24e1, LOW-2; ADR-0011). Its
# services would inherit the owner's XDG_RUNTIME_DIR (gvfsd mounts $XDG_RUNTIME_DIR/gvfs; gnome-keyring, dconf and the
# document portal use their folders there), so the bus has no service folder at all: an allowlist of none.
#
#   static   scripts/dev/dev-bus.conf has no <servicedir>, <standard_session_servicedirs/>, <include>, <includedir> or service
#            helper; scripts/dev/shell-run.sh starts its one dbus-daemon with that file (never --session) and refuses a bus
#            scripts/dev/dev-bus-check.sh does not pass;
#   runtime  a dbus-daemon started with dev-bus.conf, under this tree's .dev/ (never the owner's bus), with service files
#            planted in every folder the standard session configuration reads (XDG_RUNTIME_DIR, XDG_DATA_HOME, XDG_DATA_DIRS):
#            its activatable names (ListActivatableNames, which starts nothing) are org.freedesktop.DBus alone, and
#            dev-bus-check.sh passes;
#   controls the same file with <standard_session_servicedirs/> (what `dbus-daemon --session` reads), with one <servicedir>, and
#            (Unix socket only) the system's session.conf itself: each lists the planted names (and the machine's services
#            where it reads /usr/share: gvfs, the keyring, dconf, the portals are reported when present), and
#            dev-bus-check.sh fails on each, naming them.
#
# Every bus listens on a Unix socket under .dev/; where the sandbox refuses one, on loopback TCP with anonymous authentication
# (a copy of the file with only <auth> changed and <allow_anonymous/> added; the address is given with --address in both
# cases). The buses run with a clean environment whose homes and runtime folder are in the scratch folder. Exit 0 PASS, 1 FAIL,
# 2 environment error; SKIP (exit 0) without dbus-daemon, gdbus or python3.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
conf=$root/scripts/dev/dev-bus.conf
check=$root/scripts/dev/dev-bus-check.sh
fail=0
pass() { echo "PASS: dev bus $*"; }
bad() { echo "FAIL: dev bus $*"; fail=1; }
for tool in dbus-daemon gdbus python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: dev_bus needs $tool"; exit 0; }
done
mkdir -p "$root/.dev"
# A short name: libdbus caps socket paths at 99 bytes.
s=$(mktemp -d "$root/.dev/db.XXXXXX") || { echo "ENVIRONMENT: no scratch directory"; exit 2; }
chmod 700 "$s"
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$s"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# The scratch path goes into XML: nothing there that needs quoting.
case $s in *[[:space:]\&\<\>\"\'\\]*) echo "ENVIRONMENT: the scratch directory '$s' needs quoting"; exit 2 ;; esac

# --- static ---------------------------------------------------------------------------------------------------------
static=$(python3 -I - "$conf" "$root/scripts/dev/shell-run.sh" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
conf, run = sys.argv[1:3]
problems = []
tree = ET.parse(conf).getroot()
if tree.tag != "busconfig":
    problems.append("dev-bus.conf: the root element is not busconfig")
forbidden = {"servicedir", "standard_session_servicedirs", "standard_system_servicedirs", "servicehelper", "include", "includedir"}
found = sorted({e.tag for e in tree.iter()} & forbidden)
if found:
    problems.append("dev-bus.conf names " + ", ".join(found))
if [e.text for e in tree.findall("type")] != ["session"]:
    problems.append("dev-bus.conf: not one <type>session</type>")
if [e.text for e in tree.findall("auth")] != ["EXTERNAL"] or tree.find("allow_anonymous") is not None:
    problems.append("dev-bus.conf: authentication is not EXTERNAL alone")
code = "\n".join("" if l.lstrip().startswith("#") else l for l in open(run).read().split("\n"))
starts = [l.strip() for l in code.split("\n") if re.search(r"\bdbus-daemon\b", l) and not re.search(r"command -v dbus-daemon", l)]
if starts != ['setsid dbus-daemon --config-file="$root/scripts/dev/dev-bus.conf" --nofork --print-address=1 \\']:
    problems.append("shell-run.sh starts dbus-daemon otherwise: " + repr(starts))
if re.search(r"dbus-daemon[^\n]*--session\b", code):
    problems.append("shell-run.sh starts a bus with --session")
if not re.search(r'if ! unexpected=\$\("\$root/scripts/dev/dev-bus-check\.sh" "\$bus"\); then\n\s*echo "shell-run: refusing: [^\n]*" >&2\n\s*exit 1\n\s*fi\n\s*bus_env=\(DBUS_SESSION_BUS_ADDRESS="\$bus"\)', code):
    problems.append("shell-run.sh does not refuse a bus dev-bus-check.sh fails before it uses it")
print("\n".join(problems))
PY
) || { echo "ENVIRONMENT: the static check did not run"; exit 2; }
if [[ -z $static ]]; then
  pass "static: dev-bus.conf has no service folder, include or helper; shell-run.sh starts the bus with it and refuses one the guard fails"
else
  while IFS= read -r line; do bad "static: $line"; done <<<"$static"
fi

# --- runtime --------------------------------------------------------------------------------------------------------
# Service files in every folder the standard session configuration reads, and one for a <servicedir> of its own.
mkdir -p "$s/run/dbus-1/services" "$s/data/dbus-1/services" "$s/sys/dbus-1/services" "$s/extra" "$s/home"
plant() { printf '[D-BUS Service]\nName=%s\nExec=/bin/false\n' "$2" >"$1/$2.service"; }
plant "$s/run/dbus-1/services" org.example.PlantedRuntimeDir
plant "$s/data/dbus-1/services" org.example.PlantedDataHome
plant "$s/sys/dbus-1/services" org.example.PlantedDataDirs
plant "$s/extra" org.example.PlantedServiceDir
planted_std="org.example.PlantedRuntimeDir org.example.PlantedDataHome org.example.PlantedDataDirs"

tcp=0
# configure <source file> <out file> [extra XML]: the file as the bus reads it (TCP: anonymous authentication).
configure() {
  python3 -I - "$1" "$2" "$tcp" "${3:-}" <<'PY'
import sys
src, out, tcp, extra = sys.argv[1:5]
text = open(src).read()
if tcp == "1":
    if text.count("<auth>EXTERNAL</auth>") != 1:
        sys.exit("no single <auth>EXTERNAL</auth> in " + src)
    text = text.replace("<auth>EXTERNAL</auth>", "<auth>ANONYMOUS</auth>\n  <allow_anonymous/>")
if extra:
    if text.count("</busconfig>") != 1:
        sys.exit("no single </busconfig> in " + src)
    text = text.replace("</busconfig>", extra + "\n</busconfig>")
open(out, "w").write(text)
PY
}
# start_bus <name> <dbus-daemon config arguments...>: starts a bus (clean environment, homes in the scratch folder); sets $addr.
start_bus() {
  local name=$1 listen
  shift
  if ((tcp)); then listen="tcp:host=127.0.0.1,port=0"; else listen="unix:path=$s/$name.sock"; fi
  : >"$s/$name.addr"
  env -i PATH="$PATH" HOME="$s/home" XDG_RUNTIME_DIR="$s/run" XDG_DATA_HOME="$s/data" XDG_DATA_DIRS="$s/sys:/usr/local/share:/usr/share" \
    XDG_CONFIG_HOME="$s/home" GRASSFIELD_DEV=1 \
    setsid dbus-daemon "$@" --address="$listen" --nofork --print-address=1 >"$s/$name.addr" 2>"$s/$name.log" </dev/null &
  pids+=("$!")
  local i
  for ((i = 0; i < 50; i++)); do
    [[ -s $s/$name.addr ]] && break
    kill -0 "${pids[-1]}" 2>/dev/null || break
    sleep 0.1
  done
  addr=$(head -n 1 "$s/$name.addr")
  [[ -n $addr ]]
}

configure "$conf" "$s/dev.conf" || { echo "ENVIRONMENT: dev-bus.conf could not be copied"; exit 2; }
if ! start_bus dev --config-file="$s/dev.conf"; then
  if grep -q "Operation not permitted\|Permission denied" "$s/dev.log"; then
    tcp=1
    echo "NOTE: dev bus: no Unix socket here ($(head -n 1 "$s/dev.log")): loopback TCP with anonymous authentication"
    configure "$conf" "$s/dev.conf" || { echo "ENVIRONMENT: dev-bus.conf could not be copied"; exit 2; }
    start_bus dev --config-file="$s/dev.conf" || { cat "$s/dev.log"; echo "ENVIRONMENT: no private bus"; exit 2; }
  else
    cat "$s/dev.log"
    echo "ENVIRONMENT: no private bus"
    exit 2
  fi
fi
case $addr in
  "unix:path=$s/"* | tcp:host=127.0.0.1,*) ;;
  *) echo "ENVIRONMENT: unexpected bus address '$addr'"; exit 2 ;;
esac
# The bus as started differs from dev-bus.conf only in the authentication of a TCP run.
if ((tcp)); then
  diff <(grep -v '<auth>\|<allow_anonymous/>' "$conf") <(grep -v '<auth>\|<allow_anonymous/>' "$s/dev.conf") >/dev/null ||
    { echo "ENVIRONMENT: the TCP copy differs from dev-bus.conf beyond its authentication"; exit 2; }
else
  cmp -s "$conf" "$s/dev.conf" || { echo "ENVIRONMENT: the copy differs from dev-bus.conf"; exit 2; }
fi

names() { # <address>: the activatable names, sorted, one per line
  timeout 10 gdbus call --address "$1" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListActivatableNames 2>&1 | grep -oE "'[^']+'" | tr -d "'" | sort
}

dev_names=$(names "$addr")
if [[ $dev_names == org.freedesktop.DBus ]]; then
  pass "the bus started with dev-bus.conf lists no activatable name but its own, with services planted in XDG_RUNTIME_DIR, XDG_DATA_HOME and XDG_DATA_DIRS"
else
  bad "the bus started with dev-bus.conf lists: ${dev_names//$'\n'/ }"
fi
out=$("$check" "$addr" 2>&1)
rc=$?
if ((rc == 0)) && [[ -z $out ]]; then pass "dev-bus-check.sh passes it"; else bad "dev-bus-check.sh on it: exit $rc: ${out//$'\n'/ }"; fi

# control <name> <expected names...> -- <dbus-daemon config arguments...>: the guard must fail, naming each expected name.
control() {
  local name=$1 want=() w
  shift
  while [[ $1 != -- ]]; do want+=("$1"); shift; done
  shift
  if ! start_bus "$name" "$@"; then bad "control $name: the bus did not start ($(head -n 1 "$s/$name.log"))"; return; fi
  local listed out rc missing=()
  listed=$(names "$addr")
  out=$("$check" "$addr" 2>&1)
  rc=$?
  for w in "${want[@]}"; do
    grep -qx "$w" <<<"$listed" || missing+=("$w listed")
    grep -qx "unexpected: $w" <<<"$out" || missing+=("$w named by the guard")
  done
  if ((rc == 1)) && ((${#missing[@]} == 0)); then
    local machine
    machine=$(grep -xE 'org\.gtk\.vfs\.Daemon|org\.gnome\.keyring|ca\.desrt\.dconf|org\.freedesktop\.portal\.Desktop|org\.freedesktop\.portal\.Documents' <<<"$listed" | tr '\n' ' ')
    [[ -n $machine ]] && machine=" and of the machine ${machine% }"
    pass "control $name: the guard fails (exit 1) and names $(grep -c '^unexpected: ' <<<"$out") activatable services, among them ${want[*]}$machine"
  else
    bad "control $name: guard exit $rc, missing: ${missing[*]:-none}; it printed: ${out//$'\n'/ }"
  fi
}
configure "$conf" "$s/std.conf" "  <standard_session_servicedirs/>" || exit 2
control standard-dirs $planted_std -- --config-file="$s/std.conf"
configure "$conf" "$s/dir.conf" "  <servicedir>$s/extra</servicedir>" || exit 2
control servicedir org.example.PlantedServiceDir -- --config-file="$s/dir.conf"
if ((tcp)); then
  echo "NOTE: dev bus: the system's session.conf control needs a Unix socket (EXTERNAL authentication): NOT RUN here"
else
  control session-conf $planted_std -- --session
fi

((fail == 0)) && echo "PASS: dev_bus" || echo "FAIL: dev_bus"
exit "$fail"
