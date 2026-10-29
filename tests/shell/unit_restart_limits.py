#!/usr/bin/env python3
"""The lifetime model of tests/shell/unit_restart_limits.sh (ADR-0041 step 1a): exit 0 when a loop of one crash every
LIFETIME seconds (default 10) ends for the unit file given, exit 1 otherwise.

A start limit counts starts within an interval: with a lifetime L per cycle and RestartSec R, the (Burst + 1)-th start,
the one systemd refuses, happens Burst x (R + L) after the first, so the limit ends the loop only when
Burst x (R + L) <= Interval. A unit that names grassfield-shell-failed.service in OnFailure= ends a loop of any pace at
the counter's threshold instead. Standard library only.
"""
import re
import sys

LIFETIME = 10


def main(argv):
    if len(argv) != 2:
        print("usage: unit_restart_limits.py UNIT_FILE", file=sys.stderr)
        return 2
    text = open(argv[1], encoding="utf-8").read()

    def num(key):
        m = re.search(r"^" + key + r"=(\d+)$", text, re.M)
        return int(m[1]) if m else None

    on_failure = re.search(r"^OnFailure=(.*)$", text, re.M)
    if on_failure and "grassfield-shell-failed.service" in on_failure[1].split():
        return 0
    interval, burst, sec = num("StartLimitIntervalSec"), num("StartLimitBurst"), num("RestartSec") or 1
    if not interval or not burst:
        return 1
    return 0 if burst * (sec + LIFETIME) <= interval else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
