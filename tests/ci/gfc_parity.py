#!/usr/bin/env python3
"""gfc/1 parity: the contract table in ADR-0007, the compositor code and the shell's consumers must agree.

  python3 -I tests/ci/gfc_parity.py [ROOT]   check the tree at ROOT (default: this repository), exit 1 on any drift
  python3 -I tests/ci/gfc_parity.py --selftest   the extractors and the comparison on small in-memory fixtures

Three views of the protocol are extracted as sets and compared:

  docs   the fenced block "gfc1" in docs/decisions/ADR-0007-shell-plugin-ipc.md (the machine-checkable table):
           event <type>: <field> ...        every field of the event (nested ones flattened; "v" and "type" are implicit)
           enum <type>.<field>: <value> ... the closed values of a field (state, reason, outcome, target)
           feature <name> ...               advertised in the capabilities event
           verb <name> ...                  hl.plugin.grassfield.<verb>
  code   compositor/src: the event types and fields come from the JSON builders (the `"type":"x"` literals, the
         appendHeader / windowEventJson calls of core/Protocol.cpp and the fields named in the builder's function body),
         enum values from the reasonName / phaseName / outcomeName / targetName switches (and the reason literals of
         overview focus), features and verbs from the kFeature* / kLua* constants of core/Protocol.hpp.
  shell  shell/ and apps/: the event types a consumer tests (`msg.type === "x"`), the fields it reads in that function,
         the reasons and states it lists (overview/V2.js), `Capabilities.has("feature")` and the verb allowlist
         (platform/Minimized.js pluginVerbs).

Failures: code but not docs, docs but not code, and anything the shell reads that the plugin never sends (a type, a
field, an enum value, a feature, a verb). The plugin sending something the shell ignores is allowed (overview-focus).
Limits: the extraction is textual. A new builder that does not use the patterns above is invisible and shows up as
"documented but not in code"; teach `code_model` the new pattern rather than loosening the comparison.
"""
import re
import sys
from pathlib import Path

ADR = "docs/decisions/ADR-0007-shell-plugin-ipc.md"
IMPLICIT = {"v", "type"}
# switch functions of the event builders -> the field they name
ENUM_FUNCS = {"reasonName": "reason", "phaseName": "state", "outcomeName": "outcome", "targetName": "target"}


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


# ---- model: {"events": {type: set(fields)}, "enums": {"type.field": set}, "features": set, "verbs": set} ----

def empty():
    return {"events": {}, "enums": {}, "features": set(), "verbs": set()}


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
        en = re.fullmatch(r"enum ([a-z][a-z-]*\.[a-z]+):((?: [a-z][a-z-]*)+)", line)
        ft = re.fullmatch(r"feature((?: [a-z][a-z0-9-]*)+)", line)
        vb = re.fullmatch(r"verb((?: [a-z][a-z_]*)+)", line)
        if ev:
            m["events"][ev.group(1)] = set(ev.group(2).split())
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
        out.append((m.group(2), "\n".join(lines[i:j + 1])))
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
        bodies = function_bodies(text)
        by_name = {n: b for n, b in bodies}
        types = set(re.findall(r'"type":"([a-z][a-z-]*)"', text))
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
        if len(types) == 1:
            t = next(iter(types))
            for n, field in ENUM_FUNCS.items():
                if n in by_name:
                    vals = {v for v in re.findall(r'return "([a-z][a-z-]*)";', by_name[n])}
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
        if vals and "overview-focus" in m["events"]:
            m["enums"].setdefault("overview-focus.reason", set()).update(vals)
    return m


def enclosing_function(text, pos):
    start = text.rfind("\nfunction ", 0, pos) + 1
    end = text.find("\n}", pos)
    return text[start:end if end >= 0 else len(text)]


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
    errs = compare(docs, code, shell, problems)
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
FIX_ADR = '''# ADR
```gfc1
event capabilities: features
event minimized: address
event overview: state windows reason
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
        ADR: FIX_ADR,
    }


def run_fixture(files):
    docs, problems = docs_model(files.get(ADR))
    return compare(docs, code_model(files), shell_model(files), problems)


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
    print("gfc/1 parity: %d events, %d enums, %d features, %d verbs; shell reads %d types, %d features"
          % (len(code["events"]), len(code["enums"]), len(code["features"]), len(code["verbs"]),
             len(shell["events"]), len(shell["features"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
