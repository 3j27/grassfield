# menu-bridge spec · platform-engineer (+ shell integration) · M3 (global menus step B)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
The menu bar shows the frontmost application's own menus after the application menu: File, Edit, View, … in the
application's order, with its shortcuts, check marks, disabled items and submenus. Choosing an item runs the
application's command. Grassfield keeps its own application menu (About, Hide, Quit, the T0 app menu) and the
Window menu around the application's menus.

## Purpose and non-goals
Serve DBusMenu menus (`com.canonical.dbusmenu`) of Qt/KDE and Chromium windows to the menu bar (master-prompt §1.1
D4, §5.7 T1/T2, ADR-0008). `grassfield-menu-bridge` (C++/Qt 6: QtCore, QtDBus, QtNetwork) is the only Grassfield
daemon (§5.8). Non-goals now: X11/XWayland windows (`RegisterWindow`), Firefox (its Wayland global menu pref is off
by default, owner approval needed), Electron (exports menus only on X11), GTK4 (no menu bar to export), menu icons
(`icon-name` is relayed but not drawn: Grassfield's menus carry no application icons), keyboard navigation between
top-level menus (Left/Right).

## Functional requirements (numbered, testable)
- **MB1 Registrar gating.** The bridge owns `com.canonical.AppMenu.Registrar` only while the connected shell's latest
  `hello` says `"appmenu": true` (the plugin advertises the `appmenu` feature; the menu bar renders bridge menus). It
  releases the name on `hello` with `false` and when the shell disconnects; it starts in standby. If another process
  owns the name the bridge reports `registrar-busy` and stays in standby (state `busy`).
- **MB2 Registrar methods** (Wayland clients never call them, spike S5): `RegisterWindow`, `UnregisterWindow` →
  `com.canonical.AppMenu.Registrar.Error.NotSupported`; `GetMenuForWindow` → `…Error.NotFound`; `GetMenus` →
  `org.freedesktop.DBus.Error.NotSupported`. Each sender/method pair is logged once.
- **MB3 Socket.** `$XDG_RUNTIME_DIR/grassfield/menu-bridge.sock` (or `GRASSFIELD_MENU_BRIDGE_SOCKET` / `--socket`);
  the directory is created 0700 (an existing one must be a real directory owned by the user; wider modes are reduced),
  the socket is 0600; a live socket of another bridge is refused, a stale one replaced. One shell connection at a
  time (others get `busy`). Removed on SIGTERM/SIGINT/SIGHUP.
- **MB4 Validation (untrusted shell).** Each line ≤ 4096 bytes, JSON object, known `type`, `v` = `menu/1` for
  `hello`, `window` 1–16 hex digits, `service` a D-Bus bus name, `path` an object path (≤ 255 bytes each, the plugin's
  rules), `pid` an integer 1…2³¹−1, `id` an integer 0…2³¹−1. Invalid lines are answered with `bad-request`; more than
  32 invalid lines or an over-long line closes the connection.
- **MB5 Ownership check (spoofing).** `open` carries the pid the plugin reported for the Wayland client that called
  `set_address` (gfc/1 `appmenu` field `pid`, `wl_client_get_credentials`). The bridge resolves a well-known name to
  its unique owner (`GetNameOwner`) and accepts the pair only if `GetConnectionUnixProcessID(owner)` equals that pid;
  otherwise `pid-mismatch` (`no-owner` when the name or its process is gone). Afterwards it talks to the unique name only.
- **MB6 DBusMenu client.** Explicit signatures (Chromium has no introspection data): `GetLayout(int32 0, int32 -1,
  as [])`, `AboutToShow(int32)`, `Event(int32 id, "clicked", variant<int32 0>, uint32 0)`. `LayoutUpdated` and
  `ItemsPropertiesUpdated` trigger one coalesced `GetLayout` (40 ms); `AboutToShow` returning `needUpdate` too. The
  menu is dropped (`gone`) when the unique name leaves the bus (NameOwnerChanged) and on `close`. Calls time out after
  3 s; at most 16 windows have an open menu (least recently opened dropped).
- **MB7 Mapping (untrusted application).** Only known properties are read (`label`, `enabled`, `visible`, `type`,
  `toggle-type`, `toggle-state`, `children-display`, `icon-name`, `shortcut`); wrong types fall back to the DBusMenu
  defaults. Labels: `_x` mnemonic markers removed (`__` → `_`), control and bidirectional formatting characters
  removed, whitespace collapsed, ≤ 256 characters (never half a surrogate pair). Shortcuts ≤ 4 of ≤ 6 printable keys
  (≤ 32 characters). Icon names `[A-Za-z0-9_.+-]{0,128}` only. Trees ≤ 8 levels and ≤ 2000 items; negative ids
  skipped. `about-to-show` is accepted only for submenus and `activate` only for enabled, visible leaves of the
  latest layout (`unknown-item` otherwise).
- **MB8 Executes nothing** but the three DBusMenu calls and the two bus-daemon queries of MB5.
- **MB9 Diagnostics.** `org.grassfield.MenuBridge1` at `/org/grassfield/MenuBridge1` (XML:
  `bridges/menu-bridge/dbus/org.grassfield.MenuBridge1.xml`): `Version() → s` ("0.1.0 menu/1"), `Status() → a{sv}`
  `{state: "standby"|"active"|"busy", registrar: b, shell: b, menus: u}`. Owning this name also makes the bridge a
  single instance per bus.
- **MB10 Start-up guards.** Refuses (exit 3) unless `GRASSFIELD_SESSION=1` or `GRASSFIELD_DEV=1`. With
  `GRASSFIELD_DEV=1` it refuses the owner's default session bus (empty address, `unix:path=/run/user/<uid>/bus`,
  `unix:runtime=yes`, `autolaunch:`) before connecting, refuses a bus where `org.freedesktop.systemd1` is present, and
  requires an explicit socket path.
