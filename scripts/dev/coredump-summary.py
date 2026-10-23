#!/usr/bin/env python3
"""Read-only summary of core dumps, one line per dump (GF-082: dumps were never attributed to a session or a command).

  python3 -I scripts/dev/coredump-summary.py [--since TIME] [--max N]

For every dump `coredumpctl list` reports since TIME (default: today 00:00; anything coredumpctl --since accepts), runs
`coredumpctl info` (read-only) and prints: time, pid, signal, executable, unit, session, command line and a class:
  GRASSFIELD   the installed session: /usr/share/grassfield or /usr/lib/grassfield in the command, a grassfield-* unit
  DEV-SHELL    a quickshell/qs started with -p <path> (a development shell)
  DEV          a nested dev Hyprland or any program run from a checkout
  OTHER        everything else
It never reads or copies a core file, never writes anything, never uses sudo. A missing coredumpctl or an unreadable journal
is said on one line and exits 0 (nothing to attribute). `COREDUMPCTL` overrides the binary (tests).
Python standard library only. gate-run.sh appends this summary to the report of a gate run.
"""
import argparse
import json
import os
import re
import subprocess
import sys

FIELDS = {
    "Timestamp": "time",
    "PID": "pid",
    "Signal": "signal",
    "Executable": "exe",
    "Unit": "unit",
    "User Unit": "unit",
    "Session": "session",
    "Command Line": "cmdline",
}
MAX_FIELD = 200


def run(argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)


def clean(text):
    # One printable line: control characters and newlines never reach the output.
    return re.sub(r"[^\x20-\x7e]", "?", text)[:MAX_FIELD]


def classify(info):
    cmd, unit, exe = info.get("cmdline", ""), info.get("unit", ""), info.get("exe", "")
    # The installed session: the packaged shell path, a grassfield unit, a packaged grassfield program.
    if "/usr/share/grassfield/" in cmd or unit.startswith("grassfield-") or "/usr/lib/grassfield/" in exe or "/usr/lib/grassfield/" in cmd:
        return "GRASSFIELD"
    # Development: a shell started with -p <repository path>, a nested Hyprland with a dev config, anything run from a checkout.
    if re.search(r"(^|/)(qs|quickshell)\b", cmd + " " + exe) and re.search(r"(\s-p\s|--path)", cmd):
        return "DEV-SHELL"
    if re.search(r"Hyprland.*--config\s+\S*/dev\.lua", cmd) or "/worktrees/" in cmd or "/.dev/" in cmd:
        return "DEV"
    if "grassfield" in (cmd + " " + unit + " " + exe):
        return "GRASSFIELD"
    return "OTHER"


def parse_info(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*([A-Za-z ]+?):\s*(.*)$", line)
        if m and m.group(1) in FIELDS and FIELDS[m.group(1)] not in out:
            out[FIELDS[m.group(1)]] = clean(m.group(2).strip())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", default="today")
    ap.add_argument("--max", type=int, default=100)
    args = ap.parse_args()
    ctl = os.environ.get("COREDUMPCTL", "coredumpctl")
    try:
        listed = run([ctl, "--no-pager", "--json=short", "--since", args.since, "list"])
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"coredumps: coredumpctl unavailable ({type(e).__name__}); nothing attributed")
        return 0
    if listed.returncode != 0:
        reason = clean((listed.stderr or "no dumps").strip().splitlines()[0] if (listed.stderr or "").strip() else "no dumps")
        print(f"coredumps: none since {args.since} ({reason})")
        return 0
    try:
        dumps = json.loads(listed.stdout or "[]")
    except ValueError:
        print("coredumps: coredumpctl list output not readable; nothing attributed")
        return 0
    if not isinstance(dumps, list):
        dumps = []
    print(f"coredumps since {args.since}: {len(dumps)}")
    counts = {}
    for d in dumps[-args.max:]:
        pid = str(d.get("pid", ""))
        if not pid.isdigit():
            continue
        info = parse_info(run([ctl, "--no-pager", "info", pid]).stdout)
        info.setdefault("exe", clean(str(d.get("exe", ""))))
        kind = classify(info)
        counts[kind] = counts.get(kind, 0) + 1
        print(f"  {kind:10s} pid {pid} sig {clean(str(d.get('sig', info.get('signal', '?'))))} exe {info.get('exe', '?')} "
              f"unit {info.get('unit', '-')} session {info.get('session', '-')} cmd {info.get('cmdline', '-')} time {info.get('time', '-')}")
    if counts:
        print("  classes: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
