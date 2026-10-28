#!/usr/bin/env python3
"""Whose cost is a missed frame? Per scenario of tests/visual/presented-frames.sh, every interval longer than 1.2 refresh
periods is attributed from the compositor's own records (feature frame-times, compositor/src/core/FrameLog.hpp):

  compositor  the compositor's own time for the frame that ended it was over 0.8 period: the CPU of its render (Hyprland's
              render, the plugin's draws included: its window transforms, Hyprland's blur) plus, before that render, the
              time the event loop was held (its stalls, from the plugin's beats) or ran the plugin's own work (the shared
              edge's drag), outside any render. Without a render in the interval, the held time alone
  client      the render began late, more than 0.5 period after the previous presentation, with a short render and the
              loop free before it: nothing new was there to draw until then (a client, the shell, committed its frame late;
              or nothing changed)
  other       neither (the GPU or the presentation itself)

A main-loop stall before the render shows only as a late render (integrator review of a6d04df, MAJOR 2): without the
loop's records it would read as a client's late frame, so the gate needs them (`--beats` above 0).

The animation window (gate P3) and its tail (information) are attributed apart, from tests/visual/animation-windows.py's
events ("<label> <start ns> <window ms> <tail ms>"); an events file of "<label> <request ns>" lines takes a fixed window
after each request instead. It also prints the render CPU of the animation's frames (p50, p95, max), the plugin's animation
phases (marks) relative to the animation's start, and one line per interval of 3 periods or more (where, how long, class,
the wait before its render and that render's CPU): the concrete data for whoever owns that cost.

Usage: frame-attribution.py <frames.txt> <renders.all> <marks.all> <events> <refresh Hz> <window ms> [--stalls=FILE]
       [--work=FILE] [--beats=N] [--gate=PREFIX ...]
  frames.txt   "<presented us> <interval us>" (the intervals spanning a request already left out)
  renders.all  "<begin us> <cpu us>"
  marks.all    "<us> <name>"
  --stalls     "<begin us> <length us>": the event loop held (a late beat, compositor/src/core/FrameLog.hpp stallOf)
  --work       "<begin us> <length us>": the plugin's own work outside a render
  --beats      the beats the loop probe ran (0: the loop was not probed, so a stall could not be seen)
  --gate=PREFIX the scenarios whose label starts with PREFIX are judged here: PASS when their animations hold frames and no
               long frame the compositor caused, FAIL (exit 1) otherwise, also when the renders or the loop were not
               recorded; the client-paced ones are information (the shared edge's drag, tiling.md TL30, ADR-0036 D34 as
               amended: each window shows the buffer its app commits, at its pace). Without it the script only reports
               (exit 0).
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


def held(lo, hi, loop, renders):
    """The time in (lo, hi] the loop spans ((begin, length): stalls, the plugin's work) cover, outside every render span."""
    pieces = sorted((max(lo, b), min(hi, b + n)) for b, n in loop if b < hi and b + n > lo)
    merged = []
    for a, b in pieces:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    total = 0
    for a, b in merged:
        total += b - a
        for rb, rc in renders:
            total -= max(0, min(b, rb + rc) - max(a, rb))
    return max(0, total)


def classify(start, end, renders, cpu_limit, wait_limit, loop=()):
    """(class, wait us or None, cpu us or None, held us) of the interval (start, end]: `loop` the stalls and work spans."""
    inside = [(b, c) for b, c in renders if start < b <= end]
    if not inside:
        before = held(start, end, loop, renders)
        return ("compositor" if before > cpu_limit else "other"), None, None, before
    begin, cpu = inside[-1]
    before = held(start, begin, loop, renders)
    if cpu + before > cpu_limit:
        return "compositor", begin - start, cpu, before
    if begin - start > wait_limit:
        return "client", begin - start, cpu, before
    return "other", begin - start, cpu, before


def new_part():
    return {"frames": 0, "long": 0, "compositor": 0, "client": 0, "other": 0, "longest": 0}


def main(argv):
    options = {"--gate": [], "--stalls": [], "--work": [], "--beats": []}
    rest = []
    for a in argv:
        key = a.split("=", 1)[0]
        if key in options and "=" in a:
            options[key].append(a.split("=", 1)[1])
        else:
            rest.append(a)
    argv = rest
    gates = tuple(options["--gate"])
    try:
        beats = int(options["--beats"][-1]) if options["--beats"] else 0
    except ValueError:
        beats = -1
    if len(argv) != 7 or beats < 0:
        print("usage: frame-attribution.py <frames.txt> <renders.all> <marks.all> <events> <refresh Hz> <window ms> [--stalls=FILE] "
              "[--work=FILE] [--beats=N] [--gate=PREFIX ...]", file=sys.stderr)
        return 2
    loop = sorted((int(a[0]), int(a[1])) for path in options["--stalls"] + options["--work"] for a in rows(path, 2))
    frames = [(int(a[0]), int(a[1])) for a in rows(argv[1], 2)]
    renders = sorted((int(a[0]), int(a[1])) for a in rows(argv[2], 2))
    marks = [(int(r[0]), r[1]) for r in rows(argv[3], 2)]
    period = 1e6 / float(argv[5])
    fixed = int(argv[6]) * 1000
    events = []
    for r in rows(argv[4], 2):
        start = int(r[1]) // 1000
        window = int(float(r[2]) * 1000) if len(r) >= 3 else fixed
        tail = int(float(r[3]) * 1000) if len(r) >= 4 else 0
        events.append((r[0], start, window, tail))
    long_limit, cpu_limit, wait_limit, detail_limit = 1.2 * period, 0.8 * period, 0.5 * period, 3 * period

    per = defaultdict(lambda: {"animation": new_part(), "tail": new_part(), "cpu": [], "marks": defaultdict(list)})
    details = []
    for name, start, window, tail in events:
        acc = per[name]
        end, tail_end = start + window, start + window + tail
        acc["cpu"].extend(c for b, c in renders if start < b <= end)
        for us, what in marks:
            if start - 1_000_000 < us <= tail_end:
                acc["marks"][what].append((us - start) / 1000.0)
        for t, interval in frames:
            if not start < t <= tail_end:
                continue
            part = "animation" if t <= end else "tail"
            p = acc[part]
            p["frames"] += 1
            if interval <= long_limit:
                continue
            kind, wait, cpu, before = classify(t - interval, t, renders, cpu_limit, wait_limit, loop)
            p["long"] += 1
            p[kind] += 1
            p["longest"] = max(p["longest"], interval)
            if interval >= detail_limit:
                details.append(f"  {name} {part} +{(t - start) / 1000:.0f} ms: {interval / 1000:.1f} ms {kind}"
                               + (f" (render began {wait / 1000:.1f} ms after the previous frame, CPU {cpu / 1000:.1f} ms" if wait is not None else " (no render recorded")
                               + f"; the loop held {before / 1000:.1f} ms before it)")

    if not renders:
        print("attribution: no render spans recorded (a plugin without them: rebuild, just plugin-build)")
    if beats == 0:
        print("attribution: the event loop was not probed (no beats: a plugin without the loop records, or none given), "
              "so a stall before a render reads as a late client")
    for name in sorted(per):
        a = per[name]
        cpu = a["cpu"]

        def part_text(p):
            return (f"{p['long']} long (compositor {p['compositor']}, client {p['client']}, other {p['other']}), "
                    f"longest {p['longest'] / 1000:.1f} ms")

        marks_text = ", ".join(f"{what} {sum(v) / len(v):+.0f} ms" for what, v in sorted(a["marks"].items(), key=lambda kv: min(kv[1])))
        print(f"{name}: animation {part_text(a['animation'])}; render CPU p50 {pct(cpu, 0.5) / 1000:.1f} ms, p95 {pct(cpu, 0.95) / 1000:.1f} ms, "
              f"max {max(cpu, default=0) / 1000:.1f} ms over {len(cpu)} renders; tail {part_text(a['tail'])}"
              + (f"; plugin phases from the animation's start (mean): {marks_text}" if marks_text else ""))
    if details:
        print(f"intervals of {detail_limit / 1000:.0f} ms or more:")
        print("\n".join(details))
    status = 0
    for name in sorted(per):
        if not gates or not name.startswith(gates):
            continue
        a = per[name]["animation"]
        if not renders or beats == 0:
            print(f"FAIL {name}: no render spans or no loop beats recorded, the compositor's share cannot be judged")
            status = 1
            continue
        if a["frames"] == 0:
            print(f"FAIL {name}: no frame was presented in the animation")
            status = 1
            continue
        verdict = "PASS" if a["compositor"] == 0 else "FAIL"
        if verdict == "FAIL":
            status = 1
        print(f"{verdict} {name}: {a['compositor']} long frame(s) caused by the compositor in the animation (gate: 0); "
              f"{a['client']} paced by a client and {a['other']} other, information")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
