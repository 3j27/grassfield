#!/usr/bin/env python3
"""The real qs.lib Mode singleton in every environment of tests/fixtures/run-mode-vectors.json (ADR-0019).

Behaviour, not source text: for each vector the shell probe (probe.qml) is started offscreen with exactly that environment and
prints what Mode.dev, session, fixtures, ownBus, updateNotices, refused, configDir, stateDir and devValue(...) answer. The
vectors include a packaged session (GRASSFIELD_SESSION=1, no dev) and a leaked GRASSFIELD_DEV=1 with SESSION=1, so a gate
that opens in a real session fails here, whatever the source looks like. The probe also lists every member of the singleton: a
member the table does not know (a new property, function or signal, under any spelling) fails.

  tests/shell/run_mode_env.sh                      run the vectors against shell/lib
  GF_RUN_MODE_LIB=<dir> tests/shell/run_mode_env.sh  against another copy of the lib module (the mutation checks)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LIB = Path(os.environ.get("GF_RUN_MODE_LIB", ROOT / "shell" / "lib")).resolve()
VECTORS = json.loads((ROOT / "tests" / "fixtures" / "run-mode-vectors.json").read_text(encoding="utf-8"))
# The members of the QObject base that every singleton has, and the signal each property adds.
BASE_MEMBERS = {"children", "objectName", "objectNameChanged", "reloadableId"}
MEMBERS = VECTORS["members"]
EXPECTED_MEMBERS = sorted(BASE_MEMBERS | set(MEMBERS["properties"]) | {p + "Changed" for p in MEMBERS["properties"]} | set(MEMBERS["functions"]))
REFUSED = VECTORS["refused"]


def jobs():
    """(name, environment, expected answers) of every vector; the answers a vector does not state are not checked."""
    out = []
    for v in VECTORS["modes"]:
        out.append((f"mode: {v['name']}", v["env"], {k: v[k] for k in ("dev", "session", "fixtures", "ownBus", "updateNotices")}))
    for v in VECTORS["dirs"]:
        out.append((f"dirs: {v['name']}", v["env"], {"configDir": v["configDir"], "stateDir": v["stateDir"]}))
    for v in VECTORS["plumbing"]:
        name = v["variable"].removeprefix("GRASSFIELD_")
        out.append((f"plumbing: {v['name']}", v["env"], {"devValues": {name: v["value"]}}))
    return out


def probe(job, tmp_root):
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
    names = sorted({n.removeprefix("GRASSFIELD_") for n in vector_env if n.startswith("GRASSFIELD_")} | set(expected.get("devValues", {})))
    env["GF_PROBE_NAMES"] = ",".join(names)
    env.update(vector_env)  # exactly the vector's variables (HOME included when it sets one)
    try:
        r = subprocess.run(["nice", "-n", "19", "qs", "-p", str(cfg), "--no-color"], capture_output=True, text=True, env=env, timeout=90)
        line = next((l for l in (r.stdout + r.stderr).splitlines() if "RUNMODE " in l), None)
        if line is None:
            return [f"{name}: the probe printed nothing (qs exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}"]
        got = json.loads(line.split("RUNMODE ", 1)[1])
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        return [f"{name}: {e}"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    problems = []
    if got["members"] != EXPECTED_MEMBERS:
        problems.append(f"{name}: members {sorted(set(got['members']) ^ set(EXPECTED_MEMBERS))} differ from the table")
    if got["refused"] != REFUSED:
        problems.append(f"{name}: refused is {got['refused']!r}, not {REFUSED!r}")
    if got["shellDirIsTheShellDir"] is not True:
        problems.append(f"{name}: shellDir is not the shell directory")
    for key, want in expected.items():
        if key == "devValues":
            for n, w in want.items():
                if got["devValues"].get(n) != w:
                    problems.append(f"{name}: devValue({n!r}) is {got['devValues'].get(n)!r}, expected {w!r}")
        elif got[key] != want:
            problems.append(f"{name}: {key} is {got[key]!r}, expected {want!r}")
    return problems


def main():
    work = ROOT / ".dev"
    work.mkdir(exist_ok=True)
    tmp_root = Path(tempfile.mkdtemp(prefix="run-mode-env-", dir=work))
    try:
        all_jobs = jobs()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda j: probe(j, tmp_root), all_jobs))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    failures = [p for r in results for p in r]
    for f in failures:
        print("FAIL: run_mode_env " + f)
    if failures:
        return 1
    print(f"PASS: run_mode_env the real Mode answers every vector ({len(all_jobs)} environments, packaged and leaked-dev sessions included)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
