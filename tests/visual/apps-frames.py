#!/usr/bin/env python3
"""Frame statistics of the Apps panel openings from a shell log written with render timing (scripts/dev/nested-up.sh
--render-timing or shell-run.sh --render-timing). Standard library only.

  apps-frames.py LOG [OPENS]...

OPENS (optional, after its LOG): a file of epoch times, one per `apps open`; the open-to-visible time of an opening is the time to the first
frame the render thread logs after it (the shell draws nothing while idle), the median of the openings is printed.

Per log: the frames of the render thread ("frame rendered in R ms, sync=, render=, swap="), the share within 16 ms, the slow
frames split into render-bound (render >= 8 ms: real GPU work) and swap-bound (the wait for the compositor), and the GUI thread's
share within 16 ms (polish + lock + blockedForSync). tests/visual/icon-modes-perf.sh measures the same numbers."""
import re
import sys

import datetime
import statistics
import time


def stamps(text):
    """(epoch, line) of the lines that carry a "frame rendered"."""
    out = []
    for line in text.splitlines():
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*frame rendered in (\d+)ms", line)
        if m:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
            out.append((time.mktime(t.timetuple()) + t.microsecond / 1e6, int(m.group(2))))
    return out


args = sys.argv[1:]
pairs = []
for a in args:
    if a.endswith(".opens") and pairs:
        pairs[-1].append(a)
    else:
        pairs.append([a])
for path, *extra in pairs:
    text = open(path, errors="replace").read()
    fr = [tuple(map(int, m)) for m in re.findall(r"frame rendered in (\d+)ms, sync=(\d+), render=(\d+), swap=(\d+)", text)]
    gui = [int(p) + int(l) + int(b) for p, l, b in re.findall(r"Frame prepared, polish=(\d+) ms, lock=(\d+) ms, blockedForSync=(\d+) ms", text)]
    slow = [f for f in fr if f[0] > 16]
    rb = [f for f in slow if f[2] >= 8]
    n = max(1, len(fr))
    g = max(1, len(gui))
    over25 = sum(1 for f in fr if f[0] > 25)
    visible = ""
    if extra:
        opens = [float(x) for x in open(extra[0]).read().split()]
        st = stamps(text)
        deltas = []
        for o in opens:
            nxt = [t for t, _ in st if t > o]
            if nxt:
                deltas.append((nxt[0] - o) * 1000)
        if deltas:
            visible = " | open-to-first-frame median %.0f ms" % statistics.median(deltas)
    print("%s: render %d frames, %.1f%% <= 16 ms (slow %d: render-bound %d, swap-bound %d, slowest %d ms), over 25 ms: %d | GUI %.1f%% <= 16 ms%s"
          % (path.split("/")[-1], len(fr), 100.0 * (len(fr) - len(slow)) / n, len(slow), len(rb), len(slow) - len(rb),
             max([f[0] for f in fr] or [0]), over25, 100.0 * sum(1 for x in gui if x <= 16) / g, visible))
