#!/usr/bin/env python3
"""MenuBridge's socket path follows the shared run-mode rule (ADR-0019): the bridge process already does (M7), so the shell must too.

Before, the shell read GRASSFIELD_DEV by hand: with only GRASSFIELD_DEV=1 leaked into a real session it got an empty socket path and
never connected, so global menus stopped although the bridge itself followed the rule. Each case starts the real MenuBridge singleton
offscreen in a clean environment (a scratch XDG_RUNTIME_DIR, no bridge) and checks the path it computes.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RUNTIME = "/run/user/gf-test"
SOCK = "/dev/shm/gf-test/menu-bridge.sock"
CASES = [
    # (name, extra environment, expected path or "-" for empty)
    ("a real session", {"GRASSFIELD_SESSION": "1"}, RUNTIME + "/grassfield/menu-bridge.sock"),
    ("a real session with only GRASSFIELD_DEV=1 leaked into it", {"GRASSFIELD_DEV": "1", "GRASSFIELD_SESSION": "1"}, RUNTIME + "/grassfield/menu-bridge.sock"),
    ("a real session that has a socket override set (dev plumbing is inert)", {"GRASSFIELD_SESSION": "1", "GRASSFIELD_MENU_BRIDGE_SOCKET": SOCK}, RUNTIME + "/grassfield/menu-bridge.sock"),
    ("a leaked dev and a socket override in a real session", {"GRASSFIELD_DEV": "1", "GRASSFIELD_SESSION": "1", "GRASSFIELD_MENU_BRIDGE_SOCKET": SOCK}, RUNTIME + "/grassfield/menu-bridge.sock"),
    ("a dev session with its socket", {"GRASSFIELD_DEV": "1", "GRASSFIELD_MENU_BRIDGE_SOCKET": SOCK}, SOCK),
    ("a dev session without a socket: none, never the owner's", {"GRASSFIELD_DEV": "1"}, "-"),
    ("no variable at all", {}, RUNTIME + "/grassfield/menu-bridge.sock"),
]


def probe(case, tmp_root):
    name, extra, want = case
    tmp = Path(tempfile.mkdtemp(prefix="m-", dir=tmp_root))
    cfg = tmp / "cfg"
    cfg.mkdir()
    for entry in (ROOT / "shell").iterdir():
        if entry.name != "shell.qml":
            (cfg / entry.name).symlink_to(entry)
    shutil.copy(Path(__file__).with_name("probe.qml"), cfg / "shell.qml")
    for d in ("cache", "home"):
        (tmp / d).mkdir(mode=0o700)
    runtime = tmp / "runtime"
    runtime.mkdir(mode=0o700)  # qs needs a real, writable runtime directory: the answer is computed from XDG_RUNTIME_DIR as set below
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp / "home"), "XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(tmp / "cache"),
           "QT_QPA_PLATFORM": "offscreen", "QML_IMPORT_PATH": f"{ROOT}/ui:{ROOT}/.dev/build/qml", "GRASSFIELD_LANG": "en"}
    env.update(extra)
    expected = want.replace(RUNTIME, str(runtime))
    try:
        r = subprocess.run(["nice", "-n", "19", "qs", "-p", str(cfg), "--no-color"], capture_output=True, text=True, env=env, timeout=90)
        line = next((l for l in (r.stdout + r.stderr).splitlines() if "SOCKET " in l), None)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [f"{name}: {e}"]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if line is None:
        return [f"{name}: the probe printed nothing (qs exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}"]
    got = line.split("SOCKET ", 1)[1].strip()
    return [] if got == expected else [f"{name}: the socket path is {got!r}, expected {expected!r}"]


def main():
    work = ROOT / ".dev"
    work.mkdir(exist_ok=True)
    tmp_root = Path(tempfile.mkdtemp(prefix="menubridge-socket-", dir=work))
    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda c: probe(c, tmp_root), CASES))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    failures = [p for r in results for p in r]
    for f in failures:
        print("FAIL: menubridge_socket " + f)
    if failures:
        return 1
    print(f"PASS: menubridge_socket the shell's socket path follows the run-mode rule ({len(CASES)} environments, a leaked GRASSFIELD_DEV included)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
