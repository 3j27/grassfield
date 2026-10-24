#!/usr/bin/env python3
"""Whose cost is a missed frame? Per scenario of tests/visual/presented-frames.sh, every interval longer than 1.2 refresh
periods is attributed from the compositor's own records (feature frame-times, compositor/src/core/FrameLog.hpp):

  compositor  the frame that ended it took longer than 0.8 period of CPU to render (Hyprland's render, the plugin's draws
              included: its window transforms, Hyprland's blur)
  client      the render began late, more than 0.5 period after the previous presentation, with a short render: nothing
              new was there to draw until then (a client, the shell, committed its frame late; or nothing changed)
  other       neither (the GPU or the presentation itself)

It also prints the render CPU of every frame in the window (p50, p95, max) and the plugin's animation phases (marks)
relative to the request.

Usage: frame-attribution.py <frames.txt> <renders.all> <marks.all> <events.txt> <refresh Hz> <window ms>
  frames.txt   "<presented us> <interval us>" (the intervals spanning a request already left out)
  renders.all  "<begin us> <cpu us>"
  marks.all    "<us> <name>"
  events.txt   "<scenario> <monotonic ns>"
"""
import sys
from collections import defaultdict


def rows(path, n):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= n:
                    out.append(parts)
    except OSError:
        pass
    return out


def pct(values, q):
    if not values:
        return float("nan")
    s = sorted(values)
    return s[min(len(s) - 1, int(q * (len(s) - 1) + 0.5))]


def main(argv):
    if len(argv) != 7:
        print("usage: frame-attribution.py <frames.txt> <renders.all> <marks.all> <events.txt> <refresh Hz> <window ms>", file=sys.stderr)
        return 2
    frames = [(int(a), int(b)) for a, b in rows(argv[1], 2)]
    renders = sorted((int(a), int(b)) for a, b in rows(argv[2], 2))
    marks = [(int(r[0]), r[1]) for r in rows(argv[3], 2)]
    events = [(r[0], int(r[1]) // 1000) for r in rows(argv[4], 2)]
    period = 1e6 / float(argv[5])
    window = int(argv[6]) * 1000
    long_limit, cpu_limit, wait_limit = 1.2 * period, 0.8 * period, 0.5 * period

    per = defaultdict(lambda: {"long": 0, "compositor": 0, "client": 0, "other": 0, "cpu": [], "marks": defaultdict(list)})
    for name, t in events:
        acc = per[name]
        acc["cpu"].extend(c for b, c in renders if t < b <= t + window)
        for us, what in marks:
            if t < us <= t + window:
                acc["marks"][what].append((us - t) / 1000.0)
        for end, interval in frames:
            if not t < end <= t + window or interval <= long_limit:
                continue
            start = end - interval
            inside = [(b, c) for b, c in renders if start < b <= end]
            acc["long"] += 1
            if not inside:
                acc["other"] += 1
                continue
            begin, cpu = inside[-1]
            if cpu > cpu_limit:
                acc["compositor"] += 1
            elif begin - start > wait_limit:
                acc["client"] += 1
            else:
                acc["other"] += 1

    if not renders:
        print("attribution: no render spans recorded (a plugin without them: rebuild, just plugin-build)")
    for name in sorted(per):
        a = per[name]
        cpu = a["cpu"]
        marks_text = ", ".join(f"{what} +{sum(v) / len(v):.0f} ms" for what, v in sorted(a["marks"].items(), key=lambda kv: min(kv[1])))
        print(f"{name}: {a['long']} long intervals: compositor {a['compositor']}, client {a['client']}, other {a['other']}; "
              f"render CPU p50 {pct(cpu, 0.5) / 1000:.1f} ms, p95 {pct(cpu, 0.95) / 1000:.1f} ms, max {max(cpu, default=0) / 1000:.1f} ms "
              f"over {len(cpu)} renders" + (f"; plugin phases (mean): {marks_text}" if marks_text else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