- **MB11 Shell side** (`shell/platform/MenuBridge.{qml,js}`, `shell/menubar/`): keeps `window → {service, path, pid}`
  from gfc/1 `appmenu` events (validated: bus name, object path, pid); after the capabilities handshake it calls
  `hl.plugin.grassfield.appmenu(address)` for every window (FR22) so a restarted shell learns existing registrations.
  It connects to the socket (retry every 2 s), sends `hello` with `Capabilities.has("appmenu")` (again whenever it
  changes), `open` for the focused window (`close` for the previous one) and validates every bridge line again
  (depth, count, string caps). The shown window is Hyprland's active window, or (right after a start) the
  foreign-toplevel focus mapped to Hyprland's window list; it is kept while a shell popup holds the keyboard.
- **MB12 Menu bar.** For the shown app with a T1/T2 menu: Grassfield menu, the app name (T0 app menu), the app's
  visible top-level menus in its order (disabled ones dimmed, not opened), then the T0 Window menu. The T0 File menu
  (desktop entry actions) gives way to the app's own menus; those actions stay in the Dock menu. A title opens popup
  kind `appbridge` and sends `about-to-show`; opening a first-level submenu sends `about-to-show` once per open menu; a
  new revision that changes the open submenu reopens it. Items: plain-text labels, the app's shortcut text
  (`Control` → `Ctrl`, first shortcut), check mark for checkmark/radio items that are on, disabled items dimmed,
  hidden items left out, separators collapsed, a submenu the app has not filled shown disabled. Choosing an item sends
  `activate` and closes the menu. Without a T1/T2 menu (GTK4, Electron, no plugin, no bridge, refused or failed menu)
  the T0 menus stay: nothing is hidden.
