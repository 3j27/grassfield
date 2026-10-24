# Testing: layers and the test inventory

Every test of the repository belongs to exactly one **layer**, and `tests/inventory.json` lists all of them.
Nested Hyprland sessions reset the shared GPU, so a test goes in the lowest layer that can catch its bug.

| Layer | Needs | Examples | How it runs |
|---|---|---|---|
| `data` | nothing but files and system tools | docs vs. JSON tables, packaged fontconfig/icon theme/dconf profile, source guards | `scripts/dev/test.sh` |
| `logic` | no Qt GUI | gtest suites, Python tool tests, shell scripts under test (`hidden-entries.sh`, `open-policy.sh`) | `scripts/dev/test.sh` |
| `headless` | the real QML/Quickshell code on `QT_QPA_PLATFORM=offscreen`, no compositor, no `WAYLAND_DISPLAY`, isolated HOME/XDG | `tests/unit/tst_*.qml`, `tests/shell/*/shell.qml`, `tests/shell/settings_apply.sh`, `tests/integration/menu_bridge_memory.sh`, `tests/integration/launcher_entry.sh` (private bus) | `scripts/dev/test.sh` (a few are bare commands) |
| `nested` | the nested Hyprland instance (`just nested-up`): compositor behaviour, real input, the plugin | `tests/compositor/*.sh`, `tests/integration/global_menus.sh`, `tests/shell/apps_nested.sh` | bare commands (ask the owner) |
| `visual` | the nested session and screen captures | `just visual` scenarios, `tests/visual/*` capture scripts, `contrast.sh` | bare commands (ask the owner) |

The offscreen pattern (headless): link the real `shell/*` modules into a temporary config directory, copy the test's
`shell.qml` over, run `qs -p DIR` with `QT_QPA_PLATFORM=offscreen`, `env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE`,
`HOME`, `XDG_RUNTIME_DIR` and `GRASSFIELD_STATE_HOME` under a scratch directory. See `tests/shell/desktop_new_folder.sh` and
`tests/shell/folder_styles_apply.sh`.

## `tests/inventory.json`

```json
{
"version": 1,
"layers": ["data", "logic", "headless", "nested", "visual"],
"discover": ["tests/shell/*.sh", "..."],
"ignore": [{"path": "tests/visual/lib.sh", "reason": "helper sourced by the visual scripts"}],
"tests": [{"path": "tests/shell/hidden_entries.sh", "layer": "logic"},
          {"path": "tests/compositor/overview.sh", "layer": "nested", "runner": "bare"}]
}
```

- `path`: repository-relative file of the entry point (a `shell.qml` for a Quickshell test directory, a `tst_*.cpp`
  for a gtest source, a `*Test.cpp` for the compositor unit tests).
- `layer`: exactly one of `layers`. A `layers` key, a second entry for the same path or an unknown name is an error.
- `runner`: `test.sh` (default; `scripts/dev/test.sh` runs it) or `bare` (a bare command run by hand: nested session,
  captures). `bare` entries are counted as "manual" in the summary and never started by `test.sh`.
- `enabled`: omit it. `false` fails the gate: a required test is not switched off, it is removed or fixed.
- `discover`: globs of files that look like tests. A match that is neither in `tests` nor in `ignore` fails the gate.
- `ignore`: helpers and runners that match a glob but are not tests; each needs a `reason`.

New test file: add one line to `tests` (or to `ignore` with a reason). Helpers and fixtures outside the globs need nothing.

## The gate

`python3 -I tests/ci/inventory.py` (Python standard library only; part of `just check` as `check-inventory`, and the first
step of `scripts/dev/test.sh`) fails when

1. a test file matched by `discover` is not registered or ignored;
2. a registered test (or an ignored path) does not exist;
3. a registered test is disabled;
4. a test has no layer, an unknown layer, or two layers;
5. with `--results FILE --layers a,b`: a layer reports no result in the run, or only skips (nothing verified).
   `scripts/dev/test.sh` writes the results file and runs this check on the layers it covered.

`python3 -I tests/ci/inventory.py --selftest` runs these cases on temporary fixtures (it is also a `logic` test).
`--map` prints `path<TAB>layer<TAB>runner` for the enabled tests (`test.sh` reads it).

