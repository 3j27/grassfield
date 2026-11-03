#!/usr/bin/env python3
"""Window edge and shadow measurements for tests/compositor/window_edge.sh (ADR-0024 C-3 and C-4, note 2026-11-03).

  edge_measure.py profile <capture.ppm> <scale> <x> <y> <w> <h> <background #rrggbb>
      x y w h: the window's logical box on the output. Prints one JSON object: per side (left, right, top, bottom) the
      device pixels along the side's middle line from 8 inside the window's edge to 160 outside it ("rgb"), the first
      pixel outside the edge ("edge", rounded from the logical box) and the darkening of each outside pixel against the
      flat background ("alpha": 1 - pixel / background, the mean of the three channels).
  edge_measure.py background <capture.ppm> <x> <y> <#rrggbb>
      Exit 0 when the device pixel x, y is that colour within 3 levels per channel (the wallpaper's crossfade is done).
  edge_measure.py report <out.txt> <out.svg> <range> <power> <alpha> <offset> <profile.json>...
      Compares each profile with Hyprland 0.56.2's shadow model at the given values (shadow.glsl: alpha * (1 - d / range)
      ^ power outside the window box moved down by the offset, alpha inside it) and with the macOS 27 target below. Writes
      key=value lines (out.txt) and a plot (out.svg).

The macOS 27 target: the darkening outside the active window, measured on the 512 Pixels Golden Gate release captures
(Settings General, Finder Home, Force Quit: window crops with the shadow in their alpha channel, 2 px per pt), the mean of
the three, which agree within 0.005. Distances in pt from the window's edge to the device pixel's centre; the first entry is
the contact edge (one device pixel, 0.5 pt: about black 0.2 over the shadow on every side). Apple's pixels are not in the
repository, only these numbers (docs/audits/ui-finesse-2026-10-25/tools/webref-urls.txt).
"""
import json
import sys

MAC27_D = [0.25, 0.75, 1.25, 2.25, 3.25, 4.25, 6.25, 8.25, 10.25, 12.25, 16.25, 20.25, 24.25, 28.25, 32.25, 40.25, 48.25, 56.25]
MAC27 = {
    "side": [0.374, 0.213, 0.19, 0.182, 0.174, 0.167, 0.151, 0.137, 0.122, 0.108, 0.083, 0.062, 0.044, 0.031, 0.02, 0.009,
             0.003, 0.0],
    "top": [0.277, 0.093, 0.066, 0.062, 0.058, 0.051, 0.045, 0.038, 0.03, 0.025, 0.018, 0.009, 0.007, 0.003, 0.002, 0.0, 0.0,
            0.0],
    "bottom": [0.474, 0.339, 0.32, 0.313, 0.308, 0.302, 0.288, 0.275, 0.258, 0.244, 0.213, 0.183, 0.152, 0.123, 0.094, 0.052,
               0.025, 0.011],
}
INSIDE, OUTSIDE = 8, 160


