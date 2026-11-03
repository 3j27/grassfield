#!/usr/bin/env python3
"""Measures the plugin titlebar of one window on a GF-REF capture (tests/compositor/chrome.sh). No third-party modules.

Usage: chrome_measure.py <capture.ppm> <surface x> <surface y> <surface w> <bar height> <close x> <minimize x> <zoom x>
       <bar middle> [fill=<rrggbb>] [radius=<px>] [bar=<rrggbb>] [inactive=<rrggbb>] [rule=<rrggbb>]
Positions in output pixels (scale 1): the surface box from `hyprctl clients`, the titlebar geometry from
tests/compositor/titlebar_geometry.sh (button centres right of the surface's left edge, bar middle above its top edge).
The corners are found where the fill colour starts: the titlebar's colour by default; without the plugin (bar height 0)
the window's own content colour (fill=). radius= is the window's rounding, for the junction check. bar= and inactive=:
the palette of the appearance measured (ui/tokens/tokens.json "titlebar"; the dark values below by default). rule=: the
colour of the hairline the plugin draws in the bar's last row (titlebar.rule* over the bar, ADR-0039 step 21); without it
the bar is measured to the surface.
Prints key=value lines:
  <light>_cx <light>_cy   centre of the light (close, minimize, zoom), coverage-weighted, output px (pixel edges)
  <light>_d               diameter from the light's covered area
  <light>_ref             the colour the light is measured against: "colour" (its own) or "grey" (an inactive light: at
                          least 100 inactive-grey pixels around its centre; a light-grey light on a light bar barely
                          projects onto its own colour, so its centre and diameter come from the grey)
  <light>_glyph           dark pixels inside the light (its glyph)
  <light>_grey            pixels of the inactive grey (titlebarPalette(appearance).inactiveLight) around the light's centre
  <light>_grey_core       the same inside a 5 px radius only: a coloured light's anti-aliased ring over a light bar can
                          pass for the grey (the green edge on a light bar), its core cannot
  junction_left/_right    (with radius=) pixels of the content's top corner squares that the rounding cuts away (outside
                          the corner curve) and that differ from the content next to them: the curve between bar and
                          content; 0 when the bar and the content join square
  rule_rows               (with rule=) rows of the rule's colour right above the surface, 40 px left of its right edge
  rule_colour             the colour of the row right above the surface there (rrggbb)
  bar_rows                rows of bar colour above them (right above the surface without rule=)
  bar_bottom_gap          pixels of the bar's last row (30 px from either end) that are not its colour: the rule's with
                          rule=, the bar's without
  bar_left_gap            pixels of the bar's first column (below the corner, above the rule) that are not bar colour
  corner_diag             first pixel of bar colour on the diagonal from the bar's top-left corner (-1: none)
  corner_diag_right       the same from the top-right corner
  radius_estimate         corner radius estimated from corner_diag (rounding_power 2.6; about +-2)
  background_ok           1 when the background next to the corner differs from the bar colour (corner measurable)
"""
import sys

BAR = (40, 40, 44)  # ui/tokens/tokens.json titlebar.backgroundDark (titlebarPalette(Dark).background)
LIGHTS = {
    "close": (0xE8, 0x3A, 0x52),
    "minimize": (0xE6, 0xC6, 0x19),
    "zoom": (0x2D, 0xC4, 0x7A),
}
INACTIVE = (0x5A, 0x5A, 0x5E)  # ui/tokens/tokens.json titlebar.inactiveButtonDark (titlebarPalette(Dark).inactiveLight)
RULE = None  # the hairline under the bar (option rule=; titlebar.rule* composited over the bar)
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
    """How much of the light covers this pixel: projection of the colour between the bar and the light (or the grey)."""
    d = [l - b for l, b in zip(light, BAR)]
    n = sum(v * v for v in d)
    t = sum((p - b) * v for p, b, v in zip(c, BAR, d)) / n
    return min(1.0, max(0.0, t))