Limits: the batch runners (`qmltestrunner` over `tests/unit`, a gtest binary) report one result for their group, so
the run check is per layer, not per file. Which layer a test is in is a judgement the reviewer checks.

## `scripts/dev/test.sh`

```
scripts/dev/test.sh                     data, logic, headless, and the tests/shell scripts of the nested layer (they SKIP themselves without a session)
scripts/dev/test.sh --layer headless    one layer, or several: --layer data,logic
```

The end of every run prints one line per selected layer: `pass fail skip manual`. An explicitly requested layer that
reports nothing but skips fails the run (`--layer nested` without a session). In the default run the nested layer is not
gated (its scripts SKIP without a session by design); a layer with only bare commands (`visual`) is reported, not gated.

## Moving a test down a layer

A test that starts a nested session only to drive shell QML logic (no compositor behaviour, no capture, no real input)
belongs in `headless`. Move it, then prove it still catches its bug: apply a temporary mutant of the code under test,
see it fail, revert it. Record the layer change in `tests/inventory.json`.

## Nested tests that stay nested (reviewed 2026-10-22)

| Test | Why it needs a session |
|---|---|
| `tests/shell/apps_nested.sh` | `AppsWindow` is a layer-shell `PanelWindow` with exclusive keyboard focus; under `QT_QPA_PLATFORM=offscreen` Quickshell has no PanelWindow backend ("No PanelWindow backend loaded"). The controller logic is already headless (`tst_appspanel.qml`, `tst_exclusivesurfaces.qml`). |
| `tests/shell/overview_two_outputs.sh`, `tests/visual/overview-highlight.sh`, `tests/compositor/*.sh`, `tests/integration/global_menus.sh`, `tests/security/reload_locked.sh` | compositor behaviour: plugin, real input, outputs, focus, session lock. |
| `tests/visual/degraded-notice.sh` | the notice itself is posted by `shell/shell.qml` (not loadable alone) and the test loads and unloads the real plugin. A headless test of `Capabilities` alone would not cover it. |
| `tests/visual/icon-a2.sh`, `icon-shader-cold.sh`, `icon-modes*-perf.sh`, `icon-modes-switch-memory.sh`, `folder-glyph-perf.sh`, `dock-*` | GPU scene graph (ShaderEffect), frame timing, memory of a live shell. |
| `tests/apps/files_sandbox.sh` | real keyboard and pointer input into the Files window. |

Moved down: `tests/apps/files_registrar.sh` (nested to headless): the nested session only supplied a Wayland socket; the app
now runs on the offscreen platform. It needs a private D-Bus daemon (Unix socket), so it SKIPs inside the Claude Code
sandbox and stays a bare command (`runner: bare`) until it has run on the owner's machine.

## Functional flows and the nested smoke set (GF-009, GF-094)

`tests/visual/flow-<module>.sh` (bare, nested only; `tests/visual/flow-lib.sh` is the shared helper): one script per module,
used the way a user does, asserting the shell's own state over its dev IPC, the shared `grassfield.json`, files on disk and the
windows the compositor reports, with a screenshot per step in `.dev/visual/shots/flow-<module>-*.en.png`. Pixels only prove that
something appeared or went away. Modules: `search`, `quicksettings`, `widgets`, `settings`, `files`, `preview`, `notifications`.
Each starts a nested session when none is up (`vs_session`), refuses any other instance (`dev_nested_target`) and ends the windows,
banners, widgets and settings it changed. Where a control has no IPC (the Tab position of a Quick Settings tile, the row of a context menu) the flow
finds it by trying and asserting the effect, so a changed layout still passes and a broken control fails with the step named.
Not driven: the Lock Screen command of Search (it would lock the nested session for good; only its presence is asserted), the
devices behind the Quick Settings toggles (the dev guard answers; the flow asserts the guard), the transparency slider's drag
(the IPC hook calls the slider's setter).

`tests/shell/smoke_nested.sh` (run it bare; a `smoke-nested` just recipe is a one-line wrapper): the nested smoke set, eight checks in about 20 s on a nested session that is
ALREADY up: compositor lists, shell IPC and unlocked, plugin handshake, Quick Settings state and a menu, Search, Apps (and their
mutual exclusion), the notification server and Center, and no QML error in `.dev/shell.log`. It starts nothing and opens no window,
and it SKIPs without a session, so `scripts/dev/test.sh` (nested layer) carries it whenever a session happens to be up.
