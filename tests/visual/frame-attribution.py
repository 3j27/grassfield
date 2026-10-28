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
phases (marks) relative to the animation's start, and one line per compositor-caused interval and per interval of 3
periods or more (where, how long, class, the wait before its render, that render's CPU, and the loop's held time before
it split into stalls, with the main thread's CPU share in them, and the plugin's own work): the concrete data for whoever
owns that cost. A stall with little CPU is the main thread waiting (descheduled under load, or blocked), one with about
its length in CPU is the compositor working (integrator nested pass of ce82fd3).

Usage: frame-attribution.py <frames.txt> <renders.all> <marks.all> <events> <refresh Hz> <window ms> [--stalls=FILE]
       [--work=FILE] [--beats=N] [--gate=PREFIX ...] [--baseline=LABEL]
  frames.txt   "<presented us> <interval us>" (the intervals spanning a request already left out)
  renders.all  "<begin us> <cpu us>"
  marks.all    "<us> <name>"
  --stalls     "<begin us> <length us> [<cpu us>]": the event loop held (a late beat, compositor/src/core/FrameLog.hpp
               stallOf), with the main thread's CPU time from the beat before (the stall and up to one beat period)
  --work       "<begin us> <length us>": the plugin's own work outside a render
  --beats      the beats the loop probe ran (0: the loop was not probed, so a stall could not be seen)
  --gate=PREFIX the scenarios whose label starts with PREFIX are judged here (the shared edge's drag, tiling.md TL30,
               ADR-0036 D34 as amended); FAIL (exit 1) when the renders, the loop or the plugin's work were not recorded or
               the animation holds no frame, else PASS when both hold: (a) the plugin's own work is at most 1 ms in every
               frame of the animation; (b) its compositor-caused long frames per second of animation are at most 1.25 times
               the baseline's (--baseline), or none without a baseline. The client-paced ones are information (each window
               shows the buffer its app commits, at its pace). Without it the script only reports (exit 0).
  --baseline=LABEL the scenario a gated one is compared with: Hyprland's own resize_on_border drag of one of the same windows,
               with the same glide (the integrator's D34 gate, 2026-10-28: the shared edge is judged against what Hyprland's
               own resize costs, not against zero); not measured: FAIL.
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


# compositor/src/core/FrameLog.hpp kBeatUs: a stall's CPU time covers it and at most one beat period before it.
BEAT_US = 1000


def stall_cpu(lo, hi, stalls):
    """About how much of (lo, hi] the main thread spent on its CPU during the stalls ((begin, length, cpu or None)) there:
    each stall's overlap times its CPU share (its CPU over its length plus one beat period, at most 1); None when no
    stall there carries its CPU."""
    total, known = 0.0, False
    for b, n, cpu in stalls:
        overlap = min(hi, b + n) - max(lo, b)
        if overlap <= 0 or cpu is None:
            continue
        known = True
        total += overlap * min(1.0, cpu / (n + BEAT_US))
    return total if known else None


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


# The D34 gate (integrator, 2026-10-28): the plugin's own work in one frame, and the shared edge's compositor-caused long frames
# per second against the baseline's.
WORK_LIMIT_US = 1000
BASELINE_FACTOR = 1.25


def new_part():
    return {"frames": 0, "long": 0, "compositor": 0, "client": 0, "other": 0, "longest": 0, "work_max": 0, "work_any": False}


