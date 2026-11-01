#!/usr/bin/env bash
# grassfield-portal's printers and jobs through a real CUPS scheduler (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md
# section 7, A-PR1): a scratch cupsd run as the user (its own configuration, spool and port; never the system's scheduler), one
# queue writing to a file through a test PPD (tests/fixtures/print/office.ppd: A4, US Letter and A5, two sides, colour, its own
# paper source, media type, quality, output bin and finishing, PDF passed as it is), then portal-unit-tests' CupsPrintSystem.*
# against it: the printers listed (the default, its name and place), what the queue supports read off the GUI thread (its own
# options with their names and defaults, the user's lpoptions value apart from the queue's own, step 6b), a job sent with its
# options (kept on the job by the scheduler), a printer CUPS does not know refused; and the document the scheduler got is the one
# sent.
# Needs a cupsd the user can run (GF_TEST_CUPSD; Arch's /usr/sbin/cupsd is root's only, mode 0700: a copy, in a container),
# lpadmin, python3 and the built portal tests (apps/portal/build-direct.sh --tests); SKIPs without them.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

# The scratch scheduler (cups_ready, start_cups, stop_cups), shared with portal_filechooser.sh's scenario 9.
. "$root/tests/integration/print-cups.sh"
cups_ready || { echo "SKIP: print_cups needs a cupsd the user can run (${GF_TEST_CUPSD:-/usr/sbin/cupsd}; GF_TEST_CUPSD), lpadmin and python3"; exit 0; }
tests=${GRASSFIELD_PORTAL_TESTS:-$root/.dev/build/portal-unit-tests}
if [[ ! -x $tests ]]; then
  "$root/apps/portal/build-direct.sh" --tests >/dev/null 2>&1 || { echo "SKIP: print_cups needs the portal tests built"; exit 0; }
fi

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/print-cups.XXXXXX")
stop_all() { stop_cups; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start_cups "$tmp"
export CUPS_SERVER=localhost:$cups_port
desc="the scratch scheduler answers on localhost:$cups_port, its queue Office the default"
check bash -c 'lpstat -d | grep -q ": Office$" && lpstat -p Office | grep -q "enabled"'

# The user's own default for the queue (lpoptions, in a scratch home): it must reach a job, which libcups does not do by itself
# (counter-review of step 6b, MINOR 1).
mkdir -p "$tmp/home"
desc="the user's lpoptions print-quality=5 for Office, in a scratch home"
check bash -c 'HOME=$1 CUPS_SERVER=$2 lpoptions -p Office -o print-quality=5 >/dev/null && grep -q "print-quality=5" "$1/.cups/lpoptions"' _ "$tmp/home" "$CUPS_SERVER"
out=$(HOME=$tmp/home GF_TEST_CUPS_LPOPTIONS=print-quality=5 GF_TEST_CUPS_PRINTER=Office QT_QPA_PLATFORM=offscreen timeout 120 "$tests" --gtest_filter='CupsPrintSystem.*' 2>&1)
rc=$?
desc="CupsPrintSystem against the scheduler: printers, what the queue supports, a job with its options, an unknown printer [rc $rc]"
check bash -c '[[ $1 -eq 0 ]] && grep -q "\[  PASSED  \] 1 test" <<<"$2"' _ "$rc" "$out"
[[ $rc -eq 0 ]] || echo "$out" | grep -E "Failure|Expected|Which|actual|Value of" | head -20
document=$(ls "$tmp"/spool/d*-001 2>/dev/null | head -1)
desc="the scheduler got the document sent (a PDF, kept with the job)"
check bash -c '[[ -n $1 ]] && [[ $(head -c 5 "$1") == "%PDF-" ]]' _ "$document"
exit "$fail"
