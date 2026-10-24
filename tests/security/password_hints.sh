#!/usr/bin/env bash
# GF-AUDIT-001 GF-118 (SEC-17): every password field of the tree tells the input method it holds a secret. A QML text
# input whose echoMode can be TextInput.Password must set inputMethodHints with Qt.ImhSensitiveData (the input method
# must not learn or store it) and Qt.ImhNoPredictiveText (no prediction or autocorrection), in the same object block.
# The lock and the polkit sheet use the shared shell/security/PasswordField.qml; the Wi-Fi field of Quick Settings has
# its own. Static source check (data layer) with a self-test on fixtures (a field without hints fails it).
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
pass() { echo "PASS: password hints $*"; }
bad() { echo "FAIL: password hints $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/password-hints.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# check.py <dir>...: one "MISSING <file>:<line>" per password field without both hints, "FIELD <file>:<line>" per field.
cat >"$tmp/check.py" <<'PY'
import os, re, sys

PASSWORD = re.compile(r"\becho[Mm]ode\s*:.*\bTextInput\.Password\b")
OPEN = re.compile(r"^\s*([A-Z][A-Za-z0-9_.]*)\s*\{\s*$")

def blocks(lines):
    # (start, end) line ranges of every QML object block "Type {" ... matching "}" (brace depth, comments ignored).
    stack, out = [], []
    for i, line in enumerate(lines):
        code = line.split("//", 1)[0]
        if OPEN.match(code):
            stack.append(i)
            continue
        for ch in code:
            if ch == "{":
                stack.append(None)
            elif ch == "}" and stack:
                start = stack.pop()
                if start is not None:
                    out.append((start, i))
    return out

for top in sys.argv[1:]:
    for dirpath, _, files in os.walk(top):
        for name in sorted(files):
            if not name.endswith(".qml"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as f:
                lines = f.read().split("\n")
            spans = blocks(lines)
            for i, line in enumerate(lines):
                if not PASSWORD.search(line.split("//", 1)[0]):
                    continue
                print(f"FIELD {path}:{i + 1}")
                inner = [s for s in spans if s[0] < i <= s[1]]
                start, end = max(inner) if inner else (0, len(lines) - 1)
                # Only the field's own lines: the bodies of objects nested in it do not count.
                nested = [(a, b) for (a, b) in spans if start < a and b <= end]
                own = [k for k in range(start, end + 1) if not any(a <= k <= b for (a, b) in nested)]
                body = "\n".join(lines[k].split("//", 1)[0] for k in own)
                hints = re.findall(r"inputMethodHints\s*:\s*([^\n]*)", body)
                if not any("ImhSensitiveData" in h and "ImhNoPredictiveText" in h for h in hints):
                    print(f"MISSING {path}:{i + 1}")
PY

# Self-test: a field with both hints passes, one without (or with only one) is reported, a nested object's hints do not
# count for the outer field.
mkdir -p "$tmp/fix"
cat >"$tmp/fix/Good.qml" <<'QML'
Item {
    TextInput {
        echoMode: TextInput.Password
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
    }
}
QML
cat >"$tmp/fix/Bad.qml" <<'QML'
Item {
    TextInput {
        echoMode: root.reveal ? TextInput.Normal : TextInput.Password
        inputMethodHints: Qt.ImhNoPredictiveText
        Item {
            property int inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
        }
    }
    TextField {
        echoMode: TextInput.Password // inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
    }
}
QML
out=$(python3 -I "$tmp/check.py" "$tmp/fix")
missing=$(grep -c '^MISSING' <<<"$out")
[[ $(grep -c '^FIELD' <<<"$out") == 3 && $missing == 2 && $out != *"MISSING $tmp/fix/Good.qml"* ]] \
  && pass "self-test: 3 fields found, the 2 without both hints reported (nested object and comment do not count)" \
  || bad "self-test: $out"

# The tree.
out=$(cd "$root" && python3 -I "$tmp/check.py" shell ui apps)
fields=$(grep -c '^FIELD' <<<"$out")
if [[ $fields -ge 2 ]]; then pass "tree: $fields password field(s) found"; else bad "tree: only $fields password field(s) found: $out"; fi
if grep -q '^MISSING' <<<"$out"; then
  bad "tree: password field(s) without ImhSensitiveData and ImhNoPredictiveText: $(grep '^MISSING' <<<"$out" | tr '\n' ' ')"
else
  pass "tree: every password field sets ImhSensitiveData and ImhNoPredictiveText"
fi
grep -q 'shell/overlay/controlcenter/WifiList.qml' <<<"$out" && pass "tree: the Wi-Fi password field is checked" || bad "tree: the Wi-Fi password field was not found"
grep -q 'shell/security/PasswordField.qml' <<<"$out" && pass "tree: the shared lock/polkit field is checked" || bad "tree: PasswordField.qml was not found"
for f in shell/security/lock/LockView.qml shell/security/polkit/AuthDialog.qml; do
  grep -q 'PasswordField {' "$root/$f" && pass "tree: $f uses the shared PasswordField" || bad "tree: $f no longer uses PasswordField"
done

exit $fail
