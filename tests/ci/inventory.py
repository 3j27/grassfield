#!/usr/bin/env python3
"""Test inventory gate (docs/testing/README.md, "Test inventory").

tests/inventory.json lists every required test with exactly one layer. This script fails when

  * a test file matched by a `discover` glob is neither registered nor in `ignore`;
  * a registered test (or an ignored path) does not exist;
  * a registered test is disabled ("enabled": false);
  * a test has no layer, an unknown layer, two layers (a `layers` key, or the same path registered twice);
  * a QML test file declares a `<name>_data` function (a QtTest data provider) with no `<name>` test function, which
    QtTest then never runs as a test (GF-122: a bare `test_data` is such a name);
  * a run reports no result for a layer it was asked to run (--results).

Python standard library only. Run it isolated:

  python3 -I tests/ci/inventory.py                     static check (part of `just check`)
  python3 -I tests/ci/inventory.py --selftest          the checks above on temporary fixtures
  python3 -I tests/ci/inventory.py --map               "path<TAB>layer<TAB>runner" of every enabled test
  python3 -I tests/ci/inventory.py --results FILE [--layers data,logic]
                                                       FILE: lines "layer<TAB>id<TAB>pass|fail|skip" written by
                                                       scripts/dev/test.sh; every selected layer needs a pass or a fail
"""
import argparse
import glob
import json
import os
import re
import sys
import tempfile

RUNNERS = ("test.sh", "bare")
STATUSES = ("pass", "fail", "skip")


def load(root):
    with open(os.path.join(root, "tests", "inventory.json"), encoding="utf-8") as f:
        return json.load(f)


def discovered(root, inv):
    found = set()
    for pattern in inv.get("discover", []):
        for p in glob.glob(os.path.join(root, pattern)):
            if os.path.isfile(p):
                found.add(os.path.relpath(p, root))
    return found


DATA_FN = re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)_data\s*\(", re.M)
ANY_FN = re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)


def orphan_data_providers(text):
    """Names `<x>_data` whose test `<x>` is missing: QtTest takes them as data providers, never as tests."""
    fns = set(ANY_FN.findall(text))
    return sorted(f"{n}_data" for n in set(DATA_FN.findall(text)) if n not in fns and n != "initTestCase")


def check(root, inv=None):
    """Return the list of problems of the inventory under `root` (empty when it is consistent)."""
    problems = []
    if inv is None:
        try:
            inv = load(root)
        except (OSError, ValueError) as e:
            return [f"cannot read tests/inventory.json: {e}"]
    if inv.get("version") != 1:
        problems.append("inventory: version must be 1")
    layers = inv.get("layers")
    if not isinstance(layers, list) or not layers or not all(isinstance(x, str) for x in layers):
        return problems + ["inventory: `layers` must be a non-empty list of names"]
    seen = {}
    for i, t in enumerate(inv.get("tests", [])):
        path = t.get("path") if isinstance(t, dict) else None
        if not isinstance(path, str) or not path:
            problems.append(f"tests[{i}]: no path")
            continue
        if "layers" in t:
            problems.append(f"{path}: `layers` is not allowed, a test has exactly one `layer`")
        layer = t.get("layer")
        if layer is None:
            problems.append(f"{path}: no layer")
        elif not isinstance(layer, str) or layer not in layers:
            problems.append(f"{path}: unknown layer {layer!r} (known: {', '.join(layers)})")
        if path in seen:
            problems.append(f"{path}: registered twice (layers {seen[path]!r} and {layer!r}): exactly one layer")
        seen[path] = layer
        if t.get("runner", "test.sh") not in RUNNERS:
            problems.append(f"{path}: runner must be one of {', '.join(RUNNERS)}")
        if t.get("enabled", True) is not True:
            problems.append(f"{path}: disabled (a required test cannot be switched off; remove it with a reason in the commit)")
        if not os.path.isfile(os.path.join(root, path)):
            problems.append(f"{path}: registered but the file does not exist")
    for path in sorted(seen):
        if path.endswith(".qml") and os.path.isfile(os.path.join(root, path)):
            with open(os.path.join(root, path), encoding="utf-8") as f:
                for name in orphan_data_providers(f.read()):
                    problems.append(f"{path}: `{name}` is a QtTest data provider without a `{name[:-5]}` test function, "
                                    "so it never runs (rename it, e.g. test_dataSizes)")
    ignored = {}
    for e in inv.get("ignore", []):
        p = e.get("path") if isinstance(e, dict) else None
        if not p or not e.get("reason"):
            problems.append(f"ignore entry {e!r}: needs a path and a reason")
            continue
        ignored[p] = e["reason"]
        if p in seen:
            problems.append(f"{p}: both registered and ignored")
        if not os.path.isfile(os.path.join(root, p)):
            problems.append(f"{p}: ignored but the file does not exist")
    for p in sorted(discovered(root, inv)):
        if p not in seen and p not in ignored:
            problems.append(f"{p}: test file not registered in tests/inventory.json (add it with a layer, or ignore it with a reason)")
    return problems


