# ADR-0010: Security modules design (lock, polkit, idle)
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed) · Date: 2026-10-17 · Decider: owner · Requires opus reviewer PASS per change (R12)

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
