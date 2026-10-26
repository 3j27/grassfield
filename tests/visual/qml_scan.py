#!/usr/bin/env python3
"""Structural scan of QML for the A2 role cross-check (tests/visual/test_contrast_tokens.py).

Finds every place where the contrast of a text colour can change, so that the role table cannot silently miss one:

  secondary  a read of the textSecondary token: Appearance.colors.textSecondary, a palette alias (readonly property var pal:
             Appearance.colors; const c = Appearance.darkColors; Tokens.colorDark), pal.textSecondary and pal["textSecondary"]
  danger     the same for the danger token
  alpha      a colour derived from a text token: withAlpha(...), Qt.alpha/darker/lighter/tint/rgba/hsla/hsva(...) whose argument
             reads text, accentText, textSecondary or danger (directly, through an alias or with brackets)
  dynamic    a palette read with a computed key: colors[name]
  opacity    a Text-like item (Text, TextInput, TextEdit, TextField, Label, or an instance of a component that contains one)
             whose own opacity or an ancestor's opacity in the file is a literal below 1
  opacity-dynamic  the same with a computed value (a fade driven by state: its steady value cannot be read from the source)

Inside shell/security/ (the lock screen and the authorization dialog sit on their own backdrops, so every colour read there must
be accounted for), every other palette read counts too, whatever the palette spelling (root.colors.x, colors.x, an alias,
Appearance.darkColors.x, Tokens.colorDark.x, brackets):
  primary    a read of a primary text token (text, accentText, fieldText) outside a derived colour (those are `alpha`)
  backdrop   a read of any other token (shadow, fill, accent, materialTint, ...): a scrim, fill, ring or shadow the text sits on

Comments are removed and string literals blanked before objects and aliases are looked for; objects are found by braces (not by
indentation), so one-line items (Text { text: x; opacity: 0.5 }), `opacity :` and nested ancestors are seen. Limits: an opacity
set from another file (a component instance given an opacity by its user) counts only when the component contains a Text-like item
in the scanned tree; a palette passed through a function argument or a JS object is not followed.
"""
import os
import re

TEXT_TYPES = {"Text", "TextInput", "TextEdit", "TextField", "Label"}
PALETTE = r"(?:Appearance\.(?:dark|base)?[cC]olors|Tokens\.color(?:Dark|Light))"
TEXT_TOKENS = ("text", "accentText", "selectionText", "textSecondary", "danger")
PRIMARY_TOKENS = ("text", "accentText", "selectionText", "fieldText")
# Files whose every palette read is classified (primary/backdrop), not only the secondary/danger/derived ones.
ALL_READS_DIRS = ("shell/security/",)
DERIVE = re.compile(r"\b(?:withAlpha|Qt\.(?:alpha|darker|lighter|tint|rgba|hsla|hsva))\s*\(")
OBJECT = re.compile(r"(?<![\w.])([A-Z][\w.]*)\s*\{")
OPACITY = re.compile(r"(?:^|[;{}\s])opacity\s*:\s*([^;\n}]*)")
DECL = re.compile(r"(?:property\s+\w+\s+(\w+)\s*:|(?:const|let|var)\s+(\w+)\s*=|(?<![\w.])(\w+)\s*:)\s*([^;\n]+)")


def strip(src, blank_strings):
    """Source without comments (same offsets); string literals blanked when `blank_strings`, kept otherwise."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            j = min(j, n - 1)
            out.append(c + (re.sub(r"[^\n]", " ", src[i + 1:j]) if blank_strings else src[i + 1:j]) + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def palette_aliases(code):
    """Identifiers bound to a palette object (`property var pal: Appearance.colors`, `const c = Tokens.colorDark`, ternaries
    between palettes, aliases of aliases), resolved to a fixpoint."""
    names = set()

    def is_palette(expr):
        parts = [p.strip() for p in re.split(r"[?:]", expr)] if "?" in expr else [expr.strip()]
        tail = [p for p in parts[-2:] if p] if "?" in expr else parts
        return bool(tail) and all(re.fullmatch(PALETTE, p) or p in names for p in tail)

    changed = True
    while changed:
        changed = False
        for m in DECL.finditer(code):
            name = m.group(1) or m.group(2) or m.group(3)
            if name not in names and is_palette(m.group(4)):
                names.add(name)
                changed = True
    return names


def palette_regex(aliases):
    """Regex source of a palette: Appearance.colors, Tokens.colorDark/Light, any identifier ending in colors/Colors, or a
    resolved alias."""
    alt = [PALETTE, r"\b\w*[cC]olors"] + [r"(?<![\w.])" + re.escape(a) for a in sorted(aliases)]
    return "(?:" + "|".join(alt) + ")"


def token_reads(aliases):
    """({token: regex reading it from a palette}, regex of a palette read with a computed key)."""
    pal = palette_regex(aliases)
    reads = {t: re.compile(r"%s\s*(?:\.\s*%s\b|\[\s*[\"']%s[\"']\s*\])" % (pal, t, t)) for t in TEXT_TOKENS}
    return reads, re.compile(r"%s\s*\[\s*[^\"'\s\]]" % pal)


def any_reads(aliases):
    """Regex of a palette read of any token by name (`pal.token` or `pal["token"]`); the token is group 1 or 2."""
    return re.compile(r"%s\s*(?:\.\s*(\w+)\b|\[\s*[\"'](\w+)[\"']\s*\])" % palette_regex(aliases))


def balanced(code, start):
    """Text from the `(` at `start` to its matching `)` (or the end)."""
    depth = 0
    for i in range(start, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return code[start:i + 1]
    return code[start:]


class Obj:
    def __init__(self, typename, start, parent):
        self.type = typename
        self.start = start
        self.parent = parent
        self.end = None
        self.own = ""


def parse_objects(code):
    """Every QML object (`Type {`) of the source with its parent; `own` is its text without the content of nested braces."""
    marks = {m.end() - 1: m.group(1) for m in OBJECT.finditer(code)}
    objs, frames = [], []
    for i, c in enumerate(code):
        if c == "{":
            if i in marks:
                parent = next((f for f in reversed(frames) if f is not None), None)
                o = Obj(marks[i], i, parent)
                objs.append(o)
                frames.append(o)
            else:
                frames.append(None)
        elif c == "}" and frames:
            f = frames.pop()
            if f is not None:
                f.end = i
    for o in objs:
        end = o.end if o.end is not None else len(code)
        buf, depth = [], 0
        for i in range(o.start + 1, end):
            c = code[i]
            if c == "{":
                depth += 1
                buf.append(" ")
            elif c == "}":
                depth -= 1
                buf.append(" ")
            else:
                buf.append(c if depth == 0 else " ")
        o.own = "".join(buf)
    return objs


def opacity_of(own):
    """None, 'literal' (a number below 1) or 'dynamic' (anything else that is not 1) for the item's own opacity property."""
    m = OPACITY.search(own)
    if not m:
        return None
    value = m.group(1).strip()
    if re.fullmatch(r"1(?:\.0*)?", value):
        return None
    if re.fullmatch(r"(?:0?\.\d+|0(?:\.0*)?)", value):
        return "literal"
    return "dynamic"


