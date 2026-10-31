#!/usr/bin/env python3
"""Tokens only: no literal design value in the QML (CLAUDE.md "tokens only, no hardcoded values"; ADR-0039 steps 2-5, rule 6).

  python3 -I tests/ci/qml_literals.py             scan the tree, exit 1 on any literal outside the allowlist
  python3 -I tests/ci/qml_literals.py --selftest  the scanner on fixed samples

Scanned: every .qml file of ui/Grassfield/ (Tokens.qml, generated from ui/tokens/tokens.json, excepted), shell/ (shell/security/
included: it is read, never changed) and apps/.

A design property is known by its name (the last part of a dotted name, a group's member, or a declared property's name), so
`anchors.leftMargin`, `font { pixelSize }`, `Layout.preferredWidth`, `sourceSize.width` and `readonly property int pillInset`
are all read:
  radius      ...radius
  font        pixelSize, pointSize, letterSpacing, wordSpacing, lineHeight, fontSize
  duration    ...duration (an animation's; `Timer.interval` is not one: debounces, polls and retries are logic, ADR-0039 D7)
  opacity     ...opacity
  scale       scale
  geometry    x, y and ...width, height, size, margin(s), padding, spacing, inset, offset, gap, thickness
  colour      ...color, and every property declared `property color`
In such a binding, a number is a literal where it stands as a value: the whole value (`radius: 6`), a ternary's branch
(`width: major ? 2 : 1`), an added or subtracted offset (`Tokens.menuIconSize + 4`), an argument of Qt.size, Qt.point, Qt.rect,
Math.max or Math.min, a `||` or `??` fallback, the right operand of `&&` (`shown && 24`), a product of numbers alone
(`24 * 1`, judged by its value). A factor or a divisor of anything else (`Tokens.spacingLg * 3`, `width / 2`), a comparison's
term, an index and an argument of any other function are arithmetic or logic, not design values. Numbers from -1 to 1 are
allowed (a hairline, a flag, an off state); for opacity and scale, only 0, 1 and -1 (states and a mirror). A binding written as
a block (`width: { return wide ? 240 : 120 }`) or as a function it calls (`(function () { return 24; })()`) is read by the
values it returns and the values of its locals (a for loop's counter and the functions it defines excepted).
Anywhere in the code, outside comments:
  colour      "#rrggbb" in any quotes, Qt.rgba/hsla/hsva/rgb of literal numbers; in a colour binding, a named colour in any
              quotes ("white", "Red"; "transparent" is not a colour)
  opacity     a literal alpha given to withAlpha(), Qt.alpha() or a computed Qt.rgba/hsla/hsva (not 0 or 1)
Only QML is read as QML: a handler, a function and an object literal (`{x: 0, y: 24}`) are code and data; their colours and
alphas are still read. An object under an import alias (`qqc.Button { }`) is QML.

Exceptions: ALLOWED below (a file and how many colour literals it may hold, with the reason), or a comment on the line naming
the kinds it excepts and why: `// literal-ok radius: concentric with the menu's 12 at a 5 inset (spec)`.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("ui/Grassfield", "shell", "apps")
SKIP = {"ui/Grassfield/Ui/Tokens.qml"}
KINDS = ("radius", "font", "duration", "opacity", "scale", "geometry", "colour")
MARK = re.compile(r"\bliteral-ok\s+(?P<kinds>[a-z]+(?:\s*,\s*[a-z]+)*)\s*:\s*\S.{8,}")

NAME_KINDS = (
    ("radius", re.compile(r"[rR]adius$")),
    ("font", re.compile(r"(?:^|[a-z])(?:[pP]ixelSize|[pP]ointSize|[lL]etterSpacing|[wW]ordSpacing|[lL]ineHeight|[fF]ontSize)$")),
    ("duration", re.compile(r"[dD]uration$")),
    ("opacity", re.compile(r"[oO]pacity$")),
    ("scale", re.compile(r"^scale$")),
    ("geometry", re.compile(r"^[xy]$|[wW]idth$|[hH]eight$|[sS]ize$|[mM]argins?$|[pP]adding$|[sS]pacing$|[iI]nset$|[oO]ffset$"
                            r"|[gG]ap$|[tT]hickness$")),
    ("colour", re.compile(r"[cC]olou?r$")),
)
# Names that end like a measure but hold logic.
LOGIC = {"stepSize", "pageSize", "batchSize", "cacheSize", "fileSize", "totalSize", "maxSize", "minSize", "historySize",
         "bufferSize", "chunkSize", "fontSizeMode", "fillWidth", "fillHeight"}

STATEMENT = re.compile(r"^\s*(?:(?:readonly|required|default)\s+)*(?:property\s+(?P<type>[\w.<>]+)\s+)?"
                       r"(?P<name>[A-Za-z_][\w.]*)\s*:(?P<expr>.*)$", re.S)
TOKEN = re.compile(r"\s*(?:(?P<num>(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)"
                   r"|(?P<str>\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"
                   r"|(?P<name>[A-Za-z_$][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*)*)"
                   r"|(?P<op>===|!==|==|!=|<=|>=|&&|\|\||\?\?|\?\.|=>|\.\.\.|[-+*/%?:<>!=&|^~()\[\],{}.;]))")
MULTIPLY = {"*", "/", "%"}
COMPARE = {"<", ">", "<=", ">=", "==", "===", "!=", "!==", "!"}
# Functions whose arguments are in the unit of the result: a number in them is a value like any other.
UNIT_CALLS = {"Qt.size", "Qt.point", "Qt.rect", "Math.max", "Math.min", "Math.round", "Math.floor", "Math.ceil", "Math.abs"}
COLOUR = re.compile(r"([\"'`])#[0-9A-Fa-f]{3,8}\1"
                    r"|Qt\.(?:rgba|hsla|hsva|rgb)\(\s*-?[0-9.]+\s*,\s*-?[0-9.]+\s*,\s*-?[0-9.]+\s*(?:,\s*-?[0-9.]+\s*)?\)")
ALPHA_CALL = re.compile(r"(?<![\w.])(?:(?:[\w.]+\.)?withAlpha|Qt\.alpha|Qt\.rgba|Qt\.hsla|Qt\.hsva)\s*\(")
NAMED = re.compile(r"([\"'`])[A-Za-z]+\1")

# Colour literals that stay, by file: {path: (how many, why)}. A file holding more fails, so a new literal there is caught too.
ALLOWED = {
    "ui/Grassfield/Ui/Appearance.qml": (3, "the dev-only glyph markers of tests/visual (never drawn in production)"),
    "ui/Grassfield/Ui/TintedIcon.qml": (1, "black as the neutral default of a tint property the host sets"),
    "ui/Grassfield/Ui/IconEffect.qml": (1, "black as the neutral default of a tint property the host sets"),
    "ui/Grassfield/Ui/FolderPlate.qml": (1, "black when no mode tint is set (the plate's own fallback)"),
    "shell/desktop/WallpaperSlot.qml": (1, "black as the neutral default of a colour property the host sets"),
    "shell/saver/SaverSlides.qml": (1, "black as the fill of a prepared slide's empty border (a picture, not UI)"),
    "ui/Grassfield/Ui/WindowGlyph.qml": (1, "black as an ink whose alpha is a token (window.glyphOpacity)"),
    "ui/Grassfield/Ui/WindowLight.qml": (2, "black as an ink whose alpha is a token (window.pressedOpacity, window.lightBorderOpacity)"),
    "ui/Grassfield/Ui/Material.qml": (1, "black as the shadow cut-out mask (a mask, never drawn)"),
}


def split_comments(text):
    """(code, comments): the source with its comments blanked (strings and line breaks kept), and each line's comment text."""
    code, comments = [], {}
    line, i, n = 1, 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'`":
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == "\\":
                    j += 1
                elif text[j] == "\n" and c != "`":
                    break
                j += 1
            chunk = text[i:j + 1]
            code.append(chunk)
            line += chunk.count("\n")
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            comments[line] = comments.get(line, "") + text[i:j]
            code.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k, part in enumerate(text[i:j].split("\n")):
                comments[line + k] = comments.get(line + k, "") + part
            code.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            line += text[i:j].count("\n")
            i = j
        else:
            code.append(c)
            line += c == "\n"
            i += 1
    return "".join(code), comments


