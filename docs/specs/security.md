# Security modules spec (lock, polkit, idle) · security-engineer · M2

Design: ADR-0010. Rules: master-prompt R12, §5.9. Gates: §10 L1–L5.

## macOS reference behavior (described in words)
- Lock screen: blurred wallpaper, large clock and date at the top center, user avatar (circle) and name near
  the bottom center, a rounded password field with a return arrow; wrong password → the field shakes.
  "Cancel"/"Switch user" are not shown for a single user.
- Authorization dialog: a compact centered sheet with a lock icon, "<App> wants to make changes.", the
  user name field prefilled, password field, Cancel / Allow (default) buttons.

## Functional requirements
1. SEC1 Lock engages via IPC `lock lock`, idle timeout, lid close (`lock lid`, also when logind does not suspend;
   not in clamshell mode), and before sleep (logind delay inhibitor).
2. SEC2 Only PAM success (`omarchy-lock-password`) unlocks; errors/timeouts/crashes/graceful exits stay locked.
3. SEC3 Password cleared from the field and memory after each attempt; field disabled while authenticating.
4. SEC4 Lock surface on every monitor; input never reaches other clients (ext-session-lock).
5. SEC5 Lock screen shows clock, date, avatar (`~/.face` or AccountsService icon) and name — no notification
   content, no thumbnails.
6. SEC6 Polkit agent: exactly one; shows message, action ID and the requesting program as far as polkit tells it
   (see "Polkit details"); Cancel/Esc cancel; never auto-approve.
7. SEC7 Idle: dim → lock → displays off on the idle lock screen (DPMS); respects Wayland idle inhibitors.
8. SEC8 Fingerprint only if `/etc/pam.d/omarchy-lock-fingerprint` exists.
9. SEC9 Lock coverage never disappears silently: the shell restarts after any exit while the session runs, Omarchy's
   sleep-lock is skipped only while the shell runs, and a failing sleep inhibitor or watcher is reported to the user
   and retried for as long as the shell runs (GF-030, D-12).
10. SEC10 Dev and test switches (dev hooks, PAM suppression, no inhibitor) exist only in a dev session: one gate,
    `GRASSFIELD_DEV=1` and no `GRASSFIELD_SESSION=1` (SEC-03); IPC test hooks and private state are refused in a real
    session (SEC-04).
11. SEC11 Password-manager windows are hidden from screen sharing and screencopy as in the Omarchy session (SEC-01).

## Acceptance criteria (gates)
| Gate | Test | Level |
|---|---|---|
| L1 | lock in nested, `kill -9` the shell → nested stays locked (screenshot), restart shell → lock re-acquired; soft reload with the marker removed or forged → still locked; a foreign locker taking over and releasing the lock → locked again by Grassfield; a graceful exit while locked (SIGTERM, `qs kill`) → still locked (`graceful-exit`, DT-21); nothing typed reaches a window (`tests/security/reload_locked.sh`, bare, outside the sandbox; `just test-security-nested`) | L1, then L2† |
| L2 | `tests/security/l2_wrong_password.sh` (nested, real PAM through the opt-in `GRASSFIELD_DEV_ALLOW_PAM=1`, owner decision D-10): 3 random wrong passwords → each "Incorrect password", still locked (Hyprland `LOCK`), field empty, nothing reached the probe window. **Never more than 3 wrong attempts per run, never the right password, Return pressed at most 3 times**; a second run within 15 min is refused (faillock deny=10 shared with sudo) | L1 (owner runs it), then L2† |
| L3 | lock shown before sleep | L2† owner |
| L4 | `tests/security/lock_privacy.sh` (nested): notifications with a marker image and a window filled with the marker colour, then lock and try to open every surface over it → no marker pixel in captures of both outputs (positive control before locking); `screenshare`: a Bitwarden-class window is black in a capture (DT-05) | L1 |
| L5 | owner procedure "L5 polkit (owner, real session)" below: `pkcheck … --allow-user-interaction` (runs nothing as root) → dialog with message, action, icon; Esc/Cancel → exit 3; wrong password → "Incorrect password", no approval | L2† owner (a nested shell cannot register an agent) |

## Dev gate (GF-AUDIT-001 SEC-03)
One rule for every dev/test switch of the shell: `shell/services/DevGate.js` `allowed(GRASSFIELD_DEV, GRASSFIELD_SESSION)`
is true only for `GRASSFIELD_DEV` exactly `1` AND `GRASSFIELD_SESSION` not `1`. The packaged session config sets
`GRASSFIELD_SESSION=1` (`config/hypr/session.lua`); the nested dev session never does (`scripts/dev/devenv.sh` unsets an
inherited one). A `GRASSFIELD_DEV=1` that leaks into a real session (environment.d, a uwsm env file, an import into the
user manager) therefore changes nothing: no dev hook answers, PAM is not suppressed (the lock can be opened), the sleep
inhibitor is taken, and the lock logs once "GRASSFIELD_DEV=1 ignored in a real session". Users: `Lock.devHooks`
(`lock status|devReload|devPauseOwnershipCheck|devForgeUnlockedAnswer|devLockView`, PAM suppression), `Idle.devHooks`
(`idle status|devSleep|devDisplayOff`, the display power-off default), `SleepInhibitor.dev` (no inhibitor in dev),
`polkit status`, and, outside the security modules, `VisualFixtures.dev` (now `DevGate.allowed`), which every other IPC
test hook checks. Tests: `tests/security/tst_devgate.qml` (the predicate), `tests/security/dev_gate.sh` (the real Lock
singleton offscreen in five environments, including `GRASSFIELD_SESSION=1` with a leaked `GRASSFIELD_DEV=1`
and `GRASSFIELD_DEV_ALLOW_PAM=1`: every hook `refused`, PAM not suppressed; mutation: a gate on `GRASSFIELD_DEV` alone
fails it), `tests/security/ipc_inventory.sh` (no security module reads `GRASSFIELD_DEV` outside the gate).

## IPC surface (GF-AUDIT-001 SEC-04)
Quickshell's `IpcHandler` functions can be called by any process of the user (`qs ipc`, socket under
`$XDG_RUNTIME_DIR`; Flatpak sandboxes cannot reach it). Classes: **action** = called by Grassfield's own bindings,
gestures or screen corners (`config/hypr/grassfield/bindings.lua`, `shell/desktop/HotCornerActions.js`), available in a
real session, never returns private state; **dev** = test hook, refused outside a dev session (`DevGate`, directly or
through `VisualFixtures.dev`; void functions do nothing, others answer `refused`); **fixtures** = dev session AND
`GRASSFIELD_VISUAL_FIXTURES=1`. No function unlocks, runs a command, opens a URL, reads notification content or
approves polkit. `tests/security/ipc_inventory.sh` fails when a function is missing from this table or the table names
one that does not exist, when an action has no real-session caller or is gated, and when a dev or fixtures function
does not check its gate.

