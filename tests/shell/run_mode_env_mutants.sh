#!/usr/bin/env bash
# The mutation suite of tests/shell/run_mode_env.sh (ADR-0019): every gate-opening change of shell/lib it must catch, built as a scratch
# copy under .dev/ (the real tree is never touched), each of which must make the check FAIL; the unmodified copy and a comments-and-layout
# copy must pass. See tests/shell/run_mode_env.d/mutants.py. Optional argument: a text the mutant labels must contain.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. Runs offscreen; under three minutes.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I tests/shell/run_mode_env.d/mutants.py "$@"
