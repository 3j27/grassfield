#!/usr/bin/env bash
# GlanceApp: Esc (close) or a second Space (toggle) during the start-up wait cancels the queued Glance. The wait is made
# long with a fake `sh` that sleeps on the uwsm-app probe (a real session, GRASSFIELD_SESSION=1) and hands every other
# `sh` to the real one. The preview command is a script that leaves a marker file when it runs.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/glancecancel.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/bin"
cat >"$tmp/bin/sh" <<'EOF'
#!/bin/bash
if [[ ${2:-} == *"command -v uwsm-app"* ]]; then sleep 2; exit 0; fi
exec /usr/bin/sh "$@"
EOF
chmod +x "$tmp/bin/sh"
cat >"$tmp/preview" <<EOF
#!/bin/bash
echo ran >"$tmp/marker"
EOF
chmod +x "$tmp/preview"
qs=$(command -v qs)
status=0
run() { # <scenario> <expect marker: yes|no>
  rm -f "$tmp/marker"
  local out
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u QT_QPA_PLATFORMTHEME PATH="$tmp/bin:/usr/bin" \
    GRASSFIELD_SESSION=1 GF_SCENARIO="$1" GRASSFIELD_PREVIEW_CMD="$tmp/preview" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
    /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/glance_cancel/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: glance_cancel $1 (qs exit)"; status=1; return; }
  grep "glance-cancel" <<<"$out" || true
  if grep -q "glance-cancel: FAIL" <<<"$out"; then echo "FAIL: glance_cancel $1: $out"; status=1; return; fi
  local got=no
  [[ -f $tmp/marker ]] && got=yes
  if [[ $got == "$2" ]]; then echo "PASS: glance_cancel $1 (preview ran: $got)"; else echo "FAIL: glance_cancel $1 (preview ran: $got, expected $2)"; status=1; fi
}
run none yes
run close no
run toggle no
exit $status
