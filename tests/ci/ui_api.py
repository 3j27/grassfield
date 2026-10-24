#!/usr/bin/env python3
"""The public Grassfield.Ui QML API never changes without a changelog line.

  python3 -I tests/ci/ui_api.py [ROOT]    check ui/Grassfield/Ui/qmldir against docs/specs/ui-api.md, exit 1 on drift
  python3 -I tests/ci/ui_api.py --selftest  the comparison on small in-memory fixtures

docs/specs/ui-api.md holds an append-only block "ui-api" of `add <Name> [singleton]` and `remove <Name> [-> <New>]`
lines. add minus remove must equal the types the qmldir lists (with their singleton flag). A type added, renamed or
removed in the qmldir without its line, a remove of a never-added name, a re-added removed name and a replacement
that is not public all fail.
"""
import re
import sys
from pathlib import Path

QMLDIR = "ui/Grassfield/Ui/qmldir"
DOC = "docs/specs/ui-api.md"
LISTED = re.compile(r"^\s*(singleton\s+)?([A-Z][A-Za-z0-9_]*)\s+\d+(?:\.\d+)?\s+\S+\s*$")


def qmldir_types(text):
    """{name: singleton?} of the types a qmldir lists."""
    out = {}
    for line in text.splitlines():
        m = LISTED.match(line)
        if m:
            out[m.group(2)] = bool(m.group(1))
    return out


def changelog(doc_text):
    """(public {name: singleton?}, removed {name}, problems) from the ui-api block, replayed in order."""
    block = re.search(r"```ui-api\n(.*?)```", doc_text, re.S)
    if not block:
        return {}, set(), ["no ```ui-api block in " + DOC]
    public, removed, problems = {}, set(), []
    for raw in block.group(1).splitlines():
        line = raw.strip()
        if not line:
            continue
        add = re.fullmatch(r"add ([A-Z][A-Za-z0-9_]*)( singleton)?", line)
        rem = re.fullmatch(r"remove ([A-Z][A-Za-z0-9_]*)(?: -> ([A-Z][A-Za-z0-9_]*))?", line)
        if add:
            name = add.group(1)
            if name in public:
                problems.append("added twice: " + name)
            elif name in removed:
                problems.append("re-added after removal (pick a new name or write the history): " + name)
            public[name] = bool(add.group(2))
        elif rem:
            name, repl = rem.group(1), rem.group(2)
            if name not in public:
                problems.append("remove of a type that is not public: " + name)
                continue
            del public[name]
            removed.add(name)
            if repl is not None and repl not in public:
                problems.append("remove %s -> %s: the replacement is not public (add it first)" % (name, repl))
        else:
            problems.append("unreadable line in the ui-api block: " + line)
    return public, removed, problems


def compare(qmldir_text, doc_text):
    actual = qmldir_types(qmldir_text)
    public, _, errs = changelog(doc_text)
    for name in sorted(set(actual) - set(public)):
        errs.append("%s is in the qmldir but has no `add %s` line in %s" % (name, name, DOC))
    for name in sorted(set(public) - set(actual)):
        errs.append("%s is gone from the qmldir but has no `remove %s` line in %s" % (name, name, DOC))
    for name in sorted(set(actual) & set(public)):
        if actual[name] != public[name]:
            errs.append("%s: singleton flag differs (qmldir %s, changelog %s)" % (name, actual[name], public[name]))
    return errs


QMLDIR_FIX = "module Grassfield.Ui\nsingleton Tokens 1.0 Tokens.qml\nButton 1.0 Button.qml\nJsonSafety 1.0 JsonSafety.js\n"
DOC_FIX = "```ui-api\nadd Tokens singleton\nadd Button\nadd JsonSafety\n```\n"


def selftest():
    failures = []

    def expect(name, errs, needle):
        if needle is None and errs:
            failures.append("%s: unexpected %s" % (name, errs))
        elif needle is not None and not any(needle in e for e in errs):
            failures.append("%s: expected %r in %s" % (name, needle, errs))

    expect("clean", compare(QMLDIR_FIX, DOC_FIX), None)
    expect("added without a line", compare(QMLDIR_FIX + "Slider 1.0 Slider.qml\n", DOC_FIX), "Slider is in the qmldir")
    renamed = QMLDIR_FIX.replace("Button 1.0 Button.qml", "PushButton 1.0 PushButton.qml")
    errs = compare(renamed, DOC_FIX)
    expect("rename: new name", errs, "PushButton is in the qmldir")
    expect("rename: old name", errs, "Button is gone from the qmldir")
    expect("removed without a line", compare(QMLDIR_FIX.replace("Button 1.0 Button.qml\n", ""), DOC_FIX), "Button is gone")
    expect("rename recorded", compare(renamed, DOC_FIX + "```ui-api\n```\n"), "PushButton is in the qmldir")
    recorded = DOC_FIX.replace("add JsonSafety\n", "add JsonSafety\nadd PushButton\nremove Button -> PushButton\n")
    expect("rename with its lines", compare(renamed, recorded), None)
    expect("bad replacement", compare(renamed, DOC_FIX.replace("add JsonSafety\n", "add JsonSafety\nremove Button -> Nope\n")), "replacement is not public")
    expect("remove of unknown", compare(QMLDIR_FIX, DOC_FIX.replace("add Button\n", "add Button\nremove Ghost\n")), "not public: Ghost")
    expect("singleton flag", compare(QMLDIR_FIX.replace("singleton Tokens", "Tokens"), DOC_FIX), "singleton flag differs")
    expect("no block", compare(QMLDIR_FIX, "nothing"), "no ```ui-api block")
    if failures:
        print("selftest FAILED:")
        print("\n".join("  " + f for f in failures))
        return 1
    print("ui_api selftest: ok")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    if not (root / DOC).exists():
        print("Grassfield.Ui API drift: %s is missing" % DOC)
        return 1
    errs = compare((root / QMLDIR).read_text(), (root / DOC).read_text())
    if errs:
        print("Grassfield.Ui API drift (%d):" % len(errs))
        print("\n".join("  " + e for e in errs))
        return 1
    print("Grassfield.Ui API: %d public types, all in %s" % (len(qmldir_types((root / QMLDIR).read_text())), DOC))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
