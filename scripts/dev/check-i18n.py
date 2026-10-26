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
Part (e) reads the helpers as text (ast for Python, patterns for sh/bash): it never imports, sources or runs them. It also
flags English text held in a variable (title = "..."), in a module-level constant that is not in the catalog, and the label of
a notify-send action (-A id=Label); option values such as icon names (-i dialog-information) are not text.
(f) the Settings app's C++ (apps/settings/src), every string literal in any spelling: English text (a phrase, or a word in a return,
    a ?: branch or an assignment to error/reason/text/...) must go through tr()/QCoreApplication::translate (lupdate then lists it);
    log calls (qWarning, qDebug...) are skipped; a token carries `// i18n-ignore` on its line or the line before.
Usage: python3 -I scripts/dev/check-i18n.py [--no-lupdate] | --helpers-only DIR | --cpp-only DIR
"""
import ast
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


NOTIFY_ALLOWED = {"notify-send", "Grassfield", "critical", "normal", "low", "--"}
# notify-send options that take a value (the app name, urgency, timeout, icon name, category, hint, ...): never text.
NOTIFY_VALUE_OPTIONS = {"-a", "--app-name", "-u", "--urgency", "-t", "--expire-time", "-i", "--icon", "-c", "--category",
                        "-h", "--hint", "-r", "--replace-id", "-e"}
# Variables that hold what a notification shows: a bare English literal assigned to one is a missed tr().
TEXT_NAMES = {"title", "body", "summary", "message", "label", "text", "anyway", "button", "caption", "subtitle"}


def _words(text):
    return bool(HAS_WORD.search(text))


def _const_strings(tree):
    """Module-level NAME = "text" constants (also "a" + "b"), resolved without running anything."""
    found = {}

    def value(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name):
            return found.get(node.id)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left, right = value(node.left), value(node.right)
            return left + right if left is not None and right is not None else None
        return None

    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            text = value(node.value)
            if text is not None:
                found[node.targets[0].id] = text
    return found, value


def _candidates(node, multi):
    """Every English text an expression can be made of, read without running anything: a string, a name of a module-level text,
    both branches of a conditional, a concatenation, the LEFT side of a % format and of .format(), the constant parts of an
    f-string. A call (tr(...), anything dynamic) is unknown: nothing, which is how a translated text passes."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    if isinstance(node, ast.Name):
        return list(multi.get(node.id, []))
    if isinstance(node, ast.IfExp):
        return _candidates(node.body, multi) + _candidates(node.orelse, multi)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _candidates(node.left, multi), _candidates(node.right, multi)
        return [a + b for a in left for b in right] if left and right else left + right
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
        return _candidates(node.left, multi)
    if isinstance(node, ast.JoinedStr):
        return ["".join(v.value if isinstance(v, ast.Constant) else "{}" for v in node.values)]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "format":
        return _candidates(node.func.value, multi)
    return []


def _text_model(tree):
    """(module constants, strict resolver, candidates of a node, assigned) for a parsed helper. `assigned` maps a variable name to
    [(line, texts)] for every assignment to it anywhere in the file (a function's local included)."""
    consts, resolve = _const_strings(tree)
    multi = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            texts = _candidates(node.value, multi)
            if texts:
                multi[node.targets[0].id] = texts
    assigned = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
            for target in (node.targets if isinstance(node, ast.Assign) else [node.target]):
                if isinstance(target, ast.Name):
                    assigned.setdefault(target.id, []).append((node.lineno, _candidates(node.value, multi)))
    return consts, resolve, (lambda node: _candidates(node, multi)), assigned


