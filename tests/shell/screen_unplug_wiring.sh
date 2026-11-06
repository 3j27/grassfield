#!/usr/bin/env bash
# A display going away (hot unplug): the wiring that keeps the shell working, checked statically (the behaviour is
# tests/shell/display_unplug_nested.sh and tests/unit/tst_screenchoice.qml). Fails when one of these fixes is reverted:
#  * the handlers of "the screens changed" in Popups, Switcher, Notifications, AppsController and Search move their state with
#    ScreenChoice.replacement computed from the live names, never from Compositor.activeScreenName (a binding of the same
#    change that Qt may not have updated yet), and every one of them exists;
#  * the Search panel and the Dock keyboard surface tolerate the null screen they read while a display is torn down.
# WIRING_ROOT (a copy of the tree) is for tests/shell/ux_mutants.sh.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

for f in shell/switcher/Switcher.qml shell/notifications/Notifications.qml shell/launchpad/AppsController.qml shell/search/Search.qml; do
  desc="$f: the screens-changed handler exists and moves its state with ScreenChoice.replacement from live data (not activeScreenName)"
  check bash -c 'h=$(awk "/function onScreensChanged\\(\\)/,/^        }/" "$1"); [ -n "$h" ] && grep -q "ScreenChoice.replacement(root\\.[A-Za-z]*, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name))" <<<"$h" && ! grep -q "activeScreenName" <<<"$h"' _ "$f"
done

# Popups goes through ScreenChoice.afterScreensChanged (closes the kinds that die with their output, else moves with replacement()).
desc="shell/services/Popups.qml: the screens-changed handler exists and moves its state with ScreenChoice.afterScreensChanged from live data (not activeScreenName)"
check bash -c 'h=$(awk "/function onScreensChanged\\(\\)/,/^        }/" "$1"); [ -n "$h" ] && grep -q "ScreenChoice.afterScreensChanged(root\\.kind, root\\.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name))" <<<"$h" && grep -q "root.close()" <<<"$h" && ! grep -q "activeScreenName" <<<"$h"' _ shell/services/Popups.qml

desc="SearchPanel: the window reads its screen name with a null guard"
check grep -q 'root.controller.screenName === (modelData ? modelData.name : "")' shell/search/SearchPanel.qml

desc="Dock: the keyboard surface reads win.screen with a null guard"
check grep -q 'root.keyboardMode && win.screen && win.screen.name === root.keyboardScreen' shell/dock/Dock.qml

exit $fail
