"""Dock motion analysis (tests/visual/dock-motion.sh): tracks the position of a coloured test icon in a burst of frames.

Usage: python3 -I dock-motion.py DIR NAME COLOUR [glide|land|collapse]
  DIR/NAME-NNN.ppm  frames (P6) of the Dock area, DIR/NAME.log  "index epoch_ms" per frame
  COLOUR            magenta or cyan: the pixels of the test icon (pure colour, the default icon mode keeps it)
Prints one line per frame: time since the first frame (ms), x of the icon's left edge, x of its centre, y of its top edge,
pixel count (0: icon not visible). With a mode the motion is checked: exit status 1 and a message on failure."""
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def box(path, colour):
    w, h, px = read_ppm(path)
    x0 = y0 = 10**9
    x1 = y1 = -1
    n = 0
    for y in range(h):
        row = px[y * w * 3:(y + 1) * w * 3]
        for x in range(w):
            r, g, b = row[3 * x], row[3 * x + 1], row[3 * x + 2]
            if colour == "magenta":
                hit = r > 170 and b > 170 and g < 90
            else:
                hit = g > 170 and b > 170 and r < 90
            if hit:
                n += 1
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
    return (x0, x1, y0, y1, n) if n else (None, None, None, None, 0)


ANIM = {"glide": 220, "collapse": 120}  # motion.normal / motion.fast (ms): the animations under test


def interval(rows):
    """Median time between two frames (ms): the capture rate of this run (grim on the nested output delivers one frame every
    35-50 ms on the reference machine, so a 120 ms animation is seen in about 3 frames, a 220 ms one in about 5)."""
    ts = [b[0] - a[0] for a, b in zip(rows, rows[1:])]
    return sorted(ts)[len(ts) // 2] if ts else 0


def span(rows, xs_of):
    """Time between the last frame at the start place and the first frame at the end place: the animation lies inside it."""
    pts = [(r[0], xs_of(r)) for r in rows if xs_of(r) is not None]
    start, end = pts[0][1], pts[-1][1]
    t_start = max(t for t, x in pts if x == start and all(y == start for u, y in pts if u <= t))
    t_end = min(t for t, x in pts if x == end and t >= t_start and all(y == end for u, y in pts if u >= t))
    return t_end - t_start


def check_glide(rows):
    """The tile slides from its old place to its new one: it moves, never snaps to the target (the time between the last frame
    at the start and the first at the end covers the animation), never jumps by more than what the capture rate allows, never
    goes past its place and never turns back. Independent of how many frames the capture delivers."""
    xs = [r[1] for r in rows if r[1] is not None]
    if len(xs) < 3:
        return "no tile track"
    start, end = xs[0], xs[-1]
    dist = end - start
    if abs(dist) < 20:
        return "the tile did not move (%d px)" % dist
    sign = 1 if dist > 0 else -1
    steps = [b - a for a, b in zip(xs, xs[1:])]
    if any(v * sign < 0 for v in steps):
        return "the tile turned back (wobble): %s" % steps
    if any((x - end) * sign > 1 for x in xs):
        return "the tile went past its place"
    anim, dt = ANIM["glide"], interval(rows)
    # A frame step may cover dt of the ease-out: at most that share of the distance (never more than 0.95).
    allowed = min(0.95, max(0.65, 2.2 * dt / anim))
    if max(abs(v) for v in steps) > allowed * abs(dist):
        return "a single frame moved %d of %d px (allowed %d%% at %d ms per frame): a jump" % (max(abs(v) for v in steps), abs(dist), allowed * 100, dt)
    took = span(rows, lambda r: r[1])
    if took < 0.5 * anim:
        return "the move took at most %d ms (animation %d ms): a snap" % (took, anim)
    if took > anim + 3 * dt + 150:
        return "the move took %d ms (animation %d ms, %d ms per frame): too slow" % (took, anim, dt)
    return ""


def check_land(rows):
    """The launch hop ends with a landing when the window appears: from the last frame clearly in the air to the final rest
    the icon takes at least 100 ms (the 220 ms bounce), not a snap."""
    ys = [r[3] for r in rows if r[3] is not None]
    if len(ys) < 10:
        return "no tile track"
    base = max(ys)
    lift = [base - y for y in ys]
    times = [r[0] for r in rows if r[3] is not None]
    air = [i for i, v in enumerate(lift) if v >= 8]
    if not air:
        return "the icon never hopped"
    last_air = air[-1]
    rest = len(lift)
    for i in range(len(lift) - 1, last_air, -1):
        if lift[i] > 1:
            rest = i + 1
            break
    else:
        rest = last_air + 1
    settle = times[min(rest, len(times) - 1)] - times[last_air]
    if settle < 100:
        return "the hop ended in %d ms: a snap, not a landing" % settle
    return ""


def check_collapse(rows):
    """A tile dragged out of the Dock closes its gap: the neighbour (tracked) moves half a pitch towards the centre without
    overshoot or turning back, over a time that covers the animation (not a snap), and moves back when the tile is dragged
    back in. Independent of how many frames the capture delivers."""
    xs = [r[1] for r in rows if r[1] is not None]
    if len(xs) < 6:
        return "no tile track"
    start = xs[0]
    far = max(xs, key=lambda x: abs(x - start))
    sign = 1 if far > start else -1
    if not 20 <= abs(far - start) <= 34:
        return "the neighbour moved %d px (about half a pitch, 26, expected)" % (far - start)
    k = xs.index(far)
    up = xs[:k + 1]
    if any((b - a) * sign < 0 for a, b in zip(up, up[1:])):
        return "the neighbour turned back while the gap closed: %s" % up
    anim, dt = ANIM["collapse"], interval(rows)
    pts = [(r[0], r[1]) for r in rows if r[1] is not None]
    t_from = max(t for t, x in pts[:k + 1] if x == start and all(y == start for u, y in pts if u <= t))
    took = pts[k][0] - t_from
    if took < 0.5 * anim:
        return "the gap closed in at most %d ms (animation %d ms): no animation" % (took, anim)
    steps = [b - a for a, b in zip(up, up[1:])]
    allowed = min(0.95, max(0.65, 2.2 * dt / anim))
    if steps and max(abs(v) for v in steps) > allowed * abs(far - start):
        return "the gap closed in a single %d px step (allowed %d%% at %d ms per frame)" % (max(abs(v) for v in steps), allowed * 100, dt)
    if abs(xs[-1] - start) > 2:
        return "the gap did not reopen when the tile was dragged back (%d px off)" % (xs[-1] - start)
    return ""


def main():
    d, name, colour = sys.argv[1:4]
    mode = sys.argv[4] if len(sys.argv) > 4 else "none"
    frames = []
    with open("%s/%s.log" % (d, name)) as f:
        for line in f:
            i, t = line.split()
            frames.append((int(i), int(t)))
    t0 = frames[0][1]
    rows = []
    for i, t in frames:
        x0, x1, y0, y1, n = box("%s/%s-%03d.ppm" % (d, name, i), colour)
        rows.append((t - t0, None if x0 is None else x0, None if x0 is None else (x0 + x1) // 2, y0, n))
    for r in rows:
        print("%d %s %s %s %d" % (r[0], r[1], r[2], r[3], r[4]))
    print("# capture: %d frames, median %d ms per frame" % (len(rows), interval(rows)))
    verdict = {"glide": check_glide, "land": check_land, "collapse": check_collapse}.get(mode, lambda rows: "")(rows)
    if verdict:
        print("CHECK FAILED (%s): %s" % (name, verdict), file=sys.stderr)
        sys.exit(1)


main()
