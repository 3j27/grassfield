#!/usr/bin/env python3
"""A capture taken INSIDE a crossfade must be the old and the new colour mixed in the proportion of the fade's progress.

The incoming slot is an opaque picture drawn over the opaque outgoing one at opacity p, so the screen shows old + p * (new - old),
exactly. The test reads the progress through the dev IPC (`wallpaper progress <output>`) just before (p0) and just after (p1)
the capture, so the capture lies at some p in [p0, p1]: the measured colour must be on the straight segment from
old + p0 * (new - old) to old + p1 * (new - old), within TOL. A hard cut (the incoming picture hidden under the outgoing one,
the review finding) shows the OLD colour at every p and is far from that segment; a bleed of a third layer is off the line.

Usage: fade_mid.py R,G,B(old) R,G,B(new) R,G,B(measured) P0 P1      fade_mid.py --selftest
"""
import math
import sys

TOL = 22        # distance to the predicted segment (a prepared JPEG and the grab are within a few units)
MAX_SPAN = 0.6  # the capture must not span more than this much of the fade (else the prediction says little)


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def point(old, new, p):
    return tuple(o + p * (n - o) for o, n in zip(old, new))


def seg_dist(m, a, b):
    ab = [y - x for x, y in zip(a, b)]
    am = [y - x for x, y in zip(a, m)]
    n = sum(v * v for v in ab)
    t = 0.0 if n == 0 else max(0.0, min(1.0, sum(u * v for u, v in zip(am, ab)) / n))
    return dist(m, [x + t * v for x, v in zip(a, ab)])


def check(old, new, measured, p0, p1):
    """Returns "" when the capture is a proper blend for progress in [p0, p1], else the reason."""
    if not (0.0 < p0 <= p1 < 1.0):
        return "progress %.2f..%.2f is not inside a fade" % (p0, p1)
    if p1 - p0 > MAX_SPAN:
        return "the capture spans %.2f of the fade: too wide to say anything" % (p1 - p0)
    d = seg_dist(measured, point(old, new, p0), point(old, new, p1))
    if d > TOL:
        return "measured %s is %.0f from the predicted blend of %s and %s at %.2f..%.2f" % (measured, d, old, new, p0, p1)
    return ""


def selftest():
    red, green = (255, 0, 0), (0, 255, 0)
    assert check(red, green, point(red, green, 0.4), 0.3, 0.5) == ""
    assert check(red, green, point(red, green, 0.45), 0.3, 0.5) == ""
    assert check(red, green, red, 0.3, 0.5) != "", "a hard cut shows the old colour"
    assert check(red, green, green, 0.3, 0.5) != "", "a hard cut shows the new colour"
    assert check(red, green, (39, 94, 110), 0.3, 0.5) != "", "a third layer"
    assert check(red, green, point(red, (39, 94, 110), 0.15), 0.3, 0.5) != "", "a 15 % bleed of a third layer"
    assert check(red, green, point(red, green, 0.4), 0.0, 0.5) != "", "not inside a fade"
    assert check(red, green, point(red, green, 0.4), 0.1, 0.9) != "", "too wide"
    print("fade_mid selftest: ok")


def main(argv):
    if argv[:1] == ["--selftest"]:
        selftest()
        return 0
    old, new, measured = (tuple(int(v) for v in a.split(",")) for a in argv[:3])
    why = check(old, new, measured, float(argv[3]), float(argv[4]))
    print(why if why else "blend ok")
    return 1 if why else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
