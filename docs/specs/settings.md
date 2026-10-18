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
Non-goals (v1): pairing and Wi-Fi password entry (in Quick Settings), changing displays, Dock pinned apps (owned by the Dock),
wallpaper, user accounts, editing shortcuts.

## Functional requirements
1. S1 Native launcher (`apps/settings/src/main.cpp`): `QGuiApplication`, `setDesktopFileName("org.grassfield.Settings")`, name and version, `QQmlApplicationEngine` with `/usr/lib/qt6/qml` (plus `QML_IMPORT_PATH` in dev) so `import Grassfield.Ui` resolves; loads `Main.qml` from `GRASSFIELD_SETTINGS_QML` or the baked-in directory (installed: `/usr/share/grassfield/settings/qml`).
2. S2 Sections, real settings only, each writing the schema keys (nothing else):
   - Appearance: `appearance` (Light/Dark; `auto` is not offered because the shell renders it dark), `material.transparency` (0-1), `accessibility.reduceTransparency`, `material.profile` (full/balanced/reduced), `accessibility.reduceMotion`.
   - Desktop & Dock: `dock.magnificationEnabled`, `dock.magnification` (1-2.5), `dock.autohide`, `desktop.showIcons` (Desktop group: "Show items on the desktop"), `windows.titlebarDoubleClick`, `hotCorners.{topLeft,topRight,bottomLeft,bottomRight}` (none/overview/notifications/apps/lock).
   - Notifications: `notifications.dnd`, `notifications.previews` (always/unlocked/never).
   - Lock Screen: `lock.idleMinutes` (Never = 0, 1, 2, 5, 10, 15, 30, 60; a hand-edited other value stays selectable).
   - Keyboard: read-only list (description + keys) parsed from the bindings file; descriptions and key names are shown in the UI language (`Bindings.js` lists them for translation, context `Bindings`; a unit test checks the real file).
   - About: read-only: Grassfield (app) version, Omarchy NAME + VERSION_ID (`/etc/os-release`), Hyprland and Quickshell (`pacman -Q`, argv, no shell), Qt (`qVersion()`), CPU model and threads, memory (binary units with the UI locale: "31.0 GiB", "31,0 Gio"), graphics (`lspci`).
3. S3 Writes: the file is re-read before every change and the one key is set, so every other key (also unknown ones, `dock.pinned`) is preserved. Values are validated against rules that mirror the schema (`qml/Store.js`; a unit test checks parity with `config/schema/grassfield.schema.json`). A missing or empty file is created as `{"version": 1, ...}`. Atomic replace through `QSaveFile`.
4. S4 A file that is not valid JSON, not an object, has `version` other than 1, or cannot be read is never overwritten: a banner in the destructive colour (tokens `destructive` / `destructiveText`) shows the reason, a translated sentence fragment, the detail pane is inert, nothing is written. Fixing the file re-enables the pane (file watcher).
5. S5 Live effect: the shell watches `grassfield.json`; changes apply immediately (transparency, appearance, hot corners, Dock). The app also follows external edits of the file.
6. S6 Config location: `GRASSFIELD_CONFIG_HOME` (dev) else `$XDG_CONFIG_HOME/grassfield` else `~/.config/grassfield`, same as the shell.
7. S7 Bindings file: `/usr/share/grassfield/hypr/grassfield/bindings.lua` when installed, else `$GRASSFIELD_CONFIG_DIR/grassfield/bindings.lua` (set in the dev session), else the repository copy baked in by `build-direct.sh`. Only literal `bind("KEYS", "Description", ...)` lines are listed (loops and computed keys, e.g. the Space switchers, are skipped).
8. S8 Shell integration: Grassfield menu > "System Settings…" runs `grassfield-settings` (dev: `GRASSFIELD_SETTINGS_CMD`, split on spaces, no shell).
9. S9 Accessibility and input: `qsTr` for all strings, `Accessible` names and roles on controls, rows and the banner; Up/Down/Home/End in the sidebar, Down or Return in the search field moves to the list, Tab enters the pane, Space/Return activate controls, Left/Right change a segmented choice or slider, Esc clears the search or closes a pop-up menu. Untrusted text (file contents, system strings) is `Text.PlainText`.
10. S10 Opaque window (master-prompt 5.5): tokens only (`settings.*` group of `ui/tokens/tokens.json`); the shared PopupMenu is drawn with transparency forced to 0 inside the app.
11. S11 Global menu (T1, master-prompt 5.7, ADR-0008): when `com.canonical.AppMenu.Registrar` is on the session bus at start (`apps/globalmenu.h`), the window exports File (Close Window, Ctrl+W), Edit (Undo, Redo, Cut, Copy, Paste, Select All on the search field; Find, Ctrl+F) and View (the sections) through DBusMenu (`qml/GlobalMenu.qml`, `Qt.labs.platform`); the app menu and Window are the shell's T0 menus. Without the registrar nothing is created and the bar keeps T0. Ctrl+F and Ctrl+W also work in the window itself.