def opening_kind(head):
    """What a `{` opens in QML, from the statement before it: an object, a group or `X on y` (QML), or a block (JavaScript)."""
    head = head.strip()
    if not head or re.search(r"(?:^|[\s:,\[(])(?:[A-Za-z_]\w*\.)*[A-Z]\w*$", head) or re.search(r"\bon\s+[\w.]+$", head) \
            or re.fullmatch(r"[a-z]\w*(?:\.[a-z]\w*)*", head):
        return "qml"
    return "js"


BINDING_HEAD = re.compile(r"^\s*(?:(?:readonly|required|default)\s+)*(?:property\s+[\w.<>]+\s+)?[A-Za-z_][\w.]*\s*:\s*$")
RETURN = re.compile(r"\breturn\b(?P<expr>[^;{}]*)")
# A local's value in a binding's block (`const w = 24; return w`), a for loop's counter excepted.
LOCAL = re.compile(r"\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=(?!=)(?P<expr>[^;{}]*)")
BINDING_PREFIX = re.compile(r"^\s*(?:(?:readonly|required|default)\s+)*(?:property\s+[\w.<>]+\s+)?[A-Za-z_][\w.]*\s*:")
FUNCTION_OPEN = re.compile(r"(?:\bfunction\b\s*[\w$]*\s*\([^()]*\)|=>)\s*$")
NESTED_FUNCTION = re.compile(r"(?:\bfunction\b\s*[\w$]*\s*\([^()]*\)|=>)\s*\{")


