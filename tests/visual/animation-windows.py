#!/usr/bin/env python3
"""The window gate P3 measures for each request of tests/visual/presented-frames.sh: the animation itself (ADR-0006
amendment, integrator decision 2026-10-24 under D-5, the macOS model: a static screen owes no frames, so frames after the
animation are not misses).

  start  the first frame presented after the request: the animation's first frame. The request's own latency (the qs ipc
         process, the shell's reaction) is not part of the animation; it is printed.
  end    start + the animation's token duration, or the plugin's end mark of the phase when later (the Overview's windows
         start moving once the chrome holds the keyboard: "overview-open" for an open, "overview-closed" for a close, the
         first after the request and before the next one), plus one refresh period.
  tail   from the end to the next request, at most TAIL_MS after the request: reported as information (frames and the
         longest interval), never a verdict, so a late stall stays visible.

Usage: animation-windows.py <frames.all> <events.txt> <marks.all> <refresh Hz> <durations> <tail ms> <out events.anim>
  frames.all every presented frame, "<us> <interval us>" (the first one after a request is the animation's first frame)
  events.txt "<label> <request ns> [duration ms]" (a duration given there wins: the Dock glide as timed by the harness)
  durations  "prefix=ms,..." (the longest prefix of the label wins), e.g. overview=350,launchpad=220,dock-magnification=1320
Writes "<label> <start ns> <window ms> <tail ms>" per request to <out> (frame-stats.py reads the first three columns:
the window starts at the animation's first frame), and prints one line per request.
"""
import sys


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


def duration_for(label, durations):
    best, ms = -1, None
    for prefix, value in durations.items():
        if label.startswith(prefix) and len(prefix) > best:
            best, ms = len(prefix), value
    return ms


END_MARKS = {"overview-open": "overview-open", "overview-close": "overview-closed"}


def end_mark_for(label):
    for prefix, mark in END_MARKS.items():
        if label.startswith(prefix):
            return mark
    return None


def windows(frames, events, marks, period_us, durations, tail_us):
    """[(label, request_us, start_us, end_us, tail_end_us, latency_us or None, mark_us or None)] per request."""
    out = []
    times = [t for t, _ in frames]
    for k, (label, request, own) in enumerate(events):
        next_request = events[k + 1][1] if k + 1 < len(events) else None
        limit = request + tail_us if next_request is None else min(request + tail_us, next_request)
        duration = own if own is not None else duration_for(label, durations)
        if duration is None:
            continue
        after = [t for t in times if request < t <= limit]
        start = after[0] if after else request
        latency = (after[0] - request) if after else None
        end = start + duration * 1000
        mark_name = end_mark_for(label)
        mark = None
        if mark_name:
            hits = [t for t, what in marks if what == mark_name and request < t <= limit]
            if hits:
                mark = hits[0]
                end = max(end, mark)
        end += period_us
        out.append((label, request, start, int(end), max(int(end), limit), latency, mark))
    return out


def main(argv):
    if len(argv) != 8:
        print("usage: animation-windows.py <frames.all> <events.txt> <marks.all> <refresh Hz> <durations> <tail ms> <out>", file=sys.stderr)
        return 2
    frames = [(int(r[0]), int(r[1])) for r in rows(argv[1], 2)]
    events = [(r[0], int(r[1]) // 1000, float(r[2]) if len(r) >= 3 else None) for r in rows(argv[2], 2)]
    marks = [(int(r[0]), r[1]) for r in rows(argv[3], 2)]
    hz = float(argv[4])
    durations = {}
    for item in argv[5].split(","):
        if "=" in item:
            prefix, ms = item.split("=", 1)
            durations[prefix.strip()] = float(ms)
    tail_us = int(float(argv[6]) * 1000)
    if hz <= 0 or not events:
        print("animation-windows: no events or a bad refresh rate", file=sys.stderr)
        return 2
    period = 1e6 / hz
    with open(argv[7], "w", encoding="utf-8") as out:
        for label, request, start, end, tail_end, latency, mark in windows(frames, events, marks, period, durations, tail_us):
            out.write(f"{label} {start * 1000} {(end - start) / 1000:.1f} {(tail_end - end) / 1000:.1f}\n")
            tail = [i for t, i in frames if end < t <= tail_end]
            print(f"{label}: first frame +{latency / 1000:.0f} ms after the request" if latency is not None else f"{label}: no frame after the request",
                  end="")
            print(f", animation {(end - start) / 1000:.0f} ms" + (f" (plugin end mark +{(mark - start) / 1000:.0f} ms)" if mark else "")
                  + f"; tail (information): {len(tail)} frames, longest {max(tail, default=0) / 1000:.1f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
