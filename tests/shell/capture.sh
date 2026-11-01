#!/usr/bin/env bash
# ADR-0035 D-10, step 8: packaging/bin/grassfield-capture, Grassfield's screenshots, against fakes of every tool it runs (grim,
# slurp, wl-copy, notify-send, hyprctl, xdg-user-dir, pkill, systemd-run, uwsm-app, gdbus): what it captures, in which colours,
# where and under which name it saves, what it copies, the notice and its "Open in Preview" (checks in capture.d/check.py).
# Nothing here captures a screen or reaches a bus.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/capture.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | LC_* | LANG | LANGUAGE) unset "$v" ;; esac
done
python3 -I "$root/tests/shell/capture.d/check.py" "$root" "$tmp"
