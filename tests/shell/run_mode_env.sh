#!/usr/bin/env bash
# The real qs.lib Mode singleton in every environment of tests/fixtures/run-mode-vectors.json, a packaged session and a leaked
# GRASSFIELD_DEV=1 included (ADR-0019): behaviour, not source text. See tests/shell/run_mode_env.d/run.py.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. Runs offscreen with a clean environment per vector.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I tests/shell/run_mode_env.d/run.py
