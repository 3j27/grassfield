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

## Consequences
- Implemented in M3 (T1 + T2). M2 T0 menus need no bridge.
- Resource budget: ≤ 20 MB RSS, 0 % idle CPU (event-driven).
