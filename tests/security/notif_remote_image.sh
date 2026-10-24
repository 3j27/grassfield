#!/usr/bin/env bash
# Nested scenario DT-07 (GF-AUDIT-001 SEC-10 / GF-114): a notification whose image hint is a URL never makes the shell
# fetch it. A local HTTP listener (127.0.0.1, random port, logs every request) is the probe: a request made by the
# listener's own control (curl) shows it works; then notifications are sent to the nested shell over its private bus
# with image-path hints http://127.0.0.1:PORT/…, https://…, a data: URI, and an image://icon/ name that is a URL. After
# a wait the listener must have seen no request but the control, and the shell log must say the images were refused
# (scheme only, never the URL). Run bare, outside the sandbox, with scripts/dev/nested-up.sh running; never types.
# Prints PASS/FAIL per check; exit 0 when all passed, 2 when the environment is missing.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host notif_remote_image
dev_nested_target "$dev" || exit 2
bus=$(cat "$dev/bus.address" 2>/dev/null || true)
[[ $bus == unix:path=/tmp/dbus-* ]] || { echo "notif_remote_image: no private bus of the nested shell (.dev/bus.address); run scripts/dev/nested-up.sh" >&2; exit 2; }
# Testing rule after the review of 423766f (a probe once reached the owner's session bus): only the nested shell's
# private bus, never the caller's own, and notify-send runs under `env -i` with that address alone.
[[ $bus != *"/run/user/"* && ( -z ${DBUS_SESSION_BUS_ADDRESS:-} || $bus != "$DBUS_SESSION_BUS_ADDRESS" ) ]] || { echo "notif_remote_image: refusing the caller's own session bus ($bus)" >&2; exit 2; }
for tool in notify-send python3 curl; do
  command -v "$tool" >/dev/null || { echo "notif_remote_image: $tool is not installed" >&2; exit 2; }
done
log=$dev/shell.log
[[ -r $log ]] || { echo "notif_remote_image: no shell log $log" >&2; exit 2; }

status=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; status=1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/gf-dt07.XXXXXX")
listener=""
cleanup() { [[ -n $listener ]] && kill "$listener" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

# Listener: one line per request in $work/requests; its port in $work/port.
cat >"$work/listen.py" <<'PY'
import http.server, sys
log = open(sys.argv[1], "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write(self.path + "\n")
        self.send_response(404)
        self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_port))
s.serve_forever()
PY
: >"$work/requests"
python3 -I "$work/listen.py" "$work/requests" "$work/port" &
listener=$!
for _ in $(seq 1 50); do [[ -s $work/port ]] && break; sleep 0.1; done
port=$(cat "$work/port" 2>/dev/null)
[[ $port =~ ^[0-9]+$ ]] || { echo "notif_remote_image: the listener did not start" >&2; exit 2; }

curl -s -o /dev/null "http://127.0.0.1:$port/control" || true
grep -qx /control "$work/requests" && pass "control: the listener records requests" || { fail "control: the listener saw nothing"; exit 1; }

before=$(wc -l <"$log")
notify() { env -i PATH="$PATH" DBUS_SESSION_BUS_ADDRESS="$bus" notify-send "$@" >/dev/null 2>&1; }
notify -a dt07 -h "string:image-path:http://127.0.0.1:$port/hint-http.png" "DT-07 http" "image hint over http"
notify -a dt07 -h "string:image-path:http://127.0.0.1:$port/hint-icon.png" -i "http://127.0.0.1:$port/app-icon.png" "DT-07 icon" "app icon over http"
notify -a dt07 -h "string:image-path:https://127.0.0.1:$port/hint-https.png" "DT-07 https" "image hint over https"
notify -a dt07 -h "string:image-path:data:image/png;base64,iVBORw0KGgo=" "DT-07 data" "image hint as a data URI"
sleep 4

seen=$(grep -vx /control "$work/requests" | tr '\n' ' ')
[[ -z $seen ]] && pass "no request reached the listener after four notifications with remote images" || fail "the shell fetched: $seen"
refused=$(tail -n +"$((before + 1))" "$log" | grep -c "a notification image was refused" || true)
[[ $refused -ge 3 ]] && pass "the shell log reports $refused refused notification images" || fail "the shell log reports $refused refused images (expected at least 3)"
if tail -n +"$((before + 1))" "$log" | grep -q "127.0.0.1:$port"; then fail "the shell log repeats an image URL"; else pass "the shell log never repeats an image URL"; fi
exit $status
