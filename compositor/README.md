# grassfield-compositor

Hyprland plugin for the Grassfield session (master-prompt §5.6). Spike S2 scope:

- titlebars on floating windows: close / minimize / zoom buttons on the left, centered title,
  drag to move, double-click to zoom;
- shell IPC `gfc/1`: capabilities event on Hyprland's socket2, `hl.plugin.grassfield.hello()`,
  `hyprctl grassfield`.

Spec: [`docs/specs/compositor.md`](../docs/specs/compositor.md).

**Load it only into the nested dev instance** (R13). Loading it into a real session is an owner action.

## Requirements

- Hyprland **0.56.2** headers (`pkg-config --modversion hyprland`), built with the same compiler (GCC).
- C++23 (the 0.56.2 headers use `std::expected` and `std::string_view::contains`).
- Lua 5.5 headers (`pkg-config lua`); Lua symbols resolve at load time from Hyprland's own `liblua`.
- Tests: GoogleTest (`gtest`).

## Build

CMake (once the owner has installed `cmake` and `ninja`):

```sh
just plugin-build      # = cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build compositor/build
```

Interim build (no CMake/Ninja yet): `compositor/build-direct.sh [plugin|tests|compdb|all|tidy]` (default `all` =
plugin + tests + compdb). The exact commands it runs, from `compositor/`:

```sh
g++ -std=c++23 -O2 -g -DNDEBUG -fPIC -Wall -Wextra \
  $(pkg-config --cflags hyprland pixman-1 libdrm) $(pkg-config --cflags lua) -shared \
  src/main.cpp src/Titlebar.cpp src/Ipc.cpp \
  src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp \
  $(pkg-config --libs hyprland pixman-1 libdrm) -o build/grassfield-compositor.so

g++ -std=c++23 -O0 -g -Wall -Wextra -Isrc $(pkg-config --cflags gtest_main) \
  tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp \
  src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp \
  $(pkg-config --libs gtest_main) -o build/grassfield-compositor-tests
```

`compdb` writes `build/compile_commands.json` (one entry per translation unit, same flags as above, via `jq`).

Outputs: `compositor/build/grassfield-compositor.so`, `compositor/build/grassfield-compositor-tests`,
`compositor/build/compile_commands.json` (`compositor/build/` is gitignored).

## Test

```sh
compositor/build/grassfield-compositor-tests     # pure logic: protocol JSON, button layout, hit-testing,
                                                 # double-click, pointer press ownership / gesture end
```

## Lint (gate Q1)

Config: `compositor/.clang-tidy` (`clang-analyzer-*`, `bugprone-*`, `performance-*` minus
`bugprone-easily-swappable-parameters`; analyzer findings are errors; only `compositor/src` and
`compositor/tests` headers are reported). Exact command (writes the compile database first):

```sh
compositor/build-direct.sh tidy
# = compositor/build-direct.sh compdb && cd compositor && \
#   clang-tidy -p build --quiet src/main.cpp src/Titlebar.cpp src/Ipc.cpp \
#     src/core/Protocol.cpp src/core/TitlebarLayout.cpp src/core/PointerGesture.cpp \
#     tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp tests/PointerGestureTest.cpp
```

Clean = exit code 0 and no diagnostics. It takes several minutes (Hyprland headers).

## Run (nested only)

