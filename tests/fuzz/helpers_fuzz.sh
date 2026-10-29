#!/usr/bin/env bash
# Mutation fuzzing of the session helpers' readers (ADR-0041 step 5, T-1): tests/fuzz/fuzz_helpers.py on
# grassfield-crash-watch, grassfield-session-end, grassfield-battery-watch, the ANR stand-in's client matcher, the
# `omarchy-shell lock status` filter and the sleep-lock gate, each against its own contract (see that file's header), with
# the mutator's self-test first. Everything runs on scratch files and stubs; no session, no D-Bus, nothing real is touched.
# Budget: GF_FUZZ_ITERATIONS (default 1500 in-process, a fifth for the scenarios that start a process), GF_FUZZ_SEED.
# Prints PASS/FAIL lines; exit 0 when every scenario passed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/fuzz-helpers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
python3 -I "$root/tests/fuzz/mutate.py" --selftest || fail=1
python3 -I "$root/tests/fuzz/fuzz_helpers.py" "$root" "$tmp" "$@" || fail=1
if ((fail)); then echo "helpers_fuzz: FAIL"; exit 1; fi
echo "helpers_fuzz: PASS"
