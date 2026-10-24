#!/usr/bin/env python3
"""The token source lint (ui/tools/gen-tokens.py provenance_errors) on samples, and on the real tokens.json (audit GF-095).

  python3 -I tests/ci/token_sources.py

A source must point at something that exists: a cited docs/ or tests/ path, an ADR number, and every `§ section` of the F1
analysis must be made of real headings of docs/testing/f1-reference-gaps.md. A bare "estimate" is not a source.
"""
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gen_tokens", ROOT / "ui" / "tools" / "gen-tokens.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

HEADINGS = gen.f1_headings()


def problems(source):
    return gen.source_problems(source, HEADINGS)


def selftest():
    assert problems("estimate [ref: docs/testing/f1-reference-gaps.md § Menu bar; docs/specs/menubar.md]") == []
    assert problems("x (docs/testing/f1-reference-gaps.md § Window chrome, Dock and Menus and popovers)") == []
    assert problems("see docs/testing/f1-reference-gaps.md § Search (macOS Spotlight); docs/specs/search.md") == []
    assert problems("ADR-0016 section 5: video") == []
    assert problems("tests/visual/test_contrast_tokens.py: A2") == []
    assert problems("estimate"), "a bare estimate is not a source"
    assert problems(""), "an empty source is not a source"
    assert problems("[ref: docs/testing/f1-reference-gaps.md § Motion and easing; docs/specs/ui.md]"), "a section that is not a heading"
    assert problems("[ref: docs/testing/f1-reference-gaps.md § Menu bar and Nonsense]"), "a part that is not a heading"
    assert problems("docs/specs/does-not-exist.md: x"), "a missing file"
    assert problems("ADR-9999 says"), "a missing ADR"
    print("PASS: token_sources selftest")


def real():
    data = json.loads((ROOT / "ui" / "tokens" / "tokens.json").read_text())
    errors = gen.provenance_errors(data)
    for e in errors:
        print("FAIL:", e)
    if not errors:
        print("PASS: every token source is a followable pointer")
    return 1 if errors else 0


if __name__ == "__main__":
    selftest()
    sys.exit(real())
