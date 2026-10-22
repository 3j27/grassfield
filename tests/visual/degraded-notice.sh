#!/usr/bin/env bash
# The degraded-mode notice "Compositor extension not loaded" (review of ff5f888): a loaded plugin can answer the hello
# seconds after the 1.5 s timeout at a start, so the notice waits until the extension is known to be absent
# (Capabilities.helloAbsentMs without a reply, or an unload) and never shows for a moment at a normal start. An unload
# posts it at once, a load withdraws it. Needs the plugin build (just plugin-build).
# Usage (bare command): tests/visual/degraded-notice.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

so=$VS_ROOT/compositor/build/grassfield-compositor.so
[[ -f $so ]] || { echo "FAIL: no plugin build ($so): run just plugin-build"; exit 1; }

# The plugin is unloaded below: load it again whatever happens, the next scenario of this tree expects it.
unloaded=""
trap '[[ -n $unloaded ]] && "$VS_ROOT/scripts/nestctl" plugin load "$so" >/dev/null 2>&1' EXIT

vs_session
started=$SECONDS
st=""
for i in $(seq 1 60); do
  st=$(vs_ipc capabilities status)
  [[ $st == "ready present"* ]] && break
  sleep 0.5
done
check "the plugin answered the shell started with it ($st)" test "${st%% *}" = ready -a "$(cut -d' ' -f2 <<<"$st")" = present
# Whether this start took the late path (no reply before the timeout): the case the notice must not flash in.
if grep -q "running in degraded mode (still asking)" "$VS_DEV/shell.log"; then
  echo "info: the reply came after the timeout (late path)"
else
  echo "info: the reply came before the timeout"
fi
# Past helloAbsentMs (15 s) with a margin: no notice was ever posted at this start.
while ((SECONDS - started < 20)); do sleep 1; done
check "no degraded notice at a start with the plugin" test "$(grep -c 'degraded notice posted' "$VS_DEV/shell.log")" = 0
check "no notification at all after the start ($(vs_ipc notifications status))" grep -q "history=0 " <<<"$(vs_ipc notifications status)"

# An unload is a known absence: the notice comes at once.
unloaded=1
"$VS_ROOT/scripts/nestctl" plugin unload "$so" >/dev/null
for i in $(seq 1 20); do
  grep -q "degraded notice posted" "$VS_DEV/shell.log" && break
  sleep 0.5
done
check "an unload posts the notice at once" test "$(grep -c 'degraded notice posted' "$VS_DEV/shell.log")" = 1
check "the notice is in the history ($(vs_ipc notifications status))" grep -q "history=1 " <<<"$(vs_ipc notifications status)"

# A start without the plugin: degraded at the timeout, the notice only once helloAbsentMs passed without a reply.
# (vs_session returns about 4 s after the start: degraded at 1.5 s, then 2 s of settling.)
export GRASSFIELD_NO_PLUGIN=1
vs_session
unset GRASSFIELD_NO_PLUGIN
started=$SECONDS
sleep 5
check "no notice yet about 9 s into a start without the plugin" test "$(grep -c 'degraded notice posted' "$VS_DEV/shell.log")" = 0
check "degraded mode already ($(vs_ipc capabilities status))" test "$(vs_ipc capabilities status)" = "ready degraded"
while ((SECONDS - started < 20)); do sleep 1; done
check "the notice after helloAbsentMs without a reply" test "$(grep -c 'degraded notice posted' "$VS_DEV/shell.log")" = 1
check "the notice is in the history ($(vs_ipc notifications status))" grep -q "history=1 " <<<"$(vs_ipc notifications status)"

# A load withdraws it.
"$VS_ROOT/scripts/nestctl" plugin load "$so" >/dev/null
unloaded=""
for i in $(seq 1 20); do
  [[ $(vs_ipc capabilities status) == "ready present"* ]] && break
  sleep 0.5
done
sleep 1
check "a load withdraws the notice ($(vs_ipc notifications status))" grep -q "history=0 " <<<"$(vs_ipc notifications status)"

check "no QML error in the shell log" test "$(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log")" = 0
exit $fail
