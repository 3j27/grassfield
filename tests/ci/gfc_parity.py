#!/usr/bin/env python3
"""gfc/1 parity: the contract table in ADR-0007, the compositor code and the shell's consumers must agree.

  python3 -I tests/ci/gfc_parity.py [ROOT]   check the tree at ROOT (default: this repository), exit 1 on any drift
  python3 -I tests/ci/gfc_parity.py --selftest   the extractors and the comparison on small in-memory fixtures

Three views of the protocol are extracted as sets and compared:

  docs   the fenced block "gfc1" in docs/decisions/ADR-0007-shell-plugin-ipc.md (the machine-checkable table):
           event <type>: <field> ...        every field of the event (nested ones flattened; "v" and "type" are implicit)
           reply <command>: <field> ...     every field of the reply of `hyprctl <command>` (a state too big for an event)
           enum <type>.<field>: <value> ... the closed values of a field (state, reason, outcome, target)
           feature <name> ...               advertised in the capabilities event
           verb <name> ...                  hl.plugin.grassfield.<verb>
  code   compositor/src: the event types and fields come from the JSON builders (the `"type":"x"` literals, the
         appendHeader / windowEventJson calls of core/Protocol.cpp and the fields named in the builder's function body;
         a builder under a `// gfc1-reply: <command>` comment builds that reply, not an event),
         enum values from the reasonName / phaseName / outcomeName / targetName switches (and the reason literals of
         overview focus), features and verbs from the kFeature* / kLua* constants of core/Protocol.hpp.
  shell  shell/ and apps/: the event types a consumer tests (`msg.type === "x"`), the fields it reads in that function
         (a reply when the function sits under a `// gfc1-reply: <command>` comment, else the event of that type),
         the reasons and states it lists (overview/V2.js), `Capabilities.has("feature")` and the verb allowlist
         (platform/Minimized.js pluginVerbs).

Failures: code but not docs, docs but not code, and anything the shell reads that the plugin never sends (a type, a
field, a reply or its field, an enum value, a feature, a verb): a shell function that reads a reply's field out of the
event fails, since the event never carries it. A reply parser (a function under a `// gfc1-reply:` comment) fed from an
event also fails: a call to it inside a raw-event handler (`onRawEvent`, `rawEvent.connect(...)`), or a call to it or to
a helper that passes its argument to one (any depth, any file) with the event's payload (`<param>.data`, a local assigned
from it (declared, assigned or destructured), or `event.data`) in its arguments (the B1 regression of 6b3a31f: the menu bar
parsed the Stages notice as the state); `Qt.callLater(helper, payload)` counts as the call. Out of reach: a payload kept
in a property, signal or object and parsed later, a copy of a copy, other calls through function variables. The plugin sending something the shell ignores is allowed (overview-focus).
Limits: the extraction is textual. A new builder that does not use the patterns above is invisible and shows up as
"documented but not in code"; teach `code_model` the new pattern rather than loosening the comparison.
"""
import functools
import re
import sys
from pathlib import Path

ADR = "docs/decisions/ADR-0007-shell-plugin-ipc.md"
IMPLICIT = {"v", "type"}
# switch functions of the event builders -> the field they name
ENUM_FUNCS = {"reasonName": "reason", "phaseName": "state", "outcomeName": "outcome", "targetName": "target",
              "hoverStateName": "state"}


# ---- loading ----

def load(root):
    """{relative path: text} of everything the check reads."""
    root = Path(root)
    files = {}
    patterns = [("compositor/src", ("*.cpp", "*.hpp")), ("shell", ("*.js", "*.qml")), ("apps", ("*.js", "*.qml"))]
    for base, globs in patterns:
        for g in globs:
            for p in sorted((root / base).rglob(g)):
                if "/build/" not in p.as_posix():
                    files[p.relative_to(root).as_posix()] = p.read_text(encoding="utf-8", errors="replace")
    adr = root / ADR
    if adr.exists():
        files[ADR] = adr.read_text(encoding="utf-8")
    return files


# ---- model: {"events": {type: set(fields)}, "replies": {command: set(fields)}, "enums": {"type.field": set},
#              "features": set, "verbs": set} ----

def empty():
    return {"events": {}, "replies": {}, "enums": {}, "features": set(), "verbs": set()}


REPLY_MARK = re.compile(r"//\s*gfc1-reply:\s*([a-z][a-z-]*)\s*$")


def reply_mark(lines):
    """The command of a `// gfc1-reply: <command>` line in the comment block that ends `lines`, else None."""
    for line in reversed(lines):
        s = line.strip()
        if not s.startswith("//"):
            return None
        m = REPLY_MARK.match(s)
        if m:
            return m.group(1)
    return None


