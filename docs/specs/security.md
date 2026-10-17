# Security modules spec (lock, polkit, idle) · security-engineer · M2

Design: ADR-0010. Rules: master-prompt R12, §5.9. Gates: §10 L1–L5.

## macOS reference behavior (described in words)
- Lock screen: blurred wallpaper, large clock and date at the top center, user avatar (circle) and name near
  the bottom center, a rounded password field with a return arrow; wrong password → the field shakes.
  "Cancel"/"Switch user" are not shown for a single user.
- Authorization dialog: a compact centered sheet with a lock icon, "<App> wants to make changes.", the
  user name field prefilled, password field, Cancel / Allow (default) buttons.

## Functional requirements
1. SEC1 Lock engages via IPC `lock lock`, idle timeout, lid close, and before sleep (logind delay inhibitor).
2. SEC2 Only PAM success (`omarchy-lock-password`) unlocks; errors/timeouts/crashes stay locked.
3. SEC3 Password cleared from the field and memory after each attempt; field disabled while authenticating.
4. SEC4 Lock surface on every monitor; input never reaches other clients (ext-session-lock).
5. SEC5 Lock screen shows clock, date, avatar (`~/.face` or AccountsService icon) and name — no notification
   content, no thumbnails.
6. SEC6 Polkit agent: exactly one; shows message, action ID, program details; Cancel/Esc cancel; never auto-approve.
7. SEC7 Idle: dim → lock → DPMS off; respects idle inhibitors.
8. SEC8 Fingerprint only if `/etc/pam.d/omarchy-lock-fingerprint` exists.

