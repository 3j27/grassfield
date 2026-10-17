# ADR-0008: Menu bridge language and transport
Status: Proposed · Date: 2026-10-17 · Decider: owner

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

## Decision (proposed)
Option 1: `bridges/menu-bridge/`, binary `grassfield-menu-bridge`, systemd **user** unit
(`grassfield-menu-bridge.service`, `PartOf=graphical-session.target`, hardened: `NoNewPrivileges`,
`ProtectSystem=strict`, `PrivateNetwork`, `RestrictAddressFamilies=AF_UNIX`, `MemoryMax=64M`).
- Input: appmenu registrations from the plugin (`grassfield>>{"type":"appmenu",...}` events, ADR-0007) or,
  for T1 apps, the `com.canonical.AppMenu.Registrar` D-Bus interface that Qt uses (the bridge owns the
  registrar name `com.canonical.AppMenu.Registrar` in the Grassfield session).
- Output: `$XDG_RUNTIME_DIR/grassfield/menu-bridge.sock`, JSON lines, versioned `menu/1`:
  `{"type":"menu","window":"<address>","items":[...]}` and requests `{"type":"activate","id":N}`,
  `{"type":"about-to-show","id":N}`. Also `org.grassfield.MenuBridge1` on D-Bus for diagnostics, with XML in
  `bridges/menu-bridge/dbus/`.
- It executes nothing except DBusMenu `Event`/`AboutToShow` calls (§5.2).

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

Data flow proposed for step B (input for the Decision above, not yet decided):
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

## Consequences
- Implemented in M3 (T1 + T2). M2 T0 menus need no bridge.
- Resource budget: ≤ 20 MB RSS, 0 % idle CPU (event-driven).
