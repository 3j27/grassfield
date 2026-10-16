# Grassfield task runner (master-prompt Appendix A "Commands").
# Graphical recipes only ever target the nested instance recorded in .dev/.

set shell := ["bash", "-euo", "pipefail", "-c"]

qtbin := "/usr/lib/qt6/bin"

default:
    @just --list

# All offline checks (L0).
check: check-config check-shell check-scripts

# Validate the Grassfield Hyprland Lua config with the installed Hyprland.
check-config:
    GRASSFIELD_CONFIG_DIR={{justfile_directory()}}/config/hypr Hyprland --verify-config --config config/hypr/dev.lua 2>&1 | sed -n '/Config parsing result/,$p' | tee /dev/stderr | grep -qx 'config ok'

# Lint QML (0 warnings required in changed files, gate Q1).
check-shell:
    scripts/dev/qmllint.sh

# Syntax-check shell scripts.
check-scripts:
    for f in scripts/dev/*.sh; do bash -n "$f"; done

# Offscreen unit tests (QML TestCase) and compositor unit tests when built.
test:
    scripts/dev/test.sh

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

# Scripted nested scenario → tests/scenarios/<name>.sh (ask).
scenario name:
    tests/scenarios/{{name}}.sh

# Build the compositor plugin against the installed Hyprland headers.
plugin-build:
    cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build compositor/build

# Load/unload the plugin in the NESTED instance via scripts/nestctl (ask).
plugin-load:
    scripts/nestctl plugin load {{justfile_directory()}}/compositor/build/grassfield-compositor.so

plugin-unload:
    scripts/nestctl plugin unload {{justfile_directory()}}/compositor/build/grassfield-compositor.so
