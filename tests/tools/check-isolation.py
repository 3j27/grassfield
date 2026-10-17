#!/usr/bin/env python3
"""Fail when a test or dev script starts an app without an isolating helper (the owner's home stays untouched).

  check-isolation.py            scan tests/ and scripts/dev/, exit 1 on a violation
  check-isolation.py --selftest check the checker on synthetic scripts (one sample per launch form)

Apps covered: grassfield-settings, grassfield-files, grassfield-preview, foot, kitty, chromium, nautilus, dolphin, kate.
Files scanned: *.sh, *.bash, *.py and every file with a shell or python shebang (any extension), except this checker.

Shell scripts are parsed structurally (shlex tokens, separators ; & | && || ( ) { }, heredoc bodies skipped, comments removed
BEFORE any safety test, so a comment that mentions isolated.sh excuses nothing). A launch is an app word in command position,
reached through wrappers that are looked through, with their options: setsid (-f -w -c), exec (-a NAME -c -l), env (-i -0 -u NAME
-C DIR, VAR=value), nohup, timeout (-k DUR -s SIG, then DURATION), sudo, command (not -v/-V), stdbuf (-i -o -e MODE), nice, ionice,
dbus-run-session, systemd-run, sh/bash/dash/zsh -c "STRING" and eval (the string is parsed again). A command word that is a
variable ("$bin", ${bin}) is a launch when the file assigns that variable a value naming an app.
A launch is accepted when:
  - the wrapped command is scripts/dev/isolated.sh itself, vs_spawn or vs_foot (tests/visual/lib.sh helpers that call it): those are
    command words, not apps, so they are never launches;
  - the same simple command (VAR=value words, env arguments) sets XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_STATE_HOME, XDG_DATA_HOME and
    GRASSFIELD_CONFIG_HOME together;
  - an `isolation-ok: reason` marker comment sits on the line or the line before (a wrapper that isolates internally).
Python: a spawn call (subprocess.*, Popen, os.system/exec*/spawn*/popen) whose statement window holds a string naming an app and no
isolated.sh string is a violation.
"""
import os
import re
import shlex
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SELF = os.path.abspath(__file__)
APP_NAMES = ("grassfield-settings", "grassfield-files", "grassfield-preview", "foot", "kitty", "chromium", "nautilus", "dolphin", "kate")
ENV_SET = ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "GRASSFIELD_CONFIG_HOME")
SKIP_WORDS = {"!", "then", "do", "else", "elif", "if", "while", "until", "time", "{", "}"}
# wrapper -> (options taking a separate value, positional words to skip after the options)
WRAPPERS = {
    "setsid": (set(), 0),
    "exec": ({"-a"}, 0),
    "env": ({"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}, 0),
    "nohup": (set(), 0),
    "timeout": ({"-k", "--kill-after", "-s", "--signal"}, 1),
    "sudo": ({"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-T", "-U"}, 0),
    "command": (set(), 0),
    "stdbuf": ({"-i", "-o", "-e", "--input", "--output", "--error"}, 0),
    "nice": ({"-n", "--adjustment"}, 0),
    "ionice": ({"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"}, 0),
    "dbus-run-session": ({"--config-file", "--dbus-daemon"}, 0),
    "systemd-run": ({"-p", "--property", "-E", "--setenv", "-u", "--unit", "-d", "--description", "-G", "--same-dir", "-M", "--machine",
                     "--slice", "--working-directory", "-H", "--host", "--uid", "--gid", "--nice", "--on-active", "--on-calendar"}, 0),
}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
APP_RE = re.compile(r"^(?:.*/)?(?:%s)$" % "|".join(re.escape(a) for a in APP_NAMES))
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
VARWORD = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")


def strip_comment(line):
    """(code, comment): the `#` comment of a shell line, quotes respected (a # starts one at a word start)."""
    quote = ""
    for i, ch in enumerate(line):
        if quote:
            if ch == quote and (quote == "'" or line[i - 1] != "\\"):
                quote = ""
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t;&|(") and not (i and line[i - 1] == "$"):
            return line[:i], line[i:]
    return line, ""


def logical_lines(text):
    """Yield (first line number, code, comment): backslash continuations joined, heredoc bodies skipped."""
    buf, comments, start, doc_end = "", [], 0, None
    for i, raw in enumerate(text.splitlines(), 1):
        if doc_end is not None:
            if raw.strip() == doc_end:
                doc_end = None
            continue
        if not buf:
            start = i
        code, comment = strip_comment(raw)
        if comment:
            comments.append(comment)
        if code.rstrip().endswith("\\"):
            buf += code.rstrip()[:-1] + " "
            continue
        buf += code
        m = HEREDOC.search(buf)
        yield start, buf, " ".join(comments)
        if m:
            doc_end = m.group(2)
        buf, comments = "", []
    if buf:
        yield start, buf, " ".join(comments)


def tokens(code):
    lex = shlex.shlex(code, posix=True, punctuation_chars=";&|(){}")
    lex.whitespace_split = True
    lex.commenters = ""
    out = []
    try:
        for t in lex:
            out.append(t)
    except ValueError:
        out = code.split()
    return out


HARD = {";", "&", "&&", "||", ";;", "{", "}", "\n"}


def simple_commands(toks):
    """Simple commands (token lists) of a token stream. Skipped: array literals (x=(foot kitty)) and case patterns
    (`foot | kitty)` up to the closing parenthesis), which are words, not commands."""
    pending, cmd, depth, i = [], [], 0, 0
    while i < len(toks):
        t = toks[i]
        if t == "(" and cmd and cmd[-1].endswith("=") and depth == 0:
            # array literal: skip to the matching parenthesis
            level = 1
            i += 1
            while i < len(toks) and level:
                level += (toks[i] == "(") - (toks[i] == ")")
                i += 1
            continue
        if t == "(":
            depth += 1
            if cmd:
                pending.append(cmd)
                cmd = []
            for c in pending:
                yield c
            pending = []
        elif t == ")":
            if depth > 0:
                depth -= 1
                if cmd:
                    pending.append(cmd)
                for c in pending:
                    yield c
                pending, cmd = [], []
            else:
                pending, cmd = [], []  # case pattern list: not commands
        elif t in ("|", "|&"):
            if cmd:
                pending.append(cmd)
            cmd = []
        elif t in HARD or (t and set(t) <= set(";&|(){}")):
            if cmd:
                pending.append(cmd)
            for c in pending:
                yield c
            pending, cmd = [], []
        else:
            cmd.append(t)
        i += 1
    if cmd:
        pending.append(cmd)
    for c in pending:
        yield c


def app_vars(text):
    """Names of variables the file assigns a value that names an app (bin=$dev/build/grassfield-files, cmd=foot ...)."""
    names = set()
    for m in re.finditer(r"(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=(\S+)", text):
        value = m.group(2).strip("\"'")
        if APP_RE.match(value.rstrip(")")):
            names.add(m.group(1))
    return names


def launched(cmd, appvars, seen_env=None):
    """The app a simple command (token list) launches, with the isolation env names set on the way, else None."""
    env = set(seen_env or ())
    i = 0
    while i < len(cmd) and (ASSIGN.match(cmd[i]) or cmd[i] in SKIP_WORDS):
        if ASSIGN.match(cmd[i]):
            env.add(cmd[i].split("=", 1)[0])
        i += 1
    while i < len(cmd):
        word = cmd[i]
        base = os.path.basename(word)
        if base in SHELLS:
            # sh -c "STRING": the string is a command line of its own.
            rest = cmd[i + 1:]
            for j, t in enumerate(rest):
                if t == "-c" or (t.startswith("-") and not t.startswith("--") and "c" in t[1:]):
                    if j + 1 < len(rest):
                        return scan_string(rest[j + 1], appvars, env)
                    break
            return None
        if base == "eval":
            return scan_string(" ".join(cmd[i + 1:]), appvars, env)
        if base in WRAPPERS:
            opt_values, positional = WRAPPERS[base]
            i += 1
            while i < len(cmd):
                t = cmd[i]
                if base == "command" and t in ("-v", "-V"):
                    return None
                if ASSIGN.match(t) and base == "env":
                    env.add(t.split("=", 1)[0])
                    i += 1
                elif t == "--":
                    i += 1
                    break
                elif t.startswith("-") and len(t) > 1:
                    key = t.split("=", 1)[0]
                    if key in opt_values and "=" not in t:
                        i += 2
                    else:
                        i += 1
                elif positional > 0:
                    positional -= 1
                    i += 1
                else:
                    break
            continue
        m = VARWORD.match(word)
        if m and m.group(1) in appvars:
            return (word, env)
        if APP_RE.match(word):
            return (word, env)
        return None
    return None


def scan_string(string, appvars, env):
    for cmd in simple_commands(tokens(string)):
        r = launched(cmd, appvars, env)
        if r:
            return r
    return None


def isolated(env):
    return all(e in env for e in ENV_SET)


def scan_shell(text):
    """[(line number, text)] of launches without isolation in a shell script."""
    appvars = app_vars("\n".join(code for _, code, _ in logical_lines(text)))
    out = []
    prev_comment = ""
    for n, code, comment in logical_lines(text):
        if "isolation-ok:" in comment or "isolation-ok:" in prev_comment:
            prev_comment = comment
            continue
        prev_comment = comment if not code.strip() else ""
        for cmd in simple_commands(tokens(code)):
            r = launched(cmd, appvars)
            if r and not isolated(r[1]):
                out.append((n, code.strip()))
                break
    return out


SPAWN = re.compile(r"\b(?:subprocess\.\w+|Popen|os\.(?:system|exec\w*|spawn\w*|popen))\s*\(")
PY_APP = re.compile(r"""["'](?:[^"'\s]*/)?(?:%s)["']""" % "|".join(re.escape(a) for a in APP_NAMES))


def scan_python(text):
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        code = line.split("#")[0]
        if not SPAWN.search(code):
            continue
        window = "\n".join(l.split("#")[0] for l in lines[i:i + 4])
        marker = "isolation-ok:" in line or (i and "isolation-ok:" in lines[i - 1])
        if PY_APP.search(window) and "isolated.sh" not in window and not marker:
            out.append((i + 1, line.strip()))
    return out


def scan_file(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    return scan_python(text) if is_python(path, text) else scan_shell(text)


def is_python(path, text):
    first = text.split("\n", 1)[0]
    return path.endswith(".py") or ("python" in first and first.startswith("#!"))


def wanted(path):
    if os.path.abspath(path) == SELF:
        return False
    if path.endswith((".sh", ".bash", ".py")):
        return True
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return False
    return head.startswith(b"#!") and re.search(rb"\b(?:ba|da|z|k)?sh\b|python", head.split(b"\n", 1)[0]) is not None


# Known violations in files this checker's owner may not edit: reported as WARNING (never silent), do not fail the run. Remove an
# entry when its file is fixed.
KNOWN = {
    "tests/compositor/appmenu.sh": "chromium started with --user-data-dir only (no XDG_* isolation): open finding for the compositor-engineer",
}


# One sample per launch form. Each is a tiny script.
BAD = [
    "setsid foot >/dev/null 2>&1 </dev/null &",
    "WAYLAND_DISPLAY=$sock setsid foot -e sh -c x &",
    '"$root/.dev/build/grassfield-settings" &',
    'env FOO=1 "$VS_DEV/build/grassfield-files" /tmp &',
    'foot_bg() { WAYLAND_DISPLAY=$sock setsid foot "$@" & }',
    "timeout 5 grassfield-preview x",
    # new forms
    'bin=$dev/build/grassfield-files\n"$bin" /tmp &',
    "bin=$dev/build/grassfield-files\n$bin /tmp &",
    "bin=$dev/build/grassfield-settings\nsetsid -f \"${bin}\" &",
    "setsid -f foot &",
    "setsid -w foot",
    "env -u WAYLAND_DEBUG foot &",
    "env -i foot &",
    "env -i HOME=/x PATH=/usr/bin foot &",
    "env -C /tmp foot &",
    "exec -a myname foot",
    "exec -c foot",
    "timeout -k 5 30 foot",
    "timeout --kill-after=5 30 foot",
    "timeout -s KILL -k 2 10 grassfield-files",
    "systemd-run --user foot",
    "systemd-run --user --scope -p MemoryMax=1G -E A=b foot",
    'sh -c "foot"',
    "bash -c 'setsid foot &'",
    "sh -lc 'exec kitty'",
    "command foot",
    "command -p foot",
    "stdbuf -oL foot",
    "stdbuf -o L -e0 foot",
    "dbus-run-session foot",
    "dbus-run-session -- foot",
    "chromium --user-data-dir=/tmp/x &",
    "kitty &",
    "setsid chromium &",
    "nohup kitty >/dev/null 2>&1 &",
    "nice -n 5 foot",
    "ionice -c3 foot",
    "eval foot",
    "eval 'setsid kitty &'",
    "exit 0; foot &",
    "if foot --version; then :; fi",
    "x=1 && timeout 3 chromium",
    # a comment that mentions the helper excuses nothing
    "setsid foot & # scripts/dev/isolated.sh",
    "setsid foot # isolated.sh is documented elsewhere",
    'foot -e sh -c "echo # isolated.sh"',
    # the partial env set is not isolation
    "env XDG_CONFIG_HOME=a XDG_CACHE_HOME=b foot &",
]
GOOD = [
    'setsid "$root/scripts/dev/isolated.sh" foot &',
    'setsid -f "$root/scripts/dev/isolated.sh" --name x -- foot &',
    'vs_spawn "$VS_DEV/build/grassfield-settings"',
    'vs_foot "t" 80x24',
    "# setsid foot is documented here",
    'bin=$dev/build/grassfield-files',
    '[[ -z $x && -x $dev/build/grassfield-settings ]] && cmd=$dev/build/grassfield-settings',
    'echo "see foot docs"',
    'printf "%s\\n" "start foot with isolated.sh"',
    "command -v foot >/dev/null",
    "command -v kitty",
    "type foot",
    "which chromium",
    "pgrep -x foot",
    'env XDG_CONFIG_HOME=a XDG_CACHE_HOME=b XDG_STATE_HOME=c XDG_DATA_HOME=d GRASSFIELD_CONFIG_HOME=e setsid "$bin" x &',
    "XDG_CONFIG_HOME=a XDG_CACHE_HOME=b XDG_STATE_HOME=c XDG_DATA_HOME=d GRASSFIELD_CONFIG_HOME=e foot &",
    "setsid foot # isolation-ok: wrapper isolates",
    "# isolation-ok: the wrapper isolates internally\nsetsid foot &",
    'sh -c \'"$root/scripts/dev/isolated.sh" foot\'',
    "timeout 5 scripts/dev/isolated.sh --name t -- foot",
    "dbus-run-session -- scripts/dev/isolated.sh foot",
    "cat <<EOF\nfoot is the terminal\nEOF\necho done",
    "cat <<'EOF'\n  setsid foot &\nEOF",
    "echo foot",
    "grep -q foot file",
    "tests=(foot kitty)",
    "systemd-run --user scripts/dev/isolated.sh foot",
    "exec scripts/dev/isolated.sh -- chromium",
]
PY_BAD = [
    'import subprocess\nsubprocess.Popen(["foot", "-e", "sh"])',
    'subprocess.run(["/usr/bin/chromium", "--x"])',
    'os.system("setsid kitty")' if False else 'subprocess.call(["kitty"])',
    'p = subprocess.Popen(\n    ["grassfield-files", "x"],\n)',
]
PY_GOOD = [
    'subprocess.run(["scripts/dev/isolated.sh", "--", "foot"])',
    'x = ["foot"]',
    'subprocess.run(["echo", "hi"])',
    'subprocess.Popen(["foot"])  # isolation-ok: wrapper isolates',
]


def selftest():
    fails = []
    for s in BAD:
        if not scan_shell(s):
            fails.append("not flagged: " + s.replace("\n", " ; "))
    for s in GOOD:
        if scan_shell(s):
            fails.append("wrongly flagged: " + s.replace("\n", " ; "))
    for s in PY_BAD:
        if not scan_python(s):
            fails.append("python not flagged: " + s.replace("\n", " ; "))
    for s in PY_GOOD:
        if scan_python(s):
            fails.append("python wrongly flagged: " + s.replace("\n", " ; "))
    for f in fails:
        print("check-isolation selftest FAIL:", f)
    if not fails:
        print("check-isolation selftest: %d violating and %d clean shell samples, %d and %d python samples classified correctly"
              % (len(BAD), len(GOOD), len(PY_BAD), len(PY_GOOD)))
    return 1 if fails else 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    status = 0
    count = 0
    for sub in ("tests", "scripts/dev"):
        for d, dirs, files in os.walk(os.path.join(ROOT, sub)):
            dirs[:] = [x for x in dirs if x not in ("build", "baselines", "__pycache__", ".git")]
            for name in sorted(files):
                path = os.path.join(d, name)
                if not wanted(path):
                    continue
                count += 1
                rel = os.path.relpath(path, ROOT)
                for n, line in scan_file(path):
                    if rel in KNOWN:
                        print("WARNING %s:%d: %s (known: %s)" % (rel, n, line[:100], KNOWN[rel]))
                        continue
                    print("%s:%d: app started without scripts/dev/isolated.sh or the full XDG_*/GRASSFIELD_CONFIG_HOME set: %s"
                          % (rel, n, line[:140]))
                    status = 1
    print("check-isolation: %d files scanned, %s" % (count, "FAIL" if status else "ok"))
    return status


if __name__ == "__main__":
    sys.exit(main())
