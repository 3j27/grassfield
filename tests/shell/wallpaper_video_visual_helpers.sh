#!/usr/bin/env bash
# The pixel-count comparisons of tests/visual/wallpaper-video.sh (a nested script nobody runs here): a count that is not a number
# (a capture or a crop that failed makes magick print "compare: ...") must fail BOTH the "differs" and the "identical" check.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/tests/visual/wallpaper-video.sh
eval "$(grep -E '^num_(gt|eq)0\(\)' "$script")"
fail=0
expect() { # name expected-rc command...
  local name=$1 want=$2 rc=0
  shift 2
  "$@" || rc=$?
  if [[ $rc == "$want" ]]; then echo "PASS: $name"; else echo "FAIL: $name (rc=$rc, wanted $want)"; fail=1; fi
}
expect "differs: 3 pixels" 0 num_gt0 3
expect "differs: 0 pixels" 1 num_gt0 0
expect "differs: a failed compare is not a pass" 1 num_gt0 "compare:"
expect "differs: an empty value is not a pass" 1 num_gt0 ""
expect "differs: a negative or a fraction is not a pass" 1 num_gt0 "-1"
expect "identical: 0 pixels" 0 num_eq0 0
expect "identical: 5 pixels" 1 num_eq0 5
expect "identical: a failed compare is not a pass" 1 num_eq0 "compare:"
expect "identical: an empty value is not a pass" 1 num_eq0 ""
grep -q 'num_gt0 "$(frames_differ)"' "$script" && grep -q 'num_eq0 "$(frames_differ)"' "$script" && echo "PASS: the script uses them" || { echo "FAIL: the script does not use them"; fail=1; }
exit "$fail"
