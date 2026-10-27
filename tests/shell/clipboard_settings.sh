#!/usr/bin/env bash
# The clipboard history's settings (ADR-0034 §6; reviews of f7cd664 and c1fc254): what the REAL Clipboard and Settings services
# ask of the helper, against tests/shell/clipboard_settings.d/fake-helper, which records its arguments and the lines it is sent
# and touches no clipboard, compositor or store. The scenario is tests/shell/clipboard_settings.d/settings.qml: nothing runs and
# nothing is deleted while grassfield.json is not usable, the store jobs run one after the other, the clears reach the helper
# with their time, and a file that becomes unusable while the history runs changes nothing. A dev session under `env -i`, every
# directory under a mktemp -d. Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/clipboard-settings.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime" "$tmp/home" "$tmp/state" "$tmp/config" "$tmp/cfg"
chmod 700 "$tmp/runtime"
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/clipboard_settings.d/settings.qml "$tmp/cfg/shell.qml"
: >"$tmp/helper.log"
out=$(env -i PATH="$PATH" HOME="$tmp/home" GRASSFIELD_DEV=1 QS_NO_RELOAD_POPUP=1 XDG_RUNTIME_DIR="$tmp/runtime" \
  GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" \
  GRASSFIELD_CLIPBOARD_HELPER="$root/tests/shell/clipboard_settings.d/fake-helper" \
  GRASSFIELD_CLIPBOARD_DISPLAY="$tmp/runtime/wayland-fake" CLIPBOARD_FAKE_LOG="$tmp/helper.log" \
  QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" GRASSFIELD_LANG=en \
  timeout 120 qs -p "$tmp/cfg" --no-color 2>&1) || true
# A QML runtime error fails the test even when every check passed (the product files are loaded through links here).
errors=$(grep -E "TypeError|ReferenceError|Binding loop|Unable to assign|is not a function" <<<"$out" || true)
if grep -q "clipboard-settings: PASS" <<<"$out" && [[ -z $errors ]]; then
  grep "clipboard-settings:" <<<"$out"
  exit 0
fi
grep -E "clipboard-settings:|ERROR|WARN qml|TypeError|ReferenceError" <<<"$out" || echo "$out"
echo "--- the fake helper's log"
cat "$tmp/helper.log"
echo "FAIL: tests/shell/clipboard_settings.sh"
exit 1
