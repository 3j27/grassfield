#!/usr/bin/env bash
# GF-103: numbers shown to the user follow the UI locale ("15,5 Go" in fr, not "15.5 Go"). A QML/JS number rendered with
# toFixed() always uses a dot, so no visible string may be built from it; Qt.locale().toString(v, "f", n) or
# formattedDataSize is the way.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

hits=$(git -C "$root" grep -n -E 'qsTr\(.*toFixed\(|\.arg\([^)]*toFixed\(' -- 'shell/*.qml' 'apps/*.qml' 'ui/*.qml' || true)
desc="no visible string is built from toFixed()${hits:+ (found: $(tr '\n' ' ' <<<"$hits"))}"
check test -z "$hits"

exit $fail
