#!/usr/bin/env bash
# The newest items of a folder stack, live (shell/dock/StackWatch.qml over the native helper, ADR-0025: what the pile on a stack
# tile reads): files f1..f4 (f4 the newest) give the pile f4, f3, f2 (never the oldest), a file added later becomes the
# top, a removed one leaves. Runs tests/shell/stack_watch.d/guard.qml offscreen with the real component. Prints PASS or FAIL.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
helper=$root/.dev/build/grassfield-stack-helper
[[ -x $helper ]] || apps/stack-helper/build-direct.sh >/dev/null
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/stack-watch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/cache" "$tmp/cfg" "$tmp/dir"
chmod 700 "$tmp/runtime" "$tmp/cache"
for i in 1 2 3 4; do
  printf x >"$tmp/dir/f$i"
  touch -d "2026-01-0$i" "$tmp/dir/f$i"
done
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/stack_watch.d/guard.qml "$tmp/cfg/shell.qml"
out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_SESSION GF_STACK_DIR="$tmp/dir" GRASSFIELD_DEV=1 GRASSFIELD_STACK_HELPER="$helper" QT_QPA_PLATFORM=offscreen \
  QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
  timeout 60 qs -p "$tmp/cfg" --no-color 2>&1 || true)
echo "$out" | grep -E "PASS|FAIL" || { echo "$out" | tail -20; exit 1; }
grep -q FAIL <<<"$out" && exit 1
exit 0
