#!/usr/bin/env python3
"""Frame statistics of the Apps panel openings from a shell log written with render timing (scripts/dev/nested-up.sh
--render-timing or shell-run.sh --render-timing). Standard library only.

  apps-frames.py LOG...

Per log: the frames of the render thread ("frame rendered in R ms, sync=, render=, swap="), the share within 16 ms, the slow
frames split into render-bound (render >= 8 ms: real GPU work) and swap-bound (the wait for the compositor), and the GUI thread's
share within 16 ms (polish + lock + blockedForSync). tests/visual/icon-modes-perf.sh measures the same numbers."""
import re
import sys

for path in sys.argv[1:]:
    text = open(path, errors="replace").read()
    fr = [tuple(map(int, m)) for m in re.findall(r"frame rendered in (\d+)ms, sync=(\d+), render=(\d+), swap=(\d+)", text)]
    gui = [int(p) + int(l) + int(b) for p, l, b in re.findall(r"Frame prepared, polish=(\d+) ms, lock=(\d+) ms, blockedForSync=(\d+) ms", text)]
    slow = [f for f in fr if f[0] > 16]
    rb = [f for f in slow if f[2] >= 8]
    n = max(1, len(fr))
    g = max(1, len(gui))
    print("%s: render %d frames, %.1f%% <= 16 ms (slow %d: render-bound %d, swap-bound %d, slowest %d ms) | GUI %.1f%% <= 16 ms"
          % (path.split("/")[-1], len(fr), 100.0 * (len(fr) - len(slow)) / n, len(slow), len(rb), len(slow) - len(rb),
             max([f[0] for f in fr] or [0]), 100.0 * sum(1 for x in gui if x <= 16) / g))