<!-- ipc-inventory:begin -->
| Target | Functions | Class | Caller, or why it is gated |
|---|---|---|---|
| lock | lock | action | SUPER+CTRL+Q, screen corner, Grassfield menu (in process). Only ever locks |
| lock | lid | action | lid switch: `config/hypr/grassfield/system.lua` → `/usr/lib/grassfield/grassfield-lid closed` (D-4). Only ever locks; `docked` in clamshell mode |
| lock | status, devReload, devPauseOwnershipCheck, devForgeUnlockedAnswer, devLockView | dev | `reload_locked.sh`, `l2_wrong_password.sh`; the pause widens the foreign-release window |
| idle | status, devSleep, devDisplayOff | dev | `reload_locked.sh`, `lock_privacy.sh` |
| polkit | status | dev | registration state (the journal has it in a real session) |
| search | toggle | action | SUPER+SPACE |
| search | open, close, query, status | dev | `status` returns what the user types; `query`/`open` inject a query |
| search | filter | fixtures | visual tests |
| apps | toggle, open, close | action | XF86LaunchA, screen corner, 4-finger pinch |
| apps | status | dev | returns the typed query |
| overview | toggle, open, close | action | CTRL+UP, screen corner, 3-finger swipe |
| overview | holdNextRelease, status | dev | `status` lists window titles and app ids |
| switcher | next, previous, release, quit, hide | action | SUPER+TAB, SUPER+SHIFT+TAB, SUPER release, SUPER+Q, SUPER+H while the switcher is up |
| switcher | right, left, cancel, status | dev | tests (arrows and Esc reach the switcher through its keyboard grab) |
| windows | minimize, tile, hide, cycleApp | action | SUPER+M, SUPER+CTRL+arrows/R, SUPER+H, SUPER+` |
| notifications | toggleCenter | action | SUPER+N, screen corner (in process) |
| notifications | dnd, status | dev | `dnd` would let another process silence notices (security notices too) |
| notifications | invoke, clearAll, dismissAll | fixtures | runs another app's action / removes history |
| menubar | open, panel | action | CTRL+F2, SUPER+ALT+ESCAPE |
| menubar | close, openKind, keyboardWait, statusState, autohide, bridgeState | dev | `bridgeState` returns the focused app's menu titles |
| widgets | status, addDesktop, clearDesktop | dev | `tests/visual/widgets-blur.sh`; `addDesktop`/`clearDesktop` change the saved placements |
| controlcenter | transparency, appearance, reduceTransparency, reduceMotion | dev | persisted settings changes |
| controlcenter | state | dev | `tests/visual/flow-quicksettings.sh`, `flow-settings.sh`: what the shell applies (appearance, transparency, DND, Night Shift availability); read-only |
| controlcenter | volume, brightness, volumeLevel, brightnessLevel | dev | `tests/shell/cc_sliders_ipc.sh` (REQ-QS-CC5/CC6); in a real session the acceptance uses the sliders themselves |
| dock | keyboard, toggleAutohide | action | CTRL+F3, SUPER+ALT+D |
| dock | hover, unhover, reveal, menu | dev | UI automation for tests |
| dock | pinned, dragstate, forceinterrupt, forcehold, holdmenu, popup, tiles, hidestate, screen, targetrect, autohide, size, position, sizenow, fitsize, magnify, click, centre, stack, addfolder | fixtures | visual tests; `click` launches an app; `addfolder` changes `dock.folders` |
| dockstack | state, depth, enter, back | fixtures | visual tests of the open folder stack (it lists a folder's file names) |
| osd | display, hide, layout, state | dev | OSD spoofing (`layout` feeds a keyboard layout event) |
| volume | up, down, mute | action | volume keys |
| brightness | up, down | action | brightness keys |
| keyboard | up, down | action | keyboard backlight keys (XF86KbdBrightnessUp/Down) |
| capabilities | status | dev | visual tests wait on it |
| bartone | status | dev | visual tests |
| wallpaper | loadDelay, fadeLength, progress, onlineClock, onlineStatus, videoIdle, videoBattery, videoStatus, set, status | dev | wallpaper tests (`set` also needs the fixtures to show) |
| visual | glyphs | dev | contrast run |
<!-- ipc-inventory:end -->

## Lock coverage: restart, Omarchy's sleep-lock, failing inhibitor (GF-030, D-12)
macOS model: the screen always locks before sleep, and the lock never silently goes away.
- `grassfield-shell.service`: `Restart=always` (was `on-failure`: systemd does not restart a unit that exits 0 or is
  stopped by SIGTERM/SIGINT/SIGHUP/SIGPIPE), `RestartSec=1`, start limit 10 starts in 30 s (a crash loop ends in
  `failed`). A stop through systemd is never restarted (systemd semantics): logout stops `graphical-session.target`,
  which stops the shell (`PartOf=`), and `Requisite=graphical-session.target` refuses a restart once the target is gone,
  so a real logout is not fought. `systemctl --user stop grassfield-shell` stays a deliberate stop.
- Omarchy's `omarchy-sleep-lock.service` (a logind delay inhibitor and a `PrepareForSleep` monitor; before sleep its
  `omarchy-system-sleep-lock` asks "the shell" to lock with `omarchy-shell lock lock` and polls `omarchy-shell lock
  status` until `secure`, within logind's window, else it reports "Screen did not lock before suspend"):
  - the drop-in `10-grassfield.conf` no longer disables it unconditionally (`ConditionEnvironment=!GRASSFIELD_SESSION=1`):
    its `ExecCondition=/usr/lib/grassfield/sleep-lock-gate` skips it in the Grassfield session only while
    grassfield-shell is up (`ActiveState=active` and `SubState=running`). `activating` is not enough (follow-up N1): it
    covers the auto-restart wait after a crash and the shell's start-up, when no Grassfield inhibitor exists. A unit
    skipped by `ExecCondition=` is not failed and not restarted (systemd.service(5)); Omarchy's unit exits after each
    sleep and is started again (`Restart=always`), so a running copy disarms itself after its next sleep once the shell
    is up.
  - When it runs: at session start it starts with `graphical-session.target`, usually before grassfield-shell, and keeps
    running until its first sleep; `OnFailure=omarchy-sleep-lock.service` starts it after EVERY crash of
    grassfield-shell, not only at the start limit (systemd 254+ `RestartMode=normal`, the default: the unit passes through
    `failed` before each restart; a clean exit, SIGTERM or `qs kill`, ends `inactive` and does not trigger it).
  - Logout (GF-081): `qs` exits 255 when the compositor goes away first, so every logout also fails the unit (255 stays a
    failure: it is also the exit code of a config error). The gate therefore skips only when the session's own compositor
    is certainly gone: its Wayland socket or its own Hyprland instance directory (never "some instance directory": stale
    ones accumulate) is absent with a searchable parent and a well-formed path. Anything undecidable (unreadable runtime
    directory, an over-long or odd name, a missing variable) arms the lock. The remaining race is on the safe side: if
    the compositor has not yet removed its socket, a logout arms the lock, which is harmless. The session target is not
    used: it still reads inactive when this unit starts at login. Test: `tests/security/sleep_lock_units.sh`.
  - It never talks to Omarchy's shell: in this session `/usr/lib/grassfield/omarchy-shims` is first in PATH, and its
    `omarchy-shell` stand-in answers `lock lock` by starting grassfield-shell again when it is not running
    (`reset-failed`, then a start) and asking it to lock (`qs ipc -p /usr/share/grassfield/shell call lock lock`: WlSessionLock +
    PamContext, no other locker), and `lock status` with `secure` = Hyprland lists `LOCK` on every monitor, `requested` =
    grassfield-shell's crash-recovery marker says `locked`. Every other call fails as Omarchy's wrapper does without its
    shell; nothing unlocks. Its clamshell step (`omarchy-hyprland-monitor-clamshell`, also called by Omarchy's wake
    script) reaches a second stand-in that runs `grassfield-lid reconcile`, so Omarchy's panel switching never fights
    Grassfield's (follow-up N4).
  - grassfield-shell never stops Omarchy's unit (it could be in the middle of a sleep it is delaying). Both running is
    harmless: Omarchy's script only asks grassfield-shell to lock and sees Hyprland's `LOCK`, without the 12 s delay or the
    false notice the drop-in was made for.
  - In the Omarchy session the gate always lets it run, exactly as Omarchy ships it.
  Checked by `tests/security/sleep_lock_units.sh` (the gate for every ActiveState/SubState, the unit and drop-in lines,
  both stand-ins against stubs, the package path) and `scripts/dev/omarchy-compat.sh` (Omarchy's script still uses the
  `lock lock` / `lock status` contract and calls the clamshell helper by name). Runtime NOT VERIFIED until the owner
  check below.
- The restart path re-locks after a sleep no shell locked for (follow-up N1; a crash or restart right before or during
  a sleep, when no inhibitor delayed it):
  - the crash-recovery marker records the kernel's count of completed suspends (`/sys/power/suspend_stats/success`,
    world-readable): `unlocked sleeps=<n>`. A starting shell that reads an `unlocked` line with another count than the
    current one locks (`LockMachine.sleptSince`, `restoreAtStart`; log "the machine slept while no shell could lock").
    A live shell locks before every sleep and rewrites the marker when it is unlocked, so a different count only means a
    sleep that happened without a shell. Unknown counts (an old line without a count, an unreadable sysfs file) prove
    nothing either way: no lock. Tests: `tst_lockmachine` `test_markerWithSleepCount`; `dev_gate.sh` starts the real Lock
    singleton offscreen on a marker with the previous count (locks), the current count and no count (both unlocked).
  - a shell whose `PrepareForSleep` watcher sees the resume (`false`) without having seen the matching `true` (it started,
    or its watcher came back, after the sleep began) locks at once (`SleepInhibitor.afterResume`, reason `resume`).
- The lid (`grassfield-lid closed`, follow-up N3): when `lock lid` gets no answer (shell down or starting) and no external
  display is connected, the `omarchy-shell` stand-in is run in the background (restart + lock), so a lid close with
  `HandleLidSwitch=ignore` or `lock` (no suspend, nothing else would lock) still locks; with an external display
  connected (clamshell) nothing is locked, as before. `tests/shell/lid.sh`.
- Known limit (owner): when grassfield-shell cannot start at all (a broken install), the fail-safe cannot lock either:
  Omarchy's script waits logind's window, reports that the screen did not lock (no notification server runs then: the
  journal has it) and the machine sleeps unlocked; a shell that starts later locks at once (the count rule above).
  A crash and a sleep within a few hundred ms (before Omarchy's unit holds its inhibitor) also sleep without a lock; the
  restarted shell then locks on resume, before any input. There is no second locker on purpose (security rules:
  WlSessionLock + PamContext in grassfield-shell only). Refusing sleep instead (a logind `block` inhibitor) was rejected:
  a closed laptop would then stay awake in a bag. A deliberate `systemctl --user stop grassfield-shell` is not a failure
  and does not start the fail-safe.
- Sleep inhibitor and `PrepareForSleep` watcher (`SleepInhibitor.qml`): never given up. An exit within 2 s of the start
  counts as a failure; after 5 in a row the module is "degraded": the user gets a notice in Notifications ("The screen
  may not lock before sleep", with the lock shortcut; Do Not Disturb silences its banner, the entry stays in the
  Notification Center), the journal says why, and the child is retried every 60 s instead of every 5 s. A run of 2 s
  resets the count and withdraws the notice. Pure logic in `IdleModel.js` (`failuresAfterExit`, `retryDelayMs`,
  `degraded`), unit-tested in `tst_idlemodel.qml`.
- Sleep delay budget: the release timer was 4 s, below logind windows of 15 s that Omarchy ships
  (`InhibitDelayMaxSec=15`, because a lid close that reconfigures displays can take longer to lock). It is now derived
  from logind's `InhibitDelayMaxUSec` (`busctl get-property`, read once at start): window minus a fifth (at least 1 s),
  capped at 12 s, 4 s when unreadable (port of Omarchy's `omarchy-system-sleep-lock` `derive_budget_ms`, MIT). The delay
  still ends at once on a confirmed lock.

Owner check (real session, L2-12 addition): `systemctl --user kill -s SIGTERM grassfield-shell.service; sleep 3;
systemctl --user is-active grassfield-shell.service` → `active`; `systemctl --user show -P ActiveState
omarchy-sleep-lock.service` → `inactive`; `systemd-inhibit --list | grep -c Grassfield` → `1`, and no `Omarchy` line.
Fail-safe (owner, L2†, from a TTY or a terminal you can leave): `systemctl --user stop grassfield-shell.service;
systemctl --user start omarchy-sleep-lock.service` (stands in for the start-limit failure), then `systemctl suspend`
and wake: the Grassfield lock screen is shown before any content, and `journalctl --user -u omarchy-sleep-lock -b`
has no "suspending without a secure lock" line.

## Graceful exit while locked (SEC-18 / GF-029, DT-21)
Read in the sources (Quickshell v0.3.1, `quickshell-mirror/quickshell@v0.3.1`; Hyprland v0.56.2,
`hyprwm/Hyprland@v0.56.2`):
- `qs kill` sends an IPC kill: `IpcKillCommand::exec` → `EngineGeneration::quit()` → `destroy()`: the root object is
  deleted, then the JS engine is interrupted (`setInterrupted(true)`) and deleted. The Lock singleton is owned by the
  engine (registered in `SingletonRegistry`, no parent), so it is destroyed with JS interrupted: no binding of
  `Lock.qml` can run and set `WlSessionLock.locked = false` during teardown.
- `WlSessionLock` has no destructor that unlocks; its `SessionLockManager` child deletes the `QSWaylandSessionLock`,
  whose destructor sends `ext_session_lock_v1.destroy`, NOT `unlock_and_destroy` ("This will intentionally lock the
  session if the lock is destroyed without calling unlock", `src/wayland/session_lock/lock.cpp`).
- Hyprland 0.56.2 handles `destroy` like a dead client: `CSessionLock` is destroyed, the manager drops its lock state
  (lock surfaces gone, the "lockscreen app died" screen), and `PROTO::sessionLock->m_locked` stays true: only
  `unlock_and_destroy` sets it false (`src/protocols/SessionLock.cpp`). The session stays locked.
- SIGTERM: Quickshell installs crash handlers for SIGSEGV/SIGABRT/SIGFPE/SIGILL/SIGBUS/SIGTRAP only
  (`src/crash/handler.cpp`); SIGTERM's default action ends the process at once, which Hyprland sees as a dead client.
- Either way the restarted shell (`Restart=always`) finds the marker `locked` and takes the lock back.
Expected: locked in both cases. NOT VERIFIED at runtime until the nested `graceful-exit` step of
`tests/security/reload_locked.sh` runs (bare, outside the sandbox): (a) `kill -TERM`, (b) `qs kill --pid`; after each,
Hyprland lists `LOCK` on every monitor and nothing typed reaches the probe window; then the restarted shell reports
`locked`. No code change was needed for this item; if the step ever shows an unlock, the shell must refuse IPC kill
while locked (not possible in Quickshell 0.3.1) or the unit must restart it before input arrives.

## Nothing opens over the lock (GF-116, DT-08, DT-12)
macOS model: while the screen is locked only the lock screen exists; Spotlight, Mission Control, Launchpad, Control
Center, Notification Center, menus and the Dock do not open, and nothing waits behind the lock to appear at the unlock
except an authorization request. Hyprland already keeps rendering and the keyboard on the ext-session-lock surfaces; the
shell no longer relies on that alone:
- One predicate, `SessionState.refuses(surface)` (`shell/services/SessionState.qml`): true while `SessionState.locked`
  (bound in `shell.qml` to `Lock.locked`, i.e. locking, locked or authenticating; unknown states count as locked), with one
  log line `grassfield: <surface> refused: the session is locked`. Each entry point asks it first: `Popups.open` (every
  popup kind: Control Center, menu-bar menus, tray, Dock menus and stacks, About, Force Quit, confirm and notice sheets;
  `toggle`, `openCentered`, `confirm` and `notice` go through `open`), `Search.show`, `AppsController.show`,
  `Overview.show` (also its own `locked`), `Notifications.toggleCenter` / `openWidgetGallery`, `Dock.enterKeyboardMode`,
  the desktop's context menu and attribution card (`IconsView.openMenu` / `openAbout`), the widget menu (an Overlay
  layer with the keyboard, `DesktopWidgets` `onMenuRequested`; review of 1d2c856), and the window commands of IPC target
  `windows` (minimize, tile, hide, cycleApp). The Switcher already refused
  (`Switcher.step`). Bindings, IPC calls, screen corners and gestures all end in these entry points, so all are refused.
- When the lock engages each open surface closes: Popups, Search (its query is dropped), Apps, the Notification Center,
  the Overview (through its keyboard release), the Switcher, Dock keyboard mode, the desktop menu and card (the desktop
  lets the keyboard go), the widget menu. `Lock.lock()` also closes popups first.
- Polkit: a request that arrives while locked waits (macOS shows the authorization sheet after the unlock): the sheet is
  neither mapped nor given the keyboard until `SessionState.locked` is false; text typed into an open sheet is dropped when
  the lock hides it. Nothing is answered meanwhile (polkit keeps the request pending; Cancel/Esc work once shown).
  A held request (it arrived, or was open, while locked, or arrived within 1 s after an unlock,
  `AuthDialogModel.heldAfterUnlockMs`, review of d8e654c) appears WITHOUT the keyboard (review of 1d2c856: keys typed right
  after the unlock, the end of the lock password or a Return, landed in its field): it says
  "This request arrived at <time>, while the screen was locked. Click the sheet to answer it.", its field is empty, and
  it takes the keyboard only after a click on the sheet that comes at least 500 ms (`AuthDialogModel.heldGuardMs`) after
  it appeared (the click goes on to what it hit: the field, Cancel, Allow). Both delays are timed by Timers in the model
  (`noteUnlock`, `noteShown`; a monotonic clock), never by `Date.now()` (review of 6e24d36: a wall-clock step would stretch
  or end a hold); a click before the sheet was ever noted as shown does not count. polkit gives no program name to the agent
  (only the message, which names the program for pkexec). Tests: `tst_authdialogmodel` `test_heldGuard`,
  `test_heldJustAfterUnlock` (real timers), `tst_authdialog` `test_11_heldNotice`, `tests/security/lock_surfaces.sh`
  (wiring, no `Date` in the hold functions, eight polkit mutations). Seen on screen: NOT VERIFIED (L5).
- Not refused, on purpose: the lock itself (`lock lock`, `lock lid`), volume/brightness keys and their OSD (macOS changes
  volume on the lock screen; the OSD is under the lock surface), notifications arriving (banners are under the lock surface;
  previews follow "Show previews").
- Plugin restore path (DT-12): `hl.plugin.grassfield.restore` still un-minimizes behind the lock and asks for a focus
  Hyprland refuses; the fix is a plugin work item, `docs/specs/compositor.md` "Work item GF-116".
- Fail mode: if the shell's `SessionState` wiring were missing, surfaces would open under the lock surface (Hyprland still
  shows only the lock and keeps the keyboard there); no path of this change can unlock or hide the lock.
Tests: `tests/security/lock_surfaces/shell.qml` (headless, the real Search, Apps, Notifications, Overview and Popups:
control open while unlocked, all close at the lock, 17 popup kinds and every entry point refused while locked, open again
after; mutants removing a refusal fail it), `tests/security/lock_surfaces.sh` (static: wiring, first-decision refusals,
close-on-lock, IPC routes, screen corners, the polkit sheet; mutation self-test). Nested (bare, outside the sandbox):
`tests/security/lock_privacy.sh` step `privacy` tries every surface over the lock and checks the captures (DT-08).

## Files never runs what it opens (GF-070, SEC-12, DT-10)
macOS model (Gatekeeper): double-clicking a downloaded app, script or launcher does not run it; macOS says it was not
opened, and only a deliberate "Open Anyway" in System Settings runs it. Grassfield Files decides itself, before KIO
(`KIO::OpenUrlJob::setRunExecutables(false)` documents executables but not every `.desktop` case; KIO's source is not on
the host): `apps/files/src/launchguard.{h,cpp}` `LaunchGuard::verdict(inspect(url))` for every item `FilesApp::open`
gets (Return, double-click, File > Open, the context menu), before the scripted-test switch:
- A desktop entry (named `*.desktop` / `*.kdelnk` / `.directory`, or of type `application/x-desktop`) is never handed to
  KIO, with or without the permission bit, wherever it is (review of a5646b8: KIO downloads a `Type=Link` target and runs
  the handler of the type the server announces, or the application in `X-KDE-LastOpenedWith`; the reviewer ran an
  attacker-chosen handler on a downloaded `.msi`). A web link (exactly one `Type=Link` and one http(s) `URL` with a host,
  like a `.webloc`) opens ITS ADDRESS in the user's default web browser (`x-scheme-handler/http(s)` preferred
  application, `ApplicationLauncherJob` with the URL), nothing else; with no default browser it is refused. Any other
  entry is refused, "app launcher": `Type=Application`, `Service`, a missing or unknown Type, an unreadable file, a link to
  a file or another scheme, and an ambiguous entry (a repeated `Type` or `URL`, also across repeated groups, or `URL` with
  `URL[$e]`: KConfig keeps the last value; or longer than the 64 KiB read).
- Refused, "program or script": an executable regular file whose type is a program or script (shared-mime-info:
  `application/x-executable` and its sub-classes, scripts included; `x-pie-executable`; `x-sharedlib`), or that starts
  with `#!` or the ELF magic; and, even without the permission bit, types whose handler runs them (by type and by name):
  Windows programs and scripts (`.exe`, `.com`, `.scr`, `.cpl`, `.msi`, `.lnk`, `.bat`, `.cmd`, `.ps1`, `.vbs`, `.vbe`,
  `.wsf`, `.hta`), registry files (`.reg`), Java archives and Web Start files (`.jar`, `.jnlp`), AppImages.
