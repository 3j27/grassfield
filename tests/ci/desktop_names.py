#!/usr/bin/env python3
"""Every Grassfield desktop entry speaks French: in each tracked .desktop file, the [Desktop Entry] group has Name[fr], and
GenericName[fr], Comment[fr] and Keywords[fr] wherever it has GenericName, Comment or Keywords, none of them empty (the
integrator's request of 2026-10-28, on PR #10: the owner's French session showed "Files" and "Grassfield Settings").

  python3 -I tests/ci/desktop_names.py            scan the tracked .desktop files, exit 1 on any missing French value
  python3 -I tests/ci/desktop_names.py --selftest the check on fixed samples

Whether a French name may be used at all (no banned name) is tests/ci/ui_names.py's. A [Desktop Action] group is not
required to be localized: the shell shows only the entry's own name.
"""
import subprocess
import sys
from pathlib import Path

LOCALIZED = ("Name", "GenericName", "Comment", "Keywords")


def missing(text):
    """The keys of [Desktop Entry] that lack a non-empty French value: [] when the entry speaks French."""
    group = None
    plain, french = set(), {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line
            continue
        if group != "[Desktop Entry]" or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key in LOCALIZED:
            plain.add(key)
        elif key.endswith("[fr]") and key[:-4] in LOCALIZED:
            french[key[:-4]] = value
    need = [k for k in LOCALIZED if k == "Name" or k in plain]
    return [k for k in need if not french.get(k)]


def repo_root():
    return Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())


def run(root, files):
    if not files:
        print("desktop_names: 0 .desktop files found: the check found nothing to look at (wrong directory?)")
        return 1
    bad = 0
    for rel in files:
        lacks = missing((root / rel).read_text(encoding="utf-8", errors="replace"))
        if lacks:
            print(f"{rel}: no French value for {', '.join(k + '[fr]' for k in lacks)}")
            bad += 1
    if bad:
        print(f"desktop_names: {bad} desktop entr{'y' if bad == 1 else 'ies'} without French values")
        return 1
    print(f"desktop_names: {len(files)} desktop entries, each with its French values")
    return 0


def selftest():
    cases = [
        ("[Desktop Entry]\nName=Files\nName[fr]=Fichiers\n", []),
        ("[Desktop Entry]\nName=Files\n", ["Name"]),
        ("[Desktop Entry]\nName=Files\nName[fr]=\n", ["Name"]),
        ("[Desktop Entry]\nName=Files\nName[fr]=Fichiers\nComment=Browse\n", ["Comment"]),
        ("[Desktop Entry]\nName=Files\nName[fr]=Fichiers\nGenericName=File Manager\nGenericName[fr]=Gestionnaire\n"
         "Keywords=a;\nKeywords[fr]=b;\nComment=c\nComment[fr]=d\n", []),
        ("[Desktop Entry]\r\nName = Files\r\nName[fr] = Fichiers\r\n", []),
        ("[Desktop Entry]\nName=Files\n[Desktop Action x]\nName[fr]=Fichiers\n", ["Name"]),
        ("[Desktop Entry]\nName=Files\nName[fr_CA]=Fichiers\n", ["Name"]),
        ("# Name[fr]=Fichiers\n[Desktop Entry]\nName=Files\n", ["Name"]),
        ("[Desktop Entry]\nName=Files\nName[fr]=Fichiers\n[Desktop Action x]\nName=New Window\n", []),
    ]
    bad = [(text, want, missing(text)) for text, want in cases if missing(text) != want]
    for text, want, got in bad:
        print(f"selftest FAIL: want {want}, got {got}: {text!r}")
    if run(Path("."), []) != 1:
        print("selftest FAIL: a scan of 0 files must exit 1")
        bad.append(("zero files", [], []))
    if not bad:
        print(f"desktop_names selftest: {len(cases)} cases ok")
    return 1 if bad else 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    root = repo_root()
    files = [f for f in subprocess.check_output(["git", "-C", str(root), "ls-files", "*.desktop"], text=True).splitlines()]
    return run(root, files)


sys.exit(main())
