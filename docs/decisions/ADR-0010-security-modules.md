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
