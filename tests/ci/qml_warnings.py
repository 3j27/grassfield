#!/usr/bin/env python3
"""Gate Q2 (audit GF-073): a test run must not hide QML runtime errors of product files behind a green result.

  python3 -I tests/ci/qml_warnings.py            read a test run's output on stdin, list the offending lines, exit 1 when any
  python3 -I tests/ci/qml_warnings.py --selftest the filter on fixed samples

An offending line is a warning (QWARN, or a qs `WARN` line) that names a product file (shell/, ui/, apps/ of this tree) and
a runtime failure: TypeError, ReferenceError, "Binding loop", "Unable to assign", "is not a function" or "is not a
constructor". Lines about test files (tests/) are not product code and are left to the tests. The allowlist is narrow and
every entry says why:
  Invalid image provider  the offscreen test engine has none of the application's image providers (image://icon,
                          image://preview, ...); the real apps register them in C++
  dev lines               lines the shell prints on purpose in a dev session (GRASSFIELD_DEV), recognised by their text
"""
import re
import sys

PRODUCT = re.compile(r"(?:^|[ /(])(?:shell|ui|apps)/[A-Za-z0-9_./-]+\.(?:qml|js)")
FAILURE = re.compile(r"TypeError|ReferenceError|Binding loop|Unable to assign|is not a function|is not a constructor")
ALLOW = [
    re.compile(r"Invalid image provider: image://"),
    re.compile(r"grassfield: dev session"),
]
# A test file is named in the line before any product file it loaded: those lines belong to the test.
TEST_FILE = re.compile(r"(?:^|[ /(])tests/[A-Za-z0-9_./-]+\.(?:qml|js)")


def offending(lines):
    out = []
    for line in lines:
        if not (line.startswith("QWARN") or " WARN " in line or line.startswith("WARN") or line.startswith("QDEBUG")):
            continue
        if not FAILURE.search(line) or not PRODUCT.search(line):
            continue
        if TEST_FILE.search(line) and not PRODUCT.search(TEST_FILE.sub("", line)):
            continue
        if any(a.search(line) for a in ALLOW):
            continue
        out.append(line.rstrip())
    return out


def selftest():
    samples = [
        ("QWARN  : qmltestrunner::X::test_y() file:///w/apps/files/qml/TagDots.qml:20: TypeError: Cannot read property 'length' of undefined", True),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/apps/files/qml/GlobalMenu.qml:204:13: Unable to assign [undefined] to bool", True),
        ("WARN scene: file:///w/shell/menubar/MenuBar.qml:12:5: QML Item: Binding loop detected for property \"width\"", True),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/ui/Grassfield/Ui/Foo.qml:3: ReferenceError: x is not defined", True),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/apps/preview/qml/Viewer.qml:623:25: QML Image: Invalid image provider: image://preview/thumb/0", False),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/ui/Grassfield/Ui/TintedIcon.qml:80:5: QML Image: Invalid image provider: image://icon/folder", False),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/tests/unit/tst_foo.qml:9: TypeError: undefined is not a function", False),
        ("PASS   : qmltestrunner::X::test_y()", False),
        ("QWARN  : qmltestrunner::X::test_y() file:///w/shell/overlay/Foo.qml:9: Some other warning", False),
    ]
    bad = 0
    for line, expect in samples:
        got = bool(offending([line]))
        if got != expect:
            bad += 1
            print("qml_warnings selftest: wrong verdict for:", line, "(expected", expect, ")")
    # Fewer than 100 characters of context must not matter: a paste with surrounding lines.
    mixed = ["PASS   : a", samples[0][0], "PASS   : b"]
    if len(offending(mixed)) != 1:
        bad += 1
        print("qml_warnings selftest: mixed output")
    print("qml_warnings selftest: PASS" if bad == 0 else "qml_warnings selftest: FAIL (%d)" % bad)
    return 1 if bad else 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    bad = offending(sys.stdin.read().splitlines())
    for line in bad:
        print("QML runtime error in product code:", line)
    if bad:
        print("qml_warnings: %d line(s); fix the file, or the test's fixture when the fixture lacks what the file binds to" % len(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