def luminance(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def measure_light(img, name, cx, cy):
    light = LIGHTS[name]
    grey = sum(1 for y in range(int(cy) - 7, int(cy) + 7) for x in range(int(cx) - 7, int(cx) + 7)
               if close_to(img.at(x, y), INACTIVE, 12))
    grey_core = sum(1 for y in range(int(cy) - 6, int(cy) + 6) for x in range(int(cx) - 6, int(cx) + 6)
                    if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= 25 and close_to(img.at(x, y), INACTIVE, 12))
    # A coloured light is measured against its colour (as always); a grey (inactive) one against the grey.
    ref_name, ref = ("grey", INACTIVE) if grey >= 100 else ("colour", light)
    area = sx = sy = 0.0
    for y in range(int(cy) - 11, int(cy) + 11):
        for x in range(int(cx) - 11, int(cx) + 11):
            c = img.at(x, y)
            if c is None:
                continue
            a = coverage(c, ref)
            if a < 0.05:
                continue
            area += a
            sx += a * (x + 0.5)
            sy += a * (y + 0.5)
    if area <= 0:
        return {f"{name}_cx": -1, f"{name}_cy": -1, f"{name}_d": 0, f"{name}_ref": ref_name, f"{name}_glyph": 0,
                f"{name}_grey": grey, f"{name}_grey_core": grey_core}
    mx, my = sx / area, sy / area
    d = 2 * (area / 3.141592653589793) ** 0.5
    glyph = 0
    r = d / 2 - 1.5
    for y in range(int(my) - 8, int(my) + 9):
        for x in range(int(mx) - 8, int(mx) + 9):
            c = img.at(x, y)
            if c is None or (x + 0.5 - mx) ** 2 + (y + 0.5 - my) ** 2 > r * r:
                continue
            # Darker than the light but not the inactive grey (a grey light is darker than the yellow and green ones).
            if luminance(c) < 0.75 * luminance(light) and coverage(c, light) > 0.2 and not close_to(c, INACTIVE, 12):
                glyph += 1
    return {f"{name}_cx": round(mx, 2), f"{name}_cy": round(my, 2), f"{name}_d": round(d, 2), f"{name}_ref": ref_name,
            f"{name}_glyph": glyph, f"{name}_grey": grey, f"{name}_grey_core": grey_core}


def junction(img, x0, y0, step_x, radius, reference):
    """Pixels of the radius x radius square at a top corner of the content (corner pixel at x0, y0; step_x +1 for the
    left corner, -1 for the right one) that lie outside the window's corner curve and differ from `reference`."""
    count = 0
    limit = radius ** ROUNDING_POWER
    for j in range(radius):
        for i in range(radius):
            dx, dy = radius - (i + 0.5), radius - (j + 0.5)
            if dx ** ROUNDING_POWER + dy ** ROUNDING_POWER <= limit:
                continue  # inside the curve: the surface itself is drawn there
            c = img.at(x0 + step_x * i, y0 + j)
            if c is not None and not close_to(c, reference, 6):
                count += 1
    return count


def first_fill_on_diagonal(img, x0, y0, step_x, fill, limit=40):
    """First k where the pixel k steps along the diagonal (and the next one) has the fill colour; -1 if none."""
    for k in range(limit):
        a = img.at(x0 + step_x * k, y0 + k)
        b = img.at(x0 + step_x * (k + 1), y0 + k + 1)
        if close_to(a, fill, 10) and close_to(b, fill, 10):
            return k
    return -1


def main():
    if len(sys.argv) < 10:
        raise SystemExit(__doc__)
    img = Image(sys.argv[1])
    sx, sy, sw, bar_h, close_x, min_x, zoom_x, mid = (int(v) for v in sys.argv[2:10])
    global BAR, INACTIVE, RULE  # the palette of the appearance measured (options bar=, inactive= and rule=, from the tokens)
    fill, radius = None, 0
    for option in sys.argv[10:]:
        key, _, value = option.partition("=")
        if key in ("fill", "bar", "inactive", "rule"):
            colour = (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))
            if key == "fill":
                fill = colour
            elif key == "bar":
                BAR = colour
            elif key == "rule":
                RULE = colour
            else:
                INACTIVE = colour
        elif key == "radius":
            radius = int(value)
        else:
            raise SystemExit(__doc__)
    if fill is None:
        fill = BAR
    out = {}
    for name, ox in (("close", close_x), ("minimize", min_x), ("zoom", zoom_x)):
        out.update(measure_light(img, name, sx + ox, sy - mid))

    col = sx + sw - 40
    last = img.at(col, sy - 1)
    out["rule_colour"] = "%02x%02x%02x" % last if last else "none"
    # The hairline in the bar's last row (ADR-0039 step 21), then the bar's own colour above it.
    rule_rows = 0
    if RULE is not None:
        while rule_rows < 8 and close_to(img.at(col, sy - 1 - rule_rows), RULE, 8):
            rule_rows += 1
        out["rule_rows"] = rule_rows
    # The bar is flat, its token colour exactly; the window border right above it (black 0.58 in the dark appearance since
    # ADR-0024's note of 2026-11-03) came within 8 levels of the dark bar over a mauve wallpaper and was counted as a 32nd row.
    rows = 0
    while rows < 200 and close_to(img.at(col, sy - 1 - rule_rows - rows), BAR, 2):
        rows += 1
    out["bar_rows"] = rows

    top = sy - bar_h
    bottom = RULE if RULE is not None else BAR
    out["bar_bottom_gap"] = sum(1 for x in range(sx + 30, sx + sw - 30) if not close_to(img.at(x, sy - 1), bottom, 8))
    out["bar_left_gap"] = sum(1 for y in range(top + 30, sy - rule_rows) if not close_to(img.at(sx, y), BAR, 8))

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

    if radius > 0 and bar_h > 0:
        # The content next to each corner square, on the content's first row just past the square.
        left_ref = img.at(sx + radius + 4, sy + 1)
        right_ref = img.at(sx + sw - 1 - radius - 4, sy + 1)
        out["junction_left"] = junction(img, sx, sy, 1, radius, left_ref) if left_ref else -1
        out["junction_right"] = junction(img, sx + sw - 1, sy, -1, radius, right_ref) if right_ref else -1

    for key, value in out.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
