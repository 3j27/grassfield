# Settings spec · apps-engineer · M4

## macOS reference behavior (described in words)
- System Settings is one opaque window (about 715 x 640): a sidebar on the left with a search field on top and
  one row per section (small icon, name), a detail pane on the right with a large title and grouped, rounded
  "inset" lists. Rows hold a label (optionally a grey caption) and a control on the right: switch, slider,
  pop-up menu, segmented choice. Changes apply immediately; there is no Apply button.
- Typing in the search field filters the sidebar. Up/Down in the sidebar switch the pane.

## Purpose and non-goals
Edit the user-facing keys of `grassfield.json` (contract version 1, master-prompt 5.3) and show read-only system
information. The feature is called "Settings" (code: `grassfield-settings`, app id `org.grassfield.Settings`).
Non-goals (v1): Wi-Fi, Bluetooth, Sound, Displays (live in the Control Center), Dock pinned apps (owned by the Dock),
wallpaper, user accounts, editing shortcuts.

## Functional requirements
1. S1 Native launcher (`apps/settings/src/main.cpp`): `QGuiApplication`, `setDesktopFileName("org.grassfield.Settings")`, name and version, `QQmlApplicationEngine` with `/usr/lib/qt6/qml` (plus `QML_IMPORT_PATH` in dev) so `import Grassfield.Ui` resolves; loads `Main.qml` from `GRASSFIELD_SETTINGS_QML` or the baked-in directory (installed: `/usr/share/grassfield/settings/qml`).
2. S2 Sections, real settings only, each writing the schema keys (nothing else):
   - Appearance: `appearance` (Light/Dark; `auto` is not offered because the shell renders it dark), `material.transparency` (0-1), `accessibility.reduceTransparency`, `material.profile` (full/balanced/reduced), `accessibility.reduceMotion`.
   - Desktop & Dock: `dock.magnificationEnabled`, `dock.magnification` (1-2.5), `dock.autohide`, `windows.titlebarDoubleClick`, `hotCorners.{topLeft,topRight,bottomLeft,bottomRight}` (none/overview/notifications/apps/lock).
   - Notifications: `notifications.dnd`, `notifications.previews` (always/unlocked/never).
   - Lock Screen: `lock.idleMinutes` (Never = 0, 1, 2, 5, 10, 15, 30, 60; a hand-edited other value stays selectable).
   - Keyboard: read-only list (description + keys) parsed from the bindings file.
   - About: read-only: Grassfield (app) version, Omarchy NAME + VERSION_ID (`/etc/os-release`), Hyprland and Quickshell (`pacman -Q`, argv, no shell), Qt (`qVersion()`), CPU model and threads, memory, graphics (`lspci`).
