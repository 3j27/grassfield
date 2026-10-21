#!/usr/bin/env python3
"""Check that a crossfade of solid-colour wallpapers really blends (tests/visual/wallpaper-fade.sh, ADR-0016).

Input: a text file with one line "r g b" per capture, in time order (the mean colour of a region of the desktop), and the
pure colours of the pictures. A capture is a PICTURE when it is within PURE of one of them, else a BLEND. For every change
from one picture to the next (consecutive stable pictures that differ) there must be at least one blend capture in between
that lies on the straight line between the two colours (a crossfade of two opaque pictures is a linear blend), and not
close to either end. A hard cut (the review finding: the incoming picture faded in underneath the opaque old one) has none.

Usage: fade_blend.py FRAMES.txt R,G,B R,G,B ...      fade_blend.py --selftest
"""
import math
import sys

PURE = 40      # distance to a picture colour under which a capture is that picture
LINE = 45      # distance to the segment between two colours under which a blend is a crossfade of them
MIN_TRANSITIONS = 4


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def to_segment(p, a, b):
    """Distance of p to the segment a-b and the position (0..1) of its projection."""
    ab = [y - x for x, y in zip(a, b)]
    ap = [y - x for x, y in zip(a, p)]
    n = sum(v * v for v in ab)
    t = 0.0 if n == 0 else max(0.0, min(1.0, sum(u * v for u, v in zip(ap, ab)) / n))
    q = [x + t * v for x, v in zip(a, ab)]
    return dist(p, q), t


def analyse(frames, pures):
    labels = []
    for f in frames:
        best = min(range(len(pures)), key=lambda i: dist(f, pures[i]))
        labels.append(best if dist(f, pures[best]) < PURE else None)
    # Stable pictures in order, with the captures between two of them.
    changes = []
    last = None
    between = []
    for f, label in zip(frames, labels):
        if label is None:
            if last is not None:
                between.append(f)
            continue
        if last is not None and label != last:
            changes.append((last, label, between))
        if label != last:
            between = []
        else:
            between = []
        last = label
    results = []
    for a, b, blends in changes:
        ok = False
        for f in blends:
            d, t = to_segment(f, pures[a], pures[b])
            if d < LINE and 0.1 < t < 0.9:
                ok = True
        results.append((a, b, len(blends), ok))
    return results


def selftest():
    red, green, blue = (255, 0, 0), (0, 255, 0), (0, 0, 255)
    pures = [red, green, blue]

    def mix(a, b, t):
        return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

    good = [red, red, mix(red, green, 0.3), mix(red, green, 0.7), green, green, mix(green, blue, 0.5), blue, mix(blue, red, 0.4), red]
    r = analyse(good, pures)
    assert len(r) == 3 and all(ok for *_, ok in r), r
    # A hard cut: the pictures follow each other with nothing in between (on every other change).
    cut = [red, red, green, green, mix(green, blue, 0.5), blue, blue, red]
    r = analyse(cut, pures)
    assert [ok for *_, ok in r] == [False, True, False], r
    # A blend that is not on the line (a dip through black) is not a crossfade.
    dip = [red, (30, 30, 30), green]
    assert [ok for *_, ok in analyse(dip, pures)] == [False]
    print("fade_blend selftest: ok")


def main(argv):
    if argv[:1] == ["--selftest"]:
        selftest()
        return 0
    frames = [tuple(int(v) for v in line.split()) for line in open(argv[0]) if line.strip()]
    pures = [tuple(int(v) for v in a.split(",")) for a in argv[1:]]
    results = analyse(frames, pures)
    for a, b, n, ok in results:
        print("change %d -> %d: %d blend capture(s) between, %s" % (a, b, n, "BLENDED" if ok else "HARD CUT"))
    if len(results) < MIN_TRANSITIONS:
        print("FAIL: only %d changes seen (need %d)" % (len(results), MIN_TRANSITIONS))
        return 1
    return 0 if all(ok for *_, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