- Remote items (a share, sftp, the Trash): desktop entries and the names above are refused (KIO downloads a remote file
  and runs the handler of its type); everything else goes to KIO as before.
- Opened as before: folders, documents (also with the permission bit: every file of a FAT/NTFS volume has it), scripts
  without the permission bit (text, in their editor, as KIO and macOS do).
- The user sees one banner: "“t.desktop” was not opened: it is an app launcher, and Files never starts apps from a folder.
  Open apps from the Dock, Apps or Search." (programs: "… To run it on purpose, use a terminal."); the journal gets
  `grassfield-files: open refused (<kind>)`. No "Open Anyway" in Files, on purpose: Grassfield has no signed-app notion to
  base it on, apps start from the Dock, Apps and Search, and a program the user trusts runs from a terminal. "Open With"
  is unchanged: it opens the item WITH the chosen app (a launcher in a text editor), it never runs the item.
- The desktop already never runs `.desktop` files (`DesktopFiles.qml`, DT-11). The shell's `gio open` / `xdg-open` paths
  (Search results, Dock stacks) hand files to their MIME handler; not changed here.
Tests: `tests/unit/files/tst_launchguard.cpp` (verdicts; DT-10 on real files: `t.desktop` executable and not,
`Invoice.pdf.desktop`, web links to the browser only (the review's `.msi` link with `X-KDE-LastOpenedWith` included),
repeated keys, an oversized entry, `.directory`, file links, an unreadable entry, scripts with and without the bit, a
copied `/usr/bin/true` and a symlink to it, `.exe`, `.jar`, AppImage without +x, `.ps1`, `.vbs`, `.reg`, `.jnlp`, a
folder; remote items by name), nested `tests/apps/files_dt10.sh` (bare: pass 1 with the launch switch
on, four "open refused" and nothing reaching the launch path; pass 2 without it, the marker the launchers would create
never appears).

## Upstream base (GF-031)
Forks reviewed against Omarchy **v4.0.6** = `basecamp/omarchy@237f1b4071a0bff2296c6d740ba2b9fd695ebfa0` (installed
4.0.4 = `c668141e9c42b13c80c9ca4ea108e11708c5e8a5`, byte-identical to `/usr/share/omarchy/shell/plugins/lock/Service.qml`):
- v4.0.6 `currentlyLocked()` ("A property binding that missed a change notification once reported locked after an
  unlock, and a lock request before suspend then took that for done and never locked the session"): **ported** as
  `Lock.currentlyLocked()` / `Lock.currentlySecure()` (state machine storage via `LockController.currentState()`,
  `WlSessionLock.secure` read at the decision, the `verified` flag). Used by `lock()`, `restore()`, `checkStranded()` and
  the before-sleep release in `SleepInhibitor` (was the `Lock.secure` binding).
- v4.0.5 (`94a8fbc2d67eec5673c7f16b8c5e8a9c8452ffdc`) stranded-lock check skips the takeover while any other
  `quickshell|qs|hyprlock` process of the user runs (`omarchy-hyprland-session-lock-stranded "$PPID"`): **not ported**.
  Omarchy's problem is a shell that takes a live lock over and then strands it on exit; here a takeover only ever keeps
  the session locked, the ownership check re-locks after the foreign release (`foreign-restart`, ≤ 150 ms), and an exit
  is followed by a restart that restores from the marker. The process test would also block the recovery of a dead
  client's lock whenever another Quickshell instance of the user runs (the nested dev session always has one).
- Idle and polkit: v4.0.5/4.0.6 changes are `Commons.Color` renames (Qt 6.12) and screensaver handling Grassfield does
  not use; nothing to port.
- Pinned (GF-031 drift check): `docs/upstream/omarchy.lock` holds the sha256 of every upstream file a fork derives from
  (`plugins/lock/Service.qml` → `Lock.qml`, `plugins/services/idle/Service.qml` → `Idle.qml`,
  `plugins/polkit/PolkitAgent.qml` → `AuthAgent.qml`, `bin/omarchy-system-sleep-lock` → `IdleModel.js` budget and the
  `omarchy-shell` stand-in, `bin/omarchy-hyprland-session-locked` → the stranded-lock signal), the installed package
  (4.0.4-1) and the reviewed upstream revisions. `scripts/dev/upstream-drift.sh` (`just check-upstream`, part of
  `just check`) fails when the installed Omarchy changed or removed one of them, naming the forks to review; without
  Omarchy it says SKIP. It also fails, Omarchy or not, when a pinned fork is gone or no longer names its upstream file, and
  when a source file says "adapted from Omarchy" without being pinned, and on any read error (an unreadable fork or file of
  the scanned tree, a file that cannot be hashed). No environment variable changes what it checks (`just check` runs it
  bare); the fixture paths of its test are options (`--omarchy`, `--lock`, `--root`, `--package`; review of 395715e). After
  the review (port or reject, recorded in this section): `scripts/dev/upstream-drift.sh --update` re-pins. Test: `tests/security/upstream_drift.sh` (fixture trees:
  unchanged, edited, removed, no Omarchy, `--update`, malformed lock, lost attribution, unpinned fork; the real lock
  against the installed Omarchy).

## Screen-share protection (SEC-01 / GF-028)
`config/hypr/grassfield/privacy.lua`, required by `core.lua` (real and nested session): reads Omarchy's own
`default/hypr/apps/*.lua` in an empty Lua environment where `o.window` records only rules with `no_screen_share = true`
(with their match) and every other `o.*`/`hl.*` call does nothing; `os`, `io`, `require` and the rest are absent, so
nothing else of those files runs or applies. Each recorded match becomes `hl.window_rule({ name = "gf-no-screen-share-N",
match = …, no_screen_share = true })`. With Omarchy 4.0.4/4.0.6: 1Password, Bitwarden and the Bitwarden Chromium extension
window. A later Omarchy addition is picked up without a Grassfield change. The three built-in matches are always added
(duplicates dropped), so a rule file that stops early or disappears never leaves a password manager unprotected; when
nothing at all is read, Hyprland's log says so. Tests: `tests/security/screenshare_rules.sh` (at least one rule per
Omarchy `no_screen_share` rule; fixture tree with a new app, a table match, an `os.execute`/`io.open` file whose calls
never run; a `1password.lua` that stops before its rule still leaves 1Password protected; nothing readable;
wiring; mutation "keep every rule" fails it), `Hyprland --verify-config` in `just check` (a misspelt key fails it), and
nested `lock_privacy.sh screenshare` (DT-05: a window with app_id `Bitwarden` is black in a `grim` capture; NOT
VERIFIED until run).

## Lid, display power-off, screensaver inhibitors (D-4)
- Lid: one binding, `switch:on:Lid Switch` in `config/hypr/grassfield/system.lua` (real session only, `locked = true`) →
  `/usr/lib/grassfield/grassfield-lid closed`, which first sends `qs ipc -p /usr/share/grassfield/shell call lock lid` on every close
  (it decides nothing about locking; it only switches the laptop panel off and on for clamshell mode,
  `tests/shell/lid.sh`). `Lock.lockOnLid()` locks at
  once, whether or not logind suspends (`HandleLidSwitchExternalPower=ignore`, a docked lid, a failed suspend), except
  in clamshell mode: a physical external output is active (`LockMachine.lidShouldLock`: `DP-n`, `HDMI-X-n`, `DVI-X-n`,
  `VGA-n`, `TV-n`, `USB-n`; the built-in panel, headless and nested outputs do not count), as macOS and Omarchy's
  `omarchy-system-lid-close` do. When logind suspends, the lock is already on its way before `PrepareForSleep`.
  Hardware lid NOT VERIFIED (L2†; nested: `qs ipc call lock lid` locks, outputs WAYLAND-1 and GF-REF are not external).
- Display power-off: `Idle.qml` watches input while the lock is secured (`Lock.holding`: confirmed by the compositor,
  never while it is still being acquired; `IdleMonitor`, `respectInhibitors: false`) and after
  `IdleModel.DISPLAY_OFF_SECONDS` (30 s) without input switches the displays off through Hyprland
  (`hl.dsp.dpms({ action = "disable" })`); input or the unlock switches them on. `misc.key_press_enables_dpms` and
  `mouse_move_enables_dpms` (`looknfeel.lua`, Omarchy's values) let Hyprland itself wake the displays, so a shell that
  dies meanwhile cannot leave the screen dark. Off in the nested dev session unless `idle devDisplayOff <s>` sets it
  (`lock_privacy.sh display-off`). NOT VERIFIED on hardware (L2†).
- `org.freedesktop.ScreenSaver` inhibitors (GF-016 residual, done 2026-10-24; ADR-0008 and ADR-0010 amendments):
  Quickshell 0.3.1 cannot own a D-Bus name or serve methods (verified in its qmltypes: no D-Bus server type, only the
  DBusMenu client, the StatusNotifier, MPRIS and Notifications services and the Wayland `IdleInhibitor`), so the menu
  bridge serves `Inhibit`/`UnInhibit` (only those; `Lock`, `SetActive`… answer NotSupported), keeps cookies per sender
  (released by their owner or when it leaves the bus; 16 per sender, 64 senders) and sends the shell one boolean
  (`docs/specs/menu-bridge.md` MB16). `Idle.busInhibited` (from `MenuBridge.screenSaverInhibited`) then disarms the idle
  dim and idle lock only (`IdleModel.idleArmed`), as a macOS power assertion does while a video plays; a manual lock, the
  lid, the lock before sleep and the display power-off on the lock screen are unaffected. Fail closed: no bridge, a dead
  bridge, a hung bridge (the line is repeated every 20 s; 60 s without one drops "inhibited", `tests/shell/menubridge_heartbeat`),
  a client that left before the bridge watched it (watch, then `NameHasOwner`) or anything but an explicit `true` leaves
  idle locking on. Wayland-native players (mpv, Firefox, Chromium on
  Wayland) keep using the idle-inhibit protocol that `IdleMonitor { respectInhibitors: true }` honours (DT-16). Tests:
  `tests/unit/menu-bridge/tst_screensaver.cpp`, `tests/security/tst_idlemodel.qml` `test_idleArmed`,
  `tests/unit/tst_menubridge.qml` `test_screensaverLines`; `tests/integration/screensaver_inhibit.sh` (bare, private bus)
  NOT VERIFIED here (needs Unix sockets). Nested check (bare): with the nested session up, `gdbus call --address $(cat
  .dev/bus.address) …` cannot hold a cookie (it disconnects at once); use the integration test, then `qs ipc -p shell
  call idle status` shows `busInhibited`.

## Polkit details (SEC-07, D-4)
Quickshell 0.3.1 `AuthFlow` (`/usr/lib/qt6/qml/Quickshell/Services/Polkit/quickshell-service-polkit.qmltypes`) exposes
`message`, `iconName`, `actionId`, `cookie`, `identities`, `selectedIdentity`, `isResponseRequired`, `inputPrompt`,
`responseVisible`, `supplementaryMessage`, `supplementaryIsError`, `isCompleted`, `isSuccessful`, `isCancelled`,
`failed`, and no subject, process id, command line or `details`. The sheet shows everything that identifies the
request: the message (polkit's text; for `pkexec` it names the program and its arguments), "Action: <id>", the
identity, and now the action's `iconName` (from the root-installed `.policy` file) with the lock as a badge, macOS style.
That icon describes the action, not the program that asked: polkit does not tell the agent which process requested it
through this API (`AuthDialogModel.iconName`: plain theme names only; `AuthAgent` shows it only when the
theme has it; else the lock alone). Unit-tested (`tst_authdialogmodel` `test_iconNameIsAPlainThemeName`, `tst_authdialog`
`test_10_programIconWithLockBadge`); visual NOT verified (a nested shell cannot register an agent: L5).

## L5 polkit (owner, real session)
Never `pkexec` a real program for this test; `pkcheck` only asks polkit whether this terminal's shell may run the action
and runs nothing as root. In a terminal of the Grassfield session:
1. `journalctl --user -u grassfield-shell -b -o cat | grep -c 'authentication agent registered'` → `1`.
2. `pkcheck --action-id org.freedesktop.policykit.exec --process $$ --allow-user-interaction; echo "exit $?"`. The
   Grassfield sheet appears over a dimmed screen: the message, "Action: org.freedesktop.policykit.exec", "User: <you>",
   a password field and Cancel / Allow. Press Esc → the sheet closes, `exit 3` (dismissed), nothing approved.
3. Run step 2 again; type one wrong password, Return → the sheet shakes, "Incorrect password. Try again.", the field
   is empty, nothing approved; then Cancel → `exit 3`. (One wrong attempt counts once in faillock, shared with sudo.)
4. Optional, only if the owner wants the success path: step 2 with the right password → `exit 0`; polkit may then keep
   the authorization for this shell for a few minutes (`auth_admin_keep`): close that terminal afterwards.
5. Clicking outside the sheet never cancels or approves; `journalctl --user -u grassfield-shell -b -o cat | grep -i
   polkit` shows no password and no "approved" line.
PASS: 1–3 (and 5) as described. FAIL: any approval without the right password, a second agent, or the sheet missing.

## Lock survival (crash, reload) — fail closed
Found in R12 review: a Quickshell soft reload while locked unlocked the session when the marker was missing or not
exactly `locked`. Quickshell 0.3.1 `WlSessionLock::onReload` hands the previous instance's lock to the new
`WlSessionLock` and releases it (`realizeLockTarget` → `unlock()`) if the new `locked` is false at that moment; a
`sessionLock.locked` check in `Component.onCompleted` cannot see the handed-over lock (no manager yet).

A starting instance (session start, crash restart, soft reload) locks when ANY of these says so; only a PAM success
(`release()`) clears the carried intent and writes `unlocked`:
1. Carried intent: `PersistentProperties { reloadableId: "grassfield-lock-intent" }` (true while
   locking/locked/authenticating; the restored old value never downgrades a lock taken in `Component.onCompleted`:
   `intent = intent || controller.locked`) is declared before `WlSessionLock` in `Lock.qml`. Quickshell reloads a Singleton's
   children in declaration order (`ReloadPropagator::onReload`), so the old value is restored, and
   `WlSessionLock { locked: persist.intent || controller.locked }` re-evaluated, before `WlSessionLock::onReload`:
   the handed-over lock is kept, with no unlocked window (the new `WlSessionLock` has no Wayland lock object until its
   own reload). Verified offscreen by `tests/security/reload_order` (order, binding value, negative control,
   `Lock.qml` structure) and in nested by `reload_locked.sh` (marker removed / forged `unlocked` + reload → locked).
2. Marker, read in `Component.onCompleted` (runs before the reload pass): anything but an `unlocked` line (`unlocked`
   or `unlocked sleeps=<n>`) → lock, including an empty or unreadable marker (mode 000, a directory, I/O error) and a
   malformed line; an `unlocked sleeps=<n>` line whose count differs from the kernel's current count of completed
   suspends → lock too (the machine slept while no shell could lock, see "Lock coverage"). Only a missing file (FileView
   `FileNotFound`) counts as missing (`LockMachine.markerRead`; `tests/security/marker_read` uses the real FileView).
3. `XDG_RUNTIME_DIR` unset: no marker can prove the session unlocked → lock at start; the lock surface shows
   "Crash recovery unavailable: the lock state could not be saved." (also shown when a marker write fails; logged).
4. Stranded lock: until this instance first locks (at most 20 Hyprland monitor queries in 10 s, through
   Quickshell.Hyprland, no `hyprctl`), "LOCK" in any monitor's `solitaryBlockedBy` (the signal Omarchy's
   `omarchy-hyprland-session-locked` uses; Hyprland has no lock query) means a lock this instance did not take: a
   crashed instance whose marker was missing or forged, or a live foreign locker (Hyprland cannot tell them apart).
   It is taken over. Only ever locks. Verified in nested: forged `unlocked` + `kill -9` → restarted shell reports
   `locked` (before: `unlocked` behind Hyprland's "lockscreen app died" screen). A live foreign locker's later release
   is handled by "Lock ownership" below.

A fresh session (marker absent, no carried intent, compositor not locked) starts unlocked. A removed or forged marker
cannot expose a locked session: when a lock client dies, Hyprland keeps the session locked (ext-session-lock; no input
reaches clients, verified by L1) and rule 4 takes that lock over.

## Lock ownership and foreign lockers — fail closed
Found in the R12 re-review, verified in nested (Hyprland 0.56.2, `misc.allow_session_lock_restore = true`):
- Hyprland hands a LIVE session lock to the next client that asks, at once, and sends the previous holder nothing
  (no `finished`): both clients' `WlSessionLock` report `locked` and `secure`.
- When either client then releases its lock (`unlock_and_destroy`), Hyprland unlocks the session, although the other
  client still holds a lock object that reports `secure` and gets no event either.
- Hyprland emits no IPC event for session lock or unlock (socket2 during a foreign release: no event at all).

Before the fix, a shell whose lock was taken over (or that had taken over a live foreign lock) kept reporting `locked`
after the release while input reached windows; `lock lock` answered `already-locked`, idle/sleep locks were no-ops and
the sleep delay was released on the stale `secure`.

Behavior now (`Lock.qml`, `LockMachine.ownershipAction`):
1. While this shell holds a lock the compositor confirmed (`locked`/`authenticating`, `WlSessionLock.secure`), it asks
   Hyprland for the real session lock state (`ownershipProbe`: one `Hyprland.refreshMonitors()` request through
   Quickshell.Hyprland, no `hyprctl` process, never while unlocked or locking) once per second, and every 100 ms while
   a takeover is suspected (`LockMachine.takeoverSuspected`, R12 review #3): no lock surface of this shell has the
   keyboard (another client's lock surface took it, or a window did after an unlock under this lock), or the lock was
   requested by a restore at start (it may be a live foreign locker's lock taken over, whose release sends no event).
   The restore ("inherited lock") suspicion ends only with `relock()` (the foreign release happened) or `release()`;
   keyboard focus proves nothing: a foreign locker taken over at start sits UNDER this lock and its release unlocks
   the session while a Grassfield surface keeps the keyboard (R12 counter-review of 620f08c, which ended it on focus
   and brought back the ~1 s window; `foreign-restart` now asserts release → fresh lock ≤ 150 ms). So a
   crash-recovery lock keeps the 100 ms check for its whole life. Memory (`probe-memory`, 10 min each, nested): no leak,
   but each answer's JS garbage made a GC sawtooth (the 452 → 477 MB rise the review saw): before, RSS 434–464 MB,
   garbage 6.5 MB/min, post-collection floor +1.5 MB; after reading monitor maps lazily (`compositorLockStateLazy`:
   one map per answer while locked instead of all), RSS 428–452 MB, garbage 4.5 MB/min (finer sampling), floor
   −4.4 MB. The remaining per-answer cost is one `lastIpcObject` conversion, the only source of the lock state that
   Quickshell.Hyprland offers.
   Also at once when a lock surface loses keyboard focus, and on every monitor answer anyone requested. Suspicion only
   ever speeds the check up; it never unlocks. Cost of the 100 ms check (nested, `probe-cost`, three runs): +1.2 to
   +1.9 % CPU in the shell (0.8–1.0 → 2.0–2.7 %), Hyprland +0 to +0.6 % (0.3–0.4 → 0.3–0.9 %).
2. An answer reporting the session unlocked is confirmed by a second, fresh answer (answers in the first 500 ms after
   the lock was confirmed are ignored), then the shell takes a fresh lock: `lockLost()` (→ `locking`, PAM aborted,
   secret dropped), the stale lock object is released (the session is already unlocked) and a new lock is requested in
   the same event-loop turn. The carried intent and the marker stay `locked`. This `relock()` is not atomic (the release
   can reach Hyprland before the new request): its only caller is `checkOwnership()` on a confirmed answer
   (`tests/security/reload_order` checks it).
3. `lock()` while locked re-verifies (`verify()`) and answers `already-locked`; it never relocks on an earlier answer
   alone. Before R12 review #3 it relocked at once when one earlier answer said unlocked: on a stale answer the release
   unlocked a really locked session until the new lock arrived (forced baseline: keys reached a window in 12 of 12
   runs). A session found unlocked gets its fresh lock once the next answer confirms it (Quickshell has no synchronous
   Hyprland query; nested: within a few ms).
4. `Lock.secure` = holding AND (just acquired, or Hyprland reported the session locked since the last `verify()`).
   The sleep path calls `lock("sleep")`, which clears it until a fresh answer, so the sleep delay ends only on a
   confirmed lock, after the fresh lock when the session was found unlocked (`sleep-desync` step).
5. Policy for a live foreign locker (e.g. hyprlock): never adopted as Grassfield's own lock and never fought.
   - Present when the shell starts: taken over (rule 4, needed for a dead client's lock); when it releases, the
     session is re-locked by Grassfield.
   - Takes over a live Grassfield lock: left alone (coexist); the session is locked, so `lock status` stays `locked`.
     When it releases, Grassfield takes a fresh lock at once.
   - Only a Grassfield PAM success clears Grassfield's intent, so a user who unlocks a foreign locker then sees the
     Grassfield lock screen and authenticates again (fail closed).

Verified in nested by `tests/security/reload_locked.sh` steps `foreign-takeover`, `foreign-restart`, `lock-desync`
(the desync held on purpose with the dev hook `lock devPauseOwnershipCheck` as a positive control, then `lock lock`)
and `sleep-desync` (dev hook `idle devSleep`), with the fixture `tests/security/foreign_locker/ForeignLocker.qml`
(a Quickshell ext-session-lock client released over its IPC, which logs the epoch ms of its release). Forced races
(R12 review #3): `relock-confirm` (one stale "unlocked" answer forged by the dev hook `lock devForgeUnlockedAnswer`
while the session is locked, then `lock lock` while keys are typed every 4 ms: 12 runs, no relock, nothing reached the
probe window; the same step on the previous code relocked in 12 of 12 runs and keys reached the window in 12 of 12),
`foreign-gap` (foreign takeover then release while keys are typed: release → fresh lock request 9–101 ms over 15 runs
in three sessions, previously 250–1123 ms) and `probe-cost`. Keys typed after the fresh lock never reached the probe
window. The default step order runs the forced races right after `lock`: the crash steps restart the shell, which can
change the window Hyprland refocuses, and the in-window key count needs it to be the probe window.

File watching is disabled in `shell.qml` (`settings.watchFiles: false`, re-applied after every reload since
Quickshell resets it), so only an explicit `Quickshell.reload()` reloads the shell (none in production code; the dev
hook `lock devReload` needs a dev session, see "Dev gate"). Development restarts the shell with `scripts/dev/shell-run.sh`.

## Test safety: never submit to PAM in nested
A password submitted on the lock screen is checked against the owner's real account (`omarchy-lock-password`), and a
wrong one counts a `faillock` failure shared with sudo (deny=10 → a 120 s lockout). The nested lock tests must never
cause one. R12 review #3 found 22 real submits in the logs of this tree's nested shells (2026-10-18). Root cause
(counter-review): another worktree's test (`tests/shell/overview_two_outputs.sh`, typing a tag plus Return through the
old `keys.sh`, which trusted `.dev/nested.wayland`) typed into these lock sessions after the `wayland-2` socket name
was reused; main's `dev_nested_target` guard (verified nested target for keys/pointer/shot/ipc) closes that path.
Independent guards here:
- The shell suppresses PAM in dev (see "Dev PAM suppression"): without `GRASSFIELD_DEV_ALLOW_PAM=1`, a submit is
  swallowed and logged, never reaching PAM, and the lock shows "dev: password checks disabled".
- `tests/security/reload_locked.sh` types only through `type_letters <delay> <word>`, `bg_type <word>` (fixed,
  validated arguments: `[a-z0-9]` words, a numeric delay; no option passes through) and `press_key Escape`. It
  sources `tests/security/pam_audit.sh` (read-only; finds this tree's instances by the `Launching config` line of each
  Quickshell `log.log`, since `instance.lock` is not text and `.dev/shell.log` is overwritten on restart) and, against
  a baseline taken when the run starts, scans EVERY instance log of this tree for `authenticating (submit)` (a real PAM
  call) and `dev: PAM submit suppressed` before the run and after every step; on the first new one it stops the nested
  session (`nested-down.sh`) and exits 4, loudly. The `pam-audit` step reports the run's attempts (must be 0).
  `tests/security/pam_audit.sh` alone lists every instance with an attempt (run on the 2026-10-18 logs: 20 instances,
  22 submits).
Only wrong attempts are ever used for the L2 failure path, and only by the owner with `GRASSFIELD_DEV_ALLOW_PAM=1`
(at most 3 per run; faillock deny=10).

## Known limitations
- Successful-unlock tests need the owner's password: the agent only verifies failure paths (L2 owner check).
- L3 cannot be verified in nested.
- VERIFIED 2026-10-17 (nested): polkit agents register per logind session. The nested shell shares the owner's
  session, where omarchy-shell already owns the agent, so registration in nested fails with "An authentication
  agent already exists for the given subject" (confirmed). The module logs it once, shows no dialog and approves
  nothing. L5 functional checks move to L2 (owner); L1 covers the refusal path and unit tests of the dialog model.
- Nested runs must not take a real logind sleep inhibitor (it would delay the owner's real suspend): the
  inhibitor code path is disabled in a dev session (Dev gate) and verified in L2.
- Lock restore on Hyprland 0.56.2 (`misc.allow_session_lock_restore = true`, needed for crash recovery) does NOT wait
  for a live locker to exit: any client of the session can take a live lock over at once and, by releasing it, unlock
  the session (a Hyprland behavior no shell can prevent). Grassfield re-locks when the next ownership check sees the
  session unlocked: about 0.1 s later while a takeover is suspected (measured 9–101 ms from the release to the fresh
  lock request, `foreign-gap` and `foreign-restart`), up to ~1 s otherwise, during which the session is unlocked and
  `lock status` may still say `locked`. When Grassfield holds the lock, keyboard focus stays on its lock surface
  until something refocuses; when a foreign locker held it, Hyprland refocuses a window at once and keys typed within
  that ~0.1 s reach it (`foreign-gap`, keys forced with a 4 ms key delay: 3–18 bytes per run, previously 16–49 with the 1 s
  check; at human typing speed about one key). The fresh lock itself is not atomic when the stale lock object is the
  one Hyprland uses (release, then new request). Not done, on purpose: retaking the lock as soon as a foreign locker
  takes it over (it would fight the foreign locker, policy rule 5; its own release unlocks the session for an instant;
  the final relock still releases a lock Hyprland uses). Closing this window needs a compositor-side lock/unlock event
  (e.g. from `grassfield-compositor`) or `allow_session_lock_restore = false` (which breaks crash recovery):
  owner/compositor decision.
- A foreign locker that takes over a live Grassfield lock and then dies (no release) leaves the session locked behind
  Hyprland's "lockscreen app died" screen (fail closed); Grassfield's own lock object is no longer used, so the session
  can only be unlocked after the shell restarts (its crash recovery takes the dead lock over).

## Implementation (M2)
| Path | Role |
|---|---|
| `shell/security/LockMachine.js` | Pure state machine `next(state, event)` and helpers (marker, holding, lid decision, initials, Caps Lock inference, clock pattern) |
| `shell/services/DevGate.js` | The shell's one dev gate (`allowed(GRASSFIELD_DEV, GRASSFIELD_SESSION)`), see "Dev gate" |
| `shell/security/LockController.qml` | Auth controller over an injected PAM backend: one prompt answered, 30 s timeout, secret dropped on every outcome |
| `shell/security/PasswordField.qml` | Shared password entry (Password echo, sensitive-data hints, plain-text placeholder, return arrow) |
| `shell/security/lock/Lock.qml` | Singleton: `WlSessionLock`, `PamContext` (password; fingerprint only if its PAM file exists), crash marker, IPC `lock` |
| `shell/security/lock/LockView.qml` | Lock surface (display only): blurred `WallpaperArt` under a scrim, date and clock, avatar/initials, name, dark frosted field, one hint line (gate A2, see Decisions) |
| `shell/security/polkit/` | `AuthAgent` (PolkitAgent + overlay window, IPC `polkit status`), `AuthDialog`, `AuthDialogModel` |
| `shell/security/idle/` | `Idle` (IdleMonitor, dim layer, idle lock, display power-off on the lock screen, IPC `idle`), `SleepInhibitor` (delay inhibitor, PrepareForSleep watcher, retry and notice, logind budget), `IdleModel.js` |
| `config/hypr/grassfield/privacy.lua` | Omarchy's `no_screen_share` rules read from Omarchy's own files (SEC-01) |
| `packaging/systemd/sleep-lock-gate` | `ExecCondition` of Omarchy's sleep-lock unit (D-12), installed to `/usr/lib/grassfield/` |
| `tests/security/tst_devgate.qml`, `dev_gate.sh` | Dev gate: predicate; real Lock singleton offscreen in five environments |
| `tests/security/ipc_inventory.sh` | IPC surface = the table above; every action has a real-session caller, every hook its gate |
| `tests/security/screenshare_rules.sh` | SEC-01 rule set against Omarchy's, fixture tree, built-in matches always applied, wiring |
| `tests/security/sleep_lock_units.sh` | GF-030/D-12: gate script per state, unit and drop-in lines, package path |
| `tests/security/lock_privacy.sh` | Nested L4 (no notification or window content on the lock), DT-05 screen share, D-4 lid lock and display off |
| `tests/security/l2_wrong_password.sh` | Nested L2 with real PAM (opt-in), 3 random wrong passwords, Return ≤ 3, one run per 15 min |
| `tests/security/reload_order/` | Offscreen `qs` test of the Quickshell reload contract the lock relies on (run by `scripts/dev/test.sh`) |
| `tests/security/marker_read/` | Offscreen `qs` test: marker reads through the real FileView (missing, `unlocked`, empty, mode 000, directory) |
| `tests/security/foreign_locker/` | Nested fixture: a foreign ext-session-lock client (Quickshell), released over IPC `foreign unlock`; refuses to lock without `GRASSFIELD_FOREIGN_LOCKER=1` or on the owner's instance (`.dev/main.instance`) |
| `tests/security/reload_locked.sh` | Nested scenario: reload with marker missing/forged, `kill -9` (L1), forged marker + crash, graceful exit (SIGTERM, `qs kill`: DT-21), file watcher off, foreign locker takeover/restart (release → fresh lock ≤ 150 ms), `lock lock` and before-sleep during a desync, forced races `relock-confirm` and `foreign-gap`, `probe-cost`, `pam-audit`; `probe-memory` (10 min, explicit) |
| `tests/security/pam_audit.sh` | Read-only PAM attempt audit over every Quickshell instance log of this tree (sourced by `reload_locked.sh`) |

IPC (all on the shell instance; classes in "IPC surface"): `lock lock` → `ok` / `already-locked` / `refused: missing-pam`
(when already locked, the session lock is re-verified, see "Lock ownership"); `lock lid` → the same or `docked`. Dev
hooks, only in a dev session (else `refused`): `lock status` → `unlocked|locking|locked|authenticating`;
`lock devReload` → `reloading` (soft reload), `lock devPauseOwnershipCheck` → `paused` (periodic ownership check off
for 10 s), `lock devForgeUnlockedAnswer` → `forged` | `not-holding` (counts one "unlocked" answer Hyprland never gave,
as a stale answer would; only a confirmed relock can follow), `lock devLockView` → JSON {state, field: empty|filled,
message, failedAttempts, pamSuppressed} (never the text or its length), `idle devSleep before|after` → `ok`
(before-sleep / after-resume path without logind; no inhibitor in dev), `idle devDisplayOff <0..600>` → `ok`,
`idle status` → JSON, `polkit status` → `registered|unregistered`.

States: `unlocked -request-> locking -acquired(secure)-> locked -submit-> authenticating -success-> unlocked`;
`failure|error|timeout|abort` → `locked`; a lock dropped by the compositor, or a session found unlocked under a lock
still reported secure (foreign takeover + release) → `locking` (fresh lock, re-requested every 500 ms);
fingerprint success unlocks from `locked`. Unknown states/events never unlock (exhaustive test).

Decisions:
- Crash recovery marker: `$XDG_RUNTIME_DIR/grassfield-lock-<HYPRLAND_INSTANCE_SIGNATURE>` holds `locked`/`unlocked`,
  followed by ` sleeps=<n>` (the kernel's count of completed suspends) when it is readable
  (atomic, blocking write before the lock is requested, after unlock; re-read before and after each write, so a
  stale cache or a failed write is detected). See "Lock survival" for how a starting shell uses it.
- `PamContext.user` is left unset: PAM authenticates the uid running the shell, not `$USER`.
- Prompts are counted per `pamMessage` (one answer, a second prompt aborts): `responseRequired` stays true after
  `respond()` until PAM's next message (found in nested L2).
- Missing `/etc/pam.d/omarchy-lock-password`: new locks are refused (`refused: missing-pam`, logged); a lock being
  restored proceeds with a persistent "Authentication service unavailable" message (never fail open).
- Dev PAM suppression (defence in depth, R12 review #3 MAJOR): in a dev session (Dev gate) the lock never
  hands a password to PAM unless `GRASSFIELD_DEV_ALLOW_PAM=1` is also set (the opt-in for the L2 failure-path test).
  `Lock.qml` sets `LockController.pamSuppressed` from these at start; a suppressed `submit()` logs
  `grassfield-lock: dev: PAM submit suppressed`, clears the field and stays LOCKED (fail closed, never unlocks); the
  lock's notice line shows "dev: password checks disabled" so a dev value leaking into a real session is obvious. This
  stops a stray key that reaches the lock field in a nested test from counting a `faillock` failure against the
  owner's real account (faillock is shared with sudo). Real sessions (`GRASSFIELD_SESSION=1`, whatever
  `GRASSFIELD_DEV` says) are unchanged: `pamSuppressed` is false and authentication is normal. Unit-tested both ways (`tst_lockcontroller.qml`), structure
  checked by `tests/security/reload_order`.
- Lock before sleep: Quickshell 0.3.1 has no D-Bus/logind API, so `systemd-inhibit --what=sleep --mode=delay … cat`
  (stdin pipe: the inhibitor dies with the shell) plus `gdbus monitor` on `/org/freedesktop/login1` for
  `PrepareForSleep`. Both run under `setpriv --pdeathsig TERM --` (util-linux), so a shell crash (even SIGKILL) leaves
  no orphan (verified in nested: `kill -9` of the shell → its `gdbus monitor` child is gone). Released once
  `Lock.currentlySecure()` holds (a confirmed lock, re-verified with Hyprland when it was already held; see "Lock
  ownership"; read afresh, Omarchy 4.0.6 fix), or when logind's budget runs out (see "Lock coverage"); re-taken on
  resume. Skipped in a dev session (log `grassfield-idle: inhibitor skipped (dev)`). Lid close also locks by itself
  (`lock lid`, see D-4 above), before logind's `PrepareForSleep`.
- Idle: `IdleMonitor { respectInhibitors: true }`, dim at T−10 s, lock at T; Quickshell 0.3.1 keeps the timeout an
  `IdleMonitor` was enabled with, so the monitor is re-enabled on every timeout change (verified in nested).
- Lock screen contrast (gate A2, both appearances, any wallpaper): as on macOS, white text (dark palette, both appearances)
  with a soft shadow over the blurred wallpaper darkened by a shadow-colour scrim (`lock.dimOpacity` 0.6), and a dark frosted
  password field (shadow colour at `lock.fieldFillOpacity` 0.45, `textSecondary` placeholder, white focus ring at
  `lock.focusRingOpacity`). The scrim alone carries the contrast (the shadow is decoration). Minimum over 9 worst-case
  wallpaper colours (`tests/visual/test_contrast_tokens.py`, "lock ..." roles): text 5.27, initials 3.41 (large), placeholder
  8.59, dots and caret 10.75, return arrow 3.12 hovered, focus ring 3.51, selected dots 6.31 on the selection band, which is
  4.46 against the field; rendered at rest by `tests/visual/contrast.sh`
  (surface `lock`). Display only: no binding of the field's geometry, focus or input depends on these tokens or on an effect
  (the field has no layer); a missing colour, scrim or shadow token only loses that colour or the shadow. Checked in nested
  (2026-10-18) with the seven lock display tokens deleted from `Tokens.qml` in a throwaway copy of the tree (in `$TMPDIR`: a copy
  under the worktree's `.dev/` exceeds the 108-byte Unix socket path limit of `shell-run.sh`): the lock was acquired
  (`locking -> locked`), the scrim fell back to opaque black (opacity binding failed, default 1), the field fill, focus ring
  and avatar disc became transparent, the shadow used MultiEffect defaults, and the field showed its placeholder and blinking
  caret (focused). The palette is read through `Appearance.darkColors` (= `Tokens.colorDark`
  outside dev) so that the dev-only glyph mask of the contrast run recolours it, and in dev the backdrop draws the contrast run's
  wallpaper override (`VisualFixtures.wallpaperFile`, always empty outside dev).
- Password selection (R12 review #3, A2 residual): macOS shows a selection in a password field (the secure field allows
  selecting the bullets; only copy and cut are disabled), drawn in the accent/highlight colour like any text selection, so
  the selection stays visible. `PasswordField` draws it as every other field of the shell does: the accent behind
  `accentText` dots (the lock passes its dark palette's `accent`/`accentText`; the polkit field uses the same defaults).
  Before: white dots on the white focus-ring band, 1.7–2.1:1. Seen in nested (`.dev/shots/lock-selection.png`, letters typed
  and Ctrl+A, never submitted).
- Password fields (GF-118): the lock and the polkit sheet share `PasswordField.qml`; the Wi-Fi password field of Quick
  Settings (`WifiList.qml`) is the only other one. Each sets `inputMethodHints` `ImhSensitiveData | ImhNoPredictiveText |
  ImhNoAutoUppercase` (and `ImhHiddenText` while masked), as macOS secure fields do: an input method (fcitx5 autostarts
  on Omarchy) neither predicts, autocorrects nor learns the text. `tests/security/password_hints.sh` finds every QML
  field whose `echoMode` can be `TextInput.Password` and fails when its own block lacks the first two hints.
- Untrusted strings (PAM messages, polkit message/action ID/prompt/identities, user name) use `Text.PlainText`.
  Polkit strings are also flattened to one line by `AuthDialogModel.plainLine` (C0/C1 controls and line separators →
  space, bidi overrides/isolates/marks removed, length capped: message 400, others 200) and capped in rendered lines
  by `AuthDialog` (message 4, action ID and feedback 2, elided; at most 4 identity rows, more scroll), so the sheet has
  a bounded height and the real action line and Cancel/Allow always stay visible (unit test: 5000-character
  multi-line message).

`grassfield.json`: `lock.idleMinutes` (integer 0–240, default 5, 0 = never) is read through `Settings.lockIdleMinutes`
(clamped); invalid values fall back to 5 in `IdleModel.timings`.

Known gaps: polkit `details` (program, command line, process) are not exposed by Quickshell 0.3.1 `AuthFlow`; pkexec
puts the program in `message`, which is shown, and the action's icon is shown (see "Polkit details"). Caps Lock is
inferred from typed letters (no lock-key state in Quickshell). D-Bus `org.freedesktop.ScreenSaver` inhibitors are served
by the menu bridge and hold the idle lock only (see D-4); the GTK/KDE portal `Inhibit` reaches them only when its backend
forwards to that interface (not verified). Display power-off on the
lock screen is done (30 s), not yet seen on hardware (L2†). When grassfield-shell has failed for good, the fail-safe
restarts it before sleep; a shell that cannot start at all leaves the machine to sleep unlocked (no second locker, by
the security rules; see "Lock coverage").
The marker file of a dead compositor instance stays in `$XDG_RUNTIME_DIR` until logout (a few bytes).
Lock screen contrast: the lock's error, notice, Caps Lock, typed-dots, return-arrow and focus-ring states are proven by the
token calculation only (the contrast run's nested capture is at rest: nothing is typed into the nested lock there; the
selection was only looked at, in one nested capture). The date (22 px, weight 600) is treated as normal text (4.5:1), not
large text.
`Quickshell.reload(true)` (hard reload, never called by Grassfield) while locked makes Quickshell abort
(`qFatal`: the old instance still holds the lock): the compositor keeps the session locked and the restarted shell
re-acquires it (fail closed, not graceful). The stranded-lock check cannot tell a crashed instance's lock from a live
foreign locker (e.g. hyprlock) started before the shell: Hyprland hands the live lock over at once, and the foreign
locker's later release is followed by a fresh Grassfield lock (see "Lock ownership" and Known limitations).
