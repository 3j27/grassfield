#!/usr/bin/env python3
"""Gate I1: every visible string goes through qsTr(); the en + fr catalogs are complete.

(a) lupdate dry run: translations/grassfield_fr.ts is up to date (no new/obsolete messages),
(b) no unfinished message in the French catalog,
(c) heuristic scan of QML for visible-text properties assigned a bare string literal,
(e) the session helpers in packaging/bin (standard library only, so no Qt catalog): every helper that sends a notification has its
    own CATALOG["fr"] (Python) or `fr:` cases of tr (bash); every string passed to tr() has a French text that is not the source
    and keeps its % placeholders; no notify-send argument list holds a bare English literal,
(d) every .desktop entry of ours has a French Name, GenericName, Comment and Keywords where it has an English one.

A deliberate exception (brand name, protocol token, data key) carries `// i18n-ignore` on the line.
Usage: python3 -I scripts/dev/check-i18n.py [--no-lupdate]
"""
import ast
import importlib.machinery
import importlib.util
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
TS = ROOT / "translations" / "grassfield_fr.ts"

VISIBLE = (
    r"text|placeholderText|title|label|subtitle|caption|hint|tooltip|toolTip|headerText|windowTitle|"
    r"summary|body|description|displayName|"
    r"Accessible\.name|Accessible\.description|ToolTip\.text|"
    r"menuTitle|buttonText|actionText|emptyText|statusText"
)
# property: "literal"   (also inside inline JS objects: { label: "Foo" })
LITERAL = re.compile(r'(?<![\w.])(?:' + VISIBLE + r')\s*:\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*(?:[,;}]|$|//)')
HAS_WORD = re.compile(r"[^\W\d_]{2,}")  # at least two letters: skips symbols, numbers, "x", "%"


def scan_desktop_entries():
    """(d) every .desktop entry of ours carries a French name, generic name, comment and keywords where it has an English one
    (the shell's Apps, Search and menu bar read them). Exception: the session entry's Name, a brand name."""
    violations = []
    files = sorted(list((ROOT / "apps").glob("*/*.desktop")) + list((ROOT / "packaging" / "wayland-sessions").glob("*.desktop")))
    for path in files:
        rel = path.relative_to(ROOT)
        keys = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                keys[key.strip()] = value
        for key in ("Name", "GenericName", "Comment", "Keywords"):
            if key not in keys or f"{key}[fr]" in keys:
                continue
            if key == "Name" and "wayland-sessions" in str(rel):
                continue
            violations.append(f"{rel}: {key} has no {key}[fr]")
    return violations


def scan_qml():
    violations = []
    files = [p for d in ("shell", "ui", "apps") for p in (ROOT / d).rglob("*") if p.suffix in (".qml", ".js")]
    for path in sorted(files):
        rel = path.relative_to(ROOT)
        if ".qmlls" in path.name or "/icons/" in str(rel):
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "i18n-ignore" in line or line.lstrip().startswith("//"):
                continue
            for match in LITERAL.finditer(line):
                text = match.group(1)[1:-1]
                if HAS_WORD.search(text):
                    violations.append(f"{rel}:{number}: bare string {match.group(1)}")
    return violations


NOTIFY_OPTION_VALUES = {"Grassfield", "critical", "normal", "low", "--"}


def scan_helpers():
    """(e) the session helpers: see the module docstring."""
    violations = []
    for path in sorted((ROOT / "packaging" / "bin").iterdir()):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        if "notify-send" not in text and "Notifications.Notify" not in text:
            continue
        if text.startswith("#!/bin/bash") or text.startswith("#!/usr/bin/env bash"):
            calls = set(re.findall(r'\btr "([^"$]+)"', text))
            cases = {m.group(1) for m in re.finditer(r'^\s*fr:"([^"]+)"\)', text, re.M)}
            for source in sorted(calls - cases):
                violations.append(f"{rel}: tr {source!r} has no fr: case")
            for source in sorted(cases - calls):
                violations.append(f"{rel}: fr: case {source!r} is never used")
            for number, line in enumerate(text.splitlines(), 1):
                if "notify-send" in line and re.search(r'-- "[A-Z]', line):
                    violations.append(f"{rel}:{number}: notify-send with a bare English literal")
            continue
        loader = importlib.machinery.SourceFileLoader("helper_" + path.name.replace("-", "_"), str(path))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        sys.dont_write_bytecode = True
        loader.exec_module(module)
        fr = getattr(module, "CATALOG", {}).get("fr")
        if not fr:
            violations.append(f"{rel}: sends notifications and has no CATALOG['fr']")
            continue
        for source, french in fr.items():
            if not french.strip() or french == source:
                violations.append(f"{rel}: French text of {source!r} is empty or the source")
            elif source.count("%") != french.count("%"):
                violations.append(f"{rel}: French text of {source!r} changes the % placeholders")
        tree = ast.parse(text)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "tr" and node.args:
                arg = node.args[0]
                values = []
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    values = [arg.value]
                elif isinstance(arg, ast.Name) and isinstance(getattr(module, arg.id, None), str):
                    values = [getattr(module, arg.id)]
                elif isinstance(arg, ast.IfExp):
                    values = [n.value for n in (arg.body, arg.orelse) if isinstance(n, ast.Constant)]
                for value in values:
                    if value not in fr:
                        violations.append(f"{rel}:{node.lineno}: tr({value[:40]!r}...) has no French text")
            if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "notify-send":
                for element in node.elts[1:]:
                    if isinstance(element, ast.Constant) and isinstance(element.value, str) and HAS_WORD.search(element.value) \
                            and not element.value.startswith("-") and element.value not in NOTIFY_OPTION_VALUES:
                        violations.append(f"{rel}:{element.lineno}: notify-send argument {element.value!r} is a bare English literal")
    return violations


def main():
    failed = False
    if "--no-lupdate" not in sys.argv:
        diff = subprocess.run(
            [str(ROOT / "scripts/dev/i18n-update.sh"), "--check"], capture_output=True, text=True, cwd=ROOT
        )
        if diff.returncode != 0 or diff.stdout.strip():
            failed = True
            print("i18n: translations/grassfield_fr.ts is stale; run scripts/dev/i18n-update.sh")
            print("\n".join(diff.stdout.splitlines()[:40]), diff.stderr[:500])

    root = ET.parse(TS).getroot()
    messages = root.findall(".//message")
    unfinished = 0
    for message in messages:
        translation = message.find("translation")
        if translation is None or translation.get("type") == "unfinished" or message.find("numerus") is None and not (translation.text or "").strip():
            unfinished += 1
            print(f"i18n: unfinished: {message.findtext('source')!r}")
        elif message.get("numerus") == "yes" and not all((f.text or "").strip() for f in translation.findall("numerusform")):
            unfinished += 1
            print(f"i18n: unfinished plural: {message.findtext('source')!r}")
    if unfinished:
        failed = True

    violations = scan_qml() + scan_desktop_entries() + scan_helpers()
    for v in violations:
        print(f"i18n: {v}")
    if violations:
        failed = True

    print(f"i18n: {len(messages)} messages, {unfinished} unfinished, {len(violations)} bare literals")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
