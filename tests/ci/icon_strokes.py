#!/usr/bin/env python3
"""Every symbolic glyph uses the one stroke width of ADR-0003 (audit GF-124).

  python3 -I tests/ci/icon_strokes.py            check branding/icons/symbolic/*.svg, exit 1 on any other width
  python3 -I tests/ci/icon_strokes.py --selftest the scanner on fixed samples

ADR-0003 (amended 2026-10-26, owner decision: heavier everywhere): 2 on the 24 grid, round caps and joins. A glyph that is
filled (no stroke) is exempt: the logo is a filled shape; filled parts of a stroked glyph (the Wi-Fi bands, the speaker body)
carry no stroke-width of their own. Only the root element's attributes and explicit per-element stroke-width are read.
"""
import re
import sys
from pathlib import Path

WIDTH = 2.0
ROOT = Path(__file__).resolve().parents[2] / "branding" / "icons" / "symbolic"


def problems(name, text):
    out = []
    widths = [float(w) for w in re.findall(r'stroke-width="([0-9.]+)"', text)]
    if "stroke=" not in text and not widths:
        return out  # a filled shape
    if not widths:
        out.append(f"{name}: stroked without a stroke-width")
    out += [f"{name}: stroke-width {w} (ADR-0003: {WIDTH})" for w in widths if abs(w - WIDTH) > 1e-9]
    if 'viewBox="0 0 24 24"' not in text:
        out.append(f"{name}: not on the 24 grid")
    if 'stroke-linecap="round"' not in text:
        out.append(f"{name}: caps are not round")
    return out


def selftest():
    ok = '<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round"><path d="M0 0"/></svg>'
    assert problems("ok", ok) == []
    assert problems("heavy", ok.replace('stroke-width="2"', 'stroke-width="2.5"'))
    assert problems("light", ok.replace('stroke-width="2"', 'stroke-width="1.75"'))
    assert problems("filled", '<svg viewBox="0 0 24 24"><path fill="#000" d="M0 0"/></svg>') == []
    assert problems("nowidth", '<svg viewBox="0 0 24 24" stroke="#000" stroke-linecap="round"/>')
    assert problems("square", ok.replace("round", "butt"))
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
    for p in found:
        print("FAIL:", p)
    if not found:
        print(f"PASS: {len(files)} glyphs, stroke {WIDTH} on the 24 grid")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
