#!/usr/bin/env python3
"""Every symbolic glyph uses the one stroke width of ADR-0003 (audit GF-124).

  python3 -I tests/ci/icon_strokes.py            check branding/icons/symbolic/*.svg, exit 1 on any other width
  python3 -I tests/ci/icon_strokes.py --selftest the scanner on fixed samples

ADR-0003 (amended 2026-10-23): 1.75 on the 24 grid, round caps and joins. A glyph that is filled (no stroke) is exempt:
the logo is a filled shape. Only the root element's attributes and explicit per-element stroke-width are read.

ADR-0003 (amended 2026-10-25, menu bar status glyphs only): ui/Grassfield/Ui/icons-bar/ holds the heavier set of the menu bar's
status items, stroke 2.4. Each is the same drawing as its branding/icons/symbolic twin with only the stroke width changed, and
every glyph of the set must have a twin.
"""
import re
import sys
from pathlib import Path

WIDTH = 1.75
BAR_WIDTH = 2.4
ROOT = Path(__file__).resolve().parents[2] / "branding" / "icons" / "symbolic"
BAR = Path(__file__).resolve().parents[2] / "ui" / "Grassfield" / "Ui" / "icons-bar"


def problems(name, text, width=WIDTH):
    out = []
    widths = [float(w) for w in re.findall(r'stroke-width="([0-9.]+)"', text)]
    if "stroke=" not in text and not widths:
        return out  # a filled shape
    if not widths:
        out.append(f"{name}: stroked without a stroke-width")
    out += [f"{name}: stroke-width {w} (ADR-0003: {width})" for w in widths if abs(w - width) > 1e-9]
    if 'viewBox="0 0 24 24"' not in text:
        out.append(f"{name}: not on the 24 grid")
    if 'stroke-linecap="round"' not in text:
        out.append(f"{name}: caps are not round")
    return out


def bar_problems(name, twin, text):
    """The menu bar set: stroke BAR_WIDTH, and the twin's drawing with only the stroke width changed."""
    if text is None:
        return [f"{name}: no twin in branding/icons/symbolic"]
    out = problems(name, text, BAR_WIDTH)
    if text != twin.replace(f'stroke-width="{WIDTH}"', f'stroke-width="{BAR_WIDTH}"'):
        out.append(f"{name}: not its symbolic twin with the stroke width changed")
    return out


def selftest():
    ok = '<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.75" stroke-linecap="round"><path d="M0 0"/></svg>'
    assert problems("ok", ok) == []
    assert problems("heavy", ok.replace("1.75", "2.25"))
    assert problems("filled", '<svg viewBox="0 0 24 24"><path fill="#000" d="M0 0"/></svg>') == []
    assert problems("nowidth", '<svg viewBox="0 0 24 24" stroke="#000" stroke-linecap="round"/>')
    assert problems("square", ok.replace("round", "butt"))
    assert problems("bar-ok", ok.replace("1.75", "2.4"), BAR_WIDTH) == []
    assert problems("bar-wrong", ok, BAR_WIDTH)
    assert bar_problems("x.svg", ok, ok.replace("1.75", "2.4")) == []
    assert bar_problems("x.svg", ok, ok.replace("1.75", "2.4").replace("M0 0", "M1 1"))
    assert bar_problems("x.svg", ok, None)
    print("PASS: icon_strokes selftest")
    return 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    files = sorted(ROOT.glob("*.svg"))
    if not files:
        print(f"FAIL: no glyphs under {ROOT}")
        return 1
    found = [p for f in files for p in problems(f.name, f.read_text())]
    bars = sorted(BAR.glob("*.svg"))
    if not bars:
        print(f"FAIL: no glyphs under {BAR}")
        return 1
    for f in bars:
        twin = ROOT / f.name
        found += bar_problems("icons-bar/" + f.name, twin.read_text() if twin.exists() else "", f.read_text()) if twin.exists() else [f"icons-bar/{f.name}: no twin in branding/icons/symbolic"]
    for p in found:
        print("FAIL:", p)
    if not found:
        print(f"PASS: {len(files)} glyphs, stroke {WIDTH} on the 24 grid; {len(bars)} menu bar glyphs, stroke {BAR_WIDTH}, twins of the first set")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