- **MB14 Hostile applications and crash attribution.** A reply is the one thing an application can make the bridge
  allocate for (a 30 MB reply cost 115 MB at its peak). Defences, all in `bridges/menu-bridge/src/{Penalties,Bridge,
  MenuClient}.*`:
  - Caps while reading (MB7); a layout over a cap is `oversized`: no menu, no further `GetLayout` to that application.
    Labels are cut to 2048 characters while the layout is read. After a reply the bridge calls `malloc_trim(0)` (300 ms
    later, coalesced): RssAnon returns to about its idle size, measured by the integration test.
  - **Identity.** After MB5's pid check the bridge resolves `/proc/<pid>/exe` (` (deleted)` stripped) to `exe:<path>`
    (`pid:<pid>` when the link is unreadable). Refusals are keyed by that identity, not by the pid: a new process of the
    same executable is the same application. Applications that share an executable (interpreters) share their fate.
  - **In-flight marking.** EVERY call to an application (`GetLayout` including the re-reads after `LayoutUpdated` /
    `AboutToShow needUpdate`, `AboutToShow`, `Event`) is recorded in `<socket>.state` before it is sent and cleared once
    its reply was handled (or 4 s after the window was closed with the reply still outstanding). A clean stop leaves
    nothing in flight. A bridge that dies meanwhile (OOM kill, crash) finds the identity in the file at its next start,
    logs `a previous run died while a call to "<identity>" was in flight: refused` and refuses it.
  - **Refusals.** `oversized` and a crash: 15 min, doubling per strike up to 6 h (`backoff` error to the shell).
    `layout-failed` on open: 2^n s up to 64 s. So an application that kills the bridge costs **at most N = 1
    restart** per refusal period (`penalty::kRestartsBeforeRefusal`); one crash per 15 min at worst afterwards, then one
    per 30 min, and so on. Decay: leaving the bus while in good standing forgives one strike; an entry without a new
    strike for 24 h is dropped. At most 128 identities are kept (least recently used first out, refused ones last);
    the refusals survive restarts through the state file.
  - **State file.** `<socket>.state` (socket directory, mode 0700, file 0600, written with `QSaveFile`, i.e. atomically).
    Read with `O_NOFOLLOW`, regular file of this user, at most 32 KiB, header and boot id checked, every line validated
    (identity grammar, number ranges, at most 256 lines); one invalid line discards the whole file, which is then
    replaced. It is read only after the singleton probe (a second instance that finds the live bridge exits without
    touching it). Only code running as the same user can write the directory; such code can equally kill the bridge, so
    a forged entry can at most refuse one executable for 15 min: the bridge never writes an identity it did not itself
    resolve from a pid that passed MB5, and never reads one that fails the grammar.
