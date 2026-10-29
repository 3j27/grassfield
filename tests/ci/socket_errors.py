#!/usr/bin/env python3
"""A Quickshell Socket's error handler must not act from inside the signal.

  python3 -I tests/ci/socket_errors.py            check every QML file of the tree (shell/, ui/, apps/), exit 1 on any miss
  python3 -I tests/ci/socket_errors.py --selftest the scanner on fixed samples

Quickshell 0.3.2's Socket::onSocketError emits `error`, then deletes its QLocalSocket when it is not connected. A handler
that closes the socket from inside the signal (`connected = false`, directly or through a function that does) makes
Quickshell delete it in setConnected's disconnect path first, then call deleteLater on the null pointer: SIGSEGV. Every
request socket the shell opens to Hyprland met it at each start, and the shell restarted in a loop after the system
update to 0.3.2 (owner's session, 2026-10-29). A handler must therefore only schedule its work: its body is a
`Qt.callLater(...)` call, or a block whose statements are const reads followed by one `Qt.callLater(...)`.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("shell", "ui", "apps")
# `<id>.error.connect(<handler>)` (in QML and JS files; any object, a deliberate over-approximation: no error signal of the
# tree needs to act synchronously) and an `onError:` handler inside a `Socket {` object, qualified (`Io.Socket {`) or not.
# Not seen: a `function onError` in a `Connections` that targets a socket.
CONNECT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\.error\.connect\(")
SOCKET = re.compile(r"(?<![A-Za-z0-9_.])(?:[A-Za-z_][A-Za-z0-9_]*\.)*Socket\s*\{")
# A read the deferred work may need: `const name = a.b.c` (no call, so no side effect before the deferral).
CONST_READ = re.compile(r"^const\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$")
ON_ERROR = re.compile(r"^\s*onError\s*:", re.M)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def balanced(text, start, opener, closer):
    """The index just after the closer that matches the opener at text[start]."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == opener:
            depth += 1
        elif text[i] == closer:
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def deferred(handler):
    """True when the handler's body only schedules its work with Qt.callLater."""
    body = handler.strip()
    arrow = re.match(r"^(?:\([^)]*\)|[A-Za-z_][A-Za-z0-9_]*)\s*=>\s*", body)
    if arrow:
        body = body[arrow.end():].strip()
    elif re.match(r"^function\b", body):
        body = body[body.find("{"):].strip()
    if body.startswith("{") and body.endswith("}"):
        statements = [s.strip() for s in body[1:-1].split(";") if s.strip()]
        reads = [s for s in statements if CONST_READ.match(s)]
        rest = [s for s in statements if s not in reads]
        return len(rest) == 1 and rest[0].startswith("Qt.callLater(")
    return body.startswith("Qt.callLater(") or bool(re.match(r"^Qt\.callLater\b", body))


def misses(source):
    """Returns the handlers (as text) that act from inside the error signal."""
    text = strip_comments(source)
    out = []
    for m in CONNECT.finditer(text):
        open_at = m.end() - 1
        end = balanced(text, open_at, "(", ")")
        handler = text[open_at + 1:end - 1]
        if not deferred(handler):
            out.append(text[m.start():end].strip())
    for s in SOCKET.finditer(text):
        open_at = s.end() - 1
        block = text[open_at:balanced(text, open_at, "{", "}")]
        for e in ON_ERROR.finditer(block):
            line = block[e.end():].split("\n", 1)[0].strip()
            if line.startswith("{"):
                start = block.index("{", e.end())
                line = block[start:balanced(block, start, "{", "}")]
            if not deferred(line):
                out.append("onError: " + line)
    return out


def tracked_qml(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "--", *[f"{r}/**.qml" for r in ROOTS], *[f"{r}/**.js" for r in ROOTS]],
                         check=True, capture_output=True, text=True).stdout
    return [root / line for line in out.splitlines() if line]


def check(root):
    bad = []
    for path in tracked_qml(root):
        for handler in misses(path.read_text(encoding="utf-8")):
            bad.append(f"{path.relative_to(root)}: {handler}")
    return bad


def selftest():
    cases = [
        ("sock.error.connect(() => sock.finish());", 1),
        ("sock.error.connect(() => Qt.callLater(sock.finish));", 0),
        ("sock.error.connect(() => root.socketClosed(sock.serial, \"socket error\"))", 1),
        ("sock.error.connect(() => {\n const serial = sock.serial;\n Qt.callLater(() => root.socketClosed(serial, \"x\"));\n})", 0),
        ("sock.error.connect(() => {\n const serial = sock.serial;\n root.fail(serial);\n})", 1),
        ("sock.error.connect(function() { sock.connected = false; })", 1),
        ("sock.error.connect(function() { Qt.callLater(sock.finish); })", 0),
        ("Socket {\n id: s\n onError: s.connected = false\n}", 1),
        ("Socket {\n id: s\n onError: Qt.callLater(s.finish)\n}", 0),
        ("Socket {\n id: s\n onError: {\n s.connected = false;\n }\n}", 1),
        ("Socket {\n id: s\n onError: {\n Qt.callLater(s.finish);\n }\n}", 0),
        ("Io.Socket {\n id: s\n onError: s.connected = false\n}", 1),
        ("WebSocket {\n onError: s.close()\n}", 0),
        ("sock.error.connect(() => {\n const serial = take(sock);\n Qt.callLater(() => root.closed(serial));\n})", 1),
        # A non-Socket onError (PamContext, a Process) is not this rule's business.
        ("PamContext {\n onError: controller.pamError()\n}", 0),
        ("// sock.error.connect(() => sock.finish());", 0),
    ]
    failed = 0
    for source, want in cases:
        got = len(misses(source))
        ok = got == want
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {source.splitlines()[0][:70]!r} -> {got} (want {want})")
    return failed


def main():
    if "--selftest" in sys.argv:
        sys.exit(1 if selftest() else 0)
    root = Path(__file__).resolve().parents[2]
    bad = check(root)
    for line in bad:
        print(f"socket_errors: {line}: the error handler acts inside the signal; schedule it with Qt.callLater")
    print(f"socket_errors: {'FAIL' if bad else 'ok'} ({len(bad)} handler(s) act inside the signal)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
