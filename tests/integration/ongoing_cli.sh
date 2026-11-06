#!/usr/bin/env bash
# grassfield-ongoing run reports its command's own status (ADR-0052 D7; review of the ongoing activities, item 5: a crash was
# reported as 143 whatever the signal): the exit code, 128 + the signal that ended the command, 127 when it cannot start;
# stdin and stdout are the command's. No bus is needed (the publish fails quietly and changes nothing).
# Needs the CLI built by bridges/menu-bridge/build-direct.sh (.dev/build/grassfield-ongoing), or GRASSFIELD_ONGOING_CLI.
# Usage: tests/integration/ongoing_cli.sh   Exit: 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cli=${GRASSFIELD_ONGOING_CLI:-$root/.dev/build/grassfield-ongoing}
[[ -x $cli ]] || { echo "ENVIRONMENT: $cli is not built (bridges/menu-bridge/build-direct.sh)"; exit 2; }
fail=0
expect() { # <status wanted> <command...>
  local want=$1
  shift
  "$cli" run --title Test -- "$@" >/dev/null 2>&1
  local got=$?
  if [[ $got == "$want" ]]; then echo "  PASS $* -> $got"; else echo "  FAIL $* -> $got (want $want)"; fail=1; fi
}
expect 0 true
expect 1 false
expect 7 sh -c 'exit 7'
expect 139 sh -c 'kill -SEGV $$'
expect 143 sh -c 'kill -TERM $$'
expect 127 /nonexistent/command
out=$(echo hello | "$cli" run --title Test -- cat 2>/dev/null)
if [[ $out == hello ]]; then echo "  PASS stdin and stdout are the command's"; else echo "  FAIL stdin/stdout: '$out'"; fail=1; fi
"$cli" run --title "" -- true >/dev/null 2>&1
if [[ $? == 2 ]]; then echo "  PASS an empty title is a usage error"; else echo "  FAIL an empty title"; fail=1; fi
exit $fail