- **MB13 Development.** `scripts/dev/nested-up.sh --private-bus` → `shell-run.sh` starts one private `dbus-daemon`
  (session configuration, socket in /tmp) per nested session, reused across shell restarts, and (re)starts the
  bridge on it before the shell and any test app (`.dev/run/menu-bridge.sock`, `.dev/menu-bridge.log`,
  `--menu-bridge PATH`). Without `--private-bus` no bridge runs. `nested-down.sh` stops the bridge, then the bus.

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)
| Req | Test | Level | Status |
|---|---|---|---|
| MB4, MB7, MB10 (logic), MB9 XML | `tests/unit/menu-bridge/tst_menubridge.cpp` (gtest, 35 cases incl. identity, penalties, state file, call marking; the wire and MenuClient cases run over a peer-to-peer D-Bus connection and skip where Unix sockets are forbidden) | L0 | see STATE.md (run outside the sandbox) |
| MB11, MB12 (models) | `tests/unit/tst_menubridge.qml` (event parsing, menu/1 lines, sanitizing, caps, popup model, shortcut text) | L0 | 2026-10-17: 8/8 PASS |
| gfc/1 `pid` | `compositor/tests` `Protocol.AppmenuJson*`, `AppmenuRegistry.PidTravels…` | L0 | 2026-10-17: 92/92 PASS |
| M3 exit (MB1, MB5, MB6, MB11, MB12, MB13) | `tests/integration/global_menus.sh` (nested, private bus, virtual pointer) | L1 | 2026-10-17: PASS twice in a row (runs `.dev/global-menus/run-20261017-133714`, `run-20261017-133805`); bridge RSS 19.4–19.5 MiB (shared Qt libraries included), CPU time 0 s |
| MB14 | `tests/integration/menu_bridge_memory.sh` (private bus, hostile fixture; cases B A C D E F: memory incl. RssAnon, oversized, kill on first fetch, kill on a re-read with new pids, forged state files, second instance) | L1 | see STATE.md |
| MB5 refusal, MB4 errors, MB3 cleanup | throwaway private bus, `open` naming the bridge's own name with a wrong pid → `pid-mismatch`; right pid → accepted; invalid lines → `bad-request`; SIGTERM removes the socket | L1 | 2026-10-17 verified manually (session log) |
| MB10 | bridge started with `GRASSFIELD_DEV=1` and the owner's bus address, no address, no session variables, no socket → exit 3 before connecting | L0 | 2026-10-17 verified |
| Unit hardening | `systemd-analyze --user verify packaging/systemd/grassfield-menu-bridge.service` | L0 | only finding: `/usr/bin/grassfield-menu-bridge` not installed; runtime under systemd NOT VERIFIED (owner L2) |