3. S3 Writes: the file is re-read before every change and the one key is set, so every other key (also unknown ones, `dock.pinned`) is preserved. Values are validated against rules that mirror the schema (`qml/Store.js`; a unit test checks parity with `config/schema/grassfield.schema.json`). A missing or empty file is created as `{"version": 1, ...}`. Atomic replace through `QSaveFile`.
4. S4 A file that is not valid JSON, not an object, has `version` other than 1, or cannot be read is never overwritten: a red banner shows the reason, the detail pane is inert, nothing is written. Fixing the file re-enables the pane (file watcher).
5. S5 Live effect: the shell watches `grassfield.json`; changes apply immediately (transparency, appearance, hot corners, Dock). The app also follows external edits of the file.
6. S6 Config location: `GRASSFIELD_CONFIG_HOME` (dev) else `$XDG_CONFIG_HOME/grassfield` else `~/.config/grassfield`, same as the shell.
7. S7 Bindings file: `/usr/share/grassfield/hypr/grassfield/bindings.lua` when installed, else `$GRASSFIELD_CONFIG_DIR/grassfield/bindings.lua` (set in the dev session), else the repository copy baked in by `build-direct.sh`. Only literal `bind("KEYS", "Description", ...)` lines are listed (loops and computed keys, e.g. the Space switchers, are skipped).
8. S8 Shell integration: Grassfield menu > "System Settings…" runs `grassfield-settings` (dev: `GRASSFIELD_SETTINGS_CMD`, split on spaces, no shell).
9. S9 Accessibility and input: `qsTr` for all strings, `Accessible` names and roles on controls, rows and the banner; Up/Down/Home/End in the sidebar, Down or Return in the search field moves to the list, Tab enters the pane, Space/Return activate controls, Left/Right change a segmented choice or slider, Esc clears the search or closes a pop-up menu. Untrusted text (file contents, system strings) is `Text.PlainText`.
10. S10 Opaque window (master-prompt 5.5): tokens only (`settings.*` group of `ui/tokens/tokens.json`); the shared PopupMenu is drawn with transparency forced to 0 inside the app.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| S3/S4 | `tests/unit/tst_settingsstore.qml`: merge preserves keys, nested creation, fresh file, malformed/invalid refusal (no write), schema parity, ConfigStore with a fake backend (external change, blocked state) | L0 |
| S7/S2 | same file: bindings parser (including the real file), os-release/cpu/memory/lspci/pacman parsers | L0 |
| S1-S10 | nested: launch, screenshots of every section in light and dark, picker and slider with real pointer, keyboard navigation with wtype, hot corner effect, transparency effect on menu bar and Dock, malformed file refusal (`cmp`), menu item launch | L1 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**/*.qml`) and `check-textformat.py` | L0 |

## Implementation notes (v1, `apps/settings/`)
- `src/main.cpp` launcher, `src/backend.{h,cpp}` small QObject: `readText`, `writeText` (QSaveFile), `run(argv)` (3 s timeout), `watch` (QFileSystemWatcher on the file and its directory), `configFile`, `bindingsFile`, versions. Passed to QML as the initial property `backend`.
- `qml/`: `Main.qml` (window, sidebar, search, banner), `ConfigStore.qml` (state, `value(key)`, `set(key, v)`), `Store.js` (pure validation and merge), `Bindings.js`, `SysInfo.js`, pages `*Page.qml`, components `SettingsPage/Group/Row`, `Segmented`, `Picker` (PopupMenu from `Grassfield.Ui` on a window-wide layer).
- Build: `apps/settings/build-direct.sh` (g++, `moc`, pkg-config Qt6Gui/Qml/Quick) writes `.dev/build/grassfield-settings`; `CMakeLists.txt` is provided for when cmake is installed.
- Dev run: `WAYLAND_DISPLAY=$(cat .dev/nested.wayland) QML_IMPORT_PATH=$PWD/ui GRASSFIELD_CONFIG_HOME=$PWD/.dev/config .dev/build/grassfield-settings`.
- Desktop entry: `org.grassfield.Settings.desktop` (Name "Grassfield Settings", Icon `preferences-system` (a stock theme icon, so it resolves without the Grassfield icon set), Categories Settings).

## Known limitations
- No Wi-Fi, Bluetooth, Sound or Displays pages: those controls live in the Control Center.
- Appearance offers Light and Dark only: `auto` is accepted by the schema but the shell treats it as dark.
- Dock pinned apps, shortcuts editing, wallpaper and Auto appearance are not part of v1.
- The Keyboard list shows only literal bindings (no numbered Space switchers) and is not refreshed while the app is open.
- About runs `pacman -Q` and `lspci` once when the page opens (synchronously, 3 s timeout each); on systems without them the value reads "Unknown". The Grassfield version is the Settings app version (the shell's own version string is not exposed).
- Slider drags write the file on every step (atomic, small); the shell applies each step.
- The nested dev session has no titlebars (compositor plugin not loaded), so the window is borderless there.
- The desktop entry uses the stock `preferences-system` icon; swap to the Grassfield `gear` once the icon set is installed into an icon theme.
- Concurrent writers: the shell (`SettingsStore`) writes by merge. Setters record dirty keys, the file is re-read right before the write and only those keys are replaced, atomically; external edits made within the save delay survive, and keys outside the schema are preserved (the schema forbids them, but a writer never drops what it does not own). A fresh or empty file is created from the full defaults.
- The Settings app edits by parse and re-serialize (`Store.js`), which cannot keep integers beyond 2^53, duplicate keys or integer-like object keys. A file containing any of them is treated like a malformed file: read-only with a "cannot be edited safely" banner, file untouched. The schema has no such values, so only hand-made files are affected.
- Without the AT-SPI bus the Qt accessibility tree is not published (Accessible properties are set but only verified by code review, not by a screen reader).