def without_inner_functions(body):
    """The block with the bodies of the functions it defines blanked (their returns are theirs, not the binding's)."""
    chars = list(body)
    for m in NESTED_FUNCTION.finditer(body):
        level, j = 0, m.end() - 1
        while j < len(body):
            level += (body[j] == "{") - (body[j] == "}")
            if level == 0:
                break
            j += 1
        for k in range(m.end(), min(j, len(chars))):
            if chars[k] != "\n":
                chars[k] = " "
    return "".join(chars)


def statements(code):
    """[(text, [line of each character])] of the QML statements of a comment-free source (JavaScript blocks and object
    literals left out; an object literal inside an expression stands as OBJ). A binding written as a block
    (`width: { return wide ? 240 : 120 }`) gives one statement per value it returns."""
    out = []
    stack = []                       # (kind, saved text, saved lines, saved depth)
    text, lines, depth = [], [], 0
    line, i, n = 1, 0, len(code)
    block = None                     # the JavaScript block of a binding: {"head", "head_lines", "text", "lines", "level"}

    def keep(chunk):
        if block is not None:
            block["text"].extend(chunk)
            block["lines"].extend([line] * len(chunk))

    def returned():
        body = without_inner_functions("".join(block["text"]))
        values = [m for m in RETURN.finditer(body)]
        values += [m for m in LOCAL.finditer(body) if not re.search(r"\bfor\s*\(\s*$", body[:m.start()])]
        for m in values:
            if m.group("expr").strip():
                out.append((block["head"] + m.group("expr"), block["head_lines"] + block["lines"][m.start("expr"):m.end("expr")]))

    def flush():
        nonlocal text, lines
        if "".join(text).strip():
            out.append(("".join(text), lines))
        text, lines = [], []

    def continues(at):
        """Does the statement go on after the line break at `at` (an operator at the end, or at the start of the next line)?"""
        before = "".join(text).rstrip()
        after = code[at + 1:code.find("\n", at + 1) if code.find("\n", at + 1) >= 0 else n].lstrip()
        return bool(before) and (before[-1] in "?:+-*/%&|=<>,([.!" or (after[:1] and after[0] in "?:+-*/%&|.)],"))

    while i < n:
        c = code[i]
        in_js = bool(stack) and stack[-1][0] == "js"
        if c in "\"'`":
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            if not in_js:
                text.extend(code[i:j + 1])
                lines.extend([line] * (j + 1 - i))
            else:
                keep(code[i:j + 1])
            line += code[i:j + 1].count("\n")
            i = j + 1
            continue
        if c == "{":
            if in_js:
                keep(c)
                stack.append(("js", None, None, 0))
            else:
                head = "".join(text)
                inner = depth > 0 and re.search(r"[(\[,:?=]\s*$|^\s*$|return\s*$", head) and not re.search(r"[A-Z]\w*\s*$", head)
                if inner:
                    kind = "js"
                elif depth == 0:
                    # `name: {` is a binding or a handler written as a block (JavaScript); `name: Type {` an object.
                    after = head.split(":")[-1]
                    kind = "js" if ":" in head and not after.strip() else opening_kind(after)
                else:
                    kind = opening_kind(re.split(r"[(\[,]", head)[-1])
                if depth == 0:
                    if kind == "js" and block is None and BINDING_HEAD.match(head):
                        block = {"head": head, "head_lines": list(lines), "text": [], "lines": [], "level": len(stack)}
                    stack.append((kind, [], [], 0))
                else:
                    # A function called in a binding (`width: (function() { return 24; })()`) is read by what it returns.
                    prefix = BINDING_PREFIX.match(head)
                    if kind == "js" and block is None and prefix and FUNCTION_OPEN.search(head):
                        block = {"head": prefix.group(0), "head_lines": list(lines[:prefix.end()]), "text": [], "lines": [],
                                 "level": len(stack)}
                    stack.append((kind, text + list(" OBJ "), lines + [line] * 5, depth))
                text, lines, depth = [], [], 0
        elif c == "}":
            if not in_js:
                flush()
            if stack:
                _kind, saved, saved_lines, saved_depth = stack.pop()
                if block is not None and len(stack) == block["level"]:
                    returned()
                    block = None
                else:
                    keep(c)
                if saved is not None and not (stack and stack[-1][0] == "js"):
                    text, lines, depth = saved, saved_lines, saved_depth
        elif in_js:
            keep(c)
        elif c in "([":
            depth += 1
            text.append(c)
            lines.append(line)
        elif c in ")]":
            depth = max(0, depth - 1)
            text.append(c)
            lines.append(line)
        elif c == ";" and depth == 0:
            flush()
        elif c == "\n":
            if depth == 0 and not continues(i):
                flush()
            else:
                text.append(" ")
                lines.append(line)
        else:
            text.append(c)
            lines.append(line)
        line += c == "\n"
        i += 1
    flush()
    return out


