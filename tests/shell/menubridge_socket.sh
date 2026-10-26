#!/usr/bin/env bash
# MenuBridge's socket path follows the shared run-mode rule (ADR-0019), a leaked GRASSFIELD_DEV=1 in a real session included: the real
# singleton, offscreen, in seven clean environments. See tests/shell/menubridge_socket.d/run.py.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I tests/shell/menubridge_socket.d/run.py