`scripts/dev/nested-up.sh` passes the built `.so` to the nested config (`GRASSFIELD_PLUGIN`), and
`config/hypr/dev.lua` loads it with `hl.plugin.load` at parse time (a load requested from a `hyprland.start`
callback would be ignored: Hyprland applies the config's plugin list right after parsing).
`GRASSFIELD_PLUGIN=/path/to.so` loads another build; `GRASSFIELD_NO_PLUGIN=1` starts without it (C2).

```sh
scripts/dev/nested-up.sh
WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &
scripts/dev/shot.sh titlebar GF-REF
scripts/dev/pointer.sh output GF-REF abs 960 250 down drag 700 400 up   # drag a titlebar
```

Startup log line (in `$XDG_RUNTIME_DIR/hypr/<nested instance>/hyprland.log`):
`[grassfield] grassfield-compositor 0.1.0-s2 initialised on Hyprland v0.56.2 (commit …), ABI hash match`.

## Soak (gate C1, nested only)

```sh
scripts/dev/nested-up.sh
tests/compositor/soak.sh 3600     # duration in seconds; log: .dev/soak-<timestamp>.log
```

Window churn (short-lived and long-lived foot windows) with titlebar drags (some abandoned mid-drag),
zoom, close and cancelled clicks through the virtual pointer. PASS (exit 0) = nested Hyprland alive, no
`coredumpctl list Hyprland` entry for its PID since the start (dumps of other Hyprland instances, e.g. other
worktrees' nested sessions, are listed but not counted), no grassfield exception in the nested log.

Input consistency (FR13 regression, nested only): `tests/compositor/input_consistency.sh [rounds]` — fast
titlebar drags and close-button cancels on one mouse-reporting foot window, each followed by a click inside
another; PASS (exit 0) = every click reached the clicked window and none reached the dragged one.

Zoom restore (FR8 regression, nested only): `tests/compositor/zoom_restore.sh` — double-click, click + zoom
button and a drag on a maximized titlebar; PASS (exit 0) = the zoom toggle always restores the floating
geometry and a drag un-zooms the window under the pointer.

## Pointer input

A titlebar consumes left presses on its bar. Press ownership and gesture lifetime are pure logic
(`src/core/PointerGesture.*`, unit-tested); `Titlebar.cpp` feeds it Hyprland's events:

- no button event is cancelled on the event bus: Hyprland records every press as held, also one a
  titlebar consumes, and only a release it processes clears it (a stale held button pins pointer focus,
  so the next click on another window went to the dragged one);
- the release of a press a titlebar consumed is consumed by a titlebar when Hyprland routes it there
  (pointer over a bar); elsewhere it reaches the seat, which drops it because the client never got the
  press (Hyprland logs `sendButton release on a non-pressed button`). A release whose press went to a
  client is never consumed, even over a bar;
- a drag or armed button ends on its release, on any new press (the release was lost), or on a motion
  when Hyprland reports no held button or a pointer device present at the press has disappeared
  (Hyprland 0.56.2 does not release the buttons of a removed pointer device).

## Unload

`PLUGIN_EXIT` removes the titlebars of visible windows through `HyprlandAPI::removeWindowDecoration` and
destroys the others (unmapped or hidden windows, for which Hyprland 0.56.2 defers the removal) directly:
erase from `CWindow::m_decosToRemove`, `CDecorationPositioner::uncacheDecoration`, erase from
`CWindow::m_windowDecorations`. Each titlebar also removes itself from the plugin's
`CPlugin::m_registeredDecorations`, which Hyprland walks with `removeWindowDecoration` after `PLUGIN_EXIT`.

## IPC (gfc/1)

| Direction | How | Payload |
|---|---|---|
| plugin → shell | socket2 event, posted at load and on `hello` | `grassfield>>{"v":"gfc/1","type":"capabilities","features":["decorations"]}` |
| plugin → shell | socket2 event, minimize button (**placeholder**) | `grassfield>>{"v":"gfc/1","type":"minimize-request","address":"<hex>"}` |
| shell → plugin | `Hyprland.dispatch("hl.plugin.grassfield.hello()")` (Quickshell) | re-posts capabilities |
| query | `hyprctl grassfield` | capabilities JSON |

There is no `grassfield:hello` dispatcher: under Hyprland's Lua config every dispatch is evaluated as
`return hl.dispatch(<arg>)`, so legacy plugin dispatchers (`HyprlandAPI::addDispatcherV2`) are unreachable.

## Placeholders

- **Minimize** (button): posts `minimize-request` only; the window is not minimized (real minimize is M2).
  `minimize` is not advertised in `capabilities`.

## Layout

- `src/core/` — plain C++ without Hyprland includes (unit-tested): `Theme.hpp` (all visual constants),
  `TitlebarLayout.*` (geometry, hit-testing, double-click), `PointerGesture.*` (press ownership, gesture
  end), `Protocol.*` (gfc/1 JSON).
- `src/` — Hyprland glue: `main.cpp` (entry points, ABI check, event bus listeners, unload), `Titlebar.*`
  (decoration, drawing, input), `Ipc.*` (socket2 events, Lua function, hyprctl command).
- `tests/` — GoogleTest unit tests for `src/core/`. Nested scenarios (repository root):
  `tests/compositor/soak.sh`, `tests/compositor/input_consistency.sh`, `tests/compositor/zoom_restore.sh`.
