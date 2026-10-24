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
    assert problems("estimate: pressed"), "an estimate with no reason is not a source"
    assert problems("estimate: a pressed light darkens by this much") == [], "a declared estimate with its reason is accepted"
    assert problems(""), "an empty source is not a source"
    assert problems("[ref: docs/testing/f1-reference-gaps.md § Motion and easing; docs/specs/ui.md]"), "a section that is not a heading"
    assert problems("[ref: docs/testing/f1-reference-gaps.md § Menu bar and Nonsense]"), "a part that is not a heading"
    assert problems("docs/specs/does-not-exist.md: x"), "a missing file"
    assert problems("ADR-9999 says"), "a missing ADR"
    # Every pointer kind: a good one passes, a renamed one fails.
    assert problems("x [ref: docs/specs/ui.md \u00a7 Material blur follows transparency]") == []
    assert problems("x [ref: docs/specs/ui.md \u00a7 Material blurred]"), "a renamed spec section"
    assert problems("x [ref: docs/specs/ui.md \u00a7 Material blur]"), "a prefix of a heading is not the section"
    assert problems("x [ref: docs/specs/ui.md \u00a7 M]"), "one letter is not a section"
    assert problems("x [ref: docs/testing/f1-reference-gaps.md \u00a7 M]"), "one letter is not an F1 section"
    assert problems("estimate (see f1-reference-gaps)"), "a bare mention of the F1 file is not a pointer"
    assert problems("see master-prompt 99.9"), "a master prompt mention without a section is not a pointer"
    assert problems("estimate:pressed light darkens by this much"), "the declared form needs 'estimate: ' exactly"
    assert problems("Estimate: a pressed light darkens by this much"), "and lower case"
    assert problems("x [ref: docs/specs/ui.md \u00a7 Material shadow]"), "a section that is not in the spec"
    assert problems("x (master-prompt \u00a7 5.5)") == []
    assert problems("x (master-prompt \u00a7 5.55)"), "a master prompt section that does not exist"
    assert problems("ADR-0016 section 5: video") == []
    assert problems("ADR-0016 section 55: video"), "an ADR section that does not exist"
    assert problems("x [ref: docs/testing/f1-reference-gaps.md \u00a7 Menu bar]") == []
    assert problems("x [ref: docs/testing/f1-reference-gaps.md \u00a7 Menu barr]"), "a renamed F1 section"
    assert problems("tests/visual/test_contrast_tokens.py: A2") == []
    assert problems("tests/visual/test_contrast_token.py: A2"), "a renamed test path"
    print("PASS: token_sources selftest")


def real():
    data = json.loads((ROOT / "ui" / "tokens" / "tokens.json").read_text())
    errors = gen.provenance_errors(data)
    for e in errors:
        print("FAIL:", e)
    # Mutation: renaming one real pointer of each kind makes the lint fail on the real file.
    text = (ROOT / "ui" / "tokens" / "tokens.json").read_text()
    for needle, renamed in (("docs/specs/ui.md \u00a7 Material blur follows transparency", "docs/specs/ui.md \u00a7 Material blur follows"),
                            ("master-prompt \u00a7 5.5", "master-prompt \u00a7 5.99"),
                            ("ADR-0016 section 5", "ADR-0016 section 99"),
                            ("f1-reference-gaps.md \u00a7 Menu bar", "f1-reference-gaps.md \u00a7 Menu barX"),
                            ("docs/specs/dock.md", "docs/specs/dockX.md")):
        if needle not in text:
            print("FAIL: mutation needle not in tokens.json:", needle)
            return 1
        if not gen.provenance_errors(json.loads(text.replace(needle, renamed, 1))):
            print("FAIL: renaming '%s' went unnoticed" % needle)
            return 1
    if not errors:
        print("PASS: every token source is a followable pointer (and a renamed pointer of each kind fails)")
    return 1 if errors else 0


if __name__ == "__main__":
    selftest()
    sys.exit(real())
