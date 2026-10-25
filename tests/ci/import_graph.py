#!/usr/bin/env python3
"""Shell layering (ADR-0021, GF-087): the import graph of shell/ obeys the layers, stays acyclic, and keeps raw Hyprland events in platform.

  python3 -I tests/ci/import_graph.py             check the tree, exit 1 on any violation
  python3 -I tests/ci/import_graph.py --graph     print the modules, their layer, the edges and the strongly connected components
  python3 -I tests/ci/import_graph.py --selftest  the rules on fixed synthetic trees

Layers, low to high: lib < platform < store < services < features < shell.qml. A module may import only a lower layer; two
feature modules may import each other only while no cycle forms (a feature edge inside a strongly connected component of the
feature graph is a violation). Security modules (shell/security/**) may import only lib, services and other security
modules. `Quickshell.Hyprland` and `rawEvent` belong to platform.

Rule choices: a feature-to-feature edge is a violation only when it lies on a cycle of the feature graph once every layer
violation is removed from that graph. A raw-event violation is reported once per file, on the `import Quickshell.Hyprland`
line (on the first rawEvent use when the file has no such import).

A module is a directory with a qmldir (`qs.overlay.controlcenter` is shell/overlay/controlcenter); a directory without one
belongs to its nearest ancestor module; shell/shell.qml and the other files of shell/ itself are the composition root.
An import is `import qs.<module>` or a relative `import "<dir or file>"` (also `.import` in JS).

Ratchet: a violating import line passes only with a trailing `// layering-exception: <tag>` marker on that line. Tags:
`GF-087` (temporary: the slice that removes the violation removes the marker; L9 refuses any), `GF-050` (temporary, accepted
only on the `import qs.notifications` line of shell/security/idle/SleepInhibitor.qml), `ADR-0021 security` (permanent,
accepted only in shell/security/lock and shell/security/idle, only on a raw Hyprland event line: the lock and idle modules).
An unknown tag, a tag where it is not accepted, and a marker on a line that is not a violation are failures, so no marker
outlives its violation.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

LAYER = {"lib": 0, "platform": 1, "store": 2, "services": 3}
FEATURE = 4
ROOT_LAYER = 5
TAGS = ("GF-087", "GF-050", "ADR-0021 security")
MARKER = re.compile(r"//\s*layering-exception:\s*(.*?)\s*$")
IMPORT = re.compile(r"""^\s*\.?import\s+(?:["']([^"']+)["']|(qs(?:\.\w+)+)\b|(Quickshell\.Hyprland)\b)""")
RAW_EVENT = re.compile(r"\b(?:on)?[rR]awEvent\b")
SECURITY_ALLOWED = {"lib", "services"}
PERMANENT_DIRS = ("security/lock/", "security/idle/")  # the only places the permanent tag is accepted (not polkit)
GF050_FILE = "security/idle/SleepInhibitor.qml"
GF050_IMPORT = "qs.notifications"


def line_text(path, n):
    return path.read_text(encoding="utf-8").splitlines()[n - 1]


def listing(root, sub):
    """The files (and symlinks) under root/sub: what the checkout tracks when root is its top level (an untracked scratch
    file or build tree is not the source; same rule as scripts/dev/upstream-drift.sh), every plain file otherwise (an
    export without .git, a fixture tree inside another checkout)."""
    top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode == 0 and Path(top.stdout.strip()).resolve() == Path(root).resolve():
        names = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--", sub], check=True, capture_output=True, text=True).stdout
        return sorted(p for p in (Path(root) / n for n in names.split("\0") if n) if os.path.lexists(p))
    out = []
    for dirpath, dirnames, filenames in os.walk(Path(root) / sub):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".dev")]
        out += [Path(dirpath) / n for n in filenames]
        out += [Path(dirpath) / d for d in dirnames if (Path(dirpath) / d).is_symlink()]
    return sorted(out)


def shell_sources(shell):
    return [p for p in listing(shell.parent, shell.name) if p.suffix in (".qml", ".js")]


def layer_of(module):
    if module == "shell":
        return ROOT_LAYER
    return LAYER.get(module, FEATURE)


def is_security(module):
    return module == "security" or module.startswith("security.")


def modules_of(shell):
    """Directory (relative, '' for shell/ itself) of every module: a directory holding a qmldir."""
    return {str(p.parent.relative_to(shell)) if p.parent != shell else "" for p in listing(shell.parent, shell.name) if p.name == "qmldir"}


def module_of_path(shell, mods, path):
    """Module name of a path inside shell/ (nearest ancestor with a qmldir; the root files are 'shell'); None outside."""
    try:
        rel = path.resolve().relative_to(shell.resolve())
    except ValueError:
        return None
    d = rel if path.is_dir() else rel.parent
    while True:
        key = "" if str(d) == "." else str(d)
        if key and key in mods:
            return key.replace("/", ".")
        if not key:
            return "shell"
        d = d.parent


def scan(shell):
    """Every import of every .qml/.js file of shell/: (file, line number, line text, source module, kind, target)."""
    mods = modules_of(shell)
    out = []
    for path in shell_sources(shell):
        src = module_of_path(shell, mods, path)
        raw = []  # one raw-event record per file: the Hyprland import line, else the first use
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            statements = [IMPORT.match(seg) for seg in line.split(";")]
            statements = [m for m in statements if m]
            for m in statements:
                rel_target, qs_target, hypr = m.groups()
                if hypr:
                    raw.insert(0, (path, n, line, src, "hyprland", "Quickshell.Hyprland"))
                elif qs_target:
                    name = qs_target[3:]
                    if name.replace(".", "/") not in mods:
                        out.append((path, n, line, src, "unknown", qs_target))
                    else:
                        out.append((path, n, line, src, "module", name))
                else:
                    tgt = (path.parent / rel_target)
                    dst = module_of_path(shell, mods, tgt) if tgt.exists() or tgt.parent.exists() else None
                    if dst is not None:
                        out.append((path, n, line, src, "module", dst))
            if not statements and RAW_EVENT.search(line):
                raw.append((path, n, line, src, "rawevent", "rawEvent"))
        out.extend(raw[:1])
    return out


def tarjan(nodes, edges):
    """Strongly connected components with more than one node (self edges are not imports between modules)."""
    index, low, on, stack, comps = {}, {}, set(), [], []
    counter = [0]

    def visit(v):
        index[v] = low[v] = counter[0]
        counter[0] += 1
        stack.append(v)
        on.add(v)
        for w in sorted(edges.get(v, ())):
            if w not in index:
                visit(w)
                low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                on.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                comps.append(sorted(comp))

    sys.setrecursionlimit(10000)
    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return sorted(comps)


def analyze(shell):
    """Returns (violations, graph): violations are (file, line number, reason, marker tag or None); graph is (nodes, edges)."""
    imports = scan(shell)
    nodes, edges = set(), {}
    for _, _, _, src, kind, tgt in imports:
        nodes.add(src)
        if kind == "module" and tgt != src:
            nodes.add(tgt)
            edges.setdefault(src, set()).add(tgt)

    def upward(src, tgt):
        if is_security(src) and not is_security(tgt):
            return tgt not in SECURITY_ALLOWED
        a, b = layer_of(src), layer_of(tgt)
        return b >= a and not (a == b == FEATURE)

    # Feature edges that lie on a cycle of the feature graph with every layer violation removed.
    kept = {s: {t for t in ts if not upward(s, t)} for s, ts in edges.items()}
    in_cycle = {frozenset((s, t)) for comp in tarjan(nodes, kept) for s in comp for t in kept.get(s, ()) if t in comp}

    found = []  # (path, line number, text, reason)
    for path, n, text, src, kind, tgt in imports:
        if kind == "unknown":
            found.append((path, n, text, f"{tgt} is not a module of shell/ (no qmldir)"))
        elif kind == "module" and tgt != src:
            if upward(src, tgt):
                why = ("a security module may import only lib, services and security" if is_security(src) and not is_security(tgt)
                       else f"{src} (layer {layer_of(src)}) imports {tgt} (layer {layer_of(tgt)}): imports go to a lower layer only")
                found.append((path, n, text, why))
            elif frozenset((src, tgt)) in in_cycle:
                found.append((path, n, text, f"{src} and {tgt} import each other through a cycle of feature modules"))
        elif kind in ("hyprland", "rawevent") and src != "platform":
            found.append((path, n, text, f"{tgt} outside platform: raw Hyprland events go through qs.platform"))
    flagged = {(p, n): (reason) for p, n, _, reason in found}

    violations = []
    lines = {}
    for path, n, text, _ in found:
        lines[(path, n)] = text
    for (path, n), reason in sorted(flagged.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        m = MARKER.search(lines[(path, n)])
        tag = m.group(1) if m else None
        violations.append((path, n, reason, tag))
    # Markers on lines that are not violations (stale), checked over every line of every file.
    for path in shell_sources(shell):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = MARKER.search(line)
            if m and (path, n) not in flagged:
                violations.append((path, n, "stale marker: this line is not a layering violation", m.group(1)))
    return violations, (nodes, edges)


def problems(shell, root=None):
    root = root or shell.parent
    out = []
    violations, _ = analyze(shell)
    for path, n, reason, tag in violations:
        where = f"{path.relative_to(root)}:{n}"
        rel = path.relative_to(shell).as_posix()
        stale = reason.startswith("stale marker")
        if tag is None:
            out.append(f"{where}: {reason}; fix the import or mark the line `// layering-exception: GF-087`")
        elif tag not in TAGS:
            out.append(f"{where}: unknown layering-exception tag {tag!r} (known: {', '.join(TAGS)})")
        elif stale:
            out.append(f"{where}: {reason} (remove the `layering-exception: {tag}` marker)")
        elif tag == "ADR-0021 security" and not rel.startswith(PERMANENT_DIRS):
            out.append(f"{where}: the permanent `ADR-0021 security` marker is for shell/security/lock and shell/security/idle only")
        elif tag == "ADR-0021 security" and "Quickshell.Hyprland" not in reason and "rawEvent" not in reason:
            out.append(f"{where}: the permanent `ADR-0021 security` marker covers raw Hyprland events only ({reason})")
        elif tag == "GF-050" and not (rel == GF050_FILE and GF050_IMPORT in line_text(path, n)):
            out.append(f"{where}: the `GF-050` marker is for the `import qs.notifications` line of shell/{GF050_FILE} only")
    return out


def tree_problems(root):
    """A test tree that links shell module directories (qs.<module> resolves through them) must link shell/lib too:
    every module may import qs.lib, and a tree without the link fails at load time (main 31bce38: lock_surfaces)."""
    shell = (root / "shell").resolve()
    lib = shell / "lib"
    out = []
    by_dir = {}
    for p in listing(root, "tests"):
        if p.is_symlink():
            by_dir.setdefault(p.parent, []).append(p)
    for here, links in sorted(by_dir.items()):
        targets = {}
        for link in links:
            real = link.resolve()
            if real.is_dir() and real != lib and (real / "qmldir").exists():
                try:
                    real.relative_to(shell)
                except ValueError:
                    continue
                targets[link.name] = real
        if targets and not any(p.name == "lib" and p.resolve() == lib for p in links):
            out.append(f"{here.relative_to(root)}: links the shell module(s) {', '.join(sorted(targets))} but has no `lib` link to shell/lib "
                       f"(add `lib -> {os.path.relpath(lib, here)}`)")
    return out


def describe(shell):
    violations, (nodes, edges) = analyze(shell)
    lines = ["modules (layer):"]
    for m in sorted(nodes, key=lambda x: (layer_of(x), x)):
        lines.append(f"  {m} ({layer_of(m)})")
    lines.append("edges:")
    for s in sorted(edges):
        lines.append(f"  {s} -> {', '.join(sorted(edges[s]))}")
    comps = tarjan(nodes, edges)
    lines.append("strongly connected components (all imports): " + (("; ".join(", ".join(c) for c in comps)) or "none"))
    counts = {}
    for path, _, _, tag in violations:
        counts[(str(path.relative_to(shell)), tag)] = counts.get((str(path.relative_to(shell)), tag), 0) + 1
    lines.append(f"violations: {len(violations)}")
    for (f, tag), c in sorted(counts.items()):
        lines.append(f"  {f}: {c} ({tag or 'UNMARKED'})")
    for path, n, reason, tag in violations:
        lines.append(f"  {path.relative_to(shell)}:{n}: {reason} [{tag or 'UNMARKED'}]")
    return "\n".join(lines)


# --- selftest ---------------------------------------------------------------------------------------------------------

def build(tmp, files):
    shell = tmp / "shell"
    for rel, text in files.items():
        p = shell / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return shell


def modules(*names):
    return {f"{n.replace('.', '/')}/qmldir": f"module qs.{n}\n" for n in names}


def selftest():
    failures = []
    base_mods = modules("lib", "platform", "store", "services", "dock", "desktop", "search", "launchpad", "notifications", "security", "security.lock", "security.idle", "security.polkit")

    def run(name, files, expect):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            shell = build(tmp, {**base_mods, **files})
            got = problems(shell, tmp)
            ok = (not got) if expect is None else any(expect in g for g in got)
            if not ok:
                failures.append(f"{name}: expected {'no problem' if expect is None else repr(expect)}, got {got}")

    clean = {
        "services/Apps.qml": "import qs.platform\nimport qs.store\nimport qs.lib\nItem {}\n",
        "dock/Dock.qml": "import qs.services\nimport qs.platform\nimport \"DockModel.js\" as M\nItem {}\n",
        "dock/DockModel.js": ".pragma library\n",
        "platform/Compositor.qml": "import Quickshell.Hyprland\nimport qs.lib\nItem { function onRawEvent() {} }\n",
        "lib/Mode.qml": "Item {}\n",
        "shell.qml": "import qs.dock\nimport qs.services\nShellRoot {}\n",
    }
    run("clean tree", clean, None)
    run("new unmarked upward import fails (qs)", {**clean, "services/Apps.qml": "import qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("the same line marked passes", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: GF-087\nItem {}\n"}, None)
    run("new unmarked upward import fails (relative file)", {**clean, "services/Apps.qml": 'import "../dock/DockModel.js" as M\nItem {}\n'}, "imports go to a lower layer only")
    run("relative file marked passes", {**clean, "services/Apps.qml": 'import "../dock/DockModel.js" as M // layering-exception: GF-087\nItem {}\n'}, None)
    run("relative directory import counts", {**clean, "platform/Compositor.qml": 'import "../services"\nItem {}\n'}, "imports go to a lower layer only")
    run("JS .import counts", {**clean, "platform/X.js": '.import "../services/Y.js" as Y\n', "services/Y.js": ".pragma library\n"}, "imports go to a lower layer only")
    run("lib imports no module", {**clean, "lib/Mode.qml": "import qs.platform\nItem {}\n"}, "imports go to a lower layer only")
    run("platform imports lib only", {**clean, "platform/Compositor.qml": "import Quickshell.Hyprland\nimport qs.store\nItem {}\n"}, "imports go to a lower layer only")
    run("a commented import is not an import", {**clean, "services/Apps.qml": "// import qs.dock\nItem {}\n"}, None)
    run("a tag naming nothing known fails", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: because\nItem {}\n"}, "unknown layering-exception tag")
    run("a stale marker fails", {**clean, "services/Apps.qml": "import qs.platform // layering-exception: GF-087\nItem {}\n"}, "stale marker")
    run("an unknown module fails", {**clean, "services/Apps.qml": "import qs.nothing\nItem {}\n"}, "is not a module")
    run("a second import on the same line counts", {**clean, "services/Apps.qml": "import QtQuick; import qs.dock\nItem {}\n"}, "imports go to a lower layer only")
    run("a second import on the same line, marked, passes", {**clean, "services/Apps.qml": "import QtQuick; import qs.dock // layering-exception: GF-087\nItem {}\n"}, None)
    run("a single-quoted path counts", {**clean, "services/Apps.qml": "import '../dock/DockModel.js' as M\nItem {}\n"}, "imports go to a lower layer only")
    run("a single-quoted path, marked, passes", {**clean, "services/Apps.qml": "import '../dock/DockModel.js' as M // layering-exception: GF-087\nItem {}\n"}, None)
    run("Hyprland as a second import counts", {**clean, "search/S.qml": "import QtQuick; import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("feature to feature while acyclic passes", {**clean, "desktop/D.qml": "import qs.dock\nItem {}\n"}, None)
    cycle = {**clean, "desktop/D.qml": "import qs.dock\nItem {}\n", "dock/Dock.qml": "import qs.services\nimport qs.desktop\nItem {}\n"}
    run("a feature cycle fails", cycle, "through a cycle of feature modules")
    run("a feature cycle marked on both lines passes",
        {**cycle, "desktop/D.qml": "import qs.dock // layering-exception: GF-087\nItem {}\n",
         "dock/Dock.qml": "import qs.services\nimport qs.desktop // layering-exception: GF-087\nItem {}\n"}, None)
    run("raw Hyprland events outside platform fail", {**clean, "search/S.qml": "import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("rawEvent without the import fails", {**clean, "search/S.qml": "Item { function onRawEvent() {} }\n"}, "raw Hyprland events go through qs.platform")
    run("a temporary marker covers a raw event import", {**clean, "search/S.qml": "import Quickshell.Hyprland // layering-exception: GF-087\nItem {}\n"}, None)
    run("raw Hyprland in the lock without a marker fails", {**clean, "security/lock/Lock.qml": "import Quickshell.Hyprland\nItem {}\n"}, "raw Hyprland events go through qs.platform")
    run("raw Hyprland in the lock with the permanent marker passes",
        {**clean, "security/lock/Lock.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, None)
    run("the permanent marker outside security fails",
        {**clean, "search/S.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("the permanent marker covers raw events only",
        {**clean, "security/lock/Lock.qml": "import qs.dock // layering-exception: ADR-0021 security\nItem {}\n"}, "covers raw Hyprland events only")
    run("security imports lib, services and security", {**clean, "security/lock/Lock.qml": "import qs.lib\nimport qs.services\nimport qs.security.idle\nItem {}\n"}, None)
    run("security importing a feature fails", {**clean, "security/lock/Lock.qml": "import qs.desktop\nItem {}\n"}, "may import only lib, services and security")
    run("security importing platform fails", {**clean, "security/lock/Lock.qml": "import qs.platform\nItem {}\n"}, "may import only lib, services and security")
    run("a security import marked GF-050 passes",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.notifications // layering-exception: GF-050\nItem {}\n"}, None)
    run("GF-050 on another import of that file fails",
        {**clean, "security/idle/SleepInhibitor.qml": "import qs.search // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("GF-050 in another file fails",
        {**clean, "security/idle/Idle.qml": "import qs.notifications // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("GF-050 outside security fails", {**clean, "services/Apps.qml": "import qs.dock // layering-exception: GF-050\nItem {}\n"}, "`GF-050` marker is for the")
    run("the permanent marker in the idle module passes",
        {**clean, "security/idle/Idle.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, None)
    run("the permanent marker in polkit fails",
        {**clean, "security/polkit/Auth.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("the permanent marker in security itself fails",
        {**clean, "security/Mod.qml": "import Quickshell.Hyprland // layering-exception: ADR-0021 security\nItem {}\n"}, "shell/security/lock and shell/security/idle only")
    run("a feature importing security is a feature edge", {**clean, "dock/Dock.qml": "import qs.services\nimport qs.security.lock\nItem {}\n"}, None)
    run("a file of the module itself is no edge", {**clean, "dock/Dock.qml": 'import "."\nimport "DockModel.js" as M\nItem {}\n'}, None)

    # Test trees: a tree that links a shell module directory links lib too.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **clean})
        tree = tmp / "tests" / "shell" / "case"
        tree.mkdir(parents=True)
        (tree / "services").symlink_to("../../../shell/services")
        (tree / "Dock.qml").symlink_to("../../../shell/dock/Dock.qml")  # a file link is no module link
        if not any("no `lib` link" in p for p in tree_problems(tmp)):
            failures.append("test tree without lib passes")
        (tree / "lib").symlink_to("../../../shell/lib")
        if tree_problems(tmp):
            failures.append(f"test tree with lib fails: {tree_problems(tmp)}")
        (tree / "lib").unlink()
        (tree / "lib").symlink_to("../../../shell/store")
        if not any("no `lib` link" in p for p in tree_problems(tmp)):
            failures.append("a lib link to another module passes")
        other = tmp / "tests" / "shell" / "files_only"
        other.mkdir()
        (other / "Dock.qml").symlink_to("../../../shell/dock/Dock.qml")
        if any("files_only" in p for p in tree_problems(tmp)):
            failures.append("a tree with file links only needs no lib")

    # In a checkout top level only tracked files count: an untracked stray file with a violating import, or a stray test tree
    # without lib, is not the source.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **clean})
        tree = tmp / "tests" / "shell" / "case"
        tree.mkdir(parents=True)
        (tree / "services").symlink_to("../../../shell/services")
        (tree / "lib").symlink_to("../../../shell/lib")

        def vcs(*a):
            return subprocess.run(["git", "-C", str(tmp), *a], capture_output=True, text=True)

        if vcs("init", "-q").returncode != 0:
            failures.append("git init failed in the selftest tree")
        else:
            vcs("add", "-A")
            (shell / "services" / "Stray.qml").write_text("import qs.dock\nItem {}\n", encoding="utf-8")
            stray = tmp / "tests" / "shell" / "stray"
            stray.mkdir()
            (stray / "services").symlink_to("../../../shell/services")
            if problems(shell, tmp) or tree_problems(tmp):
                failures.append(f"an untracked stray file counts: {problems(shell, tmp) + tree_problems(tmp)}")
            vcs("add", "-A")
            if not any("Stray.qml" in x for x in problems(shell, tmp)) or not any("stray" in x for x in tree_problems(tmp)):
                failures.append("a tracked stray file is not seen")

    # The strongly connected components: the whole graph, then the feature graph without layer violations.
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        shell = build(tmp, {**base_mods, **cycle, "services/Apps.qml": "import qs.dock\nItem {}\n"})
        _, (nodes, edges) = analyze(shell)
        comps = tarjan(nodes, edges)
        if comps != [["desktop", "dock", "services"]]:
            failures.append(f"SCC of the whole graph: {comps}")
    return failures


def main(argv):
    root = Path(__file__).resolve().parents[2]
    shell = root / "shell"
    if "--selftest" in argv:
        failures = selftest()
        for f in failures:
            print("FAIL: " + f)
        print("import-graph selftest: " + ("FAILED" if failures else "ok"))
        return 1 if failures else 0
    if "--graph" in argv:
        print(describe(shell))
        return 0
    bad = problems(shell, root) + tree_problems(root)
    for line in bad:
        print(line)
    violations, _ = analyze(shell)
    print(f"import-graph: {'FAILED, ' + str(len(bad)) + ' problem(s)' if bad else 'ok'} ({sum(1 for v in violations if v[3])} marked exception(s))")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
