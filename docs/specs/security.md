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
hook `lock devReload` needs `GRASSFIELD_DEV=1`). Development restarts the shell with `scripts/dev/shell-run.sh`.

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
  inhibitor code path is disabled when `GRASSFIELD_DEV=1` and verified in L2.
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
| `shell/security/LockMachine.js` | Pure state machine `next(state, event)` and helpers (marker, initials, Caps Lock inference, clock pattern) |
| `shell/security/LockController.qml` | Auth controller over an injected PAM backend: one prompt answered, 30 s timeout, secret dropped on every outcome |
| `shell/security/PasswordField.qml` | Shared password entry (Password echo, sensitive-data hints, plain-text placeholder, return arrow) |
| `shell/security/lock/Lock.qml` | Singleton: `WlSessionLock`, `PamContext` (password; fingerprint only if its PAM file exists), crash marker, IPC `lock` |
| `shell/security/lock/LockView.qml` | Lock surface (display only): blurred `WallpaperArt` under a scrim, date and clock, avatar/initials, name, dark frosted field, one hint line (gate A2, see Decisions) |
| `shell/security/polkit/` | `AuthAgent` (PolkitAgent + overlay window, IPC `polkit status`), `AuthDialog`, `AuthDialogModel` |
| `shell/security/idle/` | `Idle` (IdleMonitor, dim layer, idle lock, IPC `idle status`), `SleepInhibitor`, `IdleModel.js` |
| `tests/security/reload_order/` | Offscreen `qs` test of the Quickshell reload contract the lock relies on (run by `scripts/dev/test.sh`) |
| `tests/security/marker_read/` | Offscreen `qs` test: marker reads through the real FileView (missing, `unlocked`, empty, mode 000, directory) |
| `tests/security/foreign_locker/` | Nested fixture: a foreign ext-session-lock client (Quickshell), released over IPC `foreign unlock`; refuses to lock without `GRASSFIELD_FOREIGN_LOCKER=1` or on the owner's instance (`.dev/main.instance`) |
| `tests/security/reload_locked.sh` | Nested scenario: reload with marker missing/forged, `kill -9` (L1), forged marker + crash, file watcher off, foreign locker takeover/restart (release → fresh lock ≤ 150 ms), `lock lock` and before-sleep during a desync, forced races `relock-confirm` and `foreign-gap`, `probe-cost`, `pam-audit`; `probe-memory` (10 min, explicit) |
| `tests/security/pam_audit.sh` | Read-only PAM attempt audit over every Quickshell instance log of this tree (sourced by `reload_locked.sh`) |

IPC (all on the shell instance): `lock lock` → `ok` / `already-locked` / `refused: missing-pam` (when already locked,
the session lock is re-verified, see "Lock ownership"); `lock status` → `unlocked|locking|locked|authenticating`
(test hook); dev hooks, only when `GRASSFIELD_DEV=1` (else `refused`), for tests/security/reload_locked.sh:
`lock devReload` → `reloading` (soft reload), `lock devPauseOwnershipCheck` → `paused` (periodic ownership check off
for 10 s), `lock devForgeUnlockedAnswer` → `forged` | `not-holding` (counts one "unlocked" answer Hyprland never gave,
as a stale answer would; only a confirmed relock can follow), `idle devSleep before|after` → `ok` (before-sleep /
after-resume path without logind; no inhibitor in dev); `polkit status` → `registered|unregistered`; `idle status` → JSON.

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
- Dev PAM suppression (defence in depth, R12 review #3 MAJOR): in a dev session (`GRASSFIELD_DEV=1`) the lock never
  hands a password to PAM unless `GRASSFIELD_DEV_ALLOW_PAM=1` is also set (the opt-in for the L2 failure-path test).
  `Lock.qml` sets `LockController.pamSuppressed` from these at start; a suppressed `submit()` logs
  `grassfield-lock: dev: PAM submit suppressed`, clears the field and stays LOCKED (fail closed, never unlocks); the
  lock's notice line shows "dev: password checks disabled" so a dev value leaking into a real session is obvious. This
  stops a stray key that reaches the lock field in a nested test from counting a `faillock` failure against the
  owner's real account (faillock is shared with sudo). Real sessions (`GRASSFIELD_DEV` unset) are unchanged:
  `pamSuppressed` is false and authentication is normal. Unit-tested both ways (`tst_lockcontroller.qml`), structure
  checked by `tests/security/reload_order`.
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
Lock screen contrast: the lock's error, notice, Caps Lock, typed-dots, return-arrow and focus-ring states are proven by the
token calculation only (the contrast run's nested capture is at rest: nothing is typed into the nested lock there; the
selection was only looked at, in one nested capture). The date (22 px, weight 600) is treated as normal text (4.5:1), not
large text.
`Quickshell.reload(true)` (hard reload, never called by Grassfield) while locked makes Quickshell abort
(`qFatal`: the old instance still holds the lock): the compositor keeps the session locked and the restarted shell
re-acquires it (fail closed, not graceful). The stranded-lock check cannot tell a crashed instance's lock from a live
foreign locker (e.g. hyprlock) started before the shell: Hyprland hands the live lock over at once, and the foreign
locker's later release is followed by a fresh Grassfield lock (see "Lock ownership" and Known limitations).
