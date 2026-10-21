"""Dock launch analysis (tests/visual/dock-launch.sh).

  python3 -I dock-launch.py locate PNG COLOUR        centre "x y" of the pure-colour test icon in a screenshot (magenta|cyan)
  python3 -I dock-launch.py launch DIR NAME COLOUR   check the frames DIR/NAME-NNN.ppm of a launch

Frames come with DIR/NAME.log ("index ms-before ms-after" per frame) and DIR/NAME.events ("down MS" and "up MS": the button
press and release of the click, same clock). The icon is tracked by its pure colour; the running dot is the white run below it.
Measured and checked (exit status 1 on failure):
  press     mean colour of the icon while the button is held is darker than at rest (macOS: the icon darkens slightly)
  start     time from the release (the click) to the first frame with the icon lifted (a frame is 25-50 ms on the reference machine)
  rise      highest lift as a fraction of the icon height (macOS: about a third)
  period    time between two lift maxima (macOS: about 0.5 s per bounce)
  dot       the running dot appears after the click, once the window maps, and the icon is at rest again at the end
"""
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def hit(colour, r, g, b):
    if colour == "magenta":
        return r > 120 and b > 120 and g < 70 and abs(r - b) < 40
    return g > 120 and b > 120 and r < 70 and abs(g - b) < 40


def box(px, w, h, colour):
    x0 = y0 = 10**9
    x1 = y1 = -1
    n = 0
    sr = sg = sb = 0
    for y in range(h):
        row = px[y * w * 3:(y + 1) * w * 3]
        for x in range(w):
            r, g, b = row[3 * x], row[3 * x + 1], row[3 * x + 2]
            if hit(colour, r, g, b):
                n += 1
                x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), max(y1, y)
                sr, sg, sb = sr + r, sg + g, sb + b
    if n == 0:
        return None
    return {"x0": x0, "x1": x1, "y0": y0, "y1": y1, "n": n, "mean": ((sr + sg + sb) / (3 * n))}


def dot(px, w, x_centre, y_below, h):
    """Bright pixels in the strip right below the icon (the running dot is white in dark appearance): only within 10 px of the
    icon's centre x, so a running neighbour's dot is not counted."""
    n = 0
    for y in range(y_below, min(h, y_below + 14)):
        for x in range(max(0, x_centre - 10), min(w, x_centre + 10)):
            r, g, b = px[(y * w + x) * 3:(y * w + x) * 3 + 3]
            if r > 200 and g > 200 and b > 200:
                n += 1
    return n


