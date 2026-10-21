#!/usr/bin/env bash
# The A2 limits of docs/specs/ui.md and tests/fixtures/icons/a2-limits.json (the data of tests/unit/tst_iconshader.qml) are one table: every
# cell of the JSON appears in the doc with its value and Default value, and the doc lists no cell that the JSON lacks.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
python3 -I - "$root" <<'PY'
import json, re, sys
root = sys.argv[1]
lim = json.load(open(root + "/tests/fixtures/icons/a2-limits.json"))["limits"]
doc = open(root + "/docs/specs/ui.md").read()
want = {"- `%s`: %.2f (Default %.2f)" % (e["key"], e["value"], e["default"]) for e in lim}
have = {l for l in doc.splitlines() if re.match(r"- `[ES] ", l)}
missing = sorted(want - have)
extra = sorted(have - want)
for l in missing:
    print("FAIL: ui.md lacks " + l)
for l in extra:
    print("FAIL: ui.md lists a limit that a2-limits.json lacks: " + l)
if missing or extra:
    sys.exit(1)
print("PASS: %d A2 limits agree between ui.md and a2-limits.json" % len(want))
PY
