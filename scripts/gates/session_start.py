#!/usr/bin/env python3
"""Gate P5: time from the session start to "usable menu bar and Dock", from the user journal.

  journalctl --user -b 0 -o short-iso-precise --no-pager | session_start.py [--max-s 2.0]
  session_start.py FILE [--max-s 2.0]
  session_start.py --selftest

Start marker: uwsm's "Starting <compositor> and waiting while it is running..." line. End marker: the shell's
"grassfield-shell: usable (...)" line (shell/platform/Usable.qml: the menu bar of every output and the Dock of every
output that shows one have drawn a first frame), the first one after each start. Every start with an end is one sample;
a start without an end (the shell never became usable, or the installed shell predates the marker) is reported and
counts as a failure only when it is the LAST start of the input. Verdict (master-prompt §10 P5: <= 2 s): PASS when the
median of the samples is <= --max-s, FAIL otherwise; no sample at all is INCONCLUSIVE (exit 2). Prints one line per
sample and the verdict with the number of samples, median and slowest.

Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE. Standard library only (python3 -I).
"""
import argparse
import re
import statistics
import sys
from datetime import datetime

STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?[+-]\d\d:?\d\d)\s")
START = re.compile(r"uwsm\[\d+\]: Starting .+ and waiting while it is running")
USABLE = re.compile(r"grassfield-shell: usable")


def parse_stamp(text):
    m = STAMP.match(text)
    if not m:
        return None
    s = m.group(1)
    if re.search(r"[+-]\d{4}$", s):
        s = s[:-2] + ":" + s[-2:]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def samples(lines):
    """-> (list of (start, usable, seconds), the last start has no end)"""
    out = []
    start = None
    for line in lines:
        t = parse_stamp(line)
        if t is None:
            continue
        if START.search(line):
            start = t
        elif USABLE.search(line) and start is not None:
            out.append((start, t, (t - start).total_seconds()))
            start = None
    return out, start is not None


def verdict(found, dangling, max_s):
    if not found and not dangling:
        return 2, "INCONCLUSIVE: no uwsm start line followed by a 'grassfield-shell: usable' line in the input"
    if not found:
        return 2, "INCONCLUSIVE: a session start but no 'grassfield-shell: usable' line after it (a shell without the marker, or it never became usable)"
    secs = [s for _a, _b, s in found]
    med = statistics.median(secs)
    text = f"{len(secs)} session start(s), median {med:.2f} s, slowest {max(secs):.2f} s (needs median <= {max_s:g} s)"
    if dangling:
        return 1, f"FAIL: the last session start never reached 'usable'; earlier: {text}"
    if med <= max_s:
        return 0, f"PASS: {text}"
    return 1, f"FAIL: {text}"


def selftest():
    fails = []

    def expect(name, got, want):
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    j = """2026-10-23T00:30:54.619011+02:00 gf-host uwsm[898]: Starting hyprland.desktop and waiting while it is running...
2026-10-23T00:30:55.100000+02:00 gf-host other[1]: noise
2026-10-23T00:30:56.119011+02:00 gf-host qs[2000]: INFO qml: grassfield-shell: usable (menu bar and Dock drawn on 2 output(s))
2026-10-23T08:00:00.000000+02:00 gf-host uwsm[900]: Starting hyprland.desktop and waiting while it is running...
2026-10-23T08:00:03.500000+02:00 gf-host qs[2100]: INFO qml: grassfield-shell: usable (menu bar and Dock drawn on 1 output(s))
"""
    found, dangling = samples(j.splitlines())
    expect("two samples", len(found), 2)
    expect("first duration", round(found[0][2], 3), 1.5)
    expect("second duration", round(found[1][2], 3), 3.5)
    expect("median 2.5 fails", verdict(found, dangling, 2.0)[0], 1)
    expect("median 2.5 passes at 3", verdict(found, dangling, 3.0)[0], 0)
    expect("one fast sample passes", verdict(found[:1], False, 2.0)[0], 0)
    expect("dangling last start fails", verdict(found[:1], True, 2.0)[0], 1)
    expect("empty is inconclusive", verdict([], False, 2.0)[0], 2)
    expect("no usable line is inconclusive", verdict([], True, 2.0)[0], 2)
    # +0200 without a colon, as older journalctl prints it
    expect("offset without colon", parse_stamp("2026-10-23T00:30:54.619011+0200 x") is not None, True)
    expect("usable before any start is ignored", samples(["2026-10-23T00:30:56.000000+02:00 h qs[1]: grassfield-shell: usable"])[0], [])
    if fails:
        print("\n".join("FAIL: " + f for f in fails))
        return 1
    print("session_start selftest: PASS (11 cases)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--max-s", type=float, default=2.0)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.file:
        with open(args.file, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    else:
        lines = sys.stdin.read().splitlines()
    found, dangling = samples(lines)
    for a, b, s in found:
        print(f"P5: uwsm start {a.isoformat(timespec='milliseconds')} -> usable {b.isoformat(timespec='milliseconds')}: {s:.2f} s")
    code, text = verdict(found, dangling, args.max_s)
    print(f"P5 startup: {text}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
