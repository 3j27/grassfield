#!/usr/bin/env python3
"""Measures the plugin titlebar of one window on a GF-REF capture (tests/compositor/chrome.sh). No third-party modules.

Usage: chrome_measure.py <capture.ppm> <surface x> <surface y> <surface w> <bar height> <close x> <minimize x> <zoom x>
       <bar middle> [<corner fill: rrggbb>]
Positions in output pixels (scale 1): the surface box from `hyprctl clients`, the titlebar geometry from
tests/compositor/titlebar_geometry.sh (button centres right of the surface's left edge, bar middle above its top edge).
The corners are found where the fill colour starts: the titlebar's colour by default; without the plugin (bar height 0)
the window's own content colour, given as the last argument.
Prints key=value lines:
  <light>_cx <light>_cy   centre of the light (close, minimize, zoom), coverage-weighted, output px (pixel edges)
  <light>_d               diameter from the light's covered area
  <light>_glyph           dark pixels inside the light (its glyph)
  bar_rows                rows of bar colour right above the surface, 40 px left of its right edge
  bar_bottom_gap          pixels of the bar's last row (30 px from either end) that are not bar colour
  bar_left_gap            pixels of the bar's first column (below the corner) that are not bar colour
  corner_diag             first pixel of bar colour on the diagonal from the bar's top-left corner (-1: none)
  corner_diag_right       the same from the top-right corner
  radius_estimate         corner radius estimated from corner_diag (rounding_power 2.6; about +-2)
  background_ok           1 when the background next to the corner differs from the bar colour (corner measurable)
"""
import sys

BAR = (40, 40, 44)  # compositor/src/core/Theme.hpp titlebarPalette(Dark).background
LIGHTS = {
    "close": (0xE5, 0x53, 0x4B),
    "minimize": (0xD9, 0xA9, 0x3B),
    "zoom": (0x4F, 0xA6, 0x4F),
}
ROUNDING_POWER = 2.6  # config/hypr/grassfield/looknfeel.lua decoration.rounding_power


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, i = [], 0
    while len(fields) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    if fields[0] != b"P6" or int(fields[3]) != 255:
        raise SystemExit(f"chrome_measure: {path}: not an 8-bit binary PPM")
    return int(fields[1]), int(fields[2]), data[i + 1:]


class Image:
    def __init__(self, path):
        self.w, self.h, self.px = read_ppm(path)

    def at(self, x, y):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return None
        o = (y * self.w + x) * 3
        return self.px[o], self.px[o + 1], self.px[o + 2]


def close_to(c, ref, tol):
    return c is not None and max(abs(a - b) for a, b in zip(c, ref)) <= tol


def coverage(c, light):
    """How much of the light covers this pixel: projection of the colour between the bar and the light."""
    d = [l - b for l, b in zip(light, BAR)]
    n = sum(v * v for v in d)
    t = sum((p - b) * v for p, b, v in zip(c, BAR, d)) / n
    return min(1.0, max(0.0, t))


def luminance(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def measure_light(img, name, cx, cy):
    light = LIGHTS[name]
    area = sx = sy = 0.0
    for y in range(int(cy) - 11, int(cy) + 11):
        for x in range(int(cx) - 11, int(cx) + 11):
            c = img.at(x, y)
            if c is None:
                continue
            a = coverage(c, light)
            if a < 0.05:
                continue
            area += a
            sx += a * (x + 0.5)
            sy += a * (y + 0.5)
    if area <= 0:
        return {f"{name}_cx": -1, f"{name}_cy": -1, f"{name}_d": 0, f"{name}_glyph": 0}
    mx, my = sx / area, sy / area
    d = 2 * (area / 3.141592653589793) ** 0.5
    glyph = 0
    r = d / 2 - 1.5
    for y in range(int(my) - 8, int(my) + 9):
        for x in range(int(mx) - 8, int(mx) + 9):
            c = img.at(x, y)
            if c is None or (x + 0.5 - mx) ** 2 + (y + 0.5 - my) ** 2 > r * r:
                continue
            if luminance(c) < 0.75 * luminance(light) and coverage(c, light) > 0.2:
                glyph += 1
    return {f"{name}_cx": round(mx, 2), f"{name}_cy": round(my, 2), f"{name}_d": round(d, 2), f"{name}_glyph": glyph}


def first_fill_on_diagonal(img, x0, y0, step_x, fill, limit=40):
    """First k where the pixel k steps along the diagonal (and the next one) has the fill colour; -1 if none."""
    for k in range(limit):
        a = img.at(x0 + step_x * k, y0 + k)
        b = img.at(x0 + step_x * (k + 1), y0 + k + 1)
        if close_to(a, fill, 10) and close_to(b, fill, 10):
            return k
    return -1


def main():
    if len(sys.argv) not in (10, 11):
        raise SystemExit(__doc__)
    img = Image(sys.argv[1])
    sx, sy, sw, bar_h, close_x, min_x, zoom_x, mid = (int(v) for v in sys.argv[2:10])
    fill = BAR
    if len(sys.argv) == 11:
        hexa = sys.argv[10]
        fill = (int(hexa[0:2], 16), int(hexa[2:4], 16), int(hexa[4:6], 16))
    out = {}
    for name, ox in (("close", close_x), ("minimize", min_x), ("zoom", zoom_x)):
        out.update(measure_light(img, name, sx + ox, sy - mid))

    col = sx + sw - 40
    rows = 0
    while rows < 200 and close_to(img.at(col, sy - 1 - rows), BAR, 8):
        rows += 1
    out["bar_rows"] = rows

    top = sy - bar_h
    out["bar_bottom_gap"] = sum(1 for x in range(sx + 30, sx + sw - 30) if not close_to(img.at(x, sy - 1), BAR, 8))
    out["bar_left_gap"] = sum(1 for y in range(top + 30, sy) if not close_to(img.at(sx, y), BAR, 8))

    k = first_fill_on_diagonal(img, sx, top, 1, fill)
    out["corner_diag"] = k
    out["corner_diag_right"] = first_fill_on_diagonal(img, sx + sw - 1, top, -1, fill)
    # The 45-degree point of a superellipse corner of radius r lies r * (1 - 2^(-1/p)) from both edges (2.8 px for r 12,
    # 6.1 px for r 26). The first two pixels of pure fill colour start about 1.5 px further in: the anti-aliased inner
    # edge of the window border (1 px, drawn along the same curve) tints the pixels on the curve. Measured on GF-REF
    # (Hyprland 0.56.2, rounding_power 2.6): inset 4 for radius 12, 6 for radius 20, 8 for radius 26.
    inset = 1 - 2 ** (-1 / ROUNDING_POWER)
    out["radius_estimate"] = round((k - 1.5) / inset, 1) if k >= 0 else -1
    bg = img.at(sx - 8, top - 8)
    out["background_ok"] = int(bg is not None and not close_to(bg, fill, 30))

    for key, value in out.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