def docs_model(adr_text):
    m = empty()
    block = re.search(r"```gfc1\n(.*?)```", adr_text or "", re.S)
    if not block:
        return m, ["no ```gfc1 block in " + ADR]
    problems = []
    for raw in block.group(1).splitlines():
        line = raw.strip()
        if not line:
            continue
        ev = re.fullmatch(r"event ([a-z][a-z-]*):((?: [A-Za-z_]+)*)", line)
        rp = re.fullmatch(r"reply ([a-z][a-z-]*):((?: [A-Za-z_]+)+)", line)
        en = re.fullmatch(r"enum ([a-z][a-z-]*\.[a-z]+):((?: [a-z][a-z-]*)+)", line)
        ft = re.fullmatch(r"feature((?: [a-z][a-z0-9-]*)+)", line)
        vb = re.fullmatch(r"verb((?: [a-z][a-z_]*)+)", line)
        if ev:
            m["events"][ev.group(1)] = set(ev.group(2).split())
        elif rp:
            m["replies"][rp.group(1)] = set(rp.group(2).split())
        elif en:
            m["enums"][en.group(1)] = set(en.group(2).split())
        elif ft:
            m["features"] |= set(ft.group(1).split())
        elif vb:
            m["verbs"] |= set(vb.group(1).split())
        else:
            problems.append("unreadable line in the gfc1 block: " + line)
    return m, problems


def function_bodies(text):
    """[(name, body)] for lines like `    std::string name(args) {` up to the closing brace at the same indent."""
    return [(n, b) for n, b, _ in marked_bodies(text)]


