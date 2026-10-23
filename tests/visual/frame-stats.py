"""Frame statistics of the P3 probe (tests/visual/overview-frames.sh, tests/tools/framepulse).

Usage: python3 -I frame-stats.py FRAMES EVENTS HZ [WINDOW_MS] [TOLERANCE]
  FRAMES  lines "epoch_us interval_us" (framepulse: one per frame callback of a surface that redraws every frame)
  EVENTS  lines "<label> <epoch_ns>" (the moment an open or a close was requested)
  HZ      refresh rate of the output
Prints, per label and for all, the frames in [event, event + WINDOW_MS] (default 700 ms: the 350 ms animation and its settle):
count, median, 95th percentile and worst interval, and the share of frames whose interval is within TOLERANCE x the refresh
period (default 1.2: 20 ms at 60 Hz; a dropped frame shows as two periods). Exit status 1 when the share is below 95 %
(gate P3: at least 95 % of frames on time) in any phase, 2 on unusable input.
"""
import sys


def read_frames(text):
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and not line.startswith("#"):
            try:
                out.append((int(parts[0]), int(parts[1])))
            except ValueError:
                continue
    return out


def read_events(text):
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                out.append((parts[0], int(parts[1]) // 1000))
            except ValueError:
                continue
    return out


def percentile(values, p):
    if not values:
        return 0
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, int(round(p * (len(ordered) - 1)))))
    return ordered[k]


def phase(frames, events, label, window_us):
    """Intervals of the frames that arrived in a window after an event of `label` (all labels when None)."""
    out = []
    for name, at in events:
        if label is not None and name != label:
            continue
        out.extend(i for t, i in frames if at <= t <= at + window_us)
    return out


def stats(intervals, period_us, tolerance):
    if not intervals:
        return None
    on_time = sum(1 for i in intervals if i <= period_us * tolerance)
    return {
        "count": len(intervals),
        "median_ms": percentile(intervals, 0.5) / 1000,
        "p95_ms": percentile(intervals, 0.95) / 1000,
        "max_ms": max(intervals) / 1000,
        "share": on_time / len(intervals),
    }


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    frames = read_frames(open(argv[1]).read())
    events = read_events(open(argv[2]).read())
    hz = float(argv[3])
    window_us = int(float(argv[4]) * 1000) if len(argv) > 4 else 700000
    tolerance = float(argv[5]) if len(argv) > 5 else 1.2
    if hz <= 0 or not frames or not events:
        print("frame-stats: no frames, no events or a bad refresh rate")
        return 2
    period = 1e6 / hz
    status = 0
    for label in sorted({e[0] for e in events}) + [None]:
        s = stats(phase(frames, events, label, window_us), period, tolerance)
        name = label or "all"
        if s is None:
            print("FAIL %s: no frame arrived in the window" % name)
            status = 1
            continue
        verdict = "PASS" if s["share"] >= 0.95 else "FAIL"
        if verdict == "FAIL":
            status = 1
        print("%s %s: %d frames, median %.1f ms, p95 %.1f ms, worst %.1f ms, %.1f %% within %.1f ms (refresh %.1f Hz)" % (
            verdict, name, s["count"], s["median_ms"], s["p95_ms"], s["max_ms"], 100 * s["share"], period * tolerance / 1000, hz))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
