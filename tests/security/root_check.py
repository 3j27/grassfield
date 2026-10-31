#!/usr/bin/env python3
"""The security root (shell/security.qml) holds nothing but ShellRoot and IpcHandler (ADR-0041 step 1, S1): read as the
QML engine reads it, not line by line (the integrator's review of eecf953, major 1: a next-line brace, a comment before the
brace, an indented or tab import and a singleton's property all slipped past a line-based grep).

  python3 -I tests/security/root_check.py <root.qml>            exit 0 "ok", or 1 with every rule the root breaks
  python3 -I tests/security/root_check.py --selftest <root.qml>  the root passes and each planted mutant is refused

Rules, on the file with comments (// and /* */) removed and string literals blanked:
  1. no `/` and no backtick outside comments and strings: no regex literal (whose `//` would read as a comment and hide
     what follows it) and no template string; so a `//` or `/*` outside a string is always a comment;
  2. every `import` stands at the start of a line (wherever indented) and names QtQuick, Quickshell or Quickshell.Io,
     nothing else (no qs.* module, no Grassfield.Ui, no file or directory, no dynamic import());
  3. every object instantiated (`Name {`, the file joined on whitespace) is ShellRoot or IpcHandler;
  4. none of these names: a loader (Loader, LazyLoader, Component but Component.onCompleted/onDestruction), a source:
     property, createComponent, createQmlObject, execDetached, Process, openUrlExternally, callLater, eval, Function,
     include, XMLHttpRequest, any `Qt.` or `qs.` name, a window or popup (…Window, Popup…), a socket, and the security
     modules' names (Lock, Idle, SleepInhibitor, AuthAgent, Pam…, Polkit…, Wl…).
Standard library only; no Qt needed."""
import re
import sys

ALLOWED_IMPORTS = {"QtQuick", "Quickshell", "Quickshell.Io"}
ALLOWED_TYPES = {"ShellRoot", "IpcHandler"}
DENIED = [r"\bLoader\b", r"\bLazyLoader\b", r"\bComponent\b(?!\.onCompleted\b|\.onDestruction\b)", r"\bsource\s*:",
          r"createComponent", r"createQmlObject", r"execDetached", r"\bProcess\b", r"openUrlExternally", r"callLater",
          r"\beval\b", r"\bFunction\b", r"\binclude\b", r"XMLHttpRequest", r"\bQt\.", r"\bqs\.", r"Window\b", r"Popup",
          r"Socket", r"\bLock\b", r"\bIdle\b", r"SleepInhibitor", r"AuthAgent", r"\bPam[A-Z]", r"Polkit", r"\bWl[A-Z]",
          r"\bimport\s*\("]


def strip(src):
    """The source without comments, its string literals blanked to "". Raises ValueError on a backtick, an unterminated
    comment or string."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise ValueError("an unterminated comment")
            out.append(" ")
            i = j + 2
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            if j >= n or src[j] != c:
                raise ValueError("an unterminated string")
            out.append('""')
            i = j + 1
        elif c == "`":
            raise ValueError("a template string")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def problems(src):
    try:
        code = strip(src)
    except ValueError as e:
        return [str(e)]
    out = []
    if "/" in code:
        out.append("a `/` outside comments and strings (a regex literal, or code hidden behind one)")
    imports = []
    for line in code.splitlines():
        m = re.match(r"^\s*import\s+(\S+)", line)
        if m:
            imports.append(m.group(1))
    if len(re.findall(r"\bimport\b", code)) != len(imports):
        out.append("an `import` that is not an import line")
    for name in imports:
        if name not in ALLOWED_IMPORTS:
            out.append(f"import {name}")
    joined = " ".join(code.split())
    for name in sorted(set(re.findall(r"\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\s*\{", joined))):
        if name not in ALLOWED_TYPES:
            out.append(f"{name} instantiated")
    for pattern in DENIED:
        if re.search(pattern, joined):
            out.append(f"the name {pattern}")
    return out


def mutants(src):
    """(description, mutated source): each must be refused."""
    head = "import Quickshell.Io\n"
    body = "    id: root\n"
    assert src.count(head) == 1 and src.count(body) == 1, "the root is not the one this selftest knows"
    top = lambda line: src.replace(head, head + line, 1)
    into = lambda text: src.replace(body, body + text + "\n", 1)
    return [
        ("a window with its brace on the next line", into("FloatingWindow\n{\n}")),
        ("a window with a comment before its brace", into("FloatingWindow /* x */ {\n}")),
        ("a window with a comment line before its next-line brace", into("FloatingWindow\n// c\n{\n}")),
        ("an indented import of Quickshell.Wayland and a WlSessionLock with a next-line brace", top("  import Quickshell.Wayland\n").replace(body, body + "WlSessionLock\n{\n}\n", 1)),
        ("a tab-indented import of the lock module and a singleton's property (no brace at all)", top("\timport qs.security.lock\n").replace(body, body + "property bool lk: Lock.locked\n", 1)),
        ("Quickshell.execDetached", into("function f() { Quickshell.execDetached([\"qs\", \"ipc\"]); }")),
        ("Qt.openUrlExternally", into("function g() { Qt.openUrlExternally(\"https://x\"); }")),
        ("a Process", into("Process {\n}")),
        ("Qt.callLater", into("function h() { Qt.callLater(root.state); }")),
        ("a Loader with a source", into("Loader {\nsource: \"x.qml\"\n}")),
        ("a file import", top("import \"lock.js\" as L\n")),
        ("a regex literal hiding a window behind its //", into("property var r: /\\//; PanelWindow {\n}")),
        ("a template string", into("property string t: `x`")),
        ("another module", top("import QtQuick.Controls\n")),
        ("a dynamic import()", into("function i() { return import(\"x\"); }")),
        ("two windows on one line", into("FloatingWindow { PanelWindow { } }")),
        ("a Component", into("Component { id: c }")),
        ("Qt.createComponent", into("function j() { Qt.createComponent(\"x\"); }")),
        ("a second import line of an allowed module with a version and a hidden one after it", top("import QtQuick 2.15 as Q\nimport Quickshell.Wayland as W\n")),
        ("eval", into("function k() { return eval(\"1\"); }")),
    ]


def main(argv):
    if argv[:1] == ["--selftest"]:
        src = open(argv[1], encoding="utf-8").read()
        ok = True
        found = problems(src)
        print(("PASS: " if not found else "FAIL: ") + "security unit root selftest: the root itself passes" + ("" if not found else " [" + "; ".join(found) + "]"))
        ok = ok and not found
        for what, text in mutants(src):
            found = problems(text)
            print(("PASS: " if found else "FAIL: ") + "security unit root selftest: " + what + " is refused" + (" (" + found[0] + ")" if found else ""))
            ok = ok and bool(found)
        return 0 if ok else 1
    src = open(argv[0], encoding="utf-8").read()
    found = problems(src)
    if found:
        print("root check: " + argv[0] + ": " + "; ".join(found))
        return 1
    print("root check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