def _argv_problems(elements, resolve, cands=None, assigned=None):
    """Bare English in a notify-send argument list: positional text (before or after --) and action labels (-A id=Label)."""
    problems = []
    is_notify = bool(elements) and isinstance(elements[0], ast.Constant) and elements[0].value == "notify-send"
    markers = {e.value for e in elements if isinstance(e, ast.Constant) and isinstance(e.value, str)}
    if not (is_notify or "--" in markers or "-A" in markers or "--action" in markers):
        return problems
    i, positional = 0, False
    while i < len(elements):
        element = elements[i]
        text = resolve(element)
        if not positional and text is not None and text.startswith("-"):
            if text == "--":
                positional = True
            elif text in ("-A", "--action") and i + 1 < len(elements):
                node = elements[i + 1]
                label = resolve(node)
                if label is not None and "=" in label and not _words(label.partition("=")[2]):
                    pass  # "default=" (the label is added by tr(): the BinOp case below) or "id="
                elif label is not None:
                    problems.append((node.lineno, f"notify-send action label {label!r} is a bare English literal"))
                elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add) and (resolve(node.left) or "").endswith("="):
                    pass  # "id=" + tr(...)
                else:
                    problems.append((node.lineno, "notify-send action label is built from text that is not an id= plus a tr(...) call"))
                i += 1
            elif text in NOTIFY_VALUE_OPTIONS:
                i += 1
        elif text is not None and _words(text) and text not in NOTIFY_ALLOWED and (positional or is_notify):
            problems.append((element.lineno, f"notify-send argument {text!r} is a bare English literal"))
        elif text is None and cands is not None and (positional or is_notify):
            # a conditional, a % or .format() on English text, an f-string; a name whose assignments hold English text
            found = [t for t in cands(element) if _words(t) and t not in NOTIFY_ALLOWED]
            if isinstance(element, ast.Name) and assigned is not None:
                for line, texts in assigned.get(element.id, []):
                    found += [t for t in texts if _words(t)]
            for t in found[:1]:
                problems.append((element.lineno, f"notify-send argument {t[:40]!r} is English text built in the code (a conditional, a "
                                                 f"format, an f-string or a variable): wrap each in tr()"))
        i += 1
    return problems