def mac27(side, d):
    """The macOS 27 darkening at d pt (linear between the measured distances; 0 beyond them)."""
    xs, ys = MAC27_D, MAC27["side" if side in ("left", "right", "side") else side]
    if d <= xs[0]:
        return ys[0]
    for i in range(1, len(xs)):
        if d <= xs[i]:
            t = (d - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + t * (ys[i] - ys[i - 1])
    return 0.0


def model(side, d, rng, power, alpha, offset):
    """Hyprland's shadow darkening at d pt outside the window's edge (the straight part of a side)."""
    if side == "bottom":
        d -= offset
    elif side == "top":
        d += offset
    if d <= 0:
        return alpha
    if d >= rng:
        return 0.0
    return alpha * (1 - d / rng) ** power


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    if fields[0] != b"P6" or int(fields[3]) != 255:
        raise SystemExit("edge_measure: not an 8-bit P6 PPM: " + path)
    return int(fields[1]), int(fields[2]), data[pos:]


def profile(args):
    path, scale = args[0], float(args[1])
    x, y, w, h = (float(v) for v in args[2:6])
    bg = tuple(int(args[6].lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    width, height, px = read_ppm(path)

    def rgb(ix, iy):
        if not (0 <= ix < width and 0 <= iy < height):
            return None
        i = (iy * width + ix) * 3
        return list(px[i:i + 3])

    left, top = round(x * scale), round(y * scale)
    right, bottom = round((x + w) * scale), round((y + h) * scale)  # first device pixel past the box
    mx, my = (left + right) // 2, (top + bottom) // 2
    sides = {  # (first outside pixel, step) along the middle line
        "left": ((left - 1, my), (-1, 0)), "right": ((right, my), (1, 0)),
        "top": ((mx, top - 1), (0, -1)), "bottom": ((mx, bottom), (0, 1)),
    }
    out = {"scale": scale, "box": [x, y, w, h], "background": "#%02X%02X%02X" % bg, "sides": {}}
    for name, ((ex, ey), (dx, dy)) in sides.items():
        pixels = [rgb(ex + dx * k, ey + dy * k) for k in range(-INSIDE, OUTSIDE)]
        alpha = []
        for p in pixels[INSIDE:]:
            alpha.append(None if p is None else round(sum(1 - p[c] / bg[c] for c in range(3)) / 3, 4))
        out["sides"][name] = {"rgb": pixels, "edge": INSIDE, "alpha": alpha}
    json.dump(out, sys.stdout)
    print()


def background(args):
    width, height, px = read_ppm(args[0])
    x, y = int(args[1]), int(args[2])
    want = tuple(int(args[3].lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    if not (0 <= x < width and 0 <= y < height):
        raise SystemExit("edge_measure: %d,%d is outside the %dx%d capture" % (x, y, width, height))
    i = (y * width + x) * 3
    got = tuple(px[i:i + 3])
    if any(abs(g - w) > 3 for g, w in zip(got, want)):
        print("background at %d,%d: #%02X%02X%02X, not #%02X%02X%02X" % ((x, y) + got + want), file=sys.stderr)
        raise SystemExit(1)


def report(args):
    out_txt, out_svg = args[0], args[1]
    rng, power, alpha, offset = (float(v) for v in args[2:6])
    lines, curves = [], []
    for path in args[6:]:
        with open(path) as f:
            prof = json.load(f)
        tag = path.rsplit("/", 1)[-1].removesuffix(".json")
        scale = prof["scale"]
        for side in ("left", "right", "top", "bottom"):
            a = prof["sides"][side]["alpha"]
            pts = [((k + 0.5) / scale, v) for k, v in enumerate(a) if v is not None]
            # past the contact pixel: the shadow alone (ours: from the second device pixel, 0.8 pt at 1.25)
            shadow = [(d, v) for d, v in pts[1:] if d <= 60]
            dm = max(abs(v - model(side, d, rng, power, alpha, offset)) for d, v in shadow)
            dmac = max(abs(v - mac27(side, d)) for d, v in shadow)
            near = [abs(v - mac27(side, d)) for d, v in shadow if d <= 16]
            lines.append(f"{tag}.{side}.contact={pts[0][1]:.3f}")
            lines.append(f"{tag}.{side}.model_max_dev={dm:.3f}")
            lines.append(f"{tag}.{side}.mac27_max_dev={dmac:.3f}")
            lines.append(f"{tag}.{side}.mac27_max_dev_16pt={max(near):.3f}")
            for want in (1, 2, 4, 8, 10, 12, 16, 20, 24, 32, 40, 48):
                d, v = min(shadow, key=lambda t: abs(t[0] - want))
                lines.append(f"{tag}.{side}.at{want}pt={v:.3f} model={model(side, d, rng, power, alpha, offset):.3f} "
                             f"mac27={mac27(side, d):.3f}")
            curves.append((tag + " " + side, side, pts))
    with open(out_txt, "w") as f:
        f.write("\n".join(lines) + "\n")
    write_svg(out_svg, curves, (rng, power, alpha, offset))


def write_svg(path, curves, params):
    """One panel per side: measured curves, the model at the given values and the macOS 27 target."""
    W, H, M = 420, 300, 40
    panels = [("side", ("left", "right")), ("top", ("top",)), ("bottom", ("bottom",))]
    colours = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"]
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{3 * W}" height="{H + 120}" font-family="sans-serif" '
           f'font-size="11"><rect width="100%" height="100%" fill="white"/>']

    def xy(px0, d, a):
        return px0 + M + d / 60 * (W - 2 * M), M + (1 - a / 0.5) * (H - 2 * M)

    legend = []
    for i, (title, sides) in enumerate(panels):
        x0 = i * W
        svg.append(f'<text x="{x0 + M}" y="20" font-weight="bold">{title} (darkening vs pt from the edge)</text>')
        svg.append(f'<rect x="{x0 + M}" y="{M}" width="{W - 2 * M}" height="{H - 2 * M}" fill="none" stroke="#999"/>')
        for t in (0.1, 0.2, 0.3, 0.4):
            _, gy = xy(x0, 0, t)
            svg.append(f'<line x1="{x0 + M}" x2="{x0 + W - M}" y1="{gy}" y2="{gy}" stroke="#eee"/>'
                       f'<text x="{x0 + 6}" y="{gy + 4}">{t}</text>')
        for d in (0, 8, 16, 24, 32, 40, 48, 56):
            gx, _ = xy(x0, d, 0)
            svg.append(f'<text x="{gx - 6}" y="{H - M + 14}">{d}</text>')
        mac = " ".join("%.1f,%.1f" % xy(x0, d / 4, mac27(title, d / 4)) for d in range(0, 241))
        svg.append(f'<polyline points="{mac}" fill="none" stroke="black" stroke-width="2.5"/>')
        mod = " ".join("%.1f,%.1f" % xy(x0, d / 4, model(title if title != "side" else "left", d / 4, *params))
                       for d in range(1, 241))
        svg.append(f'<polyline points="{mod}" fill="none" stroke="#888" stroke-width="1.5" stroke-dasharray="5,3"/>')
        n = 0
        for label, side, pts in curves:
            if side not in sides:
                continue
            c = colours[n % len(colours)]
            n += 1
            poly = " ".join("%.1f,%.1f" % xy(x0, d, max(0.0, min(0.5, v))) for d, v in pts if d <= 60)
            svg.append(f'<polyline points="{poly}" fill="none" stroke="{c}" stroke-width="1.2"/>')
            if i == 0 or side != "left":
                legend.append((label, c))
    y = H + 10
    svg.append(f'<text x="{M}" y="{y}">black: macOS 27 target; grey dashed: Hyprland model at range {params[0]:g}, power '
               f'{params[1]:g}, alpha {params[2]:g}, offset {params[3]:g}</text>')
    for j, (label, c) in enumerate(legend[:24]):
        lx, ly = M + (j % 4) * 290, y + 16 + (j // 4) * 14
        svg.append(f'<rect x="{lx}" y="{ly - 9}" width="10" height="10" fill="{c}"/><text x="{lx + 14}" y="{ly}">{label}</text>')
    svg.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(svg))


if __name__ == "__main__":
    if len(sys.argv) >= 9 and sys.argv[1] == "profile":
        profile(sys.argv[2:])
    elif len(sys.argv) == 6 and sys.argv[1] == "background":
        background(sys.argv[2:])
    elif len(sys.argv) >= 9 and sys.argv[1] == "report":
        report(sys.argv[2:])
    else:
        raise SystemExit(__doc__)
