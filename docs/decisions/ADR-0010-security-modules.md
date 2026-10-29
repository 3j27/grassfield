# ADR-0010: Security modules design (lock, polkit, idle)
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed); the separate security process of the amendment of 2026-10-24 (GF-050) is decided by the owner on 2026-10-29 (ADR-0041 SQ-1 B), its plan carried by ADR-0041 step 1 (amendment of 2026-10-29 below) · Date: 2026-10-17 · Decider: owner · Requires opus reviewer PASS per change (R12)

## Context
D2: grassfield-shell replaces omarchy-shell in the Grassfield session, including lock, polkit agent and
idle. R12 restricts building blocks to Quickshell `WlSessionLock`, `Pam`, `Polkit` and the existing PAM
service `omarchy-lock-password` (verified 2026-10-17: `pam_faillock deny=10 unlock_time=120` → `pam_unix`).
Reference implementations (MIT): `/usr/share/omarchy/shell/plugins/lock/Service.qml` (551 lines),
`plugins/polkit/PolkitAgent.qml` (392), `plugins/services/idle/Service.qml` (361).
Hyprland config sets `misc.allow_session_lock_restore = true` so a restarted shell can re-take a lock
whose client died (Omarchy relies on the same failsafe).

## Decision
**Lock** (`shell/security/lock/`)
- `WlSessionLock` + `PamContext { config: "omarchy-lock-password" }`; fingerprint `PamContext` only if
  `/etc/pam.d/omarchy-lock-fingerprint` exists.
- State machine: `unlocked → locking → locked → authenticating → locked|unlocked`. Only a PAM `success`
  result unlocks. Every error, timeout, crash or missing PAM service keeps or returns to `locked`.
- If the PAM service is missing, refuse to start a lock *only* when it would be unrecoverable: show a
  persistent error; never unlock to "fail open".
- Password lives only in the TextInput and the PAM response; cleared after each attempt and on lock.
- Lock surface shows clock, user avatar/name, password field; no notification content, no window thumbnails (L4).
- Engage from: idle timeout, `SUPER+CTRL+Q`, lid close and before sleep through a logind **delay** inhibitor
  (`org.freedesktop.login1.Manager.Inhibit("sleep", …, "delay")`), released after the lock surface is shown.
- Crash recovery: Hyprland keeps the session locked when the lock client dies (ext-session-lock); the
  systemd/uwsm restart of the shell re-acquires it (`allow_session_lock_restore`). Gate L1.

**Polkit** (`shell/security/polkit/`)
- `Quickshell.Services.Polkit` agent, registered once per session (refuse if another agent owns the session).
- Dialog shows action ID, message, program/command line details provided by polkit, identity selector.
- Never auto-approve; cancel and Escape cancel the request; the password field is cleared on every outcome.

**Idle** (`shell/security/idle/`)
- Quickshell idle notify: dim at T-10 s, lock at T (default 5 min), display off at T+60 s; respects
  `idle-inhibit` from apps (Quickshell IdleInhibitor/compositor protocol) and media playback inhibitors.

**Process**
- Each change: security tests L1–L5 in nested (§10), opus `reviewer` PASS, † items NOT VERIFIED until L2.
- Code adapted from Omarchy keeps the MIT attribution header.

## Consequences
- No PAM files, no setuid, no root services (R12).
- L3 (lock before suspend) can only be verified by the owner in L2.

## Amendment 2026-10-24 (GF-AUDIT-001 wave 3: GF-016, GF-116, GF-050)
**Idle inhibitors over D-Bus (GF-016 residual).** The idle module gains one input: `Idle.busInhibited`, fed in
`shell.qml` from `MenuBridge.screenSaverInhibited`, i.e. the menu bridge's report that applications hold
`org.freedesktop.ScreenSaver` cookies (ADR-0008 amendment of the same date). While it is true the idle monitor is not
armed (`IdleModel.idleArmed`): no dim, no idle lock. Nothing else reads it: `lock lock`, the lid, the lock before sleep, the
display power-off on the lock screen and every unlock path are unchanged, and it cannot unlock or hide anything. It fails
closed: anything but `true` counts as not inhibited, and the shell sets it false whenever no bridge is connected (a bridge
that dies or never starts leaves idle locking on). Accepted risk: a process of the user can keep the idle lock from firing
while it holds a cookie; it could already do so with the Wayland idle-inhibit protocol, and macOS power assertions behave
the same. The building blocks stay WlSessionLock + PamContext + Quickshell Polkit + Quickshell idle; the D-Bus service is
outside the security modules (the bridge), which only report one boolean.