def scan_python_helper(rel, text):
    """A Python helper, read with ast only: it is never imported or run."""
    violations = []
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        return [f"{rel}: cannot be parsed as Python ({exc.msg})"]
    consts, resolve, cands, assigned = _text_model(tree)
    fr = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "CATALOG" for t in node.targets) \
                and isinstance(node.value, ast.Dict):
            for key, table in zip(node.value.keys, node.value.values):
                if resolve(key) == "fr" and isinstance(table, ast.Dict):
                    fr = {}
                    for k, v in zip(table.keys, table.values):
                        source, french = resolve(k), resolve(v)
                        if source is None or french is None:
                            violations.append(f"{rel}:{k.lineno}: CATALOG['fr'] entry is not made of string constants")
                        else:
                            fr[source] = french
    if not fr:
        return violations + [f"{rel}: sends notifications and has no CATALOG['fr'] (a dict literal of string constants)"]
    for source, french in fr.items():
        if not french.strip() or french == source:
            violations.append(f"{rel}: French text of {source!r} is empty or the source")
        elif source.count("%") != french.count("%"):
            violations.append(f"{rel}: French text of {source!r} changes the % placeholders")
    in_catalog = {id(n) for node in tree.body if isinstance(node, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id == "CATALOG" for t in node.targets) for n in ast.walk(node)}
    used = set()
    lines = text.splitlines()
    for node in ast.walk(tree):
        if "i18n-ignore" in (lines[node.lineno - 1] if hasattr(node, "lineno") and node.lineno <= len(lines) else ""):
            continue
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "tr" and node.args:
            for value in cands(node.args[0]):
                used.add(value)
                if value not in fr:
                    violations.append(f"{rel}:{node.lineno}: tr({value[:40]!r}...) has no French text")
        if isinstance(node, ast.List):
            for line, message in _argv_problems(node.elts, resolve, cands, assigned):
                violations.append(f"{rel}:{line}: {message}")
        # English held in a variable that a notification will show (title = "..."), not wrapped in tr().
        if isinstance(node, (ast.Assign, ast.AnnAssign)) and id(node) not in in_catalog:
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            names = {t.id for t in targets if isinstance(t, ast.Name)}
            for literal in (cands(node.value) if node.value is not None else []):
                if names & TEXT_NAMES and _words(literal):
                    violations.append(f"{rel}:{node.lineno}: {sorted(names & TEXT_NAMES)[0]} holds the bare English text {literal[:40]!r}: wrap it in tr()")
                    break
    # A local function whose parameter holds what a notification shows (title, body, ...) called with English text.
    params = {n.name: [a.arg for a in n.args.args] for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name != "tr"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in params:
            pairs = list(zip(params[node.func.id], node.args)) + [(k.arg, k.value) for k in node.keywords if k.arg]
            for name, arg in pairs:
                for literal in (cands(arg) if name in TEXT_NAMES else []):
                    if _words(literal) and "i18n-ignore" not in lines[node.lineno - 1]:
                        violations.append(f"{rel}:{node.lineno}: {node.func.id}({name}=...) is given the bare English text {literal[:40]!r}: wrap it in tr()")
                        break
    # Module-level English text (constants, tuples, dicts) that is neither in the catalog nor passed to tr() is text nobody translates.
    for node in tree.body:
        if not isinstance(node, ast.Assign) or id(node) in in_catalog:
            continue
        for sub in ast.walk(node):
            if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                literal = sub.value
                if " " in literal.strip() and _words(literal) and literal not in fr and literal not in used \
                        and not re.search(r"[\\^$\[\]{}|]", literal) and not literal.startswith(("/", "-")) \
                        and "i18n-ignore" not in lines[sub.lineno - 1]:
                    violations.append(f"{rel}:{sub.lineno}: English text {literal[:40]!r} is not in CATALOG['fr']")
    return violations


def scan_shell_helper(rel, text):
    """A sh/bash helper, read as text only (a pattern reader of its tr table and notify-send lines): never run."""
    violations = []
    calls = set(re.findall(r'\btr "([^"$]+)"', text))
    cases = {m.group(1) for m in re.finditer(r'(?:^|[\s;])fr:"([^"]+)"\)', text, re.M)}
    for source in sorted(calls - cases):
        violations.append(f"{rel}: tr {source!r} has no fr: case")
    for source in sorted(cases - calls):
        violations.append(f"{rel}: fr: case {source!r} is never used")
    if not cases:
        violations.append(f"{rel}: sends notifications and has no fr: cases of tr")
    logical = re.sub(r"\\\n\s*", " ", text)
    for number, line in enumerate(logical.splitlines(), 1):
        if "i18n-ignore" in line or "notify-send" not in line or line.lstrip().startswith("#"):
            continue
        for match in re.finditer(r'(?:-A|--action)\s+"?([^\s"$=]+)=([^\s"$]*)', line):
            if _words(match.group(2)):
                violations.append(f"{rel}: notify-send action label {match.group(0).strip()!r} is a bare English literal")
        after = line.split(" -- ", 1)[1] if " -- " in line else ""
        after = re.sub(r"\$\((?:[^()]|\([^()]*\))*\)", "", after)  # $(tr "...") is the translated text
        for literal in re.findall(r'"([^"$`]*)"', after):
            if _words(literal):
                violations.append(f"{rel}: notify-send text {literal!r} is a bare English literal")
        for literal in re.findall(r"(?:^|\s)'([^']*)'", after):
            if _words(literal):
                violations.append(f"{rel}: notify-send text {literal!r} is a bare English literal")
    # English held in a shell variable: any variable that a notify-send line uses ("$msg", "${msg}") and the names in TEXT_NAMES,
    # assigned a bare literal anywhere, also inside a one-line `if ...; then body="..."; fi` or after a `;`; and the format of a
    # printf that makes it.
    flows = set()
    for line in logical.splitlines():
        if "notify-send" in line and not line.lstrip().startswith("#"):
            flows |= set(re.findall(r"\$\{?([A-Za-z_]\w*)\}?", re.sub(r"\$\((?:[^()]|\([^()]*\))*\)", "", line)))
    watched = TEXT_NAMES | flows
    assignment = re.compile(r'(?:^|[\s;&|{(])(?:local\s+|export\s+|declare\s+)?([A-Za-z_]\w*)=("(?:[^"\\$`]|\\.)*"|\'[^\']*\'|\$\(\s*printf\s+(?:-v\s+\S+\s+)?("(?:[^"\\$`]|\\.)*"|\'[^\']*\')[^)]*\))')
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#") or "i18n-ignore" in line:
            continue
        for match in assignment.finditer(line):
            literal = match.group(3) or match.group(2)
            if match.group(1) in watched and _words(literal):
                violations.append(f"{rel}:{number}: {match.group(1)} holds the bare English text {literal[:40]}: use $(tr ...)")
    return violations


def scan_helpers(directory=None):
    """(e) the session helpers: see the module docstring. Static: nothing is imported, sourced or executed."""
    violations = []
    for path in sorted((directory or ROOT / "packaging" / "bin").iterdir()):
        if not path.is_file():
            continue
        rel = path.name if directory else path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        if "notify-send" not in text and "Notifications.Notify" not in text:
            continue
        shebang = text.splitlines()[0] if text else ""
        if "python" in shebang:
            violations += scan_python_helper(rel, text)
        elif re.search(r"\b(ba)?sh\b", shebang):
            violations += scan_shell_helper(rel, text)
        else:
            violations.append(f"{rel}: sends notifications but its first line is not a python, sh or bash shebang")
    return violations


# (f) C++ of the Settings app: every string literal is read (any spelling: "..", QStringLiteral, QString(".."), u".."_s, views,
# a bare return "..", a literal on the next line), with the calls it sits in. It must be translated text (tr(), translate()) or
# a token. English text outside translate() fails when it is a phrase (two words), or a word or phrase in a return statement, a
# ?: branch or an assignment to a text-like name (error, reason, text, message, title, label, status): that is how a reason
# reaches QML. Not text: literals inside log calls (qWarning...), asserts, regular expressions and character literals.
CPP_TRANSLATING = {"tr", "translate", "QT_TR_NOOP", "QT_TRANSLATE_NOOP", "QT_TR_N_NOOP", "qsTr", "trUtf8"}
CPP_NOT_TEXT = {"qDebug", "qInfo", "qWarning", "qCritical", "qFatal", "qCDebug", "qCInfo", "qCWarning", "qCCritical", "Q_ASSERT", "Q_ASSERT_X",
                "static_assert", "QRegularExpression", "QRegExp", "Q_UNUSED", "QT_MESSAGE_PATTERN", "setObjectName", "setProperty", "property",
                "qputenv", "qgetenv", "qEnvironmentVariable", "qEnvironmentVariableIsSet", "qEnvironmentVariableIsEmpty", "Q_LOGGING_CATEGORY"}
CPP_TEXT_NAMES = re.compile(r"\b(?:error|reason|text|message|title|label|status|failure|hint|summary|description)\w*\s*=$", re.I)
CPP_LOG_STREAM = re.compile(r"\bq(?:C)?(?:Debug|Info|Warning|Critical|Fatal)\b")
CPP_WRAPPER_OPEN = re.compile(r"(?:\b(?:QStringLiteral|QLatin1String|QLatin1StringView|QStringView|QUtf8StringView|QString|QByteArray|fromUtf8|fromLatin1|fromLocal8Bit)\s*)\($")
CPP_VALUE_POSITION = re.compile(r"(?:\breturn|\?|(?<!:):(?!:))$")
CPP_ASSIGN = re.compile(r"(?<![=!<>+\-*/|&^%])=$")
CPP_WORDLIKE = re.compile(r"^[A-Za-z][A-Za-z' ,:;!?()\-]*[.!?]?$")


def _cpp_literals(text):
    """[(line, literal text, enclosing call names, statement text before the literal, statement text overall)] of a C++ source."""
    found = []
    i, n, line = 0, len(text), 1
    calls = []  # one entry per open "(": the identifier before it ("" for none)
    statement = ""  # code since the last ; { }  (literals shown as "")
    last_word = ""
    pending = []  # (line, literal, calls snapshot, statement before it)
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            line += text.count("\n", i, end)
            i = end
        elif c == '"' or (text.startswith('R"', i) and not (i and (text[i - 1].isalnum() or text[i - 1] == "_"))):
            if c == "R":  # raw string R"delim( ... )delim"
                m = re.compile(r'R"([^(\s]{0,16})\(').match(text, i)
                if not m:
                    i += 1
                    continue
                end = text.find(")" + m.group(1) + '"', m.end())
                end = n if end < 0 else end + len(m.group(1)) + 2
                literal = text[m.end():max(m.end(), end - len(m.group(1)) - 2)]
                start_line = line
                line += text.count("\n", i, end)
                i = end
            else:
                j = i + 1
                while j < n and text[j] != '"' and text[j] != "\n":
                    j += 2 if text[j] == "\\" else 1
                literal = text[i + 1:j]
                start_line = line
                i = j + 1
            pending.append((start_line, literal, list(calls), statement))
            statement += '""'
            last_word = ""
        elif c == "'":  # a character literal
            j = i + 1
            while j < n and text[j] != "'" and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            statement += "''"
        elif c.isalpha() or c == "_":
            m = re.compile(r"[A-Za-z_][A-Za-z_0-9:]*").match(text, i)
            last_word = m.group(0)
            statement += last_word
            i = m.end()
        elif c == "(":
            calls.append(last_word)
            statement += c
            last_word = ""
            i += 1
        elif c == ")":
            if calls:
                calls.pop()
            statement += c
            last_word = ""
            i += 1
        elif c in ";{}":
            if not calls or c != ";":
                statement = ""
            else:
                statement += c
            last_word = ""
            i += 1
        else:
            if not c.isspace():
                last_word = ""
            statement += c
            i += 1
    for start_line, literal, call_stack, before in pending:
        found.append((start_line, literal, call_stack, before))
    return found


def scan_cpp_text(rel, text):
    lines = text.splitlines()
    violations = []
    for line, literal, calls, before in _cpp_literals(text):
        if any(c.split("::")[-1] in CPP_TRANSLATING | CPP_NOT_TEXT for c in calls):
            continue
        marked = any("i18n-ignore" in lines[k] for k in (line - 1, line - 2) if 0 <= k < len(lines))
        if marked or not HAS_WORD.search(literal):
            continue
        if CPP_LOG_STREAM.search(before):  # qWarning().noquote() << "..."
            continue
        phrase = bool(re.search(r"[^\W\d_]{2,}\s+[^\W\d_]{2,}", literal))
        # Where the literal stands: a return value, a branch of ?:, or the right side of an assignment to a text-like name
        # (not an operand of ==, not an argument of another call).
        tail = CPP_WRAPPER_OPEN.sub("", before.rstrip()).rstrip()
        visible = bool(CPP_VALUE_POSITION.search(tail)) or (bool(CPP_ASSIGN.search(tail)) and bool(CPP_TEXT_NAMES.search(tail[-80:])))
        wordlike = bool(CPP_WORDLIKE.match(literal))
        if phrase or (visible and wordlike):
            violations.append(f"{rel}:{line}: English text {literal[:40]!r} is not wrapped in tr()/QCoreApplication::translate")
    return violations


def scan_cpp(directory=None):
    """(f) bare English text in the Settings app's C++, read as text (a tokenizer): never compiled."""
    violations = []
    base = directory or ROOT / "apps" / "settings" / "src"
    for path in sorted(list(base.glob("*.cpp")) + list(base.glob("*.h"))):
        rel = path.name if directory else path.relative_to(ROOT)
        violations += scan_cpp_text(rel, path.read_text(encoding="utf-8"))
    return violations


def main():
    if "--cpp-only" in sys.argv:  # part (f) alone on a directory (selftest, tests/shell/i18n_helpers_gate.sh)
        found = scan_cpp(Path(sys.argv[sys.argv.index("--cpp-only") + 1]))
        for v in found:
            print(f"i18n: {v}")
        return 1 if found else 0
    if "--helpers-only" in sys.argv:  # part (e) alone on a directory (the gate's selftest, tests/shell/i18n_helpers_gate.sh)
        found = scan_helpers(Path(sys.argv[sys.argv.index("--helpers-only") + 1]))
        for v in found:
            print(f"i18n: {v}")
        return 1 if found else 0
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

    violations = scan_qml() + scan_desktop_entries() + scan_helpers() + scan_cpp()
    for v in violations:
        print(f"i18n: {v}")
    if violations:
        failed = True

    print(f"i18n: {len(messages)} messages, {unfinished} unfinished, {len(violations)} bare literals")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
