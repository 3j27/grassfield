# The scratch CUPS scheduler of the print tests (ADR-0035 D-7), sourced by print_cups.sh and portal_filechooser.sh: a cupsd run
# as the user with its own configuration, spool and port (never the system's scheduler), listening on a socket and on
# localhost (a queue is reached at its URI, as in a session), with one queue, Office, the default, writing to a file through
# tests/fixtures/print/office.ppd (A4, US Letter and A5; two sides; colour; PDF passed as it is).
# Needs a cupsd the user can run (GF_TEST_CUPSD; Arch's /usr/sbin/cupsd is root's only, mode 0700: a copy, in a container),
# lpadmin, lpstat and python3; cups_ready says whether they are there. The caller sets `root`.
cups_ready() {
  [[ -x ${GF_TEST_CUPSD:-/usr/sbin/cupsd} ]] && command -v lpadmin >/dev/null && command -v lpstat >/dev/null && command -v python3 >/dev/null
}

# lpstat -r exits 0 whether the scheduler runs or not ("scheduler is not running"): its words say which. Waiting on its exit
# status did not wait, and lpadmin then raced the scheduler's start (scenario 9 failed or skipped in 2 of 7 full runs).
cups_running() {
  [[ $(LC_ALL=C CUPS_SERVER=localhost:$cups_port lpstat -r 2>/dev/null) == "scheduler is running" ]]
}

start_cups() { # start_cups <dir>: sets cups_port and cups_pid; the queue Office ready and the default; cups_error on failure
  local dir=$1
  cups_error=
  mkdir -p "$dir"/{etc,spool,cache,state,log,tmp,out}
  cups_port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  cat >"$dir/etc/cupsd.conf" <<CONF
Listen $dir/cups.sock
Listen localhost:$cups_port
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
  cat >"$dir/etc/cups-files.conf" <<CONF
ServerRoot $dir/etc
RequestRoot $dir/spool
CacheDir $dir/cache
StateDir $dir/state
TempDir $dir/tmp
AccessLog $dir/log/access_log
ErrorLog $dir/log/error_log
PageLog $dir/log/page_log
FileDevice Yes
ServerBin /usr/lib/cups
DataDir /usr/share/cups
CONF
  "${GF_TEST_CUPSD:-/usr/sbin/cupsd}" -f -c "$dir/etc/cupsd.conf" -s "$dir/etc/cups-files.conf" >"$dir/log/cupsd.out" 2>&1 &
  cups_pid=$!
  local _
  for _ in $(seq 50); do
    cups_running && break
    timeout 0.1 tail -f /dev/null
  done
  cups_running || { cups_error="no answer on localhost:$cups_port in 5 s"; return 1; }
  cups_error=$(CUPS_SERVER=localhost:$cups_port lpadmin -p Office -E -v "file://$dir/out/office.pdf" \
    -P "$root/tests/fixtures/print/office.ppd" -D "Office Printer" -L "Hall" 2>&1) || { cups_error="lpadmin: $cups_error"; return 1; }
  cups_error=$(CUPS_SERVER=localhost:$cups_port lpadmin -d Office 2>&1) || { cups_error="lpadmin -d: $cups_error"; return 1; }
}

# Why start_cups failed (cups_error), then the scheduler's own errors: its output and the error log's E lines.
cups_failure() { # cups_failure <dir>
  { echo "$cups_error"; cat "$1/log/cupsd.out" 2>/dev/null; grep -E '^[EC] ' "$1/log/error_log" 2>/dev/null; } | head -n 4 | tr '\n' ' '
}

stop_cups() {
  [[ -n ${cups_pid:-} ]] && kill "$cups_pid" 2>/dev/null
  cups_pid=
}
