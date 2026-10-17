#!/usr/bin/env bash
# Lock screen. Never types into it; the nested session is torn down afterwards (it stays locked).
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc lock lock
vs_sleep 2
# The password field caret blinks (security/PasswordField.qml, not editable here): the pixels at the start of the placeholder
# are blacked out so two captures never differ by caret phase.
VS_MASK="859,921,865,939" vs_capture lock
"$VS_ROOT/scripts/dev/nested-down.sh"
rm -f "$VS_STATE/session.lang"
