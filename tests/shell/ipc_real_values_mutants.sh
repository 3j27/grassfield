#!/usr/bin/env bash
# Mutation check of tests/shell/ipc_real_values.sh: every way of reading a fixture-backed Audio or Brightness member in the
# controlcenter IPC handler (optional chaining, bracket access, spaces and line breaks around the dot, aliasing) must make it
# fail, and the real file must pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 -I - "$root" <<'PY'
import os
import subprocess
import sys
import tempfile

root = sys.argv[1]
src = open(root + "/shell/menubar/MenuBar.qml", encoding="utf-8").read()
needle = "Audio.deviceVolume.toFixed(2)"
if needle not in src:
    print("FAIL: the mutation point is gone from MenuBar.qml; update this test")
    sys.exit(1)
mutants = {
    "m5 Audio?.muted": 'Audio?.muted ? "m" : Audio.deviceVolume.toFixed(2)',
    "m6 Audio?.[\"muted\"]": 'Audio?.["muted"]',
    "m7 Audio .muted": "Audio .muted",
    "m8 line break before .muted": "Audio\n                .muted",
    "m9 alias": "(() => { const a = Audio; return a.muted; })()",
    "m10 Audio[\"volume\"]": 'Audio["volume"].toFixed(2)',
    "m11 Audio.volume": "Audio.volume.toFixed(2)",
    "m12 Brightness.level": "Brightness.level.toFixed(2)",
}
bad = False
for name, repl in mutants.items():
    with tempfile.NamedTemporaryFile("w", suffix=".qml", delete=False) as f:
        f.write(src.replace(needle, repl, 1))
    p = subprocess.run([root + "/tests/shell/ipc_real_values.sh", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    if p.returncode == 0:
        print("FAIL: mutant %s was not caught" % name)
        bad = True
    else:
        print("PASS mutant %s fails the check" % name)
p = subprocess.run([root + "/tests/shell/ipc_real_values.sh"], capture_output=True, text=True)
if p.returncode != 0:
    print("FAIL: the real MenuBar.qml does not pass: " + p.stdout.strip())
    bad = True
else:
    print("PASS the real MenuBar.qml passes")
sys.exit(1 if bad else 0)
PY