## Interfaces / contracts (versions)
- **menu/1** (socket, JSON lines; ADR-0008). shell → bridge: `{"type":"hello","v":"menu/1","appmenu":bool}`,
  `{"type":"open","window":"<hex>","service":"…","path":"…","pid":N}`, `{"type":"about-to-show","window":…,"id":N}`,
  `{"type":"activate","window":…,"id":N}`, `{"type":"close","window":…}`. bridge → shell:
  `{"type":"status","v":"menu/1","state":…,"registrar":bool}` (after connect and each hello),
  `{"type":"menu","window":…,"revision":N,"items":[…]}`, `{"type":"error","window":…|"","code":…,"message":…}` with
  codes `bad-request`, `busy`, `registrar-busy`, `no-owner`, `pid-mismatch`, `layout-failed`, `gone`,
  `unknown-item`, `oversized` (the application's layout exceeds the caps, also when found on a re-read) and `backoff`
  (the application is refused for now, see MB14). After `pid-mismatch`, `no-owner`, `gone`, `layout-failed`, `oversized`
  and `backoff` the window has no bridge menu: the shell clears its T1/T2 menus and shows T0 (log line only). Item: `{"id","type":"standard"|"separator","label","enabled","visible",
  "toggle-type":""|"checkmark"|"radio","toggle-state":-1|0|1,"shortcut":[[keys…]…],"icon-name","submenu",
  "children":[…]}`.
- **gfc/1 `appmenu`** gains the additive field `"pid":N` (0 for clears; consumers that ignore it are unaffected).
- **D-Bus**: `org.grassfield.MenuBridge1` (MB9), `com.canonical.AppMenu.Registrar` (MB1, MB2).
- **Test hook**: `qs ipc call menubar bridgeState <output>` → JSON (shown window, bridge state, left titles and the
  open bridge menu's rows in output coordinates).

## Dependencies (verified versions)
Qt 6.11.2 (QtCore, QtDBus, QtNetwork), gtest 1.18.0, CMake/Ninja or `bridges/menu-bridge/build-direct.sh`
(g++ + pkg-config + moc). Quickshell 0.3.1 `Quickshell.Io.Socket` + `SplitParser`. Hyprland 0.56.2 with
grassfield-compositor (feature `appmenu`). Verified clients: Qt 6.11.2 (`tests/fixtures/menu-demo`), Chromium
152.0.7977.82 (`--ozone-platform=wayland`); GTK4: Nautilus.

## Degraded behavior (plugin missing, service missing)
- Plugin absent or without `appmenu`: the shell says `hello` with `false`; the bridge stays in standby, no registrar
  is owned, Qt apps keep their in-window menu bars, the bar shows T0 (verified, phase B of the exit test).
- Bridge absent, crashed or restarting: the shell retries every 2 s, the bar shows T0; the registrar disappears with
  the bridge, so apps started meanwhile keep in-window menus. Apps that hid their menu bar earlier export it again as
  soon as the bridge is back (the shell re-sends `open`).
- Shell restart: the bridge releases the registrar on disconnect and takes it again on the new `hello`; the shell
  re-queries the plugin and the focused app's menus come back (verified in the exit test).
- A refused (`pid-mismatch`, `no-owner`, `backoff`), oversized (`oversized`) or unreadable (`layout-failed`) menu, or
  an app that leaves the bus (`gone`): that window shows T0, also when the refusal answers a re-read of a menu that
  was on screen (the shell clears it).

## Automated tests · Manual verification steps
`scripts/dev/test.sh` (QML + gtest), `tests/integration/global_menus.sh` (run outside the Claude Code sandbox; it
restarts this checkout's nested session). Manual: `scripts/dev/nested-up.sh --private-bus`, start an app with
`WAYLAND_DISPLAY=$(cat .dev/nested.wayland) DBUS_SESSION_BUS_ADDRESS=$(cat .dev/bus.address)`, click its titles with
`scripts/dev/pointer.sh`, read `.dev/menu-bridge.log`; `gdbus call --address "$(cat .dev/bus.address)" --dest
org.grassfield.MenuBridge1 --object-path /org/grassfield/MenuBridge1 --method org.grassfield.MenuBridge1.Status`.

## Performance (gates affected) · Accessibility · i18n
Event-driven: no timer runs while idle (one coalescing timer per menu signal burst). RSS measured by the exit test
(see its summary; ADR-0008 budget ≤ 20 MB; unit: `MemoryHigh=64M` throttles, `MemoryMax=256M` kills, see MB14). Menu titles are `BarButton`s with
`Accessible.name` "<title> menu"; items reuse `PopupMenu`/`MenuItem` roles. Application labels are shown as the
application localized them; Grassfield strings use `qsTr()`.

## Known limitations (honest, user-visible gaps vs macOS)
- X11/XWayland apps that call `RegisterWindow` (Qt or Electron under XWayland) are answered NotSupported but, with
  the registrar present at their start, Qt hides its in-window menu bar anyway: their menus are then shown nowhere.
  Grassfield's Qt apps run on Wayland; mapping X11 window ids to windows is future work.
- Sandboxed apps behind a D-Bus proxy (Flatpak) fail the pid check (`pid-mismatch`) and keep T0: a later rule is
  needed.
- Only first-level submenus get `AboutToShow` from the shell (deeper ones are shown as the layout has them).
- Shortcut text follows Grassfield's "Ctrl+N" style, not macOS glyphs; icons in application menus are not drawn.
- The registrar check of apps happens once at their start: apps started while the shell or bridge was down keep
  in-window menus until restarted (by design: nothing hidden).
- The T0 File menu is replaced by the app's menus; desktop entry actions stay reachable in the Dock menu only.
- `RuntimeDirectory=grassfield` and the hardening of the systemd unit are not runtime-verified (owner L2 session).
- A reply over ~60 MB can still take the bridge over `MemoryMax` once: the D-Bus daemon's `max_message_size` is 1 GB
  and libdbus holds the message several times. The restarted bridge refuses that application (MB14) and the shell shows T0
  meanwhile, but the one restart cannot be prevented from the bridge's side.
- Any process of the user's can kill the bridge (same uid), or write its state file: MB14 bounds what that achieves
  (refusing one executable for 15 min); it is not a security boundary against the user's own code.
- Applications sharing an executable (interpreters such as `python3`) are one identity for the refusals of MB14.