def menu(after, before, x):
    """The Dock menu is on screen: many pixels above the Dock, around x, differ from the capture taken before the press."""
    import subprocess
    def crop(path):
        return subprocess.run(["magick", path, "-crop", "360x260+%d+620" % (int(x) - 180), "+repage", "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout
    a, b = crop(after), crop(before)
    n = sum(1 for i in range(0, min(len(a), len(b)), 3) if abs(a[i] - b[i]) + abs(a[i + 1] - b[i + 1]) + abs(a[i + 2] - b[i + 2]) > 60)
    print("menu: %d pixels above the tile differ from the capture before the press" % n)
    return 0 if n > 800 else 1


def red_outside_icon(path):
    """Red (badge) pixels outside the magenta icon square, and the icon box."""
    import subprocess
    out = subprocess.run(["magick", path, "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
    parts = out.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    px = parts[3]
    b = box(px, w, h, "magenta")
    if b is None:
        return None, 0
    n = 0
    for y in range(h):
        for x in range(w):
            r, g, bl = px[(y * w + x) * 3:(y * w + x) * 3 + 3]
            if r > 170 and g < 90 and bl < 90 and (x > b["x1"] or y < b["y0"]):
                n += 1
    return b, n


def badge(held, rest):
    bh, nh = red_outside_icon(held)
    br, nr = red_outside_icon(rest)
    print("badge: red pixels outside the icon square: %d held (dimmed icon), %d at rest" % (nh, nr))
    if bh is not None and br is not None:
        print("badge: icon mean while held %.0f, at rest %.0f" % (bh["mean"], br["mean"]))
    dark = bh is not None and br is not None and bh["mean"] < br["mean"] * 0.95
    print("badge: the icon is %s while held" % ("darker" if dark else "NOT darker"))
    return 0 if nr >= 15 and nh >= 0.8 * nr and dark else 1


def locate(path, colour):
    import subprocess
    out = subprocess.run(["magick", path, "-crop", "1400x200+260+880", "+repage", "-depth", "8", "ppm:-"], capture_output=True, check=True).stdout
    parts = out.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    b = box(parts[3], w, h, colour)
    if b is not None:
        # Several tiles of the same app (app tile and minimized-window tile): the leftmost icon only.
        cols = bytearray()
        for y in range(h):
            row = parts[3][y * w * 3:y * w * 3 + (b["x0"] + 56) * 3]
            cols += row + bytes(max(0, 3 * (w - b["x0"] - 56)))
        b = box(bytes(cols), w, h, colour)
    if b is None:
        print("locate: no %s icon" % colour, file=sys.stderr)
        sys.exit(1)
    print(260 + (b["x0"] + b["x1"]) // 2, 880 + (b["y0"] + b["y1"]) // 2)


def launch(d, name, colour, nobounce=False):
    import os
    log = [l.split() for l in open(os.path.join(d, name + ".log")).read().split("\n") if l.strip()]
    events = dict(l.split() for l in open(os.path.join(d, name + ".events")).read().split("\n") if l.strip())
    down, up = int(events["down"]), int(events["up"])
    # The press and the release as the Dock's tap handler saw them ("dock-launch: pressed true|false EPOCH-MS", same clock).
    cpath0 = os.path.join(d, name + ".curve")
    seen_press = seen_release = False
    if os.path.exists(cpath0):
        for l in open(cpath0):
            if "dock-launch: pressed" in l:
                f = l.split("dock-launch: pressed")[1].split()
                if f[0] == "true":
                    down = int(f[1])
                    seen_press = True
                else:
                    up = int(f[1])
                    seen_release = True
    if not (seen_press and seen_release):
        # The label "stall" is only for what the shell's own timing proves: without its press and release lines nothing is proved.
        print("FAIL: the Dock logged no press and release (pressed true / false) for this click: the click did not reach the tile")
        return 1
    if True:
        print("events: pressed at %d, released at %d (shell clock), held %d ms" % (down, up, up - down))
        # The click was meant to be 250 ms: a hold near the menu threshold (550 ms) means the host stalled, not that the Dock is wrong.
        if up - down >= 500:
            print("STALL: the shell measured a hold of %d ms for a click of about 250 ms (menu threshold 550 ms; seen 275-465 ms while grim records): host stall, rerun" % (up - down))
            return 2
    rows = []
    for idx, t0, t1 in log:
        w, h, px = read_ppm(os.path.join(d, "%s-%03d.ppm" % (name, int(idx))))
        b = box(px, w, h, colour)
        rows.append({"t": (int(t0) + int(t1)) // 2, "t0": int(t0), "t1": int(t1), "box": b, "px": px, "w": w, "h": h})
    rest = [r for r in rows if r["t"] < down and r["box"]]
    if not rest:
        print("FAIL no frame of the icon at rest before the click")
        return 1
    ref = rest[-1]["box"]
    top, size = ref["y0"], ref["y1"] - ref["y0"] + 1
    xc = (ref["x0"] + ref["x1"]) // 2
    below = ref["y1"] + 2
    fail = 0
    slowcap = False
    print("rest: top y=%d icon %d px, rest mean %.0f, frames %d, frame interval %d ms" % (top, size, ref["mean"], len(rows), sorted(b["t"] - a["t"] for a, b in zip(rows, rows[1:]))[len(rows) // 2]))

    # Frames captured entirely while the button was held (the capture started 60 ms after the press, ended before the release).
    held = [r for r in rows if r["t0"] >= down + 40 and r["t1"] <= up and r["box"]]
    if held:
        mean = max(r["box"]["mean"] for r in held)
        ok = mean < ref["mean"] * 0.95
        print("press: brightest held frame mean %.0f against %.0f at rest (%d frames fully inside the hold): %s" % (mean, ref["mean"], len(held), "darker" if ok else "NOT darker"))
        fail |= not ok
    else:
        print("press: no frame fully inside the hold (grim is too slow for a hold of %d ms here); the dimming is asserted by the badge part, which takes its frame at a chosen time" % (up - down))

    after = [r for r in rows if r["t"] >= up]
    seen_px = max((top - r["box"]["y0"] for r in after if r["box"]), default=0)
    print("frames: highest lift seen in the captured frames %d px (grim delivers a frame every %d ms here, see above)" % (seen_px, sorted(b["t"] - a["t"] for a, b in zip(rows, rows[1:]))[len(rows) // 2]))
    # The bounce curve, logged by the shell against the click ("dock-launch: lift MS PX", fixtures only): exact timing.
    curve = []
    cpath = os.path.join(d, name + ".curve")
    if os.path.exists(cpath):
        for l in open(cpath):
            if "dock-launch: lift" in l:
                f = l.split("dock-launch: lift")[1].split()
                curve.append((int(f[0]), float(f[1])))
    peak = max((v for _, v in curve), default=0)
    first = next((t for t, v in curve if v > 0.5), None)
    print("start: the first lifted frame is %s ms after the click (shell, scene graph; one display frame more on screen)" % first)
    fail |= (not nobounce) and (first is None or first > 100)
    ratio = peak / size
    print("rise: highest lift %.1f px = %.2f of the icon (%d px); curve samples %d" % (peak, ratio, size, len(curve)))
    fail |= (not nobounce) and (not 0.25 <= ratio <= 0.45)
    maxima = []
    for i in range(1, len(curve) - 1):
        if curve[i][1] >= 0.9 * peak and curve[i][1] >= curve[i - 1][1] and curve[i][1] > curve[i + 1][1]:
            if not maxima or curve[i][0] - maxima[-1] > 250:
                maxima.append(curve[i][0])
    gaps = [b[0] - a[0] for a, b in zip(curve, curve[1:]) if b[0] < (maxima[-1] if maxima else 0)]
    biggest = max(gaps, default=0)
    print("curve: largest gap between two frames of the shell during the bounce %d ms (a frame is 16 ms)" % biggest)
    stalled = biggest > 100
    periods = [b - a for a, b in zip(maxima, maxima[1:])]
    print("period: maxima at %s ms, between them %s ms" % (maxima, periods))
    period_fail = (not nobounce) and (not periods or not all(430 <= p <= 570 for p in periods))
    # Up and down: time from 0 to the peak and back (ease out up, ease in down).
    if len(maxima) >= 2:
        i0 = next(i for i, (t, v) in enumerate(curve) if t >= maxima[0] and v >= 0.9 * peak)
        lows = [t for t, v in curve if maxima[0] < t < maxima[1] and v <= 0.3]
        rise_t = maxima[0] - first
        print("shape: first lift %d ms, peak at %d ms (up %d ms), back near the ground at %s ms" % (first, maxima[0], rise_t, lows[0] if lows else None))

    def centre(r):
        return (r["box"]["x0"] + r["box"]["x1"]) // 2 if r["box"] else xc
    dots = [(r["t"] - up, dot(r["px"], r["w"], centre(r), below, r["h"])) for r in after]
    seen = next((t for t, n in dots if n >= 6), None)
    before_dot = max((dot(r["px"], r["w"], centre(r), below, r["h"]) for r in rest), default=0)
    print("dot: %d bright pixels before the click, first seen %s ms after it" % (before_dot, seen))
    fail |= seen is None or before_dot >= 6
    mpath = os.path.join(d, name + ".map")
    if os.path.exists(mpath):
        mapped = int(open(mpath).read().split()[0]) - up
        gap = None if seen is None else seen - mapped
        print("map: the window showed up in the compositor %d ms after the click; the dot was first seen %s ms after the window (a frame is %d ms, the poll 30-60 ms)" % (mapped, gap, sorted(b["t"] - a["t"] for a, b in zip(rows, rows[1:]))[len(rows) // 2]))
        interval_ms = sorted(b["t"] - a["t"] for a, b in zip(rows, rows[1:]))[len(rows) // 2]
        fail |= gap is None or gap > 300 + 2 * interval_ms
    end = rows[-1]["box"]
    settled = end is not None and end["y0"] == top
    print("end: icon %s" % ("at rest" if settled else "still lifted (y0 %s)" % (end["y0"] if end else None)))
    fail |= not settled
    # A skipped-frame stall of the shell itself (proved by its own frame gaps) explains a wrong hop period and nothing else: any other
    # failed check is a failure, with or without a stall.
    if period_fail and stalled and not fail:
        print("STALL: the shell itself skipped frames for %d ms during the bounce (the hop period is off for that reason only): rerun" % biggest)
        return 2
    fail |= period_fail
    print("RESULT " + ("FAIL" if fail else "PASS"))
    return 1 if fail else 0


if __name__ == "__main__":
    if sys.argv[1] == "badge":
        sys.exit(badge(sys.argv[2], sys.argv[3]))
    if sys.argv[1] == "menu":
        sys.exit(menu(sys.argv[2], sys.argv[3], sys.argv[4]))
    if sys.argv[1] == "locate":
        locate(sys.argv[2], sys.argv[3])
    else:
        sys.exit(launch(sys.argv[2], sys.argv[3], sys.argv[4], len(sys.argv) > 5 and sys.argv[5] == "nobounce"))
