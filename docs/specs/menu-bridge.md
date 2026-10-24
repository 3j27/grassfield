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
  `{state: "standby"|"active"|"busy"|"degraded", registrar: b, degraded: b, shell: b, menus: u}`. Owning this name also makes the bridge a
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
- **MB14 Hostile applications, crash attribution and graceful degradation.** Perfect attribution is impossible at the
  D-Bus layer: libdbus buffers every incoming message (a 100 MB message peaks at ~225 MB RSS; a 30 MB reply at 115 MB)
  before any slot of the bridge runs, whoever sent it, and the bridge cannot see the sender of a message it died
  reading. So the rule is: correct where possible, never blame an innocent, degrade cleanly. Code:
  `bridges/menu-bridge/src/{Penalties,Bridge,MenuClient,DBusObjects}.*`.
  - Caps while reading (MB7); a layout over a cap is `oversized`: no menu, no further `GetLayout` to that application.
    After a reply the bridge calls `malloc_trim(0)` (RssAnon returns to about idle, measured).
  - **Identity** (what a refusal is keyed by; a pid is NEVER a key). After MB5's pid check the bridge reads the peer's
    systemd app scope from `/proc/<pid>/cgroup` (`app-<launcher>-<appid>-<instance>.scope` where the instance is
    `-<digits>` (flatpak, gnome, ...), `-<8 hex>` (uwsm: `app-Hyprland-gtk\x2dlaunch-2616d5ca.scope`) or `-<32 hex>`
    (KIO launches, e.g. from Grassfield Files: `app-<name>-<QUuid Id128>.scope`);
    `app-…@<instance>.service`: the instance is stripped; the key keeps systemd's `\x2d` escape, only logs show `-`), the resolved
    `/proc/<pid>/exe` (` (deleted)` stripped) and, for interpreters (python*, perl, ruby, node, bash/sh/dash/zsh, java),
    the script from `/proc/<pid>/cmdline` when it is the first argument (only `--` and java's `-jar` may precede it); ANY
    interpreter option before the script (`-c`/`-e` inline code, `-m`, options with separate or attached values) puts the
    peer in `unknown`, because an option's value taken for the script would hand out another application's identity:
    `id:scope=<scope>|exe=<path>|script=<script>`. Without an app
    scope the scope part is left out. An exe that cannot be read (non-dumpable process, another user's) puts the peer in
    ONE shared bucket `unknown`, which is refused only for 2 min per strike and never doubles, never permanently, so
    innocents behind it recover. Escapes that remain: a copy of the binary at another path, or a process outside the
    app's scope, is another identity (not preventable from the bridge): each copy is blamed once, and its crash
    counts toward the degradation budget like every other.
  - **In-flight marking.** EVERY call to an application (`GetLayout` incl. re-reads, `AboutToShow`, `Event`) is
    recorded in `<socket>.state` before it is sent, with its age (the file is refreshed every 250 ms while a call is
    open), and cleared once its reply was handled (or 4 s after the window was closed with the reply outstanding).
    The file also says whether the bridge is running (`run 1`; a clean stop writes `run 0`).
  - **Attribution rule.** A restarted bridge finding `run 1` (the previous run did not stop cleanly) blames an identity
    ONLY when exactly ONE call was in flight, to exactly one identity, and that call was FRESH (at most 1 s old at the
    last state write). The identity is refused 15 min, doubling per strike up to 6 h (`backoff` to the shell), so an
    application that kills the bridge with its own reply costs one restart. In every other case (nothing in flight,
    several calls, a call older than 1 s: unsolicited traffic, someone else's message) the crash is
    **unattributed**: it penalises nobody. EVERY crash, blamed or not, is counted (log line, `crash <time>` lines in
    the state file); attribution only adds the per-identity refusal on top.
  - **Graceful degradation.** Five crashes, blamed or not, within any sliding one-hour window (`penalty::kMaxCrashes`,
    `kCrashWindowSec`) make the next
    bridge run give up: it logs one line (`gave up: …`), never owns `com.canonical.AppMenu.Registrar` (applications
    keep their in-window menus), reports `state: "degraded"` / `degraded: true` over menu/1 and in `Status()`, and
    answers every `open` with `backoff` so the shell shows T0. No notification is sent. The process stays up (nothing
    for systemd to restart); crashes leave the window an hour after they happened, but a degraded bridge does not
    recover by itself: it stays degraded until the session restarts it.
    systemd's `RestartSteps`/`RestartMaxDelaySec` (1 s growing to 30 s) pace the restarts meanwhile.
  - **Reduced unsolicited surface.** On the registrar path only the four registrar methods get an answer (a tiny
    stateless error: X11 clients would otherwise wait for a timeout); every other call, interface or signal on the
    registrar and diagnostics objects is dropped without a reply (the bridge allocates nothing for it, but QtDBus has
    already read and buffered the whole message before the drop). Per-menu signal subscriptions
    (`LayoutUpdated`, `ItemsPropertiesUpdated`) are sender-specific match rules (verified unique name + object path),
    and `NameOwnerChanged` is watched per name. A peer with no registered window has no subscription and no object that
    does anything.
  - **Refusals and bounds.** `layout-failed` on open: 2^n s up to 64 s. Entries decay: no strike for 24 h drops an entry;
    a clean exit does not reset the doubling inside that window. Idle (not refused) identities: at most 128, least
    recently used first out; refused identities are capped separately (64): idle churn never evicts a refusal, but past
    64 the one closest to expiry goes (`capRefused`), so a flood of cheap identities can push out old refusals.
  - **State file.** `<socket>.state` (socket directory 0700, file 0600). Written with `openat(O_CREAT|O_EXCL|O_NOFOLLOW)`
    of a temp name in the directory then `renameat` (atomic; replaces a symlink at the final name without following it;
    there is no check-then-write window). Read with `O_NOFOLLOW`, regular file of this user, at most 128 KiB, header
    and boot id checked, every line validated, one invalid line discards the whole file. Read only after the singleton
    probe. **Same user only**: code running as the user can write the directory, kill the bridge, or pass MB5 for its own
    processes.
  - **Guarantees.** (1) A crash is never blamed on an application unless it was the only one with a fresh call open.
    (2) A refusal never outlives 6 h and never covers the `unknown` bucket longer than 2 min. (3) An unexplained crash
    loop ends with a quiet, working desktop (T0 menus), not an endless restart. (4) A forged state file by the same
    user can refuse at most 64 identities, with at most 64 strikes (6 h each), and hold at most 64 crash times
    (it can force the degraded mode): it can switch menus off, nothing more; it cannot make the bridge write or execute anything.
  - **Non-guarantees.** A same-uid process can always OOM or kill the bridge (as it can kill any process of the user),
    and the bridge cannot be made immune to a huge message: buffering happens inside libdbus before the bridge sees it.
    An application whose single call is fresh when an unrelated 100 MB message arrives within that first second is
    blamed wrongly once (refused 15 min, T0 menus only), and the wrongful blame can repeat, doubling each time. A
    hostile application that delays its huge reply past 1 s escapes attribution (the crash is counted
    as unattributed instead and, repeated, degrades the bridge).
  - **Residual risks (accepted, 2026-10-18).** The failure is bounded (T0 menus); this is defense in depth against
    same-uid apps, not a boundary.
    - Same-uid apps can kill or OOM the bridge, or force degraded mode for the session.
    - An honest slow app can be wrongly blamed when an attacker's huge message lands during its call.
    - Degraded mode does not recover until the session restarts.
    - Flatpak apps with registrar access can send big messages (not verified).
- **MB13 Development.** `scripts/dev/nested-up.sh --private-bus` → `shell-run.sh` starts one private `dbus-daemon`
  (session configuration, socket in /tmp) per nested session, reused across shell restarts, and (re)starts the
  bridge on it before the shell and any test app (`.dev/run/menu-bridge.sock`, `.dev/menu-bridge.log`,
  `--menu-bridge PATH`). Without `--private-bus` no bridge runs. `nested-down.sh` stops the bridge, then the bus.
- **MB15 LauncherEntry** (ADR-0018; badges, progress and urgent set by applications, macOS `NSDockTile`). While it runs,
  the bridge subscribes to `type='signal',interface='com.canonical.Unity.LauncherEntry',member='Update'` on its bus
  (`Update(s app_uri, a{sv} properties)`; the private bus in development, so no owner application is ever read) and
  forwards each accepted update to the shell as the additive `launcher` line of menu/1. Logic: `src/Launcher.{h,cpp}`
  (pure, gtest), D-Bus side: `src/LauncherWatcher.{h,cpp}`. Every client may emit the signal: nothing is trusted.
    - `app_uri` is `application://` + an id of 1 to 255 bytes of `[A-Za-z0-9._-]` + `.desktop`; the id (without the
      suffix) is the `app` of the line. Anything else is malformed. A signal whose signature is not `sa{sv}` is malformed.
    - `count` (type `x`) is clamped to 0..99999, `progress` (type `d`) must be finite and is clamped to 0..1,
      `count-visible`, `progress-visible` and `urgent` are booleans (`b`). A property of another type is dropped (the rest of
      the update goes on) and counts as malformed; unknown properties (`quicklist`) are ignored; a map of more than 32
      entries is not read. `count-visible:false` is forwarded as `count:0`, `progress-visible:false` as `progress:-1`;
      `count-visible:true` alone brings back the count the application sent before.
    - At most 64 apps and 64 senders are tracked. At most 20 updates per second per sender go out at once: the excess is
      coalesced (the last properties per app win) and sent as soon as the sender's budget allows (a 50 ms timer runs only
      while something is pending). A sender that leaves the bus (`NameOwnerChanged`, or no process for its name) clears its
      apps: a `launcher` line with `count`, `progress` and `urgent` all `null` ("forget"), and its pending state is dropped.
      The sender that updated an app last owns it (spoofing between applications on one bus is possible as in KDE and
      cosmetic: a number or a bar on a tile; accepted risk, no pid matching).
    - Malformed input is a penalty for the sender, through `Penalties`: its application identity (pid of its unique
      name, `appIdentity`) gets a `LayoutFailed` strike (refused 2 s, doubling to 64 s), logged as `malformed
      LauncherEntry update from "<identity>"`. A refused identity's signals are dropped. The strike is shared with that
      application's menu (same identity), so a sender that spams garbage also waits before its menu is served again.
    - The current state of every app is replayed to a shell that connects later (a restarted shell keeps the badges).
    - The line: `{"type":"launcher","app":"<id>","count":N|null,"progress":P|null,"urgent":true|false|null}` (`null`: the
      update did not touch the value). Old shells ignore unknown types; the protocol stays `menu/1`.
    - Shell side (`MenuBridge.js` `parseBridgeLine` / `applyLauncher`, `MenuBridge.qml` `launcher`, `launcherUpdate`): the
      line is validated again (app charset and length, count 0..99999, progress -1..1, urgent boolean), the latest state
      per lower-case app id is kept (at most 64), and cleared when the bridge disconnects. The Dock uses it
      (docs/specs/dock.md requirements 14 and 21).
- **MB16 ScreenSaver inhibitors** (GF-016 residual; ADR-0008 and ADR-0010 amendments 2026-10-24; macOS power assertions:
  a playing video keeps the screen awake). While it runs, the bridge owns `org.freedesktop.ScreenSaver` when nobody else
  does (never replaced, never queued; logged when taken) and serves, on `/org/freedesktop/ScreenSaver` and `/ScreenSaver`,
  `Inhibit(s application, s reason) -> u cookie` and `UnInhibit(u cookie)` only (`src/ScreenSaver.h`):
    - cookies are kept per sender (unique bus name): at most 16 per sender and 64 senders (`LimitsExceeded` past it);
      a cookie is released only by the sender that took it (another sender's or an unknown cookie is answered and
      changes nothing); every cookie of a sender is dropped when it leaves the bus (`QDBusServiceWatcher`). A new holder
      is watched first and then checked with `NameHasOwner` (the bus handles the AddMatch before the question): a sender
      that left before its watch existed is dropped by the answer, and no answer within 2 s also drops it (review of
      4b8592d: 11 of 60 clients that sent Inhibit and exited at once kept their cookies for the session);
    - every other member (`Lock`, `SetActive`, `GetActive`, `SimulateUserActivity`, …) answers `NotSupported`, a wrong
      signature `InvalidArgs`; other interfaces on the paths are dropped, as on the registrar;
    - the shell gets `{"type":"screensaver","inhibited":bool,"count":N}` on every change and when it connects; the log
      names the applications (printable, 64 characters at most) on each change, never the reasons;
    - shell side: `MenuBridge.js` validates it (boolean, integer 0..1024), `MenuBridge.screenSaverInhibited` follows it
      and is false while no bridge is connected; `shell.qml` feeds `Idle.busInhibited`, which disarms only the idle dim
      and idle lock (`IdleModel.idleArmed`). A manual lock, the lid, the lock before sleep and the display power-off on the
      lock screen ignore it.

## Acceptance criteria (each mapped to a test or scenario; level L0/L1/L2)
| Req | Test | Level | Status |
|---|---|---|---|
| MB4, MB7, MB10 (logic), MB9 XML | `tests/unit/menu-bridge/tst_menubridge.cpp` (gtest, 35 cases incl. identity, penalties, state file, call marking; the wire and MenuClient cases run over a peer-to-peer D-Bus connection and skip where Unix sockets are forbidden) | L0 | see STATE.md (run outside the sandbox) |
| MB11, MB12 (models) | `tests/unit/tst_menubridge.qml` (event parsing, menu/1 lines, sanitizing, caps, popup model, shortcut text) | L0 | 2026-10-17: 8/8 PASS |
| gfc/1 `pid` | `compositor/tests` `Protocol.AppmenuJson*`, `AppmenuRegistry.PidTravels…` | L0 | 2026-10-17: 92/92 PASS |
| M3 exit (MB1, MB5, MB6, MB11, MB12, MB13) | `tests/integration/global_menus.sh` (nested, private bus, virtual pointer) | L1 | 2026-10-17: PASS twice in a row (runs `.dev/global-menus/run-20261017-133714`, `run-20261017-133805`); bridge RSS 19.4–19.5 MiB (shared Qt libraries included), CPU time 0 s |
| MB14 | `tests/integration/menu_bridge_memory.sh` (private bus, hostile fixture; cases B A C D E F G H I J: memory incl. RssAnon, oversized, kill on first fetch, kill on a re-read with new pids, forged state files, second instance, unsolicited 100 MB message until the bridge gives up, huge LayoutUpdated, slow victim plus attacker, 7 rotating copies ending degraded; the memory limit is emulated by a watcher) | L1 | see STATE.md |
| MB15 (logic) | `tests/unit/menu-bridge/tst_menubridge.cpp` `LauncherUri`, `LauncherParse`, `LauncherBook`, `LauncherProtocol` (17 cases: uri and id charset, count clamp, finite progress, wrong types, 64 apps and senders, 20 per second and coalescing, sender gone, replay, message shape), plain and ASan/UBSan builds (`scripts/dev/test.sh`); shell parser and state: `tests/unit/tst_menubridge.qml` `test_launcher*` | L0 | 2026-10-22: 64 passed, 4 skipped (no Unix sockets in the sandbox), plain and ASan |
| MB15 (D-Bus) | `tests/integration/launcher_entry.sh` (bare; private bus, bridge, socket tap as the shell, `tests/fixtures/launcher-entry.py` as applications): count and clamp, count-visible, progress and clamp, progress-visible, urgent, flood (21 lines for 300 updates, last state arrives), sender disconnect, replay to a new shell, invalid uri and wrong signature (penalty logged, sender refused then served again). Fails on the bridge before ADR-0018 | L1 | 2026-10-22: PASS (and every behaviour check FAILs against the previous bridge) |
| MB16 (logic) | `tests/unit/menu-bridge/tst_screensaver.cpp` (cookies distinct and non-zero, owner-only release, sender gone, limits, clean names, only two methods served, `SetActive` refused, wrong signatures, the line and its clamp, introspection); shell: `tests/unit/tst_menubridge.qml` `test_screensaverLines`, `tests/security/tst_idlemodel.qml` `test_idleArmed` | L0 | 2026-10-24: see the security report |
| MB16 (D-Bus) | `tests/integration/screensaver_inhibit.sh` (bare; private bus, bridge, socket tap, `tests/fixtures/screensaver-client.py`): name owned, first state, Inhibit on both paths, other/unknown cookies, owner release, sender leaving, NotSupported members, 16-cookie limit, replay to a new shell, bridge exit | L1 | NOT VERIFIED (needs Unix sockets: bare, outside the sandbox) |
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
- **menu/1 `launcher`** (bridge → shell, additive, MB15): `{"type":"launcher","app":"<desktop id>","count":N|null,
  "progress":P|null,"urgent":bool|null}`; `count` 0 hides the badge, `progress` -1 hides the bar, all three `null`
  forgets the app. Input: the `com.canonical.Unity.LauncherEntry` `Update(s, a{sv})` signal on the bridge's bus.
- **menu/1 `screensaver`** (bridge → shell, additive, MB16): `{"type":"screensaver","inhibited":bool,"count":N}`.
- **gfc/1 `appmenu`** gains the additive field `"pid":N` (0 for clears; consumers that ignore it are unaffected).
- **D-Bus**: `org.grassfield.MenuBridge1` (MB9; `Status` also reports `screensaver` (name owned) and `inhibitors`),
  `com.canonical.AppMenu.Registrar` (MB1, MB2), `org.freedesktop.ScreenSaver` (MB16).
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
- Bridge gave up (MB14: five crashes in an hour, blamed or not): state `degraded`, no registrar, every `open` answered
  `backoff`, T0 menus; one log line, no notification; it serves menus again when started after the hour has passed.
- Bridge absent, crashed or restarting: the shell retries every 2 s, the bar shows T0; the registrar disappears with
  the bridge, so apps started meanwhile keep in-window menus. Apps that hid their menu bar earlier export it again as
  soon as the bridge is back (the shell re-sends `open`).
- Without the bridge (not built, crashed, standby): no application badge, progress or urgent hint; the Dock keeps its
  notification-derived badges. The shell clears the launcher state when the bridge disconnects and gets it back when it
  connects.
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
- A reply or any message over ~60-100 MB can still take the bridge over `MemoryMax` (the D-Bus daemon's
  `max_message_size` is 1 GB and libdbus buffers the message, ~2.2x its size at the peak, before the bridge sees it).
  That cannot be prevented from the bridge's side, and the sender cannot be known: MB14 blames an application only for
  a single fresh call; every crash, blamed or not, counts (the bridge gives up after five in an hour). A same-uid process
  can always OOM or kill the bridge; the state file is not a security boundary against the user's own code.
- A hostile application that answers its huge reply after more than 1 s escapes attribution (counted as
  unattributed). One running from copies of its binary is blamed and counted, copy by copy, and degrades the bridge.
  An innocent whose single fresh call coincides with someone else's huge message is refused for 15 min (T0 menus); the
  wrongful blame can repeat, doubling each time. See the residual risks in MB14.
- Peers whose executable cannot be read share one `unknown` identity (refused 2 min at most).
- LauncherEntry (MB15): an application can set another application's badge (spoofing on a shared bus, cosmetic);
  `count` must be an int64 (`x`) and `progress` a double (`d`) as in the Unity specification, an application sending
  `int32` counts is dropped as malformed; the `quicklist` property is not supported; the urgent hint bounces only an
  app that already has a window; an application sending a huge a{sv} is read in full by QtDBus before the 32-entry cap
  (the MB14 message-size limit applies).