def check_results(inv, lines, selected):
    """Problems of a run: `lines` are "layer<TAB>id<TAB>status" records, `selected` the layers it had to cover."""
    problems = []
    layers = inv.get("layers", [])
    counts = {}
    for n, line in enumerate(lines, 1):
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 3 or parts[0] not in layers or parts[2] not in STATUSES:
            problems.append(f"results line {n}: malformed or unknown layer/status: {line!r}")
            continue
        c = counts.setdefault(parts[0], {s: 0 for s in STATUSES})
        c[parts[2]] += 1
    for layer in selected:
        if layer not in layers:
            problems.append(f"layer {layer!r} is not in the inventory")
            continue
        c = counts.get(layer)
        if c is None:
            problems.append(f"layer {layer}: no result in this run")
        elif c["pass"] + c["fail"] == 0:
            problems.append(f"layer {layer}: every check skipped ({c['skip']}), nothing was verified")
    return problems


def selftest():
    failures = []
    cases = [0]

    def expect(name, problems, needle):
        cases[0] += 1
        hit = (not problems) if needle is None else any(needle in p for p in problems)
        if not hit:
            failures.append(f"{name}: wanted {needle!r}, got {problems}")

    def make(files, tests, discover=("tests/t/*.sh",), ignore=()):
        d = tempfile.mkdtemp(prefix="inventory-selftest.")
        os.makedirs(os.path.join(d, "tests", "t"))
        for f in files:
            with open(os.path.join(d, f), "w", encoding="utf-8") as fh:
                fh.write("#!/bin/sh\n")
        inv = {"version": 1, "layers": ["data", "logic"], "discover": list(discover), "ignore": list(ignore), "tests": tests}
        with open(os.path.join(d, "tests", "inventory.json"), "w", encoding="utf-8") as fh:
            json.dump(inv, fh)
        return d, inv

    a = {"path": "tests/t/a.sh", "layer": "logic"}
    expect("consistent", check(*make(["tests/t/a.sh"], [a])), None)
    expect("unregistered", check(*make(["tests/t/a.sh", "tests/t/b.sh"], [a])), "tests/t/b.sh: test file not registered")
    expect("ignored ok", check(*make(["tests/t/a.sh", "tests/t/b.sh"], [a], ignore=[{"path": "tests/t/b.sh", "reason": "helper"}])), None)
    expect("ignored no reason", check(*make(["tests/t/a.sh", "tests/t/b.sh"], [a], ignore=[{"path": "tests/t/b.sh"}])), "needs a path and a reason")
    expect("missing", check(*make([], [a])), "registered but the file does not exist")
    expect("disabled", check(*make(["tests/t/a.sh"], [dict(a, enabled=False)])), "disabled")
    expect("no layer", check(*make(["tests/t/a.sh"], [{"path": "tests/t/a.sh"}])), "no layer")
    expect("unknown layer", check(*make(["tests/t/a.sh"], [dict(a, layer="gpu")])), "unknown layer")
    expect("two layers (key)", check(*make(["tests/t/a.sh"], [dict(a, layers=["data", "logic"])])), "`layers` is not allowed")
    expect("two layers (twice)", check(*make(["tests/t/a.sh"], [a, dict(a, layer="data")])), "registered twice")
    expect("bad runner", check(*make(["tests/t/a.sh"], [dict(a, runner="cron")])), "runner must be")

    expect("orphan data provider", orphan_data_providers("function test_data() {}\n"), "test_data")
    expect("data provider with its test", [] if not orphan_data_providers(
        "function test_values_data() {}\nfunction test_values(d) {}\nfunction initTestCase_data() {}\n") else ["x"], None)

    inv = {"layers": ["data", "logic", "nested"]}
    ok = ["data\tx\tpass\n", "logic\ty\tfail\n"]
    expect("results ok", check_results(inv, ok, ["data", "logic"]), None)
    expect("layer without result", check_results(inv, ok, ["data", "nested"]), "layer nested: no result")
    expect("layer all skipped", check_results(inv, ok + ["nested\tz\tskip\n"], ["nested"]), "every check skipped")
    expect("malformed results", check_results(inv, ["data\tx\tmaybe\n"], ["data"]), "malformed")
    expect("unknown selected layer", check_results(inv, ok, ["gpu"]), "not in the inventory")

    if failures:
        print("\n".join("FAIL: " + f for f in failures))
        return 1
    print(f"inventory selftest: PASS ({cases[0]} cases)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--map", action="store_true")
    ap.add_argument("--results")
    ap.add_argument("--layers", default="")
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    if args.selftest:
        return selftest()
    if args.map:
        inv = load(root)
        for t in inv["tests"]:
            if t.get("enabled", True) is True:
                print(f"{t['path']}\t{t['layer']}\t{t.get('runner', 'test.sh')}")
        return 0
    problems = check(root)
    if args.results:
        inv = load(root)
        with open(args.results, encoding="utf-8") as f:
            selected = [x for x in args.layers.split(",") if x]
            problems += check_results(inv, f.readlines(), selected or inv["layers"])
    if problems:
        print("\n".join("FAIL: " + p for p in problems))
        return 1
    inv = load(root)
    per = {}
    for t in inv["tests"]:
        per[t["layer"]] = per.get(t["layer"], 0) + 1
    print("inventory: ok (" + ", ".join(f"{k} {per.get(k, 0)}" for k in inv["layers"]) + f"; {sum(per.values())} tests)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