def kind_of(name, declared, strings=frozenset()):
    """The kind of a property, or None: a declared colour is a colour; a declared string (an accent's name, a key of a token
    table such as `tileColor`) is not, wherever it is bound."""
    if declared == "color":
        return "colour"
    last = name.split(".")[-1]
    if declared == "string" or last in strings or name.startswith("on") and name[2:3].isupper() or last in LOGIC or last == "id":
        return None
    for kind, rx in NAME_KINDS:
        if rx.search(last):
            return kind
    return None


def tokens_of(expr, lines, offset):
    out, i = [], 0
    while i < len(expr):
        m = TOKEN.match(expr, i)
        if not m or m.end() == i:
            i += 1
            continue
        kind = m.lastgroup
        start = m.start(kind)
        out.append((kind, m.group(kind).replace(" ", ""), lines[min(offset + start, len(lines) - 1)]))
        i = m.end()
    return out


def enclosures(tokens, i):
    """The brackets around token i, innermost first: "[" for an index or a list, a function's name for its arguments, or
    "*" for a parenthesised group that is multiplied or divided, "" for any other group."""
    out, level = [], 0
    for j in range(i - 1, -1, -1):
        value = tokens[j][1]
        if value in (")", "]"):
            level += 1
        elif value in ("(", "["):
            if level:
                level -= 1
                continue
            if value == "[":
                out.append("[")
            elif j > 0 and tokens[j - 1][0] == "name":
                out.append(tokens[j - 1][1])
            else:
                depth, k = 0, j
                while k < len(tokens):
                    depth += tokens[k][1] == "(" or -(tokens[k][1] == ")")
                    if depth == 0:
                        break
                    k += 1
                after = tokens[k + 1][1] if k + 1 < len(tokens) else None
                before = tokens[j - 1][1] if j > 0 else None
                out.append("*" if after in MULTIPLY or before in MULTIPLY else "")
    return out


