# Grassfield task runner (master-prompt Appendix A "Commands").
# Graphical recipes only ever target the nested instance recorded in .dev/.

set shell := ["bash", "-euo", "pipefail", "-c"]

qtbin := "/usr/lib/qt6/bin"

default:
    @just --list

# All offline checks (L0).
check: check-config check-schema check-shell check-shaders check-i18n check-scripts check-inventory check-secrets

# Validate the Grassfield Hyprland Lua config with the installed Hyprland.
check-config:
    for cfg in dev session; do \
      GRASSFIELD_CONFIG_DIR={{justfile_directory()}}/config/hypr Hyprland --verify-config --config config/hypr/$cfg.lua 2>&1 \
        | sed -n '/Config parsing result/,$p' | tee /dev/stderr | grep -qx 'config ok'; \
    done

# Validate the default grassfield.json (and any given files) against the versioned schema.
check-schema *files:
    python3 -I scripts/dev/check-schema.py {{files}}

# Lint QML (0 warnings required in changed files, gate Q1).
check-shell:
    scripts/dev/qmllint.sh

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

# Secret scan of the whole history (gate S1).
check-secrets:
    gitleaks detect --source . --no-banner --redact

# Syntax-check shell scripts.
check-scripts:
    for f in scripts/dev/*.sh; do bash -n "$f"; done

# Offscreen unit tests (QML TestCase) and compositor unit tests when built.
test:
    scripts/dev/test.sh

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
