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

Interim build (no CMake/Ninja yet): `compositor/build-direct.sh [plugin|tests|all]`. The exact commands it runs,
from `compositor/`:

```sh
g++ -std=c++23 -O2 -g -DNDEBUG -shared -fPIC -Wall -Wextra \
  src/main.cpp src/Titlebar.cpp src/Ipc.cpp src/core/Protocol.cpp src/core/TitlebarLayout.cpp \
  $(pkg-config --cflags --libs hyprland pixman-1 libdrm) $(pkg-config --cflags lua) \
  -o build/grassfield-compositor.so

g++ -std=c++23 -O0 -g -Wall -Wextra -Isrc \
  tests/ProtocolTest.cpp tests/TitlebarLayoutTest.cpp src/core/Protocol.cpp src/core/TitlebarLayout.cpp \
  $(pkg-config --cflags --libs gtest_main) \
  -o build/grassfield-compositor-tests
```

Outputs: `compositor/build/grassfield-compositor.so`, `compositor/build/grassfield-compositor-tests`
(`compositor/build/` is gitignored).

## Test

```sh
compositor/build/grassfield-compositor-tests     # pure logic: protocol JSON, button layout, hit-testing, double-click
```

## Run (nested only)

`scripts/dev/nested-up.sh` passes the built `.so` to the nested config (`GRASSFIELD_PLUGIN`).
Known issue (S2): `config/hypr/dev.lua` registers the plugin from a `hyprland.start` callback, which is
after Hyprland has applied the config's plugin list, so the plugin is not loaded. Until dev.lua is fixed
(see the spec), the spike shim loads it at parse time:

```sh
PATH="$PWD/spikes/s2-ipc/bin:$PATH" scripts/dev/nested-up.sh
WAYLAND_DISPLAY=$(cat .dev/nested.wayland) setsid foot >/dev/null 2>&1 &
scripts/dev/shot.sh titlebar
```

Startup log line: `[grassfield] grassfield-compositor 0.1.0-s2 initialised on Hyprland v0.56.2 (commit …), ABI hash match`.

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
  `TitlebarLayout.*` (geometry, hit-testing, double-click), `Protocol.*` (gfc/1 JSON).
- `src/` — Hyprland glue: `main.cpp` (entry points, ABI check, event bus listeners), `Titlebar.*`
  (decoration, drawing, input), `Ipc.*` (socket2 events, Lua function, hyprctl command).
- `tests/` — GoogleTest unit tests for `src/core/`.
