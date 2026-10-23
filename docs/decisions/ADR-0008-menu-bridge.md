# ADR-0008: Menu bridge language and transport
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed) · Date: 2026-10-17 · Decider: owner

## Context
D4: global menus through `org_kde_kwin_appmenu`. The plugin implements the protocol server and learns, per
`wl_surface`, a DBusMenu `(service, object path)`. The shell must render those menus and trigger real
actions. Quickshell 0.3.1 has a DBusMenu module, but `DBusMenuHandle` cannot be created from QML (§2), so
the shell cannot open an arbitrary DBusMenu by itself.

## Options
1. **C++/Qt 6 daemon** (QtDBus for `com.canonical.dbusmenu`, `QLocalServer` JSON-lines for the shell).
   No new dependency (qt6-base), same toolchain as the plugin and apps (CMake).
2. Python + dbus-next — new runtime dependency, slower startup.
3. Rust + zbus — new toolchain (not installed), duplicated build infrastructure.

## Decision (proposed; applied provisionally in M3 step B, 2026-10-17)
Option 1: `bridges/menu-bridge/`, binary `grassfield-menu-bridge` (C++/Qt 6: QtCore, QtDBus, QtNetwork; CMake and
`build-direct.sh`), systemd **user** unit `packaging/systemd/grassfield-menu-bridge.service` (`PartOf=` and
`Requisite=graphical-session.target`, `ConditionEnvironment=GRASSFIELD_SESSION=1`, hardened: `NoNewPrivileges`,
`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, `PrivateNetwork`, `RestrictAddressFamilies=AF_UNIX`,
`SystemCallFilter=@system-service`, empty capability set, `MemoryHigh=64M` / `MemoryMax=256M`, `TasksMax=16`; measured: idle ~15 MB, one 30 MB reply peaks at 115 MB, hence the 256 MB kill limit and the crash attribution below), started by
`config/hypr/grassfield/autostart.lua` before the shell and applications. Contract details: `docs/specs/menu-bridge.md`.
- **Input**: only from the shell, which is the single consumer of the plugin's `appmenu` events (data flow 1–4 below,
  adopted as proposed). The bridge never trusts names from anywhere else and checks each one (spoofing rule below).
- **Registrar**: `com.canonical.AppMenu.Registrar` is owned only while the connected shell's latest hello says
  `"appmenu": true`; released on `false` and on disconnect; standby at start. Its methods answer errors
  (`RegisterWindow`/`UnregisterWindow` NotSupported, `GetMenuForWindow` NotFound, `GetMenus` NotSupported): Wayland
  clients never call them and nothing pretends to keep a registration.
- **Output**: `$XDG_RUNTIME_DIR/grassfield/menu-bridge.sock` (directory 0700, socket 0600), JSON lines `menu/1`.
  shell → bridge: `hello` (`v`, `appmenu`), `open` (`window`, `service`, `path`, `pid`), `about-to-show` and
  `activate` (`window`, `id`), `close` (`window`). bridge → shell: `status`, `menu` (`window`, `revision`, `items`
  tree), `error` (`window`, `code`, `message`). Every message is validated on both sides (line, depth, item and string
  caps). Diagnostics: `org.grassfield.MenuBridge1` (`Version`, `Status`), XML in `bridges/menu-bridge/dbus/`.
- **Spoofing rule**: additive gfc/1 field `"pid"` in `appmenu` events (`wl_client_get_credentials` of the registering
  client); the bridge resolves the bus name to its unique owner and accepts it only if
  `GetConnectionUnixProcessID(owner)` equals that pid. Verified true for Qt 6.11 and Chromium 152 (same process for
  their Wayland and D-Bus connections).
- It executes nothing except DBusMenu `GetLayout`/`AboutToShow`/`Event` calls (explicit D-Bus types) and the two
  bus-daemon queries of the spoofing rule (§5.2).
- **Shell**: `shell/platform/MenuBridge` keeps `window → {service, path, pid}`, re-queries the plugin after a shell
  restart, opens the focused window's menu; the menu bar shows the app's menus after the app name (T0 app menu and
  Window kept, T0 File replaced) and keeps T0 when there is no T1/T2 menu.
- **Development**: the registrar, the bridge and test apps share the nested session's private bus (one dbus-daemon per
  nested session, `scripts/dev/nested-up.sh --private-bus`); with `GRASSFIELD_DEV=1` the bridge refuses the owner's
  default session bus.

## Evidence
Spike S5 and step A (2026-10-17, compositor-engineer; details, commands and run directories in
`docs/specs/compositor.md` "Appmenu (feature 3, spike S5): mechanism" and "S5 results"):
- **Protocol server feasible in a plugin.** Hyprland 0.56.2 has no plugin API for Wayland protocols, but a plugin
  can create a global with libwayland on `g_pCompositor->m_wlDisplay` and compile hyprwayland-scanner server code
  (internal API, same ABI-hash guard as the rest of the plugin). `grassfield-compositor` now advertises
  `org_kde_kwin_appmenu_manager` version 2 and feature `appmenu`, validates `set_address` (D-Bus bus name and
  object path, ≤ 255 bytes; invalid requests ignored without disconnecting the client) and posts
  `grassfield>>{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"…","path":"…"}` per window (empty
  strings = no menu); `hl.plugin.grassfield.appmenu(address)` re-posts it. Unloading safely needs care: at
  shutdown everything is destroyed; a runtime unload with live client objects pins the library
  (`RTLD_NODELETE`) because destroyed objects would get their clients disconnected (runtime unload not verified:
  no `scripts/nestctl`).
- **Qt 6.11.2**: calls `org_kde_kwin_appmenu.set_address(<unique name>, "/MenuBar/<n>")` if and only if
  `com.canonical.AppMenu.Registrar` is owned on its session bus when the menu bar is created (checked once; a
  registrar started 3 s later changes nothing). Platform theme (generic, gtk3, xdgdesktopportal, KDE) and KDE
  variables are irrelevant. Qt never calls `RegisterWindow` on Wayland. It exports `com.canonical.dbusmenu`
  (introspectable); `GetLayout`, `AboutToShow` and `Event(id, "clicked", …)` from outside ran the app's own
  actions (menu-demo action log), File > Quit closed the app.
- **Chromium 152**: same condition (registrar present), no flag needed; one object per browser window
  (`/com/canonical/menu/<n>`); **no introspection data**, so DBusMenu calls need explicit signatures
  (`GetLayout(int32, int32, as)`, `Event(int32, s, v, uint32)`); a DBusMenu click on File > New window opened a
  window. Firefox: not installed, not tested.
- Both bind manager version 1.
- **Registrar without the appmenu path hides menus**: with the registrar present and no appmenu global, Qt hides
  its in-window menu bar and the menu is shown nowhere (variant qt-no-global). In development the registrar
  (test fixture `tests/fixtures/fake-registrar`) runs only on private buses; it refuses a bus with well-known
  names.

Data flow proposed for step B (input for the Decision above; adopted as written, see the Decision):
1. **Registrar ownership is gated.** The bridge owns `com.canonical.AppMenu.Registrar` on the session bus only
   once the shell's handshake shows the plugin feature `appmenu` and the shell's menu bar can render bridge menus,
   and before applications start (Qt and Chromium check once, at their start). If the plugin is absent or loses
   the feature, the bridge does not own (or releases) the name: apps started meanwhile keep in-window menus.
   The registrar methods can stay minimal (`RegisterWindow` is never called by Wayland clients; keep it for
   XWayland apps later or answer with an error).
2. **Registration**: app exports DBusMenu → `set_address(service, path)` on its toplevel's `wl_surface` → plugin
   validates and maps it to the window → socket2 `appmenu` event (and again at map, focus and on
   `appmenu(address)`).
3. **Consumer**: the shell is the single socket2 consumer (`Hyprland.rawEvent`, already connected; it also knows
   focus). It keeps `window → (service, path)` and, for the focused window, sends the bridge
   `{"type":"open","window":"<hex>","service":"…","path":"…"}`; after a shell restart it calls
   `hl.plugin.grassfield.appmenu(address)` for the windows it shows. The bridge never trusts names from anywhere
   else.
4. **Ownership check (spoofing)**: a client can name another app's bus name in `set_address`. Proposed additive
   gfc/1 field `"pid"` (the plugin has the client's credentials from `wl_client_get_credentials`); the bridge
   accepts the pair only if `org.freedesktop.DBus.GetConnectionUnixProcessID(service)` equals that pid (true for
   Qt and Chromium, whose Wayland and D-Bus connections are in the same process; sandboxed apps behind a D-Bus
   proxy need a later rule).
5. **Menus**: the bridge calls `GetLayout(int32 0, int32 -1, as [])` with explicit signatures, follows
   `LayoutUpdated` / `ItemsPropertiesUpdated`, calls `AboutToShow(id)` when a submenu opens, and maps items
   (label with `_` mnemonic, enabled, visible, toggle-type/state, shortcut, children-display, separators) to
   `menu/1` JSON for the shell; a click is `Event(int32 id, "clicked", <int32 0>, uint32 timestamp)`. It drops a
   menu on the plugin's clear event, on `NameOwnerChanged` of the service, or when the shell closes it.
6. **Development**: the bridge, the registrar and test apps share the nested shell's private bus
   (`GRASSFIELD_PRIVATE_BUS=1`, `.dev/bus.address`), never the owner's bus.

Step B (2026-10-17, platform-engineer; branch of this change): `tests/integration/global_menus.sh` PASS on the nested
session's private bus — menu-demo (Qt 6.11.2) and Chromium 152 show their own menus in the menu bar when focused;
pointer clicks ran File > New and View > Theme > Dark (action log) and Chromium File > New window (second window);
the menus come back after a shell restart (plugin re-query); Nautilus (GTK4) keeps T0; with `--no-plugin` no
registrar is owned and menu-demo keeps its in-window menu bar (`platformMenuBar=0 menuBarVisible=1`); no bridge or
private bus is left after `nested-down.sh`. On a throwaway private bus an `open` naming another process's bus name
was refused (`pid-mismatch`).

## Consequences
- Implemented in M3 (T1 + T2). M2 T0 menus need no bridge.
- Resource budget: ≤ 20 MB RSS, 0 % idle CPU (event-driven).
- X11/XWayland apps (RegisterWindow) are not served; Qt under XWayland hides its menu bar while the registrar exists
  (limitation listed in `docs/specs/menu-bridge.md`). Sandboxed apps behind a D-Bus proxy need a later rule.

## Amendment 2026-10-17: crash attribution (global menus counter-review)
A hostile or buggy application can make the bridge allocate a multiple of its reply and hit `MemoryMax`. Decision: every
outbound call (GetLayout including re-reads, AboutToShow, Event) is recorded as in flight in `<socket>.state` until its
reply was handled; a restarted bridge refuses the application whose call was in flight, keyed by its executable
(`/proc/<pid>/exe`), not its pid, so a new process does not escape. At most one restart per refusal period (15 min,
doubling to 6 h, decaying); bounded to 128 identities; the file is atomic, symlink-safe, size-bounded and validated.
Details and residual risks: `docs/specs/menu-bridge.md` MB14 and "Known limitations".

## Amendment 2026-10-18: attribution that never blames an innocent (fix pass of the counter-review)
The first amendment keyed refusals by executable and blamed every in-flight call after a crash. A second review showed
that this blames innocents (an unsolicited 100 MB message arriving while a victim's call is open), that incoming
messages are buffered by libdbus before the bridge can mark anything, and that executables are a weak key (shared
interpreters, non-dumpable processes, copies). Decisions:
- A crash is blamed only on the one identity with exactly one FRESH (at most 1 s old) call in flight. Anything else is
  an "unattributed crash": counted, nobody penalised. Five within an hour make the bridge give up (degraded: no
  registrar, `backoff` to every `open`, T0 menus, one log line, no notification). The state file now carries `run 0|1`,
  the age of calls in flight (refreshed every 250 ms), the unattributed count and the refusals.
- Identity = systemd app scope without the instance (flatpak id included) + exe + script of interpreters. Unreadable
  exe: one shared `unknown` bucket, 2 min at most, never doubling. Never a pid.
- Unsolicited surface: only the registrar methods get an answer, other calls and signals on the bridge's objects are
  dropped, per-menu subscriptions are sender-specific. Idle identities are bounded (128) separately from refused ones
  (64, closest to expiry out past the cap); a clean exit does not reset the doubling inside the 24 h decay window; the state
  file is written with `openat(O_EXCL|O_NOFOLLOW)` + `renameat`.
Consequences and residual risk: attribution stays a heuristic. A same-uid process can always OOM or kill the bridge;
buffering cannot be prevented; a fresh single call coinciding with someone else's huge message is blamed wrongly (15 min
of T0 menus for that application; the wrongful blame can repeat and doubles each time); a hostile reply delayed beyond
1 s is merely counted, and a copied binary is blamed and counted copy by copy. The worst outcome of any of this is a
bridge that stays down or degraded and a desktop showing T0 menus.
Details: `docs/specs/menu-bridge.md` MB14 and "Known limitations".

## Amendment 2026-10-18 (final pass): every crash counts
- Every crash counts toward the degradation budget, blamed or not: 5 within any sliding 60 minutes (crash times are
  kept in the state file, header `state 3`). Attribution only adds a per-identity refusal on top, so rotating copies
  of a binary can no longer crash-loop the bridge without ending degraded.
- The scope instance is stripped for the real launcher formats (`-<digits>`, uwsm's `-<8 hex>`, KIO's `-<32 hex>`; the key keeps the
  `\x2d` escape, logs show `-`). Interpreter options before the script are skipped when known; an unknown option puts
  the peer in the shared `unknown` bucket instead of taking its value for the script.
- Idle entries are never pushed out by refused ones, but the refused set is capped at 64 (`capRefused` drops the one
  closest to expiry): a flood of fresh identities can push out old refusals.

### Residual risks (accepted, 2026-10-18)
The change is defense in depth against same-uid apps; failure is bounded (T0 menus).
- Same-uid apps can kill or OOM the bridge, or force degraded mode for the session.
- An honest slow app can be wrongly blamed when an attacker's huge message lands during its call.
- Degraded mode does not recover until the session restarts.
- Flatpak apps with registrar access can send big messages (not verified).
- 2026-10-18 (integrator, closing the attribution work): any interpreter option before the script sends the peer to the
  shared `unknown` bucket (no per-interpreter option table: values were mistaken for scripts in review); KIO's 32-hex
  scope instance is stripped. Further attribution hardening is out of scope (residual risks accepted above).
