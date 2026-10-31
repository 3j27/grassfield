#!/usr/bin/env python3
"""The Grassfield mark appears only in the places the owner decided (ADR-0040 IQ-B1 B, « Peu d'endroits, vert »; step 1d).

  python3 -I tests/ci/mark_places.py             scan shell/, ui/Grassfield/ and apps/ (QML and JS), exit 1 on a mark outside
                                                 its places, a place without it, or a notice that names no symbol
  python3 -I tests/ci/mark_places.py --selftest  the scanner on fixed samples

The places (the optical version, grassfield-logo; the full mark has none today): the menu bar's system button (monochrome,
the bar's text colour), About This Computer and Settings > General > About (the brand green), Software Update's
Grassfield release row (the brand green, as About's) and the Search result for About. Shell dialogs show their subject's
symbol instead: every Popups.notice(title, message, symbol) names one (a third argument, not undefined, null or empty;
a literal one is a file of ui/Grassfield/Ui/icons), and neither NoticeDialog nor ConfirmDialog falls back to the mark. The
mark is found in any string literal that names it, a file path included ("…/grassfield-logo.svg",
Qt.resolvedUrl("icons/grassfield-logo-full.svg")); a notice through Popups.notice or Popups["notice"]. Comments are not
read; an alias of Popups (const p = Popups; p.notice(…)) is not followed.
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
ICONS = ROOT / "ui" / "Grassfield" / "Ui" / "icons"
STRING = re.compile(r""""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`""")
NOTICE = re.compile(r"""\bPopups\s*(?:\.\s*notice|\[\s*["']notice["']\s*\])\s*\(""")
NO_SYMBOL = {"undefined", "null", '""', "''", "``"}


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
    """The top-level arguments (their source text, stripped) of the call whose "(" is at `start`; a trailing comma adds none."""
    depth, args, cur, i = 0, [], [], start
    while i < len(code):
        c = code[i]
        if c in "\"'`" and depth >= 1:
            j = i + 1
            while j < len(code) and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            cur.append(code[i:j + 1])
            i = j + 1
            continue
        if c in "([{":
            depth += 1
            if depth > 1:
                cur.append(c)
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                last = "".join(cur).strip()
                return args + ([last] if last else [])
            cur.append(c)
        elif c == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        elif depth >= 1:
            cur.append(c)
        i += 1
    return args


def symbol_problem(args):
    """Why a notice's arguments name no usable symbol, or None."""
    if len(args) < 3 or args[2] in NO_SYMBOL:
        return "names no subject symbol (its third argument)"
    lit = re.fullmatch(r"""["'](.*)["']""", args[2])
    if lit and not (ICONS / (lit.group(1) + ".svg")).is_file():
        return "names the symbol \"%s\", which ui/Grassfield/Ui/icons does not hold" % lit.group(1)
    if lit and "grassfield-logo" in lit.group(1):
        return "names the mark as its symbol"
    return None


def scan(rel, src):
    """(marks, the problems of its notices) of one file."""
    code = strip_comments(src)
    marks = sum(1 for m in STRING.finditer(code) if "grassfield-logo" in m.group(0))
    bad = [p for p in (symbol_problem(call_args(code, m.end() - 1)) for m in NOTICE.finditer(code)) if p]
    return marks, bad


def problems(files):
    out = []
    found = {}
    for rel, src in files.items():
        marks, bare = scan(rel, src)
        if marks:
            found[rel] = marks
        if marks and rel not in PLACES:
            out.append("%s: draws the mark, which is not one of its places (ADR-0040 IQ-B1 B)" % rel)
        for why in bare:
            out.append("%s: a Popups.notice %s" % (rel, why))
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
    "the mark as a file path": ({"shell/overlay/A.qml": 'Image { source: "../../ui/Grassfield/Ui/icons/grassfield-logo.svg" }\n'}, 1),
    "the full mark through resolvedUrl": ({"apps/x/B.qml": 'Image { source: Qt.resolvedUrl("icons/grassfield-logo-full.svg") }\n'}, 1),
    "a notice through brackets": ({"shell/services/C.qml": 'Item { function f() { Popups["notice"]("A", "b"); } }\n'}, 1),
    "a trailing comma": ({"shell/services/D.qml": 'Item { function f() { Popups.notice("A", "b",); } }\n'}, 1),
    "an explicit undefined": ({"shell/services/E.qml": 'Item { function f() { Popups.notice("A", "b", undefined); } }\n'}, 1),
    "a symbol without a file": ({"shell/services/F.qml": 'Item { function f() { Popups.notice("A", "b", "moonn"); } }\n'}, 1),
    "the mark as the symbol": ({"shell/services/G.qml": 'Item { function f() { Popups.notice("A", "b", "grassfield-logo"); } }\n'}, 2),
    "a computed symbol": ({"shell/services/H.qml": 'Item { function f() { Popups.notice("A", "b", root.glyph); } }\n'}, 0),
    "another object's notice": ({"shell/shell.qml": 'Item { function f() { ExtensionStatus.notice(status); } }\n'}, 0),
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