12. S12 System sections (M4, master-prompt 12): Wi-Fi, Bluetooth, Sound, Displays, at the top of the sidebar.
   - Backends (no new service or dependency; the tools are already installed, `apps/settings/qml/System.js` parses them): Wi-Fi `nmcli -t` (NetworkManager), Bluetooth `bluetoothctl` (BlueZ), Sound `wpctl status` (PipeWire), Displays the Qt screens the compositor reports to the app (no Hyprland IPC). The shell uses the Quickshell Networking/Bluetooth/Pipewire modules, which exist only inside the shell; the app is a plain Qt program, so the CLIs are the same services through their supported front ends. Queries run asynchronously (`Backend.query`, 5 s timeout) and are repeated every `settings.systemRefreshMs` while a pane is open.
   - Wi-Fi: switch, current network, list (strength glyph, lock, check), click connects to a saved or open network, click on the current one disconnects. New secured networks are not joined here (the row says to use Quick Settings).
   - Bluetooth: switch and paired devices (connect/disconnect, check when connected). No discovery or pairing.
   - Sound: output and input device lists (default checked, click sets default), volume slider (writes coalesced every `settings.volumeApplyMs`) and mute for each default device.
   - Displays: READ-ONLY. Arrangement preview (when more than one output), then resolution, refresh rate and scale per output. Monitors come from the Hyprland Lua configuration (`config/hypr/session.lua`, the user's `monitors.lua`), which Grassfield does not own and which has no settings key, so there is no safe write path in this milestone.
   - Dev guard (`GRASSFIELD_DEV=1`): `Backend.act` never runs a command (one `dev guard: <what> suppressed` line, a "dev: not applied" note in the pane); `Backend.query` runs only the exact read-only argument vectors of `src/systemguard.cpp` and refuses anything else, so a mutation cannot be smuggled in as a query. In a real session `act` runs only nmcli, bluetoothctl and wpctl; argument vectors are built by validated functions (`System.js`, null for invalid values, no shell).
   - `--section=<id>` (wifi, bluetooth, sound, displays, ...) opens a section first.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| S3/S4 | `tests/unit/tst_settingsstore.qml`: merge preserves keys, nested creation, fresh file, malformed/invalid refusal (no write), schema parity, ConfigStore with a fake backend (external change, blocked state) | L0 |
| S7/S2 | same file: bindings parser (including the real file), os-release/cpu/memory/lspci/pacman parsers | L0 |
| S1-S10 | nested: launch, screenshots of every section in light and dark, picker and slider with real pointer, keyboard navigation with wtype, hot corner effect, transparency effect on menu bar and Dock, malformed file refusal (`cmp`), menu item launch | L1 |
| S11 | nested, private bus with the bridge: File, Edit, View in the bar; View > Keyboard clicked with the pointer shows the Keyboard section | L1 |
| S12 | `tests/unit/tst_settingssystem.qml`: nmcli/bluetoothctl/wpctl parsers, argument vectors, arrangement, SystemService guard on/off | L0 |
| S12 | `tests/shell/settings_system_guard.sh`: real Backend with recording tool shims: dev runs only the 8 queries and no action, real session runs actions, unknown program refused | L0 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**/*.qml`) and `check-textformat.py` | L0 |

## Implementation notes (v1, `apps/settings/`)
- `src/main.cpp` launcher, `src/backend.{h,cpp}` small QObject: `readText`, `writeText` (QSaveFile), `run(argv)` (3 s timeout), `watch` (QFileSystemWatcher on the file and its directory), `configFile`, `bindingsFile`, versions. Passed to QML as the initial property `backend`.
- `qml/`: `Main.qml` (window, sidebar, search, banner), `ConfigStore.qml` (state, `value(key)`, `set(key, v)`), `Store.js` (pure validation and merge), `Bindings.js`, `SysInfo.js`, pages `*Page.qml`, components `SettingsPage/Group/Row`, `Segmented`, `Picker` (PopupMenu from `Grassfield.Ui` on a window-wide layer).
- Build: `apps/settings/build-direct.sh` (g++, `moc`, pkg-config Qt6Gui/Qml/Quick) writes `.dev/build/grassfield-settings`; `CMakeLists.txt` is provided for when cmake is installed.
- Dev run: `WAYLAND_DISPLAY=$(cat .dev/nested.wayland) QML_IMPORT_PATH=$PWD/ui GRASSFIELD_CONFIG_HOME=$PWD/.dev/config .dev/build/grassfield-settings`.
- Desktop entry: `org.grassfield.Settings.desktop` (Name "Grassfield Settings", Icon `preferences-system` (a stock theme icon, so it resolves without the Grassfield icon set), Categories Settings).

## Known limitations
- Displays is read-only (no write path); Wi-Fi cannot join new secured networks and Bluetooth cannot pair (Quick Settings handles passwords; pairing is deferred). The system panes were verified against recorded tool output and shims, not by acting on real hardware.
- Appearance offers Light and Dark only: `auto` is accepted by the schema but the shell treats it as dark.
- Dock pinned apps, shortcuts editing, wallpaper and Auto appearance are not part of v1.
- The Keyboard list shows only literal bindings (no numbered Space switchers) and is not refreshed while the app is open.
- About runs `pacman -Q` and `lspci` once when the page opens (synchronously, 3 s timeout each); on systems without them the value reads "Unknown". The Grassfield version is the Settings app version (the shell's own version string is not exposed).
- Slider drags write the file on every step (atomic, small); the shell applies each step.
- The nested dev session has no titlebars (compositor plugin not loaded), so the window is borderless there.
- The desktop entry uses the stock `preferences-system` icon; swap to the Grassfield `gear` once the icon set is installed into an icon theme.
- Concurrent writers: the shell (`SettingsStore`) writes by merge. Setters record dirty keys, the file is re-read right before the write and only those keys are replaced, atomically; external edits made within the save delay survive, and keys outside the schema are preserved (the schema forbids them, but a writer never drops what it does not own). A fresh or empty file is created from the full defaults.
- The Settings app edits by parse and re-serialize (`Store.js`), which cannot keep integers beyond 2^53, duplicate keys or integer-like object keys. A file containing any of them is treated like a malformed file: read-only with a "cannot be edited safely" banner, file untouched. The schema has no such values, so only hand-made files are affected. The detection is shared (`ui/Grassfield/Ui/JsonSafety.js`, also catching duplicate `__proto__` keys and big integers written with a decimal point or exponent); the shell's `SettingsStore` applies it too: it never rewrites such a file (warns once, keeps the changes in memory, `writeBlocked`).
- Without the AT-SPI bus the Qt accessibility tree is not published (Accessible properties are set but only verified by code review, not by a screen reader).
