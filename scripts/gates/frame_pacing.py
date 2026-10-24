#!/usr/bin/env python3
"""Gate P3: frame pacing of one shell surface from the shell's render-timing log (QSG_RENDER_TIMING, written when the
shell runs with GRASSFIELD_RENDER_TIMING=1: scripts/dev/shell-run.sh --render-timing).

  frame_pacing.py --surface NAME LOG [--threshold-ms 16.7] [--min-share 95] [--min-frames 100]
  frame_pacing.py --selftest

Each "frame rendered in R ms" line of the render thread is one frame of the surface being exercised (the shell draws
nothing while idle, so the log of a scenario holds the scenario's frames). The times are whole milliseconds, so a frame
is "within the budget" when R < threshold (R <= 16 for 16.7 ms). One line is printed with the frame count, the share,
p50/p95/p99 and the slowest frame.

THIS TOOL NEVER PRINTS PASS. Gate P3 (master-prompt §10, a † gate; ADR-0006) is defined on wp_presentation timestamps
from a probe client, measured on the owner's real session. The shell's own render time (sync + render + swap, the method
of tests/visual/apps-frames.py) is only a proxy: below --min-share it prints "PROXY FAIL" (exit 1, indicative); at or
above it prints "PROXY, NOT VERIFIED" (exit 2); fewer than --min-frames frames is INCONCLUSIVE (exit 2).

Exit: 1 PROXY FAIL, 2 anything else (never 0). Standard library only (python3 -I).
"""
import argparse
import re
import sys

FRAME = re.compile(r"frame rendered in (\d+)\s*ms")


def frames(text):
    return [int(m) for m in FRAME.findall(text)]


def percentile(sorted_values, q):
    if not sorted_values:
        return 0
    i = min(len(sorted_values) - 1, max(0, int(round(q * (len(sorted_values) - 1)))))
    return sorted_values[i]


def verdict(values, threshold_ms, min_share, min_frames):
    """-> (exit code, share in %, text)"""
    n = len(values)
    if n == 0:
        return 2, 0.0, "no frame in the log (was the shell started with --render-timing?)"
    within = sum(1 for v in values if v < threshold_ms)
    share = 100.0 * within / n
    s = sorted(values)
    stats = f"{within}/{n} frames < {threshold_ms:g} ms = {share:.1f} %, p50 {percentile(s, .5)} ms, p95 {percentile(s, .95)} ms, p99 {percentile(s, .99)} ms, slowest {s[-1]} ms"
    if n < min_frames:
        return 2, share, f"INCONCLUSIVE: only {n} frames (minimum {min_frames}); {stats}"
    # P3 is defined on wp_presentation timestamps (ADR-0006) measured by the owner (L2, †). The shell's render-thread time
    # is a proxy: it can say "clearly not met", never "met".
    if share >= min_share:
        return 2, share, (f"PROXY, NOT VERIFIED (not a pass: the gate needs wp_presentation timestamps, ADR-0006): shell render-thread "
                          f"time meets the share, {stats} (needs >= {min_share:g} %)")
    return 1, share, f"PROXY FAIL (indicative: shell render-thread time, not wp_presentation): {stats} (needs >= {min_share:g} %)"


def selftest():
    fails = []

    def expect(name, got, want):
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    log = "".join(f"2026-10-23 10:00:{i % 60:02d}.000 INFO qml: frame rendered in {ms} ms, sync=0, render=1, swap=2\n"
                  for i, ms in enumerate([8] * 96 + [30] * 4))
    expect("frames parsed", len(frames(log)), 100)
    expect("96 % is only a proxy, never a pass", verdict(frames(log), 16.7, 95, 100)[0], 2)
    expect("96 % says NOT VERIFIED", "NOT VERIFIED" in verdict(frames(log), 16.7, 95, 100)[2] and "PASS:" not in verdict(frames(log), 16.7, 95, 100)[2], True)
    log2 = "".join(f"frame rendered in {ms} ms\n" for ms in [8] * 90 + [30] * 10)
    expect("90 % is a proxy fail", verdict(frames(log2), 16.7, 95, 100)[0], 1)
    expect("few frames inconclusive", verdict([8] * 10, 16.7, 95, 100)[0], 2)
    expect("no frames inconclusive", verdict([], 16.7, 95, 100)[0], 2)
    expect("16 ms is within 16.7", verdict([16] * 100, 16.7, 95, 100)[2].startswith("PROXY, NOT VERIFIED"), True)
    expect("17 ms is not", verdict([17] * 100, 16.7, 95, 100)[0], 1)
    expect("exactly at the share", verdict([8] * 95 + [30] * 5, 16.7, 95, 100)[0], 2)
    if fails:
        print("\n".join("FAIL: " + f for f in fails))
        return 1
    print("frame_pacing selftest: PASS (9 cases)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log", nargs="?")
    ap.add_argument("--surface")
    ap.add_argument("--threshold-ms", type=float, default=16.7)
    ap.add_argument("--min-share", type=float, default=95.0)
    ap.add_argument("--min-frames", type=int, default=100)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.log or not args.surface:
        ap.error("--surface and LOG are required")
    try:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            values = frames(f.read())
    except OSError as e:
        print(f"P3 {args.surface}: cannot read {args.log}: {e}", file=sys.stderr)
        return 2
    code, _share, text = verdict(values, args.threshold_ms, args.min_share, args.min_frames)
    print(f"P3 {args.surface}: {text}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
