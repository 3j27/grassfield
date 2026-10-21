#!/usr/bin/env python3
"""Check that a crossfade of solid-colour wallpapers really blends (tests/visual/wallpaper-fade.sh, ADR-0016).

Input: a text file with one line "r g b" per capture, in time order (the mean colour of a region of the desktop), and the
pure colours of the pictures. A capture is a PICTURE when it is within PURE of one of them, else a BLEND. For every change
from one picture to the next (consecutive stable pictures that differ) there must be at least one blend capture in between
that lies on the straight line between the two colours (a crossfade of two opaque pictures is a linear blend), and not
close to either end. A hard cut (the review finding: the incoming picture faded in underneath the opaque old one) has none.

Usage: fade_blend.py FRAMES.txt R,G,B R,G,B ...      fade_blend.py --selftest
       fade_blend.py --between FRAMES.txt R,G,B R,G,B to|from   (one transition: only the two contents and their blends show)
       fade_blend.py --only-pictures FRAMES.txt R,G,B ...   (every capture must be a picture or a blend of two: nothing else shows)
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


def foreign(frames, pures):
    """Captures that are neither a picture nor a blend of two pictures (the bare window or the artwork showing through)."""
    bad = []
    started = False
    for i, f in enumerate(frames):
        near = min(dist(f, p) for p in pures)
        # Until the first picture is on screen the artwork (or its fade into the first picture) is what shows.
        if not started:
            started = near < PURE
            continue
        on_line = min(to_segment(f, a, b)[0] for a in pures for b in pures)
        if near >= PURE and on_line >= LINE:
            bad.append(i)
    return bad


def between(frames, a, b, final):
    """A transition from content a to content b: every capture is a, b, or a point on the line between them (a crossfade of
    the two); never a third colour (the artwork or the bare window showing through). The last capture is `final` (b, or a
    when the change must fail and keep what is on screen). Returns the list of problems."""
    problems = []
    for i, f in enumerate(frames):
        if dist(f, a) >= PURE and dist(f, b) >= PURE and to_segment(f, a, b)[0] >= LINE:
            problems.append("capture %d is a third thing: %s" % (i, f))
    if not frames:
        problems.append("no capture")
    else:
        end = b if final == "to" else a
        if dist(frames[-1], end) >= PURE:
            problems.append("the last capture %s is not %s" % (frames[-1], final))
    return problems


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
    # Foreign captures: the artwork (a dark blue) between two pictures.
    assert foreign([red, mix(red, green, 0.5), green], pures) == []
    assert foreign([red, (15, 42, 63), green], pures) == [1]
    assert foreign([(15, 42, 63), (130, 20, 30), red, green], pures) == [], "the start from the artwork is not foreign"
    art = (47, 95, 90)
    assert between([red, red, mix(red, green, 0.4), green, green], red, green, "to") == []
    assert between([red, red, red], red, green, "to") != [], "never arrived"
    assert between([red, red, red], red, green, "from") == [], "a failure keeps what was on screen"
    assert between([red, art, green], red, green, "to") != [], "the artwork showed between the two"
    assert between([red, mix(red, art, 0.5), art, green], red, green, "to") != []
    print("fade_blend selftest: ok")


def main(argv):
    if argv[:1] == ["--selftest"]:
        selftest()
        return 0
    if argv[:1] == ["--between"]:
        frames = [tuple(int(v) for v in line.split()) for line in open(argv[1]) if line.strip()]
        a, b = (tuple(int(v) for v in x.split(",")) for x in argv[2:4])
        problems = between(frames, a, b, argv[4])
        for p in problems:
            print(p)
        print("%d captures, %d problem(s)" % (len(frames), len(problems)))
        return 1 if problems or len(frames) < 6 else 0
    only = argv[:1] == ["--only-pictures"]
    if only:
        argv = argv[1:]
    frames = [tuple(int(v) for v in line.split()) for line in open(argv[0]) if line.strip()]
    pures = [tuple(int(v) for v in a.split(",")) for a in argv[1:]]
    if only:
        bad = foreign(frames, pures)
        for i in bad:
            print("capture %d is neither a picture nor a blend: %s" % (i, frames[i]))
        print("%d captures, %d foreign" % (len(frames), len(bad)))
        return 1 if bad or len(frames) < 6 else 0
    results = analyse(frames, pures)
    for a, b, n, ok in results:
        print("change %d -> %d: %d blend capture(s) between, %s" % (a, b, n, "BLENDED" if ok else "HARD CUT"))
    if len(results) < MIN_TRANSITIONS:
        print("FAIL: only %d changes seen (need %d)" % (len(results), MIN_TRANSITIONS))
        return 1
    return 0 if all(ok for *_, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
