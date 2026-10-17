#!/usr/bin/env python3
"""Guard against rich-text injection: every QML `Text {` block in shell/ and ui/ must set `textFormat`.

Untrusted strings (app ids, titles, desktop entries, SSIDs, notification fields) rendered as rich text can
spoof UI or fetch remote resources. `Text.StyledText`/`Text.RichText` are allowed only in ALLOW.
Usage: check-textformat.py   (exit 1 on violations)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
# file → reason; only the sanitized notification body may use StyledText.
ALLOW = {"shell/notifications/NotificationContent.qml": "sanitized body (Sanitizer.js) rendered as StyledText"}
OPEN = re.compile(r"(^|[^\w.])Text\s*\{")


def blocks(src):
    """Yield (line, body) for each `Text {` block, matching braces."""
    for m in OPEN.finditer(src):
        start = m.end()
        depth, i = 1, start
        while i < len(src) and depth:
            depth += {"{": 1, "}": -1}.get(src[i], 0)
            i += 1
        body = src[start:i - 1]
        # Only the block's own properties: drop nested child objects.
        own, d = [], 0
        for ch in body:
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
            elif d == 0:
                own.append(ch)
        yield src.count("\n", 0, m.start()) + 1, "".join(own)


def main():
    bad = []
    for path in sorted(list(ROOT.glob("shell/**/*.qml")) + list(ROOT.glob("ui/**/*.qml"))):
        rel = str(path.relative_to(ROOT))
        for line, own in blocks(path.read_text()):
            fmt = re.search(r"textFormat\s*:\s*([\w.]+)", own)
            if not fmt:
                bad.append(f"{rel}:{line}: Text without textFormat")
            elif fmt.group(1) != "Text.PlainText" and rel not in ALLOW:
                bad.append(f"{rel}:{line}: {fmt.group(1)} outside the allowlist")
    for b in bad:
        print(b, file=sys.stderr)
    print(f"check-textformat: {'FAIL' if bad else 'ok'} ({len(bad)} issue(s))")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