def marked_bodies(text):
    """[(name, body, reply command or None)]: function_bodies plus the gfc1-reply mark of the comment above each."""
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(?:std::string_view|std::string)\s+(\w+)\(.*\)\s*(?:noexcept\s*)?\{\s*$", line)
        if not m:
            continue
        close = m.group(1) + "}"
        j = i + 1
        while j < len(lines) and lines[j].rstrip() != close:
            j += 1
        out.append((m.group(2), "\n".join(lines[i:j + 1]), reply_mark(lines[:i])))
    return out


def json_fields(text):
    return {f for f in re.findall(r'"([A-Za-z_]+)":', text) if f not in IMPLICIT}


def code_model(files):
    m = empty()
    proto_hpp = files.get("compositor/src/core/Protocol.hpp", "")
    for name in re.findall(r'kFeature\w+\s*=\s*"([a-z][a-z0-9-]*)"', proto_hpp):
        m["features"].add(name)
    for name in re.findall(r'kLua(?!Namespace)\w+\s*=\s*"([a-z][a-z_]*)"', proto_hpp):
        m["verbs"].add(name)

    for path, text in sorted(files.items()):
        if not (path.startswith("compositor/src/") and path.endswith(".cpp")):
            continue
        marked = marked_bodies(text)
        bodies = [(n, b) for n, b, _ in marked]
        by_name = {n: b for n, b in bodies}
        types = set(re.findall(r'"type":"([a-z][a-z-]*)"', text))
        for n, body, reply in marked:
            if reply:
                m["replies"].setdefault(reply, set()).update(json_fields(body))
        bodies = [(n, b) for n, b, reply in marked if not reply]
        if path.endswith("core/Protocol.cpp"):
            # appendHeader(out, "x") in a builder; windowEventJson("x", ...) shares the body of windowEventJson
            for n, body in bodies:
                for t in re.findall(r'appendHeader\(out,\s*"([a-z][a-z-]*)"\)', body):
                    m["events"].setdefault(t, set()).update(json_fields(body))
            for t in re.findall(r'windowEventJson\("([a-z][a-z-]*)"', text):
                m["events"].setdefault(t, set()).update(json_fields(by_name.get("windowEventJson", "")))
            continue
        for n, body in bodies:
            for t in set(re.findall(r'"type":"([a-z][a-z-]*)"', body)):
                # Ipc.cpp holds the hyprctl reply (capabilities + version, handled below) and its bare error reply
                m["events"].setdefault(t, set()).update(set() if path.endswith("/Ipc.cpp") else json_fields(body))
        for t in types:
            m["events"].setdefault(t, set())
        for n, field in ENUM_FUNCS.items():
            if n not in by_name:
                continue
            vals = {v for v in re.findall(r'return "([a-z][a-z-]*)";', by_name[n])}
            # the file's one event type, or with several (core/Tiling.cpp: tiling, tile-hover) the types of the event
            # builders that call the switch
            owners = types if len(types) == 1 else {
                t for _, body in bodies if re.search(r"\b%s\(" % n, body)
                for t in re.findall(r'"type":"([a-z][a-z-]*)"', body)}
            for t in owners:
                m["enums"].setdefault(t + "." + field, set()).update(vals)
    # the hyprctl reply is the capabilities event plus a trailing "version"; its failure reply is the type "error"
    ipc = files.get("compositor/src/Ipc.cpp", "")
    if re.search(r'R"\(,"version":"\)"', ipc) and "capabilities" in m["events"]:
        m["events"]["capabilities"].add("version")
    # overview focus reasons are literals passed to finish()/post() and the `.why` of the plan
    for path in ("compositor/src/OverviewFocus.cpp", "compositor/src/core/OverviewFocus.cpp"):
        text = files.get(path, "")
        vals = set()
        for line in text.splitlines():
            if re.search(r"\b(?:finish|post)\(of::Outcome::", line):
                vals |= set(re.findall(r'"([a-z][a-z]*(?:-[a-z]+)*)"', line))
            vals |= set(re.findall(r'\.why = "([a-z][a-z-]*)"', line))
            vals |= set(re.findall(r'\bapplyFallback\(\w+,\s*"([a-z][a-z-]*)"', line))
        if vals and "overview-focus" in m["events"]:
            m["enums"].setdefault("overview-focus.reason", set()).update(vals)
    return m


def enclosing_function(text, pos):
    start = text.rfind("\nfunction ", 0, pos) + 1
    end = text.find("\n}", pos)
    return text[start:end if end >= 0 else len(text)]


def enclosing_reply(text, pos):
    """The gfc1-reply command marked above the function around `pos`, else None."""
    start = text.rfind("\nfunction ", 0, pos) + 1
    return reply_mark(text[:start].splitlines()) if start > 0 else None


def shell_model(files):
    """Same shape as the others, but a read set: what the shell consumes. Features/verbs are what it names."""
    m = empty()
    for path, text in sorted(files.items()):
        if not (path.split("/")[0] in ("shell", "apps") and path.endswith((".js", ".qml"))):
            continue
        for found in re.finditer(r'\b(?:msg|doc)\.type\s*[!=]==\s*"([a-z][a-z-]*)"', text):
            t = found.group(1)
            body = enclosing_function(text, found.start())
            reads = {f for _, f in re.findall(r"\b(m\.front|msg|doc|m)\.([A-Za-z_]\w*)", body)}
            reply = enclosing_reply(text, found.start())
            if reply:
                m["replies"].setdefault(reply, set()).update(reads - IMPLICIT)
            else:
                m["events"].setdefault(t, set()).update(reads - IMPLICIT)
        for f in re.findall(r'\bCapabilities\.has\("([a-z][a-z0-9-]*)"\)', text):
            m["features"].add(f)
    v2 = files.get("shell/overview/V2.js", "")
    for var, field in (("states", "state"), ("reasons", "reason")):
        found = re.search(r"\bvar %s\s*=\s*\[([^\]]*)\]" % var, v2)
        if found:
            m["enums"]["overview." + field] = set(re.findall(r'"([a-z][a-z-]*)"', found.group(1)))
    mini = files.get("shell/platform/Minimized.js", "")
    found = re.search(r"\bpluginVerbs\s*=\s*\[([^\]]*)\]", mini)
    if found:
        m["verbs"] = set(re.findall(r'"([a-z][a-z_]*)"', found.group(1)))
    return m


def matching_block(text, pos):
    """(start, end) of the {...} block that opens at the first '{' at or after pos; strings and // comments skipped."""
    start = text.find("{", pos)
    if start < 0:
        return None
    depth, i, n = 0, start, len(text)
    while i < n:
        c = text[i]
        if c in "\"'`":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return start, i
        i += 1
    return None


def call_args(text, pos):
    """The argument text of the call whose '(' is at pos (up to the matching ')')."""
    depth, i = 0, pos
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[pos + 1:i]
        i += 1
    return text[pos + 1:]


def reply_parsers(files):
    """{"File.js": {function: reply command}} for the shell's reply-marked JS functions."""
    out = {}
    for path, text in files.items():
        if not (path.split("/")[0] in ("shell", "apps") and path.endswith(".js")):
            continue
        for found in re.finditer(r"(?m)^function (\w+)\(", text):
            reply = reply_mark(text[:found.start()].splitlines())
            if reply:
                out.setdefault(path.rsplit("/", 1)[-1], {})[found.group(1)] = reply
    return out


SHELL_SRC = ("shell", "apps")


def shell_sources(files):
    return {p: t for p, t in files.items() if p.split("/")[0] in SHELL_SRC and p.endswith((".js", ".qml"))}


def module_of(path):
    return path.rsplit("/", 1)[-1]


def param_names(params):
    """Identifiers of a parameter list ("event: HyprlandEvent, x = 1" -> ["event", "x"])."""
    out = []
    for part in params.split(","):
        m = re.match(r"\s*(\w+)", part)
        if m:
            out.append(m.group(1))
    return out


def resolver(path, text):
    """fn(call text before '(') -> (module, function) or None: `Alias.f` (a JS import), `Singleton.f` (a QML file of
    that name), `root.f` / bare `f` (this file)."""
    aliases = {a: f for f, a in re.findall(r'import\s+"(?:[^"]*/)?(\w+\.js)"\s+as\s+(\w+)', text)}
    here = module_of(path)

    def resolve(qualifier, name):
        if not qualifier or qualifier == "root":
            return (here, name)
        if qualifier in aliases:
            return (aliases[qualifier], name)
        if qualifier[:1].isupper():
            return (qualifier + ".qml", name)
        return None
    return resolve


CALL = re.compile(r"(?<![\w.])(?:(\w+)\.)?(\w+)\s*\(")


def calls_in(text, start, end):
    """[(qualifier, name, position of '(')] of the calls between start and end."""
    out = []
    for m in CALL.finditer(text, start, end):
        if m.group(2) in ("function", "if", "for", "while", "switch", "return", "catch"):
            continue
        out.append((m.group(1), m.group(2), m.end() - 1))
    return out


@functools.lru_cache(maxsize=None)
def functions_in(text):
    """[(name, params, body start, body end)] of `function name(params) ... {` definitions (QML and JS)."""
    out = []
    for m in re.finditer(r"\bfunction\s+(\w+)\s*\(([^)]*)\)", text):
        block = matching_block(text, m.end())
        if block:
            out.append((m.group(1), param_names(m.group(2)), block[0], block[1]))
    return out


def reply_helpers(files):
    """{(module, function): reply}: the reply parsers, and every function that passes one of its parameters to one
    (directly or through another helper), to a fixed point."""
    helpers = {}
    for module, funcs in reply_parsers(files).items():
        for name, reply in funcs.items():
            helpers[(module, name)] = reply
    # Every function with parameters, once: its key, a regex of its parameters and its resolved calls with their arguments.
    funcs = []
    for path, text in shell_sources(files).items():
        if not re.search(r"\bfunction\b", text):
            continue
        resolve = resolver(path, text)
        for name, params, a, b in functions_in(text):
            if params:
                calls = [(resolve(q, c), call_args(text, paren)) for q, c, paren in calls_in(text, a, b)]
                funcs.append(((module_of(path), name), re.compile(r"\b(%s)\b" % "|".join(map(re.escape, params))), calls))
    changed = True
    while changed:
        changed = False
        for key, uses_param, calls in funcs:
            if key in helpers:
                continue
            for target, args in calls:
                if target in helpers and uses_param.search(args):
                    helpers[key] = helpers[target]
                    changed = True
                    break
    return helpers


def event_handlers(text):
    """[(start, end, [parameter names])] of the code that runs on a Hyprland raw event: `onRawEvent` handlers (function
    or property form), `rawEvent.connect(<lambda or function>)` and a function connected by name."""
    out = []
    for m in re.finditer(r"\bonRawEvent\b\s*(?:\(([^)]*)\)|:\s*(?:function\s*\(([^)]*)\)|\(?(\w*)\)?\s*=>))?", text):
        block = matching_block(text, m.end())
        if block:
            names = param_names(m.group(1) or m.group(2) or m.group(3) or "")
            out.append((block[0], block[1], names or ["event"]))
    for m in re.finditer(r"\brawEvent\.connect\s*\(", text):
        paren = m.end() - 1
        args = call_args(text, paren)
        named = re.fullmatch(r"\s*(?:root\.)?(\w+)\s*", args)
        if named:
            for name, params, a, b in functions_in(text):
                if name == named.group(1):
                    out.append((a, b, params))
            continue
        lam = re.match(r"\s*(?:function\s*\(([^)]*)\)|\(?\s*(\w+)\s*\)?\s*=>)", args)
        names = param_names((lam.group(1) or lam.group(2) or "") if lam else "")
        out.append((paren, paren + len(args) + 1, names))
    return out


def event_data_pattern(text, a, b, params):
    """A regex for the event's payload in a handler: `<param>.data`, `<param>["data"]`, and the locals that hold it:
    declared from it (`const d = e.data`), assigned it later (`let d; d = e.data`) or destructured from the event
    (`const {data} = e`, `const {data: d} = e`); one level, no copies of copies."""
    names = [re.escape(p) for p in params if p]
    if not names:
        return None
    param = r"\b(?:%s)" % "|".join(names)
    data = r"%s(?:\.data\b|\[\s*[\"']data[\"']\s*\])" % param
    body = text[a:b]
    local = re.findall(r"(?<![\w.])(\w+)\s*=(?!=)\s*%s(?!\s*[.\[(\w])" % data, body)
    for fields in re.findall(r"\b(?:const|let|var)\s*\{([^}]*)\}\s*=\s*%s\b(?!\s*[.\[(])" % param, body):
        for field in fields.split(","):
            m = re.match(r"\s*data\s*(?::\s*(\w+))?", field)
            if m:
                local.append(m.group(1) or "data")
    return re.compile(data + "".join(r"|(?<![\w.])%s\b" % re.escape(v) for v in sorted(set(local))))


def reply_feed_errors(files):
    """A reply parser fed from an event: called inside a raw-event handler; or a reply parser or a helper that passes its
    argument to one (any depth, any file) given the event's payload (`<param>.data` or a local assigned from it) in a
    handler, or `event.data` anywhere. Out of reach (textual check): a payload kept in a property, a signal argument or
    an object field and parsed later, a call through a variable holding the function, and code outside shell/ and apps/."""
    parsers = {(m, f) for m, funcs in reply_parsers(files).items() for f in funcs}
    helpers = reply_helpers(files)
    errs = []
    names = {name for _, name in helpers}
    wanted = re.compile(r"\b(%s)\s*\(" % "|".join(map(re.escape, sorted(names))))
    for path, text in sorted(shell_sources(files).items()):
        if not wanted.search(text):
            continue
        resolve = resolver(path, text)
        handlers = event_handlers(text)
        own = {(module_of(path), name) for name, _, _, _ in functions_in(text)}
        for qual, name, paren in calls_in(text, 0, len(text)):
            args = call_args(text, paren)
            if qual == "Qt" and name == "callLater":
                # Qt.callLater(fn, args...): the call of fn with those arguments, one event-loop turn later
                deferred = re.match(r"\s*(?:(\w+)\.)?(\w+)\s*(?:,|$)", args)
                if not deferred:
                    continue
                qual, name = deferred.group(1), deferred.group(2)
                args = args[deferred.end():]
            target = resolve(qual, name)
            if target not in helpers:
                continue
            # the definition of a helper of this file is not a call
            if target in own and re.search(r"\bfunction\s+%s\s*\($" % re.escape(name), text[max(0, paren - 80):paren + 1]):
                continue
            inside = [h for h in handlers if h[0] <= paren <= h[1]]
            direct = target in parsers and bool(inside)
            payload = any((lambda pat: pat is not None and pat.search(args))(event_data_pattern(text, h[0], h[1], h[2]))
                          for h in inside)
            if direct or payload or "event.data" in args:
                line = text.count("\n", 0, paren) + 1
                shown = "%s.%s" % (qual, name) if qual else name
                errs.append("shell feeds the reply parser %s (reply %s) from an event: %s:%d"
                            % (shown, helpers[target], path, line))
    return errs


# ---- comparison ----

def compare(docs, code, shell, adr_problems=()):
    errs = list(adr_problems)

    def sets(label, d, c):
        for x in sorted(c - d):
            errs.append("%s: in code but not documented: %s" % (label, x))
        for x in sorted(d - c):
            errs.append("%s: documented but not in code: %s" % (label, x))

    sets("event types", set(docs["events"]), set(code["events"]))
    for t in sorted(set(docs["events"]) & set(code["events"])):
        sets("fields of %s" % t, docs["events"][t], code["events"][t])
    sets("replies", set(docs["replies"]), set(code["replies"]))
    for r in sorted(set(docs["replies"]) & set(code["replies"])):
        sets("fields of reply %s" % r, docs["replies"][r], code["replies"][r])
    sets("enums", set(docs["enums"]), set(code["enums"]))
    for k in sorted(set(docs["enums"]) & set(code["enums"])):
        sets("values of %s" % k, docs["enums"][k], code["enums"][k])
    sets("features", docs["features"], code["features"])
    sets("verbs", docs["verbs"], code["verbs"])

    for t in sorted(shell["events"]):
        if t not in code["events"]:
            errs.append("shell reads event type %s that the plugin never sends" % t)
            continue
        for f in sorted(shell["events"][t] - code["events"][t]):
            errs.append("shell reads %s.%s that the plugin never sends" % (t, f))
    for r in sorted(shell["replies"]):
        if r not in code["replies"]:
            errs.append("shell reads reply %s that the plugin never gives" % r)
            continue
        for f in sorted(shell["replies"][r] - code["replies"][r]):
            errs.append("shell reads reply %s field %s that the plugin never gives" % (r, f))
    for k in sorted(shell["enums"]):
        for v in sorted(shell["enums"][k] - code["enums"].get(k, set())):
            errs.append("shell lists %s value %s that the plugin never sends" % (k, v))
    for f in sorted(shell["features"] - code["features"]):
        errs.append("shell asks for feature %s that the plugin never advertises" % f)
    for v in sorted(shell["verbs"] - code["verbs"]):
        errs.append("shell may call verb %s that the plugin does not register" % v)
    return errs


def check_tree(root):
    files = load(root)
    docs, problems = docs_model(files.get(ADR))
    code = code_model(files)
    shell = shell_model(files)
    errs = compare(docs, code, shell, problems) + reply_feed_errors(files)
    if not code["events"] or not code["features"]:
        errs.append("extractor found no events or features in compositor/src (patterns out of date?)")
    # every declared feature constant must be pushed by features() (a constant nobody advertises is dead protocol)
    cpp = files.get("compositor/src/core/Protocol.cpp", "")
    hpp = files.get("compositor/src/core/Protocol.hpp", "")
    for const in sorted(set(re.findall(r"\b(kFeature[A-Z]\w*)\s*=", hpp)) - {"kFeatures"}):
        if const not in cpp:
            errs.append("feature constant %s is never advertised by Protocol.cpp features()" % const)
    return errs, docs, code, shell


# ---- selftest ----

FIX_HPP = '''
inline constexpr std::string_view kLuaHello = "hello";
inline constexpr std::string_view kLuaNamespace = "grassfield";
inline constexpr std::string_view kLuaCursorRefresh = "cursor_refresh";
inline constexpr std::string_view kFeatureDecorations = "decorations";
inline constexpr std::string_view kFeatureStagesAvailable = "stages-available";
'''
FIX_PROTO_CPP = '''
    std::string capabilitiesJson(int x) {
        std::string out;
        appendHeader(out, "capabilities");
        out += R"(,"features":[)";
        return out;
    }
    std::string windowEventJson(std::string_view type, std::string_view a) {
        out += R"(,"address":")";
        return out;
    }
    std::string minimizedJson(std::string_view a) {
        return windowEventJson("minimized", a);
    }
    void features() { kFeatureDecorations; kFeatureStagesAvailable; }
'''
FIX_OV_CPP = '''
    std::string_view reasonName(Reason reason) {
        switch (reason) {
            case Reason::None: return "";
            case Reason::Invalid: return "invalid";
        }
        return "";
    }
    std::string_view phaseName(Phase phase) {
        switch (phase) {
            case Phase::Open: return "open";
        }
        return "open";
    }
    std::string eventJson(Phase phase, size_t windows, Reason reason) {
        out += R"(","type":"overview","state":")";
        out += R"(","windows":)";
        out += R"(,"reason":")";
        return out;
    }
'''
FIX_STAGES_CPP = '''
    std::string noticeJson(uint64_t generation, bool on) {
        out += std::format(R"(","type":"stages","gen":{},"on":)", generation);
        return out;
    }

    // gfc1-reply: grassfield-stages
    // The state.
    std::string stateJson(uint64_t generation, bool on) {
        out += std::format(R"(","type":"stages","gen":{},"on":)", generation);
        out += R"(,"monitors":[)";
        return out;
    }
'''
FIX_STAGES_JS = '''
function parseNotice(data) {
    if (!msg || msg.v !== "gfc/1" || msg.type !== "stages") return null;
    return {on: msg.on, gen: msg.gen};
}

// gfc1-reply: grassfield-stages
// The state fetched with hyprctl.
function parse(data) {
    if (!msg || msg.v !== "gfc/1" || msg.type !== "stages") return null;
    return {on: msg.on, gen: msg.gen, monitors: msg.monitors};
}
'''
FIX_LINK_QML = '''
import "StagesState.js" as StagesState
Item {
    Connections {
        function onRawEvent(event: HyprlandEvent): void {
            const n = StagesState.parseNotice(event.data); // "}" in a string and a comment { do not end the handler
            if (n)
                fetch();
        }
    }
    function applyFetched(text: string): void {
        state = StagesState.parse(text);
    }
}
'''
FIX_TWO_CPP = '''
    std::string_view reasonName(Reason reason) {
        switch (reason) {
            case Reason::Placed: return "placed";
        }
        return "";
    }
    std::string noticeJson(uint64_t generation, Reason reason) {
        out += std::format(R"(","type":"tiling","gen":{})", generation);
        out += reasonName(reason);
        return out;
    }
    std::string_view hoverStateName(HoverState state) {
        switch (state) {
            case HoverState::Enter: return "enter";
        }
        return "enter";
    }
    std::string tileHoverJson(uint64_t address, HoverState state) {
        out += std::format(R"(","type":"tile-hover","address":"{:x}","state":"{}")", address, hoverStateName(state));
        return out;
    }
'''
FIX_TWO_ADR = """event tiling: gen
event tile-hover: address state
enum tiling.reason: placed
enum tile-hover.state: enter
"""
FIX_ADR = '''# ADR
```gfc1
event capabilities: features
event minimized: address
event overview: state windows reason
event stages: gen on
reply grassfield-stages: gen on monitors
enum overview.reason: invalid
enum overview.state: open
feature decorations stages-available
verb hello cursor_refresh
```
'''
FIX_SHELL_JS = '''
function parse(data) {
    if (!msg || msg.v !== "gfc/1" || msg.type !== "overview") return null;
    return {state: msg.state, windows: msg.windows, reason: msg.reason};
}
'''


def fixtures():
    return {
        "compositor/src/core/Protocol.hpp": FIX_HPP,
        "compositor/src/core/Protocol.cpp": FIX_PROTO_CPP,
        "compositor/src/core/Overview.cpp": FIX_OV_CPP,
        "shell/overview/V2.js": FIX_SHELL_JS + 'var states = ["open"];\nvar reasons = ["invalid"];\n',
        "shell/platform/Minimized.js": 'var pluginVerbs = ["hello", "cursor_refresh"];\n',
        "shell/x/Use.qml": 'if (Capabilities.has("stages-available")) {}\n',
        "compositor/src/core/Stages.cpp": FIX_STAGES_CPP,
        "shell/platform/StagesState.js": FIX_STAGES_JS,
        "shell/platform/Link.qml": FIX_LINK_QML,
        ADR: FIX_ADR,
    }


def run_fixture(files):
    docs, problems = docs_model(files.get(ADR))
    return compare(docs, code_model(files), shell_model(files), problems) + reply_feed_errors(files)


def selftest():
    failures = []

    def expect(name, errs, needle):
        hit = any(needle in e for e in errs)
        if needle is None:
            hit = not errs
        if not hit:
            failures.append("%s: expected %r in %s" % (name, needle, errs))

    base = fixtures()
    errs = run_fixture(base)
    if errs:
        failures.append("clean fixture reports drift: %s" % errs)

    # a field renamed in the code
    renamed = dict(base)
    renamed["compositor/src/core/Overview.cpp"] = FIX_OV_CPP.replace('"windows"', '"count"')
    errs = run_fixture(renamed)
    expect("renamed field (undocumented)", errs, "fields of overview: in code but not documented: count")
    expect("renamed field (documented, gone)", errs, "fields of overview: documented but not in code: windows")
    expect("renamed field (shell reads gone field)", errs, "shell reads overview.windows that the plugin never sends")

    # an event type missing from the code
    missing = dict(base)
    missing["compositor/src/core/Protocol.cpp"] = FIX_PROTO_CPP.replace('windowEventJson("minimized", a)', "a")
    expect("missing type", run_fixture(missing), "event types: documented but not in code: minimized")

    # a type in the code that the docs lack
    extra = dict(base)
    extra[ADR] = FIX_ADR.replace("event minimized: address\n", "")
    expect("undocumented type", run_fixture(extra), "event types: in code but not documented: minimized")

    # a reason removed from the code and one the shell lists but nobody sends
    reason = dict(base)
    reason["compositor/src/core/Overview.cpp"] = FIX_OV_CPP.replace('"invalid"', '"bad"')
    errs = run_fixture(reason)
    expect("renamed reason", errs, "values of overview.reason: documented but not in code: invalid")
    expect("shell reason never sent", errs, "shell lists overview.reason value invalid that the plugin never sends")

    # a feature or verb the shell uses without the plugin providing it
    feat = dict(base)
    feat["shell/x/Use.qml"] = 'if (Capabilities.has("window-chrome")) {}\n'
    expect("shell feature", run_fixture(feat), "shell asks for feature window-chrome")
    verb = dict(base)
    verb["shell/platform/Minimized.js"] = 'var pluginVerbs = ["hello", "tile"];\n'
    expect("shell verb", run_fixture(verb), "shell may call verb tile")

    # a shell parser that reads the reply's monitors out of the event (the reply mark gone)
    unmarked = dict(base)
    unmarked["shell/platform/StagesState.js"] = FIX_STAGES_JS.replace("// gfc1-reply: grassfield-stages\n", "")
    expect("reply field read from the event", run_fixture(unmarked), "shell reads stages.monitors that the plugin never sends")

    # the state built as an event (the code's reply mark gone), and a reply field the docs lack
    code_unmarked = dict(base)
    code_unmarked["compositor/src/core/Stages.cpp"] = FIX_STAGES_CPP.replace("// gfc1-reply: grassfield-stages\n", "")
    errs = run_fixture(code_unmarked)
    expect("state as an event", errs, "fields of stages: in code but not documented: monitors")
    expect("reply gone from the code", errs, "replies: documented but not in code: grassfield-stages")
    reply_field = dict(base)
    reply_field[ADR] = FIX_ADR.replace("reply grassfield-stages: gen on monitors", "reply grassfield-stages: gen on")
    expect("undocumented reply field", run_fixture(reply_field), "fields of reply grassfield-stages: in code but not documented: monitors")
    shell_reply = dict(base)
    shell_reply["shell/platform/StagesState.js"] = FIX_STAGES_JS.replace("monitors: msg.monitors", "screens: msg.screens")
    expect("shell reply field never given", run_fixture(shell_reply), "shell reads reply grassfield-stages field screens")

    # the reply parser fed from the event (the exact B1 regression; re-review mutants M5/M6)
    fed = dict(base)
    fed["shell/platform/Link.qml"] = FIX_LINK_QML.replace("StagesState.parseNotice(event.data)", "StagesState.parse(event.data)")
    expect("reply parser fed from an event handler", run_fixture(fed), "feeds the reply parser StagesState.parse (reply grassfield-stages) from an event: shell/platform/Link.qml:6")
    inside = dict(base)
    inside["shell/platform/Link.qml"] = FIX_LINK_QML.replace("if (n)\n                fetch();", "if (n)\n                state = StagesState.parse(lastText);")
    expect("reply parser called inside the handler", run_fixture(inside), "from an event: shell/platform/Link.qml:8")
    outside = dict(base)
    outside["shell/platform/Link.qml"] = FIX_LINK_QML.replace("StagesState.parse(text)", "StagesState.parse(event.data)")
    expect("reply parser given event.data outside the handler", run_fixture(outside), "from an event: shell/platform/Link.qml:12")
    other = dict(base)
    other["shell/x/Bar.qml"] = 'import "../platform/StagesState.js" as SS\nConnections { function onRawEvent(event) { SS.parse(event.data) } }\n'
    expect("reply parser imported under another name", run_fixture(other), "feeds the reply parser SS.parse")
    # the re-review's mutants M8-M10 and kin: a helper, rawEvent.connect, another parameter name, a local variable
    helper = dict(base)
    helper["shell/x/Helper.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function take(text) {\n        state = SS.parse(text);\n    }\n'
                                    '    Connections {\n        function onRawEvent(event) {\n            root.take(event.data);\n        }\n    }\n}\n')
    expect("reply parser reached through a helper", run_fixture(helper), "feeds the reply parser root.take (reply grassfield-stages) from an event: shell/x/Helper.qml:8")
    deep = dict(base)
    deep["shell/x/Deep.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function inner(t) { return SS.parse(t); }\n    function outer(x) { return inner(x); }\n'
                                '    Component.onCompleted: Hyprland.rawEvent.connect(e => { if (e.name === "grassfield") outer(e.data); })\n}\n')
    expect("a helper of a helper from a connected lambda, payload e.data", run_fixture(deep), "feeds the reply parser outer")
    lam = dict(base)
    lam["shell/x/Lambda.qml"] = 'import "../platform/StagesState.js" as SS\nItem {\n    Component.onCompleted: Hyprland.rawEvent.connect(function (ev) { state = SS.parse(ev.data); })\n}\n'
    expect("rawEvent.connect with a function", run_fixture(lam), "feeds the reply parser SS.parse")
    local = dict(base)
    local["shell/x/Local.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function take(text) { state = SS.parse(text); }\n'
                                  '    Connections {\n        function onRawEvent(e) {\n            const d = e.data;\n            take(d);\n        }\n    }\n}\n')
    expect("payload through a local variable", run_fixture(local), "feeds the reply parser take")
    for label, body in (("destructured", "const {data} = e;\n            take(data);"),
                        ("destructured under another name", "const {name, data: raw} = e;\n            take(raw);"),
                        ("assigned later", "let d;\n            d = e.data;\n            take(d);"),
                        ("indexed", "take(e[\"data\"]);")):
        case = dict(base)
        case["shell/x/Late.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function take(text) { state = SS.parse(text); }\n'
                                    '    Connections {\n        function onRawEvent(e) {\n            %s\n        }\n    }\n}\n' % body)
        expect("payload " + label, run_fixture(case), "feeds the reply parser take")
    later = dict(base)
    later["shell/x/Later.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function take(text) { state = SS.parse(text); }\n'
                                  '    Connections {\n        function onRawEvent(event) {\n            Qt.callLater(root.take, event.data);\n        }\n    }\n}\n')
    expect("a helper deferred with Qt.callLater", run_fixture(later), "feeds the reply parser root.take")
    named = dict(base)
    named["shell/x/Named.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function handle(e) { state = SS.parse(e.data); }\n'
                                  '    Component.onCompleted: Hyprland.rawEvent.connect(root.handle)\n}\n')
    expect("a function connected by name", run_fixture(named), "feeds the reply parser SS.parse")
    clean = dict(base)
    clean["shell/x/Clean.qml"] = ('import "../platform/StagesState.js" as SS\nItem {\n    function take(text) { state = SS.parse(text); }\n'
                                  '    Connections {\n        function onRawEvent(event) {\n            const n = SS.parseNotice(event.data);\n            if (n) fetch(n.gen);\n        }\n    }\n'
                                  '    function done(reply) { take(reply); }\n}\n')
    errs = run_fixture(clean)
    if errs:
        failures.append("a helper fed from a reply (not an event) is flagged: %s" % errs)

    # two event types in one file: each name switch belongs to the builder that calls it
    two = dict(base)
    two["compositor/src/core/Tiling.cpp"] = FIX_TWO_CPP
    two[ADR] = FIX_ADR.replace("verb hello", FIX_TWO_ADR + "verb hello")
    expect("two types in one file", run_fixture(two), None)
    uncalled = dict(two)
    uncalled["compositor/src/core/Tiling.cpp"] = FIX_TWO_CPP.replace("hoverStateName(state)", '"enter"')
    expect("switch no builder calls", run_fixture(uncalled), "enums: documented but not in code: tile-hover.state")

    # a docs block that cannot be read
    expect("no block", run_fixture({**base, ADR: "# no table\n"}), "no ```gfc1 block")
    expect("bad line", run_fixture({**base, ADR: FIX_ADR.replace("verb hello", "verbs hello")}), "unreadable line")

    if failures:
        print("selftest FAILED:")
        for f in failures:
            print("  " + f)
        return 1
    print("gfc_parity selftest: ok")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2]
    errs, docs, code, shell = check_tree(root)
    if errs:
        print("gfc/1 drift (%d):" % len(errs))
        for e in errs:
            print("  " + e)
        return 1
    print("gfc/1 parity: %d events, %d replies, %d enums, %d features, %d verbs; shell reads %d types, %d replies, %d features"
          % (len(code["events"]), len(code["replies"]), len(code["enums"]), len(code["features"]), len(code["verbs"]),
             len(shell["events"]), len(shell["replies"]), len(shell["features"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
