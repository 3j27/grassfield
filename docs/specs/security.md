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
| L1 | lock in nested, `kill -9` the shell → nested stays locked (screenshot), restart shell → lock re-acquired; soft reload with the marker removed or forged → still locked, nothing typed reaches a window (`tests/security/reload_locked.sh`) | L1, then L2† |
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
   locking/locked/authenticating) is declared before `WlSessionLock` in `Lock.qml`. Quickshell reloads a Singleton's
   children in declaration order (`ReloadPropagator::onReload`), so the old value is restored, and
   `WlSessionLock { locked: persist.intent || controller.locked }` re-evaluated, before `WlSessionLock::onReload`:
   the handed-over lock is kept, with no unlocked window (the new `WlSessionLock` has no Wayland lock object until its
   own reload). Verified offscreen by `tests/security/reload_order` (order, binding value, negative control,
   `Lock.qml` structure) and in nested by `reload_locked.sh` (marker removed / forged `unlocked` + reload → locked).
2. Marker, read in `Component.onCompleted` (runs before the reload pass): anything but exactly `unlocked` → lock.
3. `XDG_RUNTIME_DIR` unset: no marker can prove the session unlocked → lock at start; the lock surface shows
   "Crash recovery unavailable: the lock state could not be saved." (also shown when a marker write fails; logged).
4. Stranded lock: until this instance first locks (at most 20 Hyprland monitor queries in 10 s, through
   Quickshell.Hyprland, no `hyprctl`), "LOCK" in any monitor's `solitaryBlockedBy` (the signal Omarchy's
   `omarchy-hyprland-session-locked` uses; Hyprland has no lock query) means a lock this instance did not take, i.e. a
   crashed instance whose marker was missing or forged: it is re-acquired. Only ever locks. Verified in nested:
   forged `unlocked` + `kill -9` → restarted shell reports `locked` (before: `unlocked` behind Hyprland's
   "lockscreen app died" screen).

A fresh session (marker absent, no carried intent, compositor not locked) starts unlocked. This is safe because the
shell is never the only guard: when a lock client dies, Hyprland keeps the session locked (ext-session-lock; no input
reaches clients, verified by L1), and `misc.allow_session_lock_restore = true` only lets a new client take that lock
over. So a removed or forged marker can at worst leave the session locked behind Hyprland's failsafe screen, which
rule 4 resolves; it can never expose it.

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
| `tests/security/reload_locked.sh` | Nested scenario: reload with marker missing/forged, `kill -9` (L1), forged marker + crash, file watcher off |

IPC (all on the shell instance): `lock lock` → `ok` / `already-locked` / `refused: missing-pam`; `lock status` →
`unlocked|locking|locked|authenticating` (test hook); `lock devReload` → `reloading` only when `GRASSFIELD_DEV=1`
(soft reload for tests/security/reload_locked.sh), else `refused`; `polkit status` → `registered|unregistered`;
`idle status` → JSON.

States: `unlocked -request-> locking -acquired(secure)-> locked -submit-> authenticating -success-> unlocked`;
`failure|error|timeout|abort` → `locked`; a lock dropped by the compositor → `locking` (re-acquired every 500 ms);
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
  no orphan (verified in nested: `kill -9` of the shell → its `gdbus monitor` child is gone). Released once the lock is `secure`, or after 4 s; re-taken on resume. Skipped when
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
foreign locker (e.g. hyprlock) started before the shell: it would keep requesting the lock until that locker exits.
