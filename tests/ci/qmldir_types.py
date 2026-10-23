#!/usr/bin/env python3
"""A QML file must not use a sibling type its module's qmldir does not list.

  python3 -I tests/ci/qmldir_types.py            check every module of the tree (shell/, ui/, apps/), exit 1 on any miss
  python3 -I tests/ci/qmldir_types.py --selftest the scanner on fixed samples

In a directory with a qmldir, the implicit import of a file's own directory offers only the types that qmldir lists: a
sibling file that is not listed is "not a type" at load time, and the whole shell fails to load (main 46ee452: StackPile).
qmllint and the offscreen tests did not see it, because no test loads shell.qml. A use is an object declaration
`Name {` (line start, optional `id`-less property prefix such as `delegate: Name {`) whose Name is a sibling `Name.qml`.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("shell", "ui", "apps")
# `Name {` at the start of a line, or after `property: ` (delegate: Name {, contentItem: Name {).
USE = re.compile(r"^\s*(?:[a-z][A-Za-z0-9_.]*\s*:\s*)?([A-Z][A-Za-z0-9_]*)\s*\{", re.M)
LISTED = re.compile(r"^\s*(?:singleton\s+)?([A-Z][A-Za-z0-9_]*)\s+\d+(?:\.\d+)?\s+\S+\.qml\s*$", re.M)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def misses(qmldir_text, files):
    """files: {basename without .qml: source}. Returns sorted (file, type) pairs used but not listed."""
    listed = set(LISTED.findall(qmldir_text))
    siblings = set(files)
    out = set()
    for name, source in files.items():
        for used in USE.findall(strip_comments(source)):
            if used in siblings and used not in listed and used != name:
                out.add((name + ".qml", used))
    return sorted(out)


def tracked_qmldirs(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "--", *[f"{r}/**/qmldir" for r in ROOTS], *[f"{r}/qmldir" for r in ROOTS]],
                         check=True, capture_output=True, text=True).stdout
    return [root / line for line in out.splitlines() if line]


def check(root):
    bad = []
    for qmldir in tracked_qmldirs(root):
        folder = qmldir.parent
        files = {p.stem: p.read_text(encoding="utf-8") for p in folder.glob("*.qml")}
        for file, used in misses(qmldir.read_text(encoding="utf-8"), files):
            bad.append(f"{folder.relative_to(root)}/{file} uses {used}, which {qmldir.relative_to(root)} does not list")
    return bad


def selftest():
    qmldir = "module qs.dock\nDock 1.0 Dock.qml\nStackIcon 1.0 StackIcon.qml\nsingleton Model 1.0 Model.qml\n"
    files = {
        "Dock": "Item {\n  StackIcon { }\n  // StackPile { } in a comment\n  StackPile {\n  }\n  delegate: Model {}\n  Text { }\n}",
        "StackIcon": "Item {}",
        "StackPile": "Item {}",
        "Model": "QtObject {}",
    }
    got = misses(qmldir, files)
    want = [("Dock.qml", "StackPile")]
    if got != want:
        print(f"qmldir-types selftest: FAIL (got {got}, want {want})")
        return 1
    if misses(qmldir + "StackPile 1.0 StackPile.qml\n", files):
        print("qmldir-types selftest: FAIL (a listed type is reported)")
        return 1
    print("qmldir-types selftest: ok")
    return 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip())
    bad = check(root)
    for line in bad:
        print("qmldir-types: " + line)
    if bad:
        return 1
    print("qmldir-types: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
