#!/usr/bin/env python3
"""The qs.lib Mode singleton (ADR-0019): what it does in every environment, and exactly what it is.

Two checks, because each alone has a hole:

1. Behaviour. For each vector of tests/fixtures/run-mode-vectors.json the shell probe (probe.qml) is started offscreen with exactly that
   environment and prints what the real Mode answers (dev, session, fixtures, ownBus, updateNotices, refused, configDir, stateDir,
   devValue(...)) at the start, whenever it changes, and after 1.2 s. The vectors include a packaged session (GRASSFIELD_SESSION=1,
   no dev) and a leaked GRASSFIELD_DEV=1 with SESSION=1. devValue is asked for every GRASSFIELD_ name the shell reads or passes to it
   (taken from the tree), each set to a probe value in every environment, so a gate that skips the dev check for one name fails.
   A read that differs from the first one fails (a gate that opens later). The probe lists every member of the singleton.
2. Structure. Behaviour cannot see a gate that depends on a variable no vector sets (`|| env("SOMETHING") === "1"`), so Mode.qml is also
   read from Qt's syntax tree (qmldom --dump-ast) and must be exactly the allowlist of `members` in the vectors: the pragma, the
   imports, one root object with only `id: root`, the expected readonly properties with the expected expression each (rendered
   canonically from the tree: only calls, member accesses, identifiers, string literals and `+` are known), and the expected function.
   A timer, a binding, a signal, a second object, an unknown node or any other expression fails.

  tests/shell/run_mode_env.sh                      run both against shell/lib
  GF_RUN_MODE_LIB=<dir> tests/shell/run_mode_env.sh  against another copy of the lib module (the mutation checks)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = Path(os.environ.get("GF_RUN_MODE_LIB", ROOT / "shell" / "lib")).resolve()
QMLDOM = "/usr/lib/qt6/bin/qmldom"
VECTORS = json.loads((ROOT / "tests" / "fixtures" / "run-mode-vectors.json").read_text(encoding="utf-8"))
MEMBERS = VECTORS["members"]
REFUSED = VECTORS["refused"]
# The members of the QObject base that every singleton has, and the signal each property adds.
BASE_MEMBERS = {"children", "objectName", "objectNameChanged", "reloadableId"}
EXPECTED_MEMBERS = sorted(BASE_MEMBERS | set(MEMBERS["properties"]) | {p + "Changed" for p in MEMBERS["properties"]} | set(MEMBERS["functions"]))
# Mode inputs and the variables that are honoured always: not dev plumbing, so not injected into every environment.
NOT_PLUMBING = {"DEV", "SESSION", "VISUAL_FIXTURES", "PRIVATE_BUS", "CONFIG_HOME", "STATE_HOME"}
NAME_IN_TREE = re.compile(r"""(?:Quickshell\.env\(\s*["']GRASSFIELD_([A-Z0-9_]+)["']|devValue\(\s*["']([A-Z0-9_]+)["'])""")
PROBE_READS = 60  # keep in step with probe.qml: one read every 20 ms


def plumbing_names():
    """Every GRASSFIELD_ variable the shell reads, and every name it passes to Mode.devValue: derived from the tree."""
    names = set()
    for p in sorted((ROOT / "shell").rglob("*")):
        if p.suffix in (".qml", ".js") and p.is_file() and p.parent != LIB:
            for m in NAME_IN_TREE.finditer(p.read_text(encoding="utf-8", errors="replace")):
                names.add(m.group(1) or m.group(2))
    for v in VECTORS["plumbing"]:
        names.add(v["variable"].removeprefix("GRASSFIELD_"))
    return sorted(names - NOT_PLUMBING)


def dev_rule(env):
    """The rule of ADR-0019, spelled out here independently of the code under test."""
    return env.get("GRASSFIELD_DEV") == "1" and env.get("GRASSFIELD_SESSION") != "1"


def jobs(names):
    """(name, environment, expected answers) of every vector."""
    out = []
    for v in VECTORS["modes"]:
        out.append((f"mode: {v['name']}", v["env"], {k: v[k] for k in ("dev", "session", "fixtures", "ownBus", "updateNotices")}))
    for v in VECTORS["dirs"]:
        out.append((f"dirs: {v['name']}", v["env"], {"configDir": v["configDir"], "stateDir": v["stateDir"]}))
    for v in VECTORS["plumbing"]:
        out.append((f"plumbing: {v['name']}", v["env"], {}))
    return out


def probe(job, names, tmp_root):
    name, vector_env, expected = job
    tmp = Path(tempfile.mkdtemp(prefix="p-", dir=tmp_root))
    cfg = tmp / "cfg"
    cfg.mkdir()
    (cfg / "lib").symlink_to(LIB)
    shutil.copy(Path(__file__).with_name("probe.qml"), cfg / "shell.qml")
    for d in ("runtime", "cache", "home"):
        (tmp / d).mkdir(mode=0o700)
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp / "home"), "XDG_RUNTIME_DIR": str(tmp / "runtime"), "XDG_CACHE_HOME": str(tmp / "cache"),
           "QT_QPA_PLATFORM": "offscreen", "QML_IMPORT_PATH": str(ROOT / "ui")}
    # Every plumbing variable set to a probe value (a vector's own value wins): a gate that opens for one of them shows.
    probes = {f"GRASSFIELD_{n}": f"gf-probe-{n}" for n in names}
    env.update(probes)
    env.update(vector_env)  # exactly the vector's variables (HOME included when it sets one)
    env["GF_PROBE_NAMES"] = ",".join(names)
    try:
        r = subprocess.run(["nice", "-n", "19", "qs", "-p", str(cfg), "--no-color"], capture_output=True, text=True, env=env, timeout=90)
        reads = [l.split("RUNMODE ", 1)[1] for l in (r.stdout + r.stderr).splitlines() if "RUNMODE " in l]
        if len(reads) < 2:
            return [f"{name}: the probe printed {len(reads)} read(s) (qs exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}"]
        parsed = [(int(x.split(" ", 1)[0]), json.loads(x.split(" ", 1)[1])) for x in reads]
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        return [f"{name}: {e}"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    problems = []
    if len(parsed) != 2 or parsed[0][0] != 1 or parsed[1][0] < PROBE_READS:
        problems.append(f"{name}: Mode changed while it was watched (reads printed at {[n for n, _ in parsed]}): a gate that opens later")
    if parsed[0][1] != parsed[-1][1]:
        problems.append(f"{name}: the first read and the last differ: {sorted(k for k in parsed[0][1] if parsed[0][1][k] != parsed[-1][1].get(k))}")
    got = parsed[-1][1]
    if got["members"] != EXPECTED_MEMBERS:
        problems.append(f"{name}: members {sorted(set(got['members']) ^ set(EXPECTED_MEMBERS))} differ from the table")
    if got["refused"] != REFUSED:
        problems.append(f"{name}: refused is {got['refused']!r}, not {REFUSED!r}")
    if got["shellDirIsTheShellDir"] is not True:
        problems.append(f"{name}: shellDir is not the shell directory")
    for key, want in expected.items():
        if got[key] != want:
            problems.append(f"{name}: {key} is {got[key]!r}, expected {want!r}")
    # devValue(n) is the variable's value in dev and "" otherwise, for every name asked about.
    final_env = {**probes, **vector_env}
    is_dev = dev_rule(final_env)
    for n in names:
        want = final_env.get(f"GRASSFIELD_{n}", "") if is_dev else ""
        if got["devValues"].get(n) != want:
            problems.append(f"{name}: devValue({n!r}) is {got['devValues'].get(n)!r}, expected {want!r} (dev is {is_dev})")
    return problems


# --- the structure of Mode.qml, from Qt's syntax tree -----------------------------------------------------------------

TAG = re.compile(r"^\s*<(/?)(\w+)\b(.*?)(/?)>\s*$")
ATTR = re.compile(r'(\w+)="([^"]*)"')
STRING_VALUE = re.compile(r'value="(.*)" literalToken="')


class Node:
    def __init__(self, tag, attrs):
        self.tag, self.attrs, self.children = tag, attrs, []


def dom_tree(path):
    """qmldom --dump-ast as a tree (its dump is not well-formed XML: string values hold raw quotes). `Node` wrappers are dropped."""
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(["nice", "-n", "19", QMLDOM, "--dump-ast", str(path)], capture_output=True, text=True, env=env, timeout=120)
    if r.returncode != 0 or "<UiProgram>" not in r.stdout:
        raise ValueError(f"qmldom could not read {path.name}: {(r.stderr or r.stdout)[:200]}")
    root = Node("root", {})
    stack = [root]
    for line in r.stdout.split("\n"):
        m = TAG.match(line)
        if not m:
            continue
        closing, tag, rest, selfclose = m.groups()
        if tag == "Node":
            continue
        if closing:
            if len(stack) > 1 and stack[-1].tag == tag:
                stack.pop()
            continue
        attrs = dict(ATTR.findall(rest))
        if tag == "StringLiteral":
            s = STRING_VALUE.search(rest)
            attrs["value"] = s.group(1) if s else attrs.get("value", "")
        node = Node(tag, attrs)
        stack[-1].children.append(node)
        if not selfclose:
            stack.append(node)
    return root


def render(node):
    """The canonical text of an expression; any node the allowlist does not know renders as <TAG?> and so matches nothing."""
    kids = node.children
    if node.tag in ("ExpressionStatement",) and len(kids) == 1:
        return render(kids[0])
    if node.tag == "ReturnStatement" and len(kids) == 1:
        return "return " + render(kids[0])
    if node.tag == "IdentifierExpression" and not kids:
        return node.attrs.get("name", "?")
    if node.tag == "StringLiteral" and not kids:
        return '"' + node.attrs.get("value", "") + '"'
    if node.tag == "FieldMemberExpression" and len(kids) == 1:
        return f"{render(kids[0])}.{node.attrs.get('name', '?')}"
    if node.tag == "CallExpression" and len(kids) == 2 and kids[1].tag == "ArgumentList":
        return f"{render(kids[0])}({', '.join(render(a) for a in kids[1].children)})"
    if node.tag == "BinaryExpression" and len(kids) == 2:
        return f"({render(kids[0])} op{node.attrs.get('op', '?')} {render(kids[1])})"
    return f"<{node.tag}?>"


def members_of(node):
    for child in node.children:
        if child.tag.endswith("List"):
            yield from members_of(child)
        else:
            yield child


def first(node, tag):
    return next((c for c in node.children if c.tag == tag), None)


def structure_problems(path):
    out = []
    try:
        tree = dom_tree(path)
    except (ValueError, OSError, subprocess.TimeoutExpired) as e:
        return [f"structure: {e}"]
    program = first(tree, "UiProgram")
    pragmas, imports, top = [], [], []
    for item in members_of_lists(program):
        if item.tag == "UiPragma":
            pragmas.append(item.attrs.get("name", "?"))
        elif item.tag == "UiImport":
            ident = first(item, "UiQualifiedId")
            parts = []
            while ident is not None:
                parts.append(ident.attrs.get("name", "?"))
                ident = first(ident, "UiQualifiedId")
            name = item.attrs.get("fileName") or ".".join(parts)
            imports.append(f'"{name}" as {item.attrs["importId"]}' if item.attrs.get("fileName") else name)
        else:
            top.append(item)
    if pragmas != MEMBERS["pragmas"]:
        out.append(f"structure: pragmas {pragmas} are not {MEMBERS['pragmas']}")
    if imports != MEMBERS["imports"]:
        out.append(f"structure: imports {imports} are not {MEMBERS['imports']}")
    if len(top) != 1 or top[0].tag != "UiObjectDefinition":
        return out + [f"structure: expected exactly one root object, found {[t.tag for t in top]}"]
    obj = top[0]
    type_id = first(obj, "UiQualifiedId")
    if type_id is None or type_id.attrs.get("name") != MEMBERS["root"]:
        out.append(f"structure: the root object is not a {MEMBERS['root']}")
    init = first(obj, "UiObjectInitializer")
    seen_props, seen_funcs, seen_id = {}, {}, False
    env_text = MEMBERS["env"]
    for m in members_of(init) if init is not None else []:
        if m.tag == "UiScriptBinding":
            ident = first(m, "UiQualifiedId")
            body = first(m, "ExpressionStatement")
            if ident is not None and ident.attrs.get("name") == "id" and body is not None and render(body) == "root" and not seen_id:
                seen_id = True
            else:
                out.append(f"structure: a binding other than `id: root`: {ident.attrs.get('name') if ident is not None else '?'}")
        elif m.tag == "UiPublicMember":
            name = m.attrs.get("name", "?")
            tid = first(m, "UiQualifiedId")
            typ = tid.attrs.get("name") if tid is not None else "?"
            body = first(m, "ExpressionStatement")
            ok = (m.attrs.get("type") == "Property" and m.attrs.get("isReadonlyMember") == "true" and m.attrs.get("isDefaultMember") == "false"
                  and m.attrs.get("isRequired") == "false" and m.attrs.get("typeModifier", "") == "" and body is not None)
            if not ok or name in seen_props:
                out.append(f"structure: member {name} is not a single `readonly property` with a binding")
            seen_props[name] = (typ, render(body) if body is not None else None)
        elif m.tag == "UiSourceElement":
            fn = first(m, "FunctionDeclaration")
            if fn is None:
                out.append("structure: a source element that is not a function")
                continue
            params = [f"{p.attrs.get('bindingIdentifier', '?')}" + (" = ..." if p.children else "") for p in iter_tag(first(fn, "FormalParameterList"), "PatternElement")]
            stmts = first(fn, "StatementList")
            body = " ; ".join(render(s) for s in (stmts.children if stmts is not None else []))
            seen_funcs[fn.attrs.get("name", "?")] = (params, body)
        else:
            out.append(f"structure: {m.tag} is not allowed in Mode (a timer, an object, a signal or a binding that could change later)")
    for name, (typ, expr) in MEMBERS["properties"].items():
        want = expr % env_text
        if name not in seen_props:
            out.append(f"structure: Mode.{name} is missing")
        elif seen_props[name] != (typ, want):
            out.append(f"structure: Mode.{name} is `{seen_props[name][0]} {seen_props[name][1]}`, expected `{typ} {want}`")
    for name in seen_props:
        if name not in MEMBERS["properties"]:
            out.append(f"structure: Mode.{name} is not in the table")
    for name, (params, expr) in MEMBERS["functions"].items():
        want = expr % env_text
        if name not in seen_funcs:
            out.append(f"structure: Mode.{name}() is missing")
        elif seen_funcs[name] != (params, want):
            out.append(f"structure: Mode.{name}({', '.join(seen_funcs[name][0])}) is `{seen_funcs[name][1]}`, expected `{want}`")
    for name in seen_funcs:
        if name not in MEMBERS["functions"]:
            out.append(f"structure: function {name} is not in the table")
    if not seen_id:
        out.append("structure: `id: root` is missing")
    return out


def members_of_lists(program):
    """The header items and the top-level members of a program, through every list wrapper."""
    for child in program.children:
        if child.tag.endswith("List"):
            yield from members_of_lists(child)
        else:
            yield child


def iter_tag(node, tag):
    if node is None:
        return
    for c in node.children:
        if c.tag == tag:
            yield c
        else:
            yield from iter_tag(c, tag)


def main():
    work = ROOT / ".dev"
    work.mkdir(exist_ok=True)
    names = plumbing_names()
    tmp_root = Path(tempfile.mkdtemp(prefix="run-mode-env-", dir=work))
    try:
        all_jobs = jobs(names)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda j: probe(j, names, tmp_root), all_jobs))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    failures = [p for r in results for p in r] + structure_problems(LIB / "Mode.qml")
    for f in failures:
        print("FAIL: run_mode_env " + f)
    if failures:
        return 1
    print(f"PASS: run_mode_env the real Mode answers every vector ({len(all_jobs)} environments, {len(names)} dev-plumbing names each, "
          "packaged and leaked-dev sessions included, stable for 1.2 s) and Mode.qml is exactly the allowlist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
