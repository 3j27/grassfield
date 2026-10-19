"""Dock motion analysis (tests/visual/dock-motion.sh): tracks the position of a coloured test icon in a burst of frames.

Usage: python3 -I dock-motion.py DIR NAME COLOUR [glide|land]
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


def check_glide(rows):
    """The tile slides from its old place to its new one: it moves, never jumps to the target at once, never goes past it and
    never turns back."""
    xs = [r[1] for r in rows if r[1] is not None]
    if len(xs) < 3:
        return "no tile track"
    start, end = xs[0], xs[-1]
    dist = end - start
    if abs(dist) < 20:
        return "the tile did not move (%d px)" % dist
    sign = 1 if dist > 0 else -1
    moving = [x for x in xs if x != start and x != end]
    if len(moving) < 3:
        return "only %d intermediate frames: the tile jumped" % len(moving)
    steps = [b - a for a, b in zip(xs, xs[1:])]
    if max(abs(v) for v in steps) > 0.6 * abs(dist):
        return "a single frame moved %d of %d px: a jump" % (max(abs(v) for v in steps), abs(dist))
    if any(v * sign < 0 for v in steps):
        return "the tile turned back (wobble): %s" % steps
    if any((x - end) * sign > 1 for x in xs):
        return "the tile went past its place"
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
    verdict = {"glide": check_glide, "land": check_land}.get(mode, lambda rows: "")(rows)
    if verdict:
        print("CHECK FAILED (%s): %s" % (name, verdict), file=sys.stderr)
        sys.exit(1)


main()