def numeric_product(tokens, i):
    """The value of the product or quotient token i stands in when every operand is a number (`24 * 1`), with the index of
    its first operand; None when an operand is anything else (`Tokens.spacingLg * 3`, `(w - width) / 2 * 2`)."""
    first = last = i
    while first >= 2 and tokens[first - 1][1] in MULTIPLY:
        if tokens[first - 2][0] != "num":
            return None
        first -= 2
    while last + 2 < len(tokens) and tokens[last + 1][1] in MULTIPLY:
        if tokens[last + 2][0] != "num":
            return None
        last += 2
    value = float(tokens[first][1])
    for k in range(first + 2, last + 1, 2):
        operand, op = float(tokens[k][1]), tokens[k - 1][1]
        if op == "*":
            value *= operand
        elif operand:
            value = value / operand if op == "/" else value % operand
    return first, value


def value_hits(tokens, kind):
    """[(line, excerpt)] of the numbers (or, in a colour binding, the named colours) that stand as values in an expression."""
    hits = []
    for i, (tkind, value, line) in enumerate(tokens):
        if tkind not in ("num", "str"):
            continue
        prev = tokens[i - 1][1] if i > 0 else None
        nxt = tokens[i + 1][1] if i + 1 < len(tokens) else None
        sign = 1
        if prev in ("-", "+") and (i < 2 or tokens[i - 2][0] == "op" and tokens[i - 2][1] not in (")", "]")):
            sign = -1 if prev == "-" else 1
            prev = tokens[i - 2][1] if i >= 2 else None
        # `shown && 24` gives 24: the right operand of && is a value, its left one a condition.
        if prev in COMPARE or nxt in COMPARE or nxt == "&&" or prev == ".":
            continue
        # A factor or a divisor of something else is arithmetic; a number times a number (`24 * 1`) is still a literal, judged
        # once, by its value.
        product = None
        if tkind == "num" and (prev in MULTIPLY or nxt in MULTIPLY):
            product = numeric_product(tokens, i)
            if product is None or product[0] != i:
                continue
        # An index, a factor in parentheses, or an argument of a function that changes the unit (Math.sin, a lookup).
        if any(e in ("[", "*") or e and e not in UNIT_CALLS for e in enclosures(tokens, i)):
            continue
        if tkind == "str":
            if kind == "colour" and NAMED.fullmatch(value) and value[1:-1].lower() != "transparent":
                hits.append((line, value))
            continue
        if kind == "colour":
            continue
        number = sign * (product[1] if product else float(value))
        if kind in ("opacity", "scale"):
            if number not in (0.0, 1.0, -1.0):
                hits.append((line, value))
        elif abs(number) > 1:
            hits.append((line, value))
    return hits


def alpha_hits(code):
    """[(line, excerpt)] of the literal alphas given to withAlpha(), Qt.alpha() or a computed Qt.rgba/hsla/hsva."""
    hits = []
    for m in ALPHA_CALL.finditer(code):
        start = m.end()
        level, j, args, arg_start = 1, start, [], start
        while j < len(code) and level:
            ch = code[j]
            if ch in "([{":
                level += 1
            elif ch in ")]}":
                level -= 1
            elif ch == "," and level == 1:
                args.append(code[arg_start:j])
                arg_start = j + 1
            j += 1
        args.append(code[arg_start:j - 1])
        if len(args) < 2 or COLOUR.match(code, m.start()):
            continue
        last = args[-1].strip()
        if re.fullmatch(r"(?:\d+\.?\d*|\.\d+)", last) and float(last) not in (0.0, 1.0):
            hits.append((code.count("\n", 0, j) + 1, m.group(0) + "..., " + last + ")"))
    return hits


