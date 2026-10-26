#!/usr/bin/env bash
# GlanceApp: Esc (close) or a second Space (toggle) during the start-up wait cancels the queued Glance. A dev session (GRASSFIELD_DEV=1,
# no GRASSFIELD_SESSION: the preview command override is dev plumbing, honoured only there, ADR-0019) knows its scope at once, so the
# probe makes the wait by hand (Apps.scopeKnown false until Apps.settleScope(), as while a real session's uwsm-app probe is pending).
# The preview command is a script that leaves a marker file when it runs. A last case shows that the override is inert in a real
# session (GRASSFIELD_SESSION=1, even with GRASSFIELD_DEV=1 leaked into it): nothing runs.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/glancecancel.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p -m 700 "$tmp/runtime" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/bin"
# A PATH with only what the launcher needs: the real grassfield-preview (installed on a machine that runs Grassfield) must never start.
for tool in sh setsid; do ln -s "/usr/bin/$tool" "$tmp/bin/$tool"; done
cat >"$tmp/preview" <<EOF
#!/bin/bash
echo ran >"$tmp/marker"
EOF
chmod +x "$tmp/preview"
qs=$(command -v qs)
status=0
run() { # <scenario> <expect marker: yes|no> <environment...>
  local scenario=$1 expect=$2
  shift 2
  rm -f "$tmp/marker"
  local out
  out=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u GRASSFIELD_DEV -u GRASSFIELD_SESSION -u QT_QPA_PLATFORMTHEME PATH="$tmp/bin" \
    "$@" GF_SCENARIO="$scenario" GRASSFIELD_PREVIEW_CMD="$tmp/preview" GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
    QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" XDG_RUNTIME_DIR="$tmp/runtime" XDG_CACHE_HOME="$tmp/cache" \
    /usr/bin/timeout 60 "$qs" -p "$root/tests/shell/glance_cancel/probe.qml" --no-color 2>&1) || { echo "$out"; echo "FAIL: glance_cancel $scenario (qs exit)"; status=1; return; }
  grep "glance-cancel" <<<"$out" || true
  if grep -q "glance-cancel: FAIL" <<<"$out"; then echo "FAIL: glance_cancel $scenario: $out"; status=1; return; fi
  local got=no
  [[ -f $tmp/marker ]] && got=yes
  if [[ $got == "$expect" ]]; then echo "PASS: glance_cancel $scenario (preview ran: $got)"; else echo "FAIL: glance_cancel $scenario (preview ran: $got, expected $expect)"; status=1; fi
}
run none yes GRASSFIELD_DEV=1
run close no GRASSFIELD_DEV=1
run toggle no GRASSFIELD_DEV=1
# The preview override is dev plumbing: a real session, a leaked dev included, starts the real preview (absent here) and never the override.
run none no GRASSFIELD_SESSION=1
run none no GRASSFIELD_SESSION=1 GRASSFIELD_DEV=1
exit $status