**Nothing opens over the lock (GF-116).** Every shell surface refuses to open while `SessionState.locked` and closes when
it becomes true; the polkit sheet is held (not mapped, no keyboard) until the unlock and drops text typed before the lock
(docs/specs/security.md "Nothing opens over the lock"). The plugin's restore path is a compositor work item
(docs/specs/compositor.md "Work item GF-116").

**Separate security process (GF-050): analysed, not done in this slice; adopted as the direction, plan below.**
macOS keeps loginwindow (the lock screen and authorization) apart from the Dock and the menu bar, so a crash of the
desktop UI never takes the lock down. Today one Quickshell process, `grassfield-shell` (`Restart=always`, `RestartSec=1`),
hosts every surface and the lock, polkit agent and idle. When it dies while locked, Hyprland keeps the session locked
(ext-session-lock; its "lockscreen app died" screen) until the restarted shell takes the lock back (L1); when it dies while
unlocked, idle locking and the sleep inhibitor are gone until the restart, and Omarchy's sleep-lock unit covers a sleep
meanwhile (`OnFailure=`, GF-030). So the lock never fails open, but every UI crash costs a lock restart, and the process
that talks to PAM also runs the Dock, Overview, wallpaper, notifications and menus (the audit counted 64 dev-shell core
dumps, all UI).
A minimal `grassfield-security` Quickshell unit (Lock, AuthAgent, Idle and SleepInhibitor only) was evaluated against
this slice's bar ("only if low-risk"). It is not low-risk:
1. the IPC contract moves to another instance: Hyprland bindings, `grassfield-lid`, the `omarchy-shell` stand-in (`lock
   lock`/`lock status`, the D-12 fail-safe), screen corners (`qs ipc --pid <shell>`), the sleep-lock gate and `OnFailure=`
   (both keyed on `grassfield-shell`), packaging (PKGBUILD, another stream's file) and five security tests change at once;
2. the UI needs the lock state across processes (GF-116 refusals, "Show previews: When Unlocked", Overview, Switcher):
   Hyprland emits no lock event, so the security process must push it over Quickshell IPC, and a missed or stale push
   makes the UI refusals fail open (Hyprland still keeps input and rendering on the lock surface);
3. the lock surface draws the wallpaper (`LockView` imports `qs.desktop`), `SleepInhibitor` posts its notice through the
   UI's notification server and `Lock` closes the UI's popups: the module is not yet free of UI imports;
4. a second Qt Quick process costs memory (not measured).
Plan (next security milestone, each step reviewed and gated L1–L5):
- S1: make `shell/security/` free of UI imports: the lock backdrop through a `Grassfield.Ui` type; popups closed by the UI
  on `SessionState.locked` (done by GF-116, so `Lock.lock()`'s `Popups.close()` can go); the sleep notice through the
  notification server's public D-Bus interface;
- S2: `shell/security/shell.qml`, a root with Lock, AuthAgent and Idle only, run beside the UI in nested: one session lock
  owner, one polkit agent, memory measured;
- S3: IPC: the same target names on the security instance (`qs ipc -p /usr/share/grassfield/security …`); an action
  `lock state` (`unlocked`|`locked` only) the UI reads at start, plus a push from the security instance on every
  transition into the UI; the UI treats "no answer yet" as locked for its refusals; bindings, lid helper, stand-in and
  tests switch together;
- S4: `grassfield-security.service` (`Restart=always`, `RestartSec=1`, `PartOf=`/`Requisite=graphical-session.target`,
  `OnFailure=omarchy-sleep-lock.service`), the sleep-lock gate keyed on it; `grassfield-shell` keeps `Restart=always`;
- S5: crash-injection test: a crash signal to the UI process while locked (the lock surface never goes away: no
  "lockscreen app died" screen) and while unlocked (the idle lock still fires); DT-01/DT-21 re-run against the security
  process.

## Amendment 2026-10-26 (Settings > Lock Screen, macOS 27)
**Display off while unlocked.** The idle module gains a second idle monitor: after `lock.displayOffBattery` (on battery,
default 2 min) or `lock.displayOffPower` (on the power adapter, default 10 min) without input, the displays turn off (Hyprland
DPMS) while the session stays unlocked; any input turns them on (the compositor also does at a key press or pointer motion).
It respects the same inhibitors as the idle lock (an application holding a ScreenSaver cookie or a Wayland idle inhibitor
keeps the displays on) and reads the power source from UPower (`Battery.onBattery`; unknown reads as the power adapter). It
never locks and never delays the lock: the idle lock still fires at `lock.idleMinutes` from the first monitor, unchanged
(dim at T-10 s, lock at T), and a lock that follows a display-off keeps the displays off until input instead of lighting them
for the lock screen's own delay. A lock being acquired is never kept dark: the displays come on until the compositor
confirms it (`Lock.holding`; it confirms a lock only once it has drawn it on every display), then go dark again if no input
came (review of 6e61829: kept dark, the lock before sleep would wait out its budget and the ownership check would not run).
An unlock without Wayland input (fingerprint) lights a session that went dark for inactivity. A change of power source or of
the setting re-arms the monitor and lights the displays (as a Mac wakes its display when the adapter is plugged in); while
locked it then leaves the dark lock screen to its own 30 s delay. An invalid or 0 value means never (turning the displays off
is not what keeps the session safe). `IdleModel.inactiveDisplayOffSeconds`, `inactiveOffArmed`, `displaysOff`; tests/security/tst_idlemodel.qml. "Off" is
now sent whenever the wanted state is recomputed (the compositor may have switched the displays on by itself, so a remembered
"off" must not suppress the next one); "on" only when this module had them off, or while a lock is being acquired (an
instance restarted with the displays dark believes them on; counter-review of a15c05e): at start, then every 2 s until the
lock holds, at most 5 times (`IdleModel.ACQUIRE_DISPLAYS_ON_MS`, `ACQUIRE_DISPLAYS_ON_TRIES`: a lock that cannot hold, with no
display connected, is not woken all night); only a change of state is logged. The changes of the lock's state are handled later in the turn, once
(`Qt.callLater`), so a lock or an unlock sends no repeated "on". In the nested dev session it is always off (no dev hook: no
test needed one; review of PR #9).

**What the lock surface shows.** `lock.showUser` (default true) hides the account's picture and name (the password field
stays); `lock.showMessage` with `lock.message` shows one line of plain text of the user's (at most 200 UTF-16 code units, no C0 or
C1 control characters, line or paragraph separators, bidirectional overrides or isolates: refused otherwise by the settings
contract, rule `plainText`) above them, at most two lines on screen.
Display only: authentication, the lock state machine and every unlock path are unchanged, and the message is user text from
the user's own configuration (no notification or window content: L4 holds).

## Amendment 2026-10-29 (ADR-0041 SQ-1 B: the separate security process is decided)
The owner chose the separate security process as the answer to ADR-0041's SQ-1 (« Processus sécurité séparé », asked by
the integrator on 2026-10-29): the lock, the polkit agent, idle and the sleep inhibitor always run apart from the UI, and
safe mode is "the UI unit failed, the security process is up". The plan S1-S5 of the amendment of 2026-10-24 is carried
from here by `docs/decisions/ADR-0041-stability.md` step 1, in the integrator's order under the owner's rule: 1a (the
loop detector) first, then the process and its unit with nothing moved yet (S1, which also makes `shell/security/` free
of UI imports and measures the second process's memory and start time), then the lock (S2, with the IPC move and the
UI's fail-closed reading of the lock state: "no state yet" or "stale" is locked), the polkit agent (S3), idle and the
sleep inhibitor (S4, where `OnFailure=` and the sleep-lock gate move to `grassfield-security.service`), and safe mode
last (S5). Each step is its own pull request under the opus security review, and every intermediate state keeps
"failures stay locked" (R12). IQ-T5 (ADR-0040) applies to a crash of the security process itself. The risks listed
above (the IPC contract move, the lock state across processes, the UI imports, the memory of a second process) are
answered step by step there; nothing of this ADR's rules changes: `WlSessionLock`, `PamContext("omarchy-lock-password")`
and Quickshell's polkit only, no unlock on a failure.