## Acceptance criteria (gates)
| Gate | Test | Level |
|---|---|---|
| L1 | lock in nested, `kill -9` the shell → nested stays locked (screenshot), restart shell → lock re-acquired; soft reload with the marker removed or forged → still locked; a foreign locker taking over and releasing the lock → locked again by Grassfield; nothing typed reaches a window (`tests/security/reload_locked.sh`) | L1, then L2† |
| L2 | wrong password ×3 → error, still locked, field empty. **Never more than 3 wrong attempts per run**: the PAM service counts failures against the owner's real account (faillock deny=10). | L1 |
| L3 | lock shown before sleep | L2† owner |
| L4 | screenshot of lock with pending notifications → none visible | L1 |
| L5 | `pkexec --help` is safe: use `pkcheck --action-id org.freedesktop.policykit.exec --process $$ -u` in nested → agent dialog appears; Cancel → pkcheck fails; no auto-approve | L1 |

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
2. Marker, read in `Component.onCompleted` (runs before the reload pass): anything but exactly `unlocked` → lock,
   including an empty or unreadable marker (mode 000, a directory, I/O error). Only a missing file (FileView
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
   Hyprland for the real session lock state once per second (`ownershipProbe`: one `Hyprland.refreshMonitors()`
   request through Quickshell.Hyprland, no `hyprctl` process, never while unlocked or locking), plus at once when its
   lock surface loses keyboard focus (what a takeover or an unlock under it looks like to the client), and on every
   monitor answer anyone requested. Low frequency because no event exists; the interval bounds the window below.
2. An answer reporting the session unlocked is confirmed by a second, fresh answer (answers in the first 500 ms after
   the lock was confirmed are ignored), then the shell takes a fresh lock: `lockLost()` (→ `locking`, PAM aborted,
   secret dropped), the stale lock object is released (the session is already unlocked) and a new lock is requested in
   the same event-loop turn. The carried intent and the marker stay `locked`.
3. `lock()` while locked re-verifies (`verify()`): a session found unlocked gets a fresh lock (at once if the last
   answer already said so). The IPC answer is `already-locked` when the check is still pending (Quickshell has no
   synchronous Hyprland query); the fresh lock follows within a round trip (nested: 2 ms).
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
(a Quickshell ext-session-lock client released over its IPC). Measured: Hyprland reports the session locked again
0.3–0.9 s after a foreign release (ten releases over five runs); keys typed after that never reached the probe window.

File watching is disabled in `shell.qml` (`settings.watchFiles: false`, re-applied after every reload since
Quickshell resets it), so only an explicit `Quickshell.reload()` reloads the shell (none in production code; the dev
hook `lock devReload` needs `GRASSFIELD_DEV=1`). Development restarts the shell with `scripts/dev/shell-run.sh`.

## Known limitations
- Successful-unlock tests need the owner's password: the agent only verifies failure paths (L2 owner check).
- L3 cannot be verified in nested.
- VERIFIED 2026-10-17 (nested): polkit agents register per logind session. The nested shell shares the owner's
  session, where omarchy-shell already owns the agent, so registration in nested fails with "An authentication
  agent already exists for the given subject" (confirmed). The module logs it once, shows no dialog and approves
  nothing. L5 functional checks move to L2 (owner); L1 covers the refusal path and unit tests of the dialog model.
- Nested runs must not take a real logind sleep inhibitor (it would delay the owner's real suspend): the
  inhibitor code path is disabled when `GRASSFIELD_DEV=1` and verified in L2.
- Lock restore on Hyprland 0.56.2 (`misc.allow_session_lock_restore = true`, needed for crash recovery) does NOT wait
  for a live locker to exit: any client of the session can take a live lock over at once and, by releasing it, unlock
  the session (a Hyprland behavior no shell can prevent). Grassfield re-locks when the next ownership check sees the
  session unlocked: up to ~1 s later (measured 0.3–0.9 s in nested), during which the session is unlocked and
  `lock status` may still say `locked`. When Grassfield holds the lock, keyboard focus stays on its lock surface
  until something refocuses (nested: keys typed at once did not leak in that case); when a foreign locker held it,
  Hyprland refocuses a window at once (nested: keys typed immediately did leak). Closing this window needs a
  compositor-side lock/unlock event (e.g. from `grassfield-compositor`) or `allow_session_lock_restore = false`
  (which breaks crash recovery): owner/compositor decision.
- A foreign locker that takes over a live Grassfield lock and then dies (no release) leaves the session locked behind
  Hyprland's "lockscreen app died" screen (fail closed); Grassfield's own lock object is no longer used, so the session
  can only be unlocked after the shell restarts (its crash recovery takes the dead lock over).

## Implementation (M2)
| Path | Role |
|---|---|
| `shell/security/LockMachine.js` | Pure state machine `next(state, event)` and helpers (marker, initials, Caps Lock inference, clock pattern) |
| `shell/security/LockController.qml` | Auth controller over an injected PAM backend: one prompt answered, 30 s timeout, secret dropped on every outcome |
| `shell/security/PasswordField.qml` | Shared password entry (Password echo, sensitive-data hints, plain-text placeholder, return arrow) |
| `shell/security/lock/Lock.qml` | Singleton: `WlSessionLock`, `PamContext` (password; fingerprint only if its PAM file exists), crash marker, IPC `lock` |
| `shell/security/lock/LockView.qml` | Lock surface: blurred + dimmed `WallpaperArt`, date and clock, avatar/initials, name, field, one hint line |
| `shell/security/polkit/` | `AuthAgent` (PolkitAgent + overlay window, IPC `polkit status`), `AuthDialog`, `AuthDialogModel` |
| `shell/security/idle/` | `Idle` (IdleMonitor, dim layer, idle lock, IPC `idle status`), `SleepInhibitor`, `IdleModel.js` |
| `tests/security/reload_order/` | Offscreen `qs` test of the Quickshell reload contract the lock relies on (run by `scripts/dev/test.sh`) |
| `tests/security/marker_read/` | Offscreen `qs` test: marker reads through the real FileView (missing, `unlocked`, empty, mode 000, directory) |
| `tests/security/foreign_locker/` | Nested fixture: a foreign ext-session-lock client (Quickshell), released over IPC `foreign unlock`; refuses to lock without `GRASSFIELD_FOREIGN_LOCKER=1` or on the owner's instance (`.dev/main.instance`) |
| `tests/security/reload_locked.sh` | Nested scenario: reload with marker missing/forged, `kill -9` (L1), forged marker + crash, file watcher off, foreign locker takeover/restart, `lock lock` and before-sleep during a desync |

IPC (all on the shell instance): `lock lock` → `ok` / `already-locked` / `refused: missing-pam` (when already locked,
the session lock is re-verified, see "Lock ownership"); `lock status` → `unlocked|locking|locked|authenticating`
(test hook); dev hooks, only when `GRASSFIELD_DEV=1` (else `refused`), for tests/security/reload_locked.sh:
`lock devReload` → `reloading` (soft reload), `lock devPauseOwnershipCheck` → `paused` (periodic ownership check off
for 10 s), `idle devSleep before|after` → `ok` (before-sleep / after-resume path without logind; no inhibitor in dev);
`polkit status` → `registered|unregistered`; `idle status` → JSON.

States: `unlocked -request-> locking -acquired(secure)-> locked -submit-> authenticating -success-> unlocked`;
`failure|error|timeout|abort` → `locked`; a lock dropped by the compositor, or a session found unlocked under a lock
still reported secure (foreign takeover + release) → `locking` (fresh lock, re-requested every 500 ms);
fingerprint success unlocks from `locked`. Unknown states/events never unlock (exhaustive test).

Decisions:
- Crash recovery marker: `$XDG_RUNTIME_DIR/grassfield-lock-<HYPRLAND_INSTANCE_SIGNATURE>` holds `locked`/`unlocked`
  (atomic, blocking write before the lock is requested, after unlock; re-read before and after each write, so a
  stale cache or a failed write is detected). See "Lock survival" for how a starting shell uses it.
- `PamContext.user` is left unset: PAM authenticates the uid running the shell, not `$USER`.
- Prompts are counted per `pamMessage` (one answer, a second prompt aborts): `responseRequired` stays true after
  `respond()` until PAM's next message (found in nested L2).
- Missing `/etc/pam.d/omarchy-lock-password`: new locks are refused (`refused: missing-pam`, logged); a lock being
  restored proceeds with a persistent "Authentication service unavailable" message (never fail open).
- Lock before sleep: Quickshell 0.3.1 has no D-Bus/logind API, so `systemd-inhibit --what=sleep --mode=delay … cat`
  (stdin pipe: the inhibitor dies with the shell) plus `gdbus monitor` on `/org/freedesktop/login1` for
  `PrepareForSleep`. Both run under `setpriv --pdeathsig TERM --` (util-linux), so a shell crash (even SIGKILL) leaves
  no orphan (verified in nested: `kill -9` of the shell → its `gdbus monitor` child is gone). Released once
  `Lock.secure` holds (a confirmed lock, re-verified with Hyprland when it was already held; see "Lock ownership"), or
  after 4 s; re-taken on resume. Skipped when
  `GRASSFIELD_DEV=1` (log `grassfield-idle: inhibitor skipped (dev)`). Lid close locks through logind's
  `HandleLidSwitch=suspend` → `PrepareForSleep`; no separate lid binding.
- Idle: `IdleMonitor { respectInhibitors: true }`, dim at T−10 s, lock at T; Quickshell 0.3.1 keeps the timeout an
  `IdleMonitor` was enabled with, so the monitor is re-enabled on every timeout change (verified in nested).
- Untrusted strings (PAM messages, polkit message/action ID/prompt/identities, user name) use `Text.PlainText`.
  Polkit strings are also flattened to one line by `AuthDialogModel.plainLine` (C0/C1 controls and line separators →
  space, bidi overrides/isolates/marks removed, length capped: message 400, others 200) and capped in rendered lines
  by `AuthDialog` (message 4, action ID and feedback 2, elided; at most 4 identity rows, more scroll), so the sheet has
  a bounded height and the real action line and Cancel/Allow always stay visible (unit test: 5000-character
  multi-line message).

`grassfield.json`: `lock.idleMinutes` (integer 0–240, default 5, 0 = never) is read through `Settings.lockIdleMinutes`
(clamped); invalid values fall back to 5 in `IdleModel.timings`.

Known gaps (M2): polkit `details` (program, command line) are not exposed by Quickshell 0.3.1 `AuthFlow`; pkexec puts
the program in `message`, which is shown. Caps Lock is inferred from typed letters (no lock-key state in Quickshell).
Display power-off after the lock (T+60 s) and D-Bus `org.freedesktop.ScreenSaver` inhibitors are not handled.
The marker file of a dead compositor instance stays in `$XDG_RUNTIME_DIR` until logout (a few bytes).
`Quickshell.reload(true)` (hard reload, never called by Grassfield) while locked makes Quickshell abort
(`qFatal`: the old instance still holds the lock): the compositor keeps the session locked and the restarted shell
re-acquires it (fail closed, not graceful). The stranded-lock check cannot tell a crashed instance's lock from a live
foreign locker (e.g. hyprlock) started before the shell: Hyprland hands the live lock over at once, and the foreign
locker's later release is followed by a fresh Grassfield lock (see "Lock ownership" and Known limitations).