def text_components(root_dir, subdirs):
    """Type names of the QML files that contain a Text-like object (their instances count as text items)."""
    names = set()
    for sub in subdirs:
        for d, _, files in os.walk(os.path.join(root_dir, sub)):
            for name in files:
                if name.endswith(".qml") and name[0].isupper():
                    with open(os.path.join(d, name), encoding="utf-8") as f:
                        objs = parse_objects(strip(f.read(), True))
                    if any(o.type.split(".")[-1] in TEXT_TYPES for o in objs):
                        names.add(name[:-4])
    return names


def scan_source(src, rel, components=frozenset()):
    """{(rel, class): count} of the contrast-relevant uses in one QML file's source."""
    found = {}

    def add(cls, n=1):
        found[(rel, cls)] = found.get((rel, cls), 0) + n

    if os.path.basename(rel) == "Tokens.qml":
        return found
    code = strip(src, True)
    raw = strip(src, False)
    aliases = palette_aliases(code)
    reads, dynamic = token_reads(aliases)

    def live(m):
        # A match whose first character is code, not the content of a string literal (blanked to spaces in `code`).
        return code[m.start()] == raw[m.start()] and not raw[m.start()].isspace()

    for token, cls in (("textSecondary", "secondary"), ("danger", "danger")):
        n = sum(1 for m in reads[token].finditer(raw) if live(m))
        if n:
            add(cls, n)
    n = sum(1 for m in dynamic.finditer(raw) if live(m))
    if n:
        add("dynamic", n)
    derived = []  # (start, end) of every live derived-colour call
    for m in DERIVE.finditer(raw):
        if not live(m):
            continue
        call = balanced(raw, m.end() - 1)
        derived.append((m.end() - 1, m.end() - 1 + len(call)))
        if any(r.search(call) for r in reads.values()):
            add("alpha")
    if rel.replace(os.sep, "/").startswith(ALL_READS_DIRS):
        for m in any_reads(aliases).finditer(raw):
            if not live(m):
                continue
            token = m.group(1) or m.group(2)
            if token in ("textSecondary", "danger"):
                continue  # counted above (secondary, danger)
            inside = any(a <= m.start() < b for a, b in derived)
            if token in TEXT_TOKENS and inside:
                continue  # counted above (alpha)
            add("primary" if token in PRIMARY_TOKENS else "backdrop")
    for o in parse_objects(code):
        base = o.type.split(".")[-1]
        if base not in TEXT_TYPES and base not in components:
            continue
        kinds, p = [], o
        while p is not None:
            k = opacity_of(p.own)
            if k:
                kinds.append(k)
            p = p.parent
        if kinds:
            add("opacity" if "literal" in kinds else "opacity-dynamic")
    return found


def scan_tree(root_dir, subdirs=("shell", "ui/Grassfield")):
    comps = text_components(root_dir, subdirs)
    found = {}
    for sub in subdirs:
        for d, _, files in os.walk(os.path.join(root_dir, sub)):
            for name in sorted(files):
                if name.endswith(".qml"):
                    path = os.path.join(d, name)
                    with open(path, encoding="utf-8") as f:
                        src = f.read()
                    for key, n in scan_source(src, os.path.relpath(path, root_dir), comps).items():
                        found[key] = found.get(key, 0) + n
    return found


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    for (rel, cls), n in sorted(scan_tree(os.path.dirname(os.path.dirname(here))).items()):
        print("%-60s %-16s %d" % (rel, cls, n))
