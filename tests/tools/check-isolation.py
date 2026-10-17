#!/usr/bin/env python3
"""Fail when a test or dev script starts an app without an isolating helper (owner's home stays untouched).

  check-isolation.py            scan tests/ and scripts/dev/ (*.sh), exit 1 on a violation
  check-isolation.py --selftest check the checker on synthetic lines

Apps covered: grassfield-settings, grassfield-files, grassfield-preview, foot, nautilus, dolphin, kate.
A launch (the app in command position: first word, or after setsid/exec/env/nohup/timeout/&/;/|/(/&&/||) is accepted when
its logical line (backslash continuations joined) contains one of:
  - scripts/dev/isolated.sh (the helper), or vs_spawn / vs_foot (tests/visual/lib.sh, which call the helper),
  - XDG_CONFIG_HOME=, XDG_CACHE_HOME=, XDG_STATE_HOME=, XDG_DATA_HOME= and GRASSFIELD_CONFIG_HOME= together,
  - an `isolation-ok:` marker comment with the reason (for a wrapper that isolates internally).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APPS = r"(?:grassfield-(?:settings|files|preview)|foot|nautilus|dolphin|kate)"
# Command position: line start, or after a separator / launcher word (with optional VAR=value words and options).
LAUNCH = re.compile(
    r"""(?:^|[;&|(]\s*|\b(?:setsid|exec|env|nohup|timeout\s+\S+|sudo)\s+)   # command position
        (?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*                                   # VAR=value prefixes
        ["']?(?:[^\s"';&|()=]*/)?""" + APPS + r"""["']?(?=\s|$|[;&|)])""",
    re.X)
SAFE = [re.compile(p) for p in (r"scripts/dev/isolated\.sh", r"\bisolated\.sh\b", r"\bvs_spawn\b", r"\bvs_foot\b", r"isolation-ok:")]
ENV_SET = ("XDG_CONFIG_HOME=", "XDG_CACHE_HOME=", "XDG_STATE_HOME=", "XDG_DATA_HOME=", "GRASSFIELD_CONFIG_HOME=")


def logical_lines(text):
    """Yield (first line number, joined line); keeps comments for the marker check."""
    buf, start = "", 0
    for i, raw in enumerate(text.splitlines(), 1):
        if not buf:
            start = i
        if raw.endswith("\\"):
            buf += raw[:-1] + " "
            continue
        yield start, buf + raw
        buf = ""
    if buf:
        yield start, buf


def violation(line):
    code = line.split(" #")[0] if " #" in line else line
    if code.lstrip().startswith("#"):
        return False
    if not LAUNCH.search(code):
        return False
    if any(p.search(line) for p in SAFE):
        return False
    return not all(e in line for e in ENV_SET)


def scan_file(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    # Heredoc/usage text and comments never launch anything; the launch regex needs command position.
    lines = list(logical_lines(text))
    out = []
    for idx, (n, line) in enumerate(lines):
        if violation(line):
            prev = lines[idx - 1][1] if idx else ""
            if "isolation-ok:" in prev:
                continue
            out.append((n, line.strip()))
    return out


def selftest():
    bad = [
        'setsid foot >/dev/null 2>&1 </dev/null &',
        'WAYLAND_DISPLAY=$sock setsid foot -e sh -c x &',
        '"$root/.dev/build/grassfield-settings" &',
        'env FOO=1 "$VS_DEV/build/grassfield-files" /tmp &',
        'foot_bg() { WAYLAND_DISPLAY=$sock setsid foot "$@" & }',
        'timeout 5 grassfield-preview x',
    ]
    good = [
        'setsid "$root/scripts/dev/isolated.sh" foot &',
        'vs_spawn "$VS_DEV/build/grassfield-settings"',
        '# setsid foot is documented here',
        'bin=$dev/build/grassfield-files',
        '[[ -z $x && -x $dev/build/grassfield-settings ]] && cmd=$dev/build/grassfield-settings',
        'echo "see foot docs"',
        'env XDG_CONFIG_HOME=a XDG_CACHE_HOME=b XDG_STATE_HOME=c XDG_DATA_HOME=d GRASSFIELD_CONFIG_HOME=e setsid "$bin" x &',
        'setsid foot # isolation-ok: wrapper isolates',
    ]
    fails = [b for b in bad if not violation(b)] + [g for g in good if violation(g)]
    for f in fails:
        print("check-isolation selftest FAIL:", f)
    if not fails:
        print("check-isolation selftest: %d violating and %d clean samples classified correctly" % (len(bad), len(good)))
    return 1 if fails else 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    status = 0
    count = 0
    for sub in ("tests", "scripts/dev"):
        for d, _, files in os.walk(os.path.join(ROOT, sub)):
            for name in sorted(files):
                if not name.endswith(".sh"):
                    continue
                path = os.path.join(d, name)
                count += 1
                for n, line in scan_file(path):
                    print("%s:%d: app started without scripts/dev/isolated.sh or the full XDG_*/GRASSFIELD_CONFIG_HOME set: %s"
                          % (os.path.relpath(path, ROOT), n, line[:140]))
                    status = 1
    print("check-isolation: %d scripts scanned, %s" % (count, "FAIL" if status else "ok"))
    return status


if __name__ == "__main__":
    sys.exit(main())
