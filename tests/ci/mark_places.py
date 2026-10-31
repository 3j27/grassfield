#!/usr/bin/env python3
"""The Grassfield mark appears only in the places the owner decided (ADR-0040 IQ-B1 B, « Peu d'endroits, vert »; step 1d).

  python3 -I tests/ci/mark_places.py             scan shell/, ui/Grassfield/ and apps/ (QML and JS), exit 1 on a mark outside
                                                 its places, a place without it, or a notice that names no symbol
  python3 -I tests/ci/mark_places.py --selftest  the scanner on fixed samples

The places (the optical version, grassfield-logo; the full mark has none today): the menu bar's system button (monochrome,
the bar's text colour), About This Computer and Settings > General > About (the brand green), Software Update's
Grassfield release row (the brand green, as About's) and the Search result for About. Shell dialogs show their subject's
symbol instead: every Popups.notice(title, message, symbol) names one (a third argument), and neither NoticeDialog nor
ConfirmDialog falls back to the mark. Comments are not read.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUBDIRS = ("shell", "ui/Grassfield", "apps")
PLACES = {
    "shell/menubar/MenuBar.qml": "the menu bar's system button (monochrome)",
    "shell/search/SettingsPages.js": "the Search result for About",
    "apps/settings/qml/AboutWindow.qml": "About This Computer's product line (the brand green)",
    "apps/settings/qml/AboutPage.qml": "Settings > General > About's Grassfield row (the brand green)",
    "apps/settings/qml/SoftwareUpdatePage.qml": "Software Update's Grassfield release row (the brand green)",
}
MARK = re.compile(r"""["']grassfield-logo(?:-full)?["']""")
NOTICE = re.compile(r"\bPopups\.notice\s*\(")


def strip_comments(src):
    """The source without // and /* */ comments (string literals kept, so "a // b" inside a string survives)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def call_args(code, start):
    """The number of top-level arguments of the call whose "(" is at `start`."""
    depth, args, i, seen = 0, 0, start, False
    while i < len(code):
        c = code[i]
        if c in "\"'`":
            j = i + 1
            while j < len(code) and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            i = j + 1
            seen = True
            continue
        if c in "([{":
            depth += 1
            if depth > 1:
                seen = True
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return args + (1 if seen else 0)
        elif c == "," and depth == 1:
            args += 1
        elif not c.isspace() and depth >= 1:
            seen = True
        i += 1
    return args


def scan(rel, src):
    """(marks, notices without a symbol) of one file."""
    code = strip_comments(src)
    marks = len(MARK.findall(code))
    bare = [m.start() for m in NOTICE.finditer(code) if call_args(code, m.end() - 1) < 3]
    return marks, bare


def problems(files):
    out = []
    found = {}
    for rel, src in files.items():
        marks, bare = scan(rel, src)
        if marks:
            found[rel] = marks
        if marks and rel not in PLACES:
            out.append("%s: draws the mark, which is not one of its places (ADR-0040 IQ-B1 B)" % rel)
        for _ in bare:
            out.append("%s: a Popups.notice names no subject symbol (its third argument)" % rel)
    for rel, what in PLACES.items():
        if rel in files and rel not in found:
            out.append("%s: %s no longer draws the mark (update PLACES and ADR-0040)" % (rel, what))
    return out


def tree():
    files = {}
    for sub in SUBDIRS:
        for path in sorted((ROOT / sub).rglob("*")):
            if path.suffix in (".qml", ".js") and path.is_file():
                files[str(path.relative_to(ROOT))] = path.read_text(encoding="utf-8")
    return files


SAMPLES = {
    "a dialog with the mark": ({"shell/overlay/NoticeDialog.qml": 'Dialog {\n    icon: "grassfield-logo"\n}\n'}, 1),
    "the full mark anywhere": ({"shell/overlay/Other.qml": "Icon { name: 'grassfield-logo-full' }\n"}, 1),
    "a notice without a symbol": ({"shell/services/Power.qml": 'Item { function f() { Popups.notice(qsTr("A"), qsTr("b, c")); } }\n'}, 1),
    "a notice with a symbol": ({"shell/services/Power.qml": 'Item { function f() { Popups.notice(qsTr("A"), qsTr("b").arg(x(1, 2)), "power"); } }\n'}, 0),
    "a mark in a comment": ({"shell/overlay/X.qml": '// icon: "grassfield-logo"\n/* "grassfield-logo" */\nItem {}\n'}, 0),
    "a place keeps it": ({"shell/menubar/MenuBar.qml": 'Icon { name: "grassfield-logo" }\n'}, 0),
    "a place that lost it": ({"shell/menubar/MenuBar.qml": 'Icon { name: "apple" }\n'}, 1),
}


def selftest():
    bad = []
    for name, (files, want) in SAMPLES.items():
        got = len(problems(files))
        if got != want:
            bad.append("%s: %d problem(s), want %d" % (name, got, want))
    for line in bad:
        print("mark_places selftest: FAIL " + line)
    print("mark_places selftest: %s" % ("PASS" if not bad else "FAIL"))
    return 1 if bad else 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    files = tree()
    out = problems(files)
    for line in out:
        print("mark_places: " + line)
    used = sum(1 for rel in files if scan(rel, files[rel])[0])
    print("mark_places: %s (%d places, %d files draw the mark)" % ("ok" if not out else "FAILED", len(PLACES), used))
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
