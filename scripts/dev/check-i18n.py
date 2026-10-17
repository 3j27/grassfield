#!/usr/bin/env python3
"""Gate I1: every visible string goes through qsTr(); the en + fr catalogs are complete.

(a) lupdate dry run: translations/grassfield_fr.ts is up to date (no new/obsolete messages),
(b) no unfinished message in the French catalog,
(c) heuristic scan of QML for visible-text properties assigned a bare string literal.

A deliberate exception (brand name, protocol token, data key) carries `// i18n-ignore` on the line.
Usage: python3 -I scripts/dev/check-i18n.py [--no-lupdate]
"""
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

    violations = scan_qml()
    for v in violations:
        print(f"i18n: {v}")
    if violations:
        failed = True

    print(f"i18n: {len(messages)} messages, {unfinished} unfinished, {len(violations)} bare literals")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
