#!/usr/bin/env bash
# grassfield-store-helper's deny list without root and without pacman (ADR-0045 D2, D3): its denied() cut out of the file and
# run on the vectors the Store's C++ rule runs (tests/fixtures/store/removal-vectors.json), the optional preinstalls named
# in the helper and in apps/store/src/removal.cpp the same, and Omarchy's own removal list (when installed) covered. The
# helper's other refusals (a name charset, required packages, a running pacman, an unfinished update) need root and a real
# pacman: tests/integration/store_helper.sh, in a container. Nothing is installed or removed here.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
helper=$root/packaging/store/grassfield-store-helper
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

work=$(mktemp -d "${TMPDIR:-/tmp}/store-denied.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
sed -n '/^denied() {/,/^}/p' "$helper" >"$work/denied.sh"
[[ -s $work/denied.sh ]] && ok "denied() found in the helper" || { bad "denied() not found"; exit 1; }

out=$(python3 -I - "$work/denied.sh" "$root/tests/fixtures/store/removal-vectors.json" 2>&1 <<'PY'
import json, subprocess, sys
fn, vec = sys.argv[1], json.load(open(sys.argv[2]))
script = "declare -A omarchy=() hold=()\n"
script += "".join("omarchy[%s]=1\n" % n for n in vec["omarchyLists"])
script += "".join("hold[%s]=1\n" % n for n in vec["holdPkg"])
script += open(fn).read()
script += 'while IFS= read -r n; do if denied "$n"; then echo "$n denied"; else echo "$n allowed"; fi; done\n'
names = [c["name"] for c in vec["cases"]]
res = subprocess.run(["bash", "-c", script], input="\n".join(names) + "\n", capture_output=True, text=True).stdout.split("\n")
bad = 0
for c, line in zip(vec["cases"], res):
    want = "allowed" if c["protection"] == "none" else "denied"
    if line != "%s %s" % (c["name"], want):
        print("MISMATCH %s: helper says %r, vectors say %s" % (c["name"], line, c["protection"]))
        bad += 1
print("%d vectors, %d mismatches" % (len(names), bad))
PY
)
echo "$out" | grep MISMATCH | head -5
[[ $out == *' 0 mismatches' ]] && ok "every vector: ${out##*$'\n'}" || bad "vectors: $out"

# The optional preinstalls: the helper's case arm and the C++ set name the same packages.
helper_names=$(sed -n '/^denied() {/,/^}/p' "$helper" | sed -n '/aether | cliamp/,/return ;;/p' | tr -d '\\' | sed 's/).*//' | tr '|' '\n' | tr -d ' ' | sed '/^$/d' | sort)
cpp_names=$(sed -n '/preinstalledApps()/,/^}/p' "$root/apps/store/src/removal.cpp" | grep -o 'QStringLiteral("[^"]*")' | sed 's/QStringLiteral("//; s/")//' | sort)
[[ -n $helper_names && $helper_names == "$cpp_names" ]] && ok "helper and removal.cpp name the same $(echo "$helper_names" | wc -l) preinstalled apps" ||
  bad "preinstalled apps differ: helper [$(echo $helper_names)] C++ [$(echo $cpp_names)]"

# Omarchy's own removal list (omarchy-remove-preinstalls), when this machine has it: every desktop package it drops is allowed.
list=/usr/share/omarchy/bin/omarchy-remove-preinstalls
if [[ -r $list ]]; then
  want=$(sed -n '/omarchy-pkg-drop/,/^fi/p' "$list" | grep -v 'omarchy-pkg-drop' | tr -d '\\' | grep -v '^fi' | tr -s ' ' '\n' | sed '/^$/d' | sort)
  missing=""
  for n in $want; do
    script="declare -A omarchy=() hold=(); omarchy[$n]=1; $(cat "$work/denied.sh"); denied $n && echo DENIED"
    [[ $(bash -c "$script") == DENIED ]] && missing="$missing $n"
  done
  [[ -z $missing ]] && ok "every package omarchy-remove-preinstalls drops is allowed ($(echo $want | wc -w))" ||
    echo "NOTE: Omarchy's list holds a name the helper keeps:$missing (the list changed upstream: ADR-0045 D2)"
else
  echo "SKIP: omarchy-remove-preinstalls is not installed"
fi

((fails == 0)) && exit 0
exit 1
