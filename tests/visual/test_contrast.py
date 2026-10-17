#!/usr/bin/env python3
"""Unit tests for tests/visual/contrast.py (pixel reading and the glyph-mask measurement) on synthetic images.

  python3 -I tests/visual/test_contrast.py          (also run by scripts/dev/test.sh; needs ImageMagick)
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("contrast", os.path.join(HERE, "contrast.py"))
contrast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contrast)

IW, IH = 200, 40


def solid(rgb, w=IW, h=IH):
    return [bytes(rgb) * w for _ in range(h)]


def with_rect(rows, box, rgb, w=IW):
    """Rows with the rectangle box [x, y, w, h] painted rgb."""
    x, y, bw, bh = box
    out = []
    for r in range(len(rows)):
        row = bytearray(rows[r])
        if y <= r < y + bh:
            for c in range(x, x + bw):
                row[c * 3:c * 3 + 3] = bytes(rgb)
        out.append(bytes(row))
    return out


def checker(w=IW, h=IH):
    """1 px black/white checker."""
    return [b"".join(bytes((255, 255, 255) if (x + y) % 2 == 0 else (0, 0, 0)) for x in range(w)) for y in range(h)]


def blend(bg, glyph, alpha):
    return tuple(round(alpha * g + (1 - alpha) * b) for b, g in zip(bg, glyph))


class ReadRgb(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def png(self, name, rows):
        p = os.path.join(self.tmp, name)
        contrast.write_png(p, rows, IW, IH)
        return p

    def test_box_has_exactly_w_times_h_pixels(self):
        # Regression: the txt parser counted every non-named pixel twice (an 80x13 box gave n=1514, not 1040).
        rows = with_rect(solid((10, 20, 30)), (50, 10, 80, 13), (200, 100, 50))
        w, h, buf = contrast.read_rgb(self.png("a.png", rows))
        self.assertEqual((w, h, len(buf)), (IW, IH, IW * IH * 3))
        px = contrast.crop(buf, w, h, (50, 10, 80, 13))
        self.assertEqual(len(px), 1040)
        self.assertEqual(set(px), {(200, 100, 50)})
        self.assertEqual(set(contrast.crop(buf, w, h, (0, 0, 20, 5))), {(10, 20, 30)})

    def test_box_outside_the_image_is_an_error(self):
        _, _, buf = contrast.read_rgb(self.png("b.png", solid((0, 0, 0))))
        with self.assertRaises(ValueError):
            contrast.crop(buf, IW, IH, (150, 0, 80, 13))


class Score(unittest.TestCase):
    BOX = (20, 10, 60, 13)
    SIZE = (60, 13)

    def region(self, rows):
        return contrast.crop(b"".join(rows), IW, IH, self.BOX)

    def render(self, backdrop, glyph_colour, alpha=1.0):
        """The four captures of a glyph rectangle (80% of the box) with coverage alpha over a backdrop (rows)."""
        x, y, w, h = self.BOX
        rect = (x + 5, y + 2, w - 10, h - 4)
        def paint(colour):
            rows = []
            for r, row in enumerate(backdrop):
                row = bytearray(row)
                if rect[1] <= r < rect[1] + rect[3]:
                    for c in range(rect[0], rect[0] + rect[2]):
                        bg = tuple(row[c * 3:c * 3 + 3])
                        row[c * 3:c * 3 + 3] = bytes(blend(bg, colour, alpha) if colour is not None else bg)
                rows.append(bytes(row))
            return rows
        return [self.region(paint(c)) for c in (glyph_colour, None, (255, 255, 254), (0, 0, 1))]

    def test_black_text_on_white_is_21(self):
        a, b, w, k = self.render(solid((255, 255, 255)), (0, 0, 0))
        n_glyph = len(contrast.glyph_ratios(a, b, w, k, *self.SIZE))
        self.assertEqual(n_glyph, 50 * 9)
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), 21.0, delta=0.1)

    def test_antialiased_pixels_give_the_true_glyph_colour(self):
        # 60 % covered black on white: the rendered pixel is gray 102, the glyph colour is still black (21:1).
        a, b, w, k = self.render(solid((255, 255, 255)), (0, 0, 0), alpha=0.6)
        self.assertEqual(set(a) - set(b), {(102, 102, 102)})
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), 21.0, delta=0.5)

    def test_low_coverage_pixels_are_not_glyph_pixels(self):
        a, b, w, k = self.render(solid((255, 255, 255)), (0, 0, 0), alpha=0.3)
        self.assertIsNone(contrast.score(a, b, w, k, *self.SIZE))

    def test_known_gray_text(self):
        # Gray 118 on white is the classic 4.5:1 pair.
        a, b, w, k = self.render(solid((255, 255, 255)), (118, 118, 118))
        expect = contrast.ratio(contrast.luminance((118, 118, 118)), 1.0)
        self.assertAlmostEqual(expect, 4.54, delta=0.02)
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), expect, delta=0.05)

    def test_white_text_on_white_is_invisible(self):
        a, b, w, k = self.render(solid((255, 255, 255)), (255, 255, 255))
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), 1.0, delta=0.01)

    def test_white_text_on_a_checker_is_low_contrast(self):
        # Half of the glyph pixels sit on white cells. A median/extremes method reads about 21 here; the local
        # backdrop of a 1 px checker is mid gray, so white text scores about 1.9 and black text about 11.
        a, b, w, k = self.render(checker(), (255, 255, 255))
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), 1.9, delta=0.15)
        a, b, w, k = self.render(checker(), (0, 0, 0))
        self.assertLess(contrast.score(a, b, w, k, *self.SIZE), 12.0)

    def test_coloured_backdrop(self):
        bg = (200, 255, 0)
        a, b, w, k = self.render(solid(bg), (0, 0, 0))
        expect = contrast.ratio(0.0, contrast.luminance(bg))
        self.assertAlmostEqual(contrast.score(a, b, w, k, *self.SIZE), expect, delta=0.1)

    def test_measure_surface_end_to_end(self):
        tmp = tempfile.mkdtemp()
        try:
            x, y, w, h = self.BOX
            for suffix, colour in (("", (0, 0, 0)), (".hidden", None), (".white", (255, 255, 254)), (".black", (0, 0, 1))):
                rows = solid((255, 255, 255))
                if colour is not None:
                    rows = with_rect(rows, (x + 5, y + 2, w - 10, h - 4), colour)
                contrast.write_png(os.path.join(tmp, "s" + suffix + ".png"), rows, IW, IH)
            res = contrast.measure_surface(tmp, "s", [{"name": "t", "box": list(self.BOX), "kind": "text"},
                                                      {"name": "empty", "box": [120, 20, 40, 10], "kind": "text"},
                                                      {"name": "img", "box": [0, 0, 10, 10], "kind": "icon", "image": True}])
            self.assertAlmostEqual(res["t"], 21.0, delta=0.1)
            self.assertIsNone(res["empty"])
            self.assertEqual(res["img"], "skip")
            self.assertIsNone(contrast.measure_surface(tmp, "missing", []))
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    if shutil.which("magick") is None:
        print("SKIP: ImageMagick missing")
        sys.exit(0)
    unittest.main(verbosity=1)