def scan_text(text, strings=frozenset()):
    """[(line number, kind, excerpt)] of the literals of one QML source (lines marked for their kind excepted); `strings`
    are the names declared `property string` in the tree."""
    code, comments = split_comments(text)
    source = text.splitlines()
    hits = []
    for stmt, lines in statements(code):
        m = STATEMENT.match(stmt)
        if not m:
            continue
        kind = kind_of(m.group("name"), m.group("type"), strings)
        if not kind:
            continue
        offset = m.start("expr")
        for line, _value in value_hits(tokens_of(m.group("expr"), lines, offset), kind):
            hits.append((line, kind, source[line - 1].strip()[:120]))
    for number, code_line in enumerate(code.split("\n"), 1):
        for _ in COLOUR.finditer(code_line):
            hits.append((number, "colour", source[number - 1].strip()[:120]))
    for line, _excerpt in alpha_hits(code):
        hits.append((line, "colour", source[line - 1].strip()[:120]))
    kept = []
    for line, kind, excerpt in sorted(hits):
        mark = MARK.search(comments.get(line, ""))
        if mark and kind in {k.strip() for k in mark.group("kinds").split(",")}:
            continue
        kept.append((line, kind, excerpt))
    return kept


def files(root):
    for base in ROOTS:
        for dirpath, _dirs, names in os.walk(root / base):
            for name in sorted(names):
                if name.endswith(".qml"):
                    rel = (Path(dirpath) / name).relative_to(root).as_posix()
                    if rel not in SKIP:
                        yield rel


DECLARED = re.compile(r"\bproperty\s+([\w.<>]+)\s+(\w+)")
BUILT_IN_COLOURS = {"color", "fillColor", "strokeColor", "selectionColor", "selectedTextColor", "placeholderTextColor",
                    "styleColor", "linkColor"}


def string_names(sources):
    """The names the tree only ever declares `property string` (an accent's name such as `tileColor`): a key, not a colour.
    A name also declared with another type somewhere (`size`, `color`), or a built-in colour, stays a design property."""
    types = {}
    for text in sources:
        for declared, name in DECLARED.findall(text):
            types.setdefault(name, set()).add(declared)
    return frozenset(name for name, kinds in types.items() if kinds == {"string"} and name not in BUILT_IN_COLOURS)


def check(root):
    problems, scanned = [], 0
    sources = {rel: (root / rel).read_text(encoding="utf-8") for rel in files(root)}
    strings = string_names(sources.values())
    for rel, text in sources.items():
        scanned += 1
        hits = scan_text(text, strings)
        colours = [h for h in hits if h[1] == "colour"]
        allowed, _why = ALLOWED.get(rel, (0, ""))
        for number, kind, excerpt in hits:
            if kind != "colour":
                problems.append(f"{rel}:{number}: literal {kind}: {excerpt}")
        if len(colours) > allowed:
            for number, _kind, excerpt in colours:
                problems.append(f"{rel}:{number}: literal colour ({len(colours)} in the file, {allowed} allowed): {excerpt}")
    return problems, scanned


