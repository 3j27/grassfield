# Grassfield task runner (master-prompt Appendix A "Commands").
# Graphical recipes only ever target the nested instance recorded in .dev/.

set shell := ["bash", "-euo", "pipefail", "-c"]

qtbin := "/usr/lib/qt6/bin"

default:
    @just --list

# All offline checks (L0).
check: check-config check-schema check-shell check-shaders check-i18n check-scripts check-inventory check-upstream check-secrets

# Validate the Grassfield Hyprland Lua config with the installed Hyprland. Verify mode inherits this environment, a
# running Hyprland's signature included: it runs with a scratch runtime directory and a signature of the installed
# Hyprland's commit that no instance has, and fails if the session's loader wrote a runtime note there (it must not in
# verify mode, config/hypr/grassfield/compositor.lua verifying()).
check-config:
    rt=$(mktemp -d); trap 'rm -rf "$rt"' EXIT; \
    [[ -r /usr/include/hyprland/src/version.h ]] || { echo "check-config: no Hyprland headers (/usr/include/hyprland/src/version.h): install hyprland" >&2; exit 1; }; \
    commit=$(sed -n 's/^#define[[:space:]]*GIT_COMMIT_HASH[[:space:]]*"\([0-9a-f]*\)".*/\1/p' /usr/include/hyprland/src/version.h); \
    for cfg in dev session; do \
      XDG_RUNTIME_DIR=$rt HYPRLAND_INSTANCE_SIGNATURE=${commit:-0000000}_0_verify \
        GRASSFIELD_CONFIG_DIR={{justfile_directory()}}/config/hypr Hyprland --verify-config --config config/hypr/$cfg.lua 2>&1 \
        | sed -n '/Config parsing result/,$p' | tee /dev/stderr | grep -qx 'config ok'; \
    done; \
    if compgen -G "$rt/grassfield-compositor-*" >/dev/null; then \
      echo "check-config: verify mode wrote a compositor runtime note" >&2; exit 1; \
    fi

# Validate the default grassfield.json (and any given files) against the versioned schema.
check-schema *files:
    python3 -I scripts/dev/check-schema.py {{files}}

# Lint QML (0 warnings required in changed files, gate Q1).
check-shell:
    scripts/dev/qmllint.sh
    python3 -I tests/ci/qmldir_types.py --selftest
    python3 -I tests/ci/qmldir_types.py

# The committed .qsb shaders are current with their .frag sources (rebuild: scripts/dev/build-shaders.sh).
check-shaders:
    scripts/dev/build-shaders.sh --check

# Gate I1: every visible string is in qsTr(); the fr catalog is current and complete.
check-i18n:
    python3 -I scripts/dev/check-i18n.py

# Regenerate translations/grassfield_fr.ts after adding or changing qsTr() strings.
i18n-update:
    scripts/dev/i18n-update.sh

# Every test is registered in tests/inventory.json with exactly one layer (static, cheap; docs/testing/README.md).
check-inventory:
    python3 -I tests/ci/inventory.py

# The upstream Omarchy files the security forks derive from are unchanged (docs/upstream/omarchy.lock, GF-031); after a
# review of an upstream change: scripts/dev/upstream-drift.sh --update.
check-upstream:
    scripts/dev/upstream-drift.sh

# Secret scan of the whole history (gate S1).
check-secrets:
    gitleaks detect --source . --no-banner --redact

# Syntax-check shell scripts.
check-scripts:
    for f in scripts/dev/*.sh; do bash -n "$f"; done

# Omarchy private paths, commands and units Grassfield relies on (docs/compat.md); --require fails without Omarchy.
check-omarchy *args:
    scripts/dev/omarchy-compat.sh {{args}}

# Offscreen unit tests (QML TestCase) and compositor unit tests when built.
test:
    scripts/dev/test.sh

# Security gates L1 (+ DT-21 graceful exit) and L4 (+ DT-05 screen share, D-4 lid and display off), each on a fresh
# nested session (ask). Bare, outside the sandbox only: inside it the scripts refuse (PID namespace). Every nested session
# it opens ends locked and is stopped. L2 (tests/security/l2_wrong_password.sh) and L5 stay owner steps.
test-security-nested:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    scripts/dev/nested-up.sh || exit 2
    tests/security/reload_locked.sh || rc=1
    scripts/dev/nested-down.sh
    scripts/dev/nested-up.sh || exit 2
    tests/security/lock_privacy.sh || rc=1
    scripts/dev/nested-down.sh
    exit $rc

# Gate A2 for the icon modes on a GPU scene graph, as a client of the nested session (ask).
test-icons:
    tests/visual/icon-a2.sh

# Nested dev session (ask).
nested-up:
    scripts/dev/nested-up.sh

nested-down:
    scripts/dev/nested-down.sh

# Restart grassfield-shell inside the nested instance (ask).
shell-run:
    scripts/dev/shell-run.sh

# Screenshot of the nested output → .dev/shots/<name>.png (ask).
shot name:
    scripts/dev/shot.sh {{name}}

# Visual regression on GF-REF vs tests/visual/baselines (reference machine, nested session; ask). Flags: --update --determinism --only a,b --lang en|fr|both
visual *args:
    tests/visual/run.sh {{args}}

# Gate A2 contrast table on 5 worst-case wallpapers x light/dark x transparency 0.25/0.6 (nested session; ask).
contrast *args:
    tests/visual/contrast.sh {{args}}

# Scripted nested scenario → tests/scenarios/<name>.sh (ask).
scenario name:
    tests/scenarios/{{name}}.sh

# Scripted pointer in the nested instance, e.g. `just pointer output GF-REF abs 960 1050 click` (ask).
pointer *args:
    scripts/dev/pointer.sh {{args}}

# Compose the grassfield-icons theme (pinned MacTahoe + Pebble, GitHub) into .dev/share/icons (dev sessions only).
icons *args:
    scripts/dev/icons.sh {{args}}

# Build the Grassfield cursor theme into .dev/share/icons/grassfield-cursors (hyprcursor + XCursor).
cursors *args:
    branding/cursors/build.sh {{args}}

# Build the compositor plugin against the installed Hyprland headers.
plugin-build:
    cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build compositor/build

# Load/unload the plugin in the NESTED instance via scripts/nestctl (ask).
plugin-load:
    scripts/nestctl plugin load {{justfile_directory()}}/compositor/build/grassfield-compositor.so

plugin-unload:
    scripts/nestctl plugin unload {{justfile_directory()}}/compositor/build/grassfield-compositor.so
