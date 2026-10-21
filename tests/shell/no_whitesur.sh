#!/usr/bin/env bash
# ADR-0017 amendment 2026-10-21: Grassfield does not use the WhiteSur icon theme at all. The app icon chain is
# Grassfield's own icons, Breeze, Adwaita, hicolor.
#  * the wrapper theme never inherits WhiteSur;
#  * no tracked file installs, fetches, selects or references a WhiteSur theme at runtime. Docs and licence notices keep
#    the history (docs/, THIRD_PARTY.md, branding/LICENSES.md), and the design tokens and one unit test name the theme
#    the tuned values were measured on (comments and "source" strings only); those files are the only exceptions.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

desc="the wrapper index.theme does not mention WhiteSur"
check bash -c '! grep -qi whitesur "$1"' _ "$root/branding/icons/theme/index.theme"
desc="the wrapper Inherits line is exactly breeze,Adwaita,hicolor"
check bash -c '[ "$(grep -c "^Inherits=" "$1")" = 1 ] && grep -qx "Inherits=breeze,Adwaita,hicolor" "$1"' _ "$root/branding/icons/theme/index.theme"

hits=$(git -C "$root" grep -l -i -e whitesur -e 'white-sur' -- . \
  ':!docs' ':!THIRD_PARTY.md' ':!branding/LICENSES.md' ':!ui/tokens/tokens.json' ':!ui/Grassfield/Ui/Tokens.qml' \
  ':!tests/unit/tst_foldercolors.qml' ':!tests/shell/no_whitesur.sh' || true)
desc="no tracked file outside the documented exceptions mentions WhiteSur${hits:+ (found: $(tr '\n' ' ' <<<"$hits"))}"
check test -z "$hits"

desc="the WhiteSur provisioning and filtering scripts are gone"
check bash -c 'cd "$1"; for f in scripts/dev/whitesur.sh packaging/arch/whitesur-guard.sh packaging/arch/whitesur-detect.py packaging/arch/whitesur-blocklist.txt packaging/arch/whitesur-apple-logos.txt; do [ ! -e "$f" ] || exit 1; done' _ "$root"
desc="the PKGBUILD builds no WhiteSur package"
check bash -c '! grep -qi whitesur "$1/packaging/arch/PKGBUILD"' _ "$root"
desc="the PKGBUILD depends on breeze-icons (the second step of the icon chain)"
check grep -qE '^  depends=\(.*\bbreeze-icons\b' "$root/packaging/arch/PKGBUILD"
exit "$fail"