def main(argv):
    options = {"--gate": [], "--stalls": [], "--work": [], "--beats": [], "--baseline": []}
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
              "[--work=FILE] [--beats=N] [--gate=PREFIX ...] [--baseline=LABEL]", file=sys.stderr)
        return 2
    baseline = options["--baseline"][-1] if options["--baseline"] else None
    stalls = sorted((int(a[0]), int(a[1]), int(a[2]) if len(a) >= 3 else None) for path in options["--stalls"] for a in rows(path, 2))
    work = sorted((int(a[0]), int(a[1])) for path in options["--work"] for a in rows(path, 2))
    loop = sorted([(b, n) for b, n, _ in stalls] + work)
    stall_spans = [(b, n) for b, n, _ in stalls]
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

    per = defaultdict(lambda: {"animation": new_part(), "tail": new_part(), "cpu": [], "marks": defaultdict(list), "anim_us": 0,
                               "held": {"frames": 0, "stalls": 0, "stall_cpu": 0.0, "stall_cpu_known": False, "work": 0, "render": 0}})
    details = []
    for name, start, window, tail in events:
        acc = per[name]
        acc["anim_us"] += window
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
            in_frame = held(t - interval, t, work, ())
            p["work_max"] = max(p["work_max"], in_frame)
            p["work_any"] = p["work_any"] or in_frame > 0
            if interval <= long_limit:
                continue
            kind, wait, cpu, before = classify(t - interval, t, renders, cpu_limit, wait_limit, loop)
            p["long"] += 1
            p[kind] += 1
            p["longest"] = max(p["longest"], interval)
            if kind == "compositor" or interval >= detail_limit:
                lo = t - interval
                hi = lo + wait if wait is not None else t
                by_stalls, by_work = held(lo, hi, stall_spans, renders), held(lo, hi, work, renders)
                on_cpu = stall_cpu(lo, hi, stalls)
                if kind == "compositor" and part == "animation":
                    h = acc["held"]
                    h["frames"] += 1
                    h["stalls"] += by_stalls
                    h["work"] += by_work
                    h["render"] += cpu or 0
                    if on_cpu is not None:
                        h["stall_cpu"] += on_cpu
                        h["stall_cpu_known"] = True
                details.append(f"  {name} {part} +{(t - start) / 1000:.0f} ms: {interval / 1000:.1f} ms {kind}"
                               + (f" (render began {wait / 1000:.1f} ms after the previous frame, CPU {cpu / 1000:.1f} ms" if wait is not None else " (no render recorded")
                               + f"; before it the loop was held {before / 1000:.1f} ms: stalls {by_stalls / 1000:.1f} ms"
                               + (f", the main thread on its CPU for about {on_cpu / 1000:.1f} ms of them" if on_cpu is not None else "")
                               + f", the plugin's work {by_work / 1000:.1f} ms)")

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
        h = a["held"]
        if h["frames"]:
            print(f"{name}: its {h['frames']} compositor-caused long frame(s) in the animation, in total: loop stalls {h['stalls'] / 1000:.1f} ms"
                  + (f" (the main thread on its CPU for about {h['stall_cpu'] / 1000:.1f} ms of them)" if h["stall_cpu_known"] else "")
                  + f", the plugin's work {h['work'] / 1000:.1f} ms, render CPU {h['render'] / 1000:.1f} ms")
    if details:
        print(f"long intervals caused by the compositor, and any of {detail_limit / 1000:.0f} ms or more:")
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
        if not a["work_any"]:
            print(f"FAIL {name}: no work of the plugin recorded in the animation, the drag's own cost cannot be judged")
            status = 1
            continue
        work_ok = a["work_max"] <= WORK_LIMIT_US
        work_text = f"(a) the plugin's own work at most {a['work_max'] / 1000:.2f} ms in a frame (gate: {WORK_LIMIT_US / 1000:.0f} ms)"
        seconds = per[name]["anim_us"] / 1e6
        rate = a["compositor"] / seconds if seconds > 0 else float("inf")
        if baseline is None:
            rate_ok = a["compositor"] == 0
            rate_text = f"(b) {a['compositor']} long frame(s) caused by the compositor in the animation (gate: 0, no baseline)"
        else:
            b = per.get(baseline)
            if b is None or b["animation"]["frames"] == 0 or b["anim_us"] <= 0:
                print(f"FAIL {name}: the baseline {baseline} was not measured, (b) cannot be judged; {work_text}")
                status = 1
                continue
            base_rate = b["animation"]["compositor"] / (b["anim_us"] / 1e6)
            rate_ok = rate <= base_rate * BASELINE_FACTOR + 1e-9
            rate_text = (f"(b) {a['compositor']} compositor-caused long frame(s) in {seconds:.2f} s, {rate:.1f}/s, against {baseline}'s "
                         f"{b['animation']['compositor']} in {b['anim_us'] / 1e6:.2f} s, {base_rate:.1f}/s (gate: {base_rate * BASELINE_FACTOR:.1f}/s)")
        verdict = "PASS" if work_ok and rate_ok else "FAIL"
        if verdict == "FAIL":
            status = 1
        print(f"{verdict} {name}: {work_text}; {rate_text}; {a['client']} paced by a client and {a['other']} other, information")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
