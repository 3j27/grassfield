#!/usr/bin/env bash
# Mutation fuzzing of the session helpers' readers (ADR-0041 step 5, T-1): tests/fuzz/fuzz_helpers.py on
# grassfield-crash-watch, grassfield-session-end, grassfield-battery-watch, the ANR stand-in's client matcher, the
# `omarchy-shell lock status` filter, the sleep-lock gate and grassfield-update-check's readers, each against its own
# contract (see that file's header), with the mutator's self-test first and a determinism check last (two runs of one seed
# must mutate the same inputs). Everything runs on scratch files and stubs; no session, no D-Bus, nothing real is touched:
# the harness runs without the caller's session variables (as scripts/dev/isolated.sh starts a client) and with every home
# under the scratch directory. Budget: GF_FUZZ_ITERATIONS (default 1500 in-process, a fifth for the scenarios that start a
# process), GF_FUZZ_SEED. Prints PASS/FAIL lines; exit 0 when every scenario passed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/fuzz-helpers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/home" "$tmp/run" "$tmp/config" "$tmp/cache" "$tmp/state" "$tmp/data"
harness() { # [scenario...] -> the harness in a scrubbed environment (its own scratch directory per call)
  local scratch
  scratch=$(mktemp -d "$tmp/run-XXXXXX")
  env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS -u DBUS_SYSTEM_BUS_ADDRESS \
    HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state" \
    XDG_DATA_HOME="$tmp/data" GRASSFIELD_ISOLATED=1 python3 -I "$root/tests/fuzz/fuzz_helpers.py" "$root" "$scratch" "$@"
}
fail=0
python3 -I "$root/tests/fuzz/mutate.py" --selftest || fail=1
harness "$@" || fail=1
# Determinism: the same seed must give the same inputs twice (hash() of a str is randomised per process; a scenario's seed
# once came from it, found by the integrator's review of 265e6c7).
if [[ $# -eq 0 ]]; then
  one=$(GF_FUZZ_ITERATIONS=300 harness battery-watch session-end | grep '^\[fuzz\]') || fail=1
  two=$(GF_FUZZ_ITERATIONS=300 harness battery-watch session-end | grep '^\[fuzz\]') || fail=1
  if [[ -n $one && $one == "$two" ]]; then echo "PASS: determinism: two runs of one seed mutate the same inputs"
  else echo "FAIL: determinism: two runs of one seed differ:"; echo "$one"; echo "$two"; fail=1; fi
fi
if ((fail)); then echo "helpers_fuzz: FAIL"; exit 1; fi
echo "helpers_fuzz: PASS"
