#!/usr/bin/env bash
# grassfield-portal's printers and jobs through a real CUPS scheduler (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md
# section 7, A-PR1): a scratch cupsd run as the user (its own configuration, spool and port; never the system's scheduler), one
# queue writing to a file through a test PPD (tests/fixtures/print/office.ppd: A4, US Letter and A5, two sides, colour, PDF
# passed as it is), then portal-unit-tests' CupsPrintSystem.* against it: the printers listed (the default, its name and place),
# what the queue supports read off the GUI thread, a job sent with its options (kept on the job by the scheduler), a printer
# CUPS does not know refused; and the document the scheduler got is the one sent.
# Needs a cupsd the user can run (GF_TEST_CUPSD; Arch's /usr/sbin/cupsd is root's only, mode 0700: a copy, in a container),
# lpadmin, python3 and the built portal tests (apps/portal/build-direct.sh --tests); SKIPs without them.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

cupsd=${GF_TEST_CUPSD:-/usr/sbin/cupsd}
[[ -x $cupsd ]] || { echo "SKIP: print_cups needs a cupsd the user can run ($cupsd; GF_TEST_CUPSD)"; exit 0; }
for tool in lpadmin python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: print_cups needs $tool"; exit 0; }
done
tests=${GRASSFIELD_PORTAL_TESTS:-$root/.dev/build/portal-unit-tests}
if [[ ! -x $tests ]]; then
  "$root/apps/portal/build-direct.sh" --tests >/dev/null 2>&1 || { echo "SKIP: print_cups needs the portal tests built"; exit 0; }
fi

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/print-cups.XXXXXX")
pid=
stop_all() { [[ -n $pid ]] && kill "$pid" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$tmp"/{etc,spool,cache,state,log,tmp,out}
# A free port on localhost: the scheduler listens there too, as a session's does (cupsConnectDest reaches a queue at its URI).
port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat >"$tmp/etc/cupsd.conf" <<CONF
Listen $tmp/cups.sock
Listen localhost:$port
LogLevel warn
WebInterface No
Browsing No
DefaultPaperSize A4
PreserveJobFiles Yes
DefaultAuthType None
<Location />
  Order allow,deny
  Allow all
</Location>
<Policy default>
  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CONF
cat >"$tmp/etc/cups-files.conf" <<CONF
ServerRoot $tmp/etc
RequestRoot $tmp/spool
CacheDir $tmp/cache
StateDir $tmp/state
TempDir $tmp/tmp
AccessLog $tmp/log/access_log
ErrorLog $tmp/log/error_log
PageLog $tmp/log/page_log
FileDevice Yes
ServerBin /usr/lib/cups
DataDir /usr/share/cups
CONF
"$cupsd" -f -c "$tmp/etc/cupsd.conf" -s "$tmp/etc/cups-files.conf" >"$tmp/log/cupsd.out" 2>&1 &
pid=$!
export CUPS_SERVER=localhost:$port
for _ in $(seq 50); do
  lpstat -r >/dev/null 2>&1 && break
  timeout 0.1 tail -f /dev/null
done
desc="the scratch scheduler answers on localhost:$port"
check bash -c 'lpstat -r >/dev/null 2>&1'
lpadmin -p Office -E -v "file://$tmp/out/office.pdf" -P "$root/tests/fixtures/print/office.ppd" -D "Office Printer" -L "Hall" 2>/dev/null
lpadmin -d Office
desc="the queue Office, the default"
check bash -c 'lpstat -d | grep -q ": Office$" && lpstat -p Office | grep -q "enabled"'

out=$(GF_TEST_CUPS_PRINTER=Office QT_QPA_PLATFORM=offscreen timeout 120 "$tests" --gtest_filter='CupsPrintSystem.*' 2>&1)
rc=$?
desc="CupsPrintSystem against the scheduler: printers, what the queue supports, a job with its options, an unknown printer [rc $rc]"
check bash -c '[[ $1 -eq 0 ]] && grep -q "\[  PASSED  \] 1 test" <<<"$2"' _ "$rc" "$out"
[[ $rc -eq 0 ]] || echo "$out" | grep -E "Failure|Expected|Which|actual|Value of" | head -20
document=$(ls "$tmp"/spool/d*-001 2>/dev/null | head -1)
desc="the scheduler got the document sent (a PDF, kept with the job)"
check bash -c '[[ -n $1 ]] && [[ $(head -c 5 "$1") == "%PDF-" ]]' _ "$document"
exit "$fail"