SAMPLES = {
    "radius": ("Rectangle { radius: 6 }", 1),
    "font size": ("Text { font.pixelSize: 13 }", 1),
    "animation duration": ("NumberAnimation { duration: 120 }", 1),
    "opacity": ("Item { opacity: 0.5 }", 1),
    "margins": ("Item { anchors.margins: 12 }", 1),
    "left margin": ("Item { anchors.leftMargin: 8 }", 1),
    "width": ("Item { width: 24; height: 24 }", 2),
    "x": ("Item { x: 24 }", 1),
    "border width": ("Rectangle { border.width: 2 }", 1),
    "hex colour": ('Rectangle { color: "#1B1B1F" }', 1),
    "rgba colour": ("Rectangle { color: Qt.rgba(0, 0, 0, 0.5) }", 1),
    "named colour": ('Rectangle { color: "white" }', 1),
    "token": ("Rectangle { radius: Tokens.radiusControl; width: Tokens.spacingLg * 3 }", 0),
    "hairline and states": ('Rectangle { border.width: 1; opacity: 0; height: 1; x: 0; color: "transparent" }', 0),
    "timer": ("Timer { interval: 1500 }", 0),
    "comment": ("Item { // radius: 6 in the old design\n}", 0),
    "url with //": ('Image { source: "file:///x.png"; width: 40 }', 1),
    # The escapes of step 2's review (ADR-0039 step 3).
    "ternary": ("Rectangle { width: major ? 2 : 1 }", 1),
    "token plus an offset": ("Icon { size: Tokens.menuItemHeight - 6 }", 1),
    "Layout": ("Item { Layout.preferredWidth: 120 }", 1),
    "custom property": ("Item {\n    readonly property int pillInset: 2\n}", 1),
    "declared colour": ('Item { property color tint: "black" }', 1),
    "literal alpha": ("Rectangle { color: Appearance.withAlpha(Appearance.colors.text, 0.37) }", 1),
    "computed rgba": ("Item { property color c: Qt.rgba(t.r, t.g, t.b, 0.5) }", 1),
    "font group": ("Text {\n    font {\n        pixelSize: 13\n        weight: Font.Medium\n    }\n}", 1),
    "anchors group": ("Item { anchors { fill: parent; margins: 8 } }", 1),
    "scale": ("Item { scale: 0.96 }", 1),
    "source size": ("Image { sourceSize: Qt.size(32, 32) }", 2),
    "source size width": ("Image { sourceSize.width: 64 }", 1),
    "capitalised colour": ('Rectangle { color: "Red" }', 1),
    "stroke": ('ShapePath { strokeColor: "red"; strokeWidth: 3 }', 2),
    "ternary colour": ('Text { color: dark ? "white" : Appearance.colors.text }', 1),
    "multi-line ternary": ("Item {\n    width: wide\n        ? 240\n        : Tokens.settingsPickerWidth\n}", 1),
    "list of objects": ("Item { transform: [Scale { xScale: 2 }, Translate { x: 12 }] }", 1),
    "fallback": ("Item { width: given || 24 }", 1),
    "max": ("Item { width: Math.max(120, label.implicitWidth) }", 1),
    # Arithmetic, logic and data, not design values.
    "factor and divisor": ("Item { x: parent.width / 2 - width / 2; height: Tokens.spacingSm * 3 }", 0),
    "condition": ("Item { width: index % 3 === 0 ? Tokens.spacingSm : Tokens.spacingXs }", 0),
    "function argument": ("Item { width: Math.round(Tokens.settingsPopupInset * 2) / 2; height: list.itemAt(3).height }", 0),
    "object literal in a function": ("Item {\n    function corner() {\n        return {x: 0, y: 24};\n    }\n}", 0),
    "multi-line object literal": ("Item {\n    function corner() {\n        return {\n            x: 0,\n            y: 24\n        };\n    }\n}", 0),
    "handler": ("Item { onClicked: { width = 24; } }", 0),
    "model data": ('ListView { model: [{id: "a", width: 120}] }', 0),
    "step size": ("Slider { stepSize: 5 }", 0),
    "z order": ("Item { z: 2 }", 0),
    "alpha token": ("Item { property color c: Appearance.withAlpha(Appearance.colors.text, Tokens.disabledOpacity) }", 0),
    "behaviour on a value": ("Item { Behavior on width { NumberAnimation { duration: Tokens.motionFast } } }", 0),
    # The marker excepts the kinds it names, from a comment only.
    "marked": ("Rectangle { radius: 7 // literal-ok radius: concentric with a 12 menu at a 5 inset, see the spec\n}", 0),
    "marked for another kind": ("Rectangle { radius: 7; width: 30 // literal-ok radius: concentric with a 12 menu, the spec\n}", 1),
    "marker in a string": ('Text { text: "literal-ok radius: not a comment at all"; radius: 7 }', 1),
    # The review of step 3 (ADR-0039 step 4).
    "single-quoted hex": ("Rectangle { color: '#FFFFFF' }", 1),
    "template hex": ("Rectangle { color: `#FFFFFF` }", 1),
    "binding block": ("Item { width: { return wide ? 240 : 120 } }", 2),
    "multi-line binding block": ("Item {\n    width: {\n        if (wide)\n            return 240;\n        return Tokens.settingsPickerWidth;\n    }\n}", 1),
    "block with an inner block": ("Item {\n    height: {\n        for (const r of rows) {\n            if (r.big)\n                return 64;\n        }\n        return Tokens.menuItemHeight;\n    }\n}", 1),
    "handler with a return": ("Item { onClicked: { return 24; } }", 0),
    "literal times one": ("Item { width: 24 * 1; radius: 6 / 1 }", 2),
    "half a pixel": ("Item { x: Math.round((preview.width - width) / 2 * 2) / 2; width: 0.5 * 2 }", 0),
    "and value": ("Item { width: shown && 24 }", 1),
    "and condition": ("Item { width: shown && count > 3 ? Tokens.spacingLg : Tokens.spacingSm }", 0),
    "aliased type": ("import QtQuick.Controls as qqc\nItem {\n    qqc.Button { width: 30 }\n}", 1),
    # The review of step 4 (ADR-0039 step 5).
    "inner function's return": ("Item {\n    width: {\n        const pick = function () { return 24; };\n        return pick() * Tokens.spacingSm;\n    }\n}", 0),
    "inner arrow's return": ("Item { height: { const f = r => { return 64; }; return rows.map(f).length * Tokens.menuItemHeight; } }", 0),
    "value through a local": ("Item { width: { const w = 24; return w; } }", 1),
    "loop counter": ("Item { width: { let s = 0; for (let i = 2; i < n; i++) s += Tokens.spacingSm; return s; } }", 0),
    "called function": ("Item { width: (function () { return 24; })() }", 1),
    "backtick colour": ("Rectangle { color: `red` }", 1),
    # Keys, units and groups the second pass of the review raised.
    "accent key": ('Item { property string tileColor: "blue" }', 0),
    "accent key in an index": ('Rectangle { color: Tokens.colorAccentLight[keys[id] || "graphite"] }', 0),
    "phase in radians": ("Item { y: h * (base - amp * Math.sin(phase + 2.0)) }", 0),
    "count of paddings": ("Item { implicitWidth: label.width + (actions.length > 0 ? 4 : 3) * Tokens.storeNoticePadding }", 0),
    "rounded offset": ("Item { width: Math.round(label.implicitWidth + 12) }", 1),
    "glow alpha": ("GradientStop { color: Qt.alpha(root.art.sun, 0.55) }", 1),
}


def selftest():
    bad = 0
    for name, (src, want) in SAMPLES.items():
        got = scan_text(src)
        if len(got) != want:
            print(f"selftest FAIL: {name}: want {want}, got {len(got)} {got}: {src!r}")
            bad += 1
    if bad:
        return 1
    print(f"qml_literals selftest: {len(SAMPLES)} cases ok")
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    problems, scanned = check(root)
    if scanned == 0:
        print("qml_literals: no QML file scanned")
        return 1
    if problems:
        print("qml_literals: a design value written as a literal; use a token (or `literal-ok <kind>: <reason>` after review):")
        print("\n".join(problems))
        return 1
    print(f"qml_literals: {scanned} QML files, no literal design value ({sum(n for n, _ in ALLOWED.values())} colour literals allowed in {len(ALLOWED)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
