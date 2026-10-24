# ADR-0004: Notifications storage and privacy
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed) · Date: 2026-10-17 · Decider: owner

## Context
grassfield-shell is the only `org.freedesktop.Notifications` server in the Grassfield session (D2, §5.2),
via Quickshell `Quickshell.Services.Notifications`. macOS keeps a notification history in Notification
Center until dismissed. Notification bodies can contain secrets (OTP codes, messages).

## Options
1. In-memory only. Simple, private; history lost on shell restart (R1 gate needs state restore).
2. Persist to `$XDG_STATE_HOME/grassfield/notifications.json` (0600), bounded, with expiry.
3. Persist encrypted with the keyring. Adds a dependency and a prompt; overkill.

## Decision
Option 2 with limits:
- File `$XDG_STATE_HOME/grassfield/notifications.json`, mode 0600, written atomically (temp + rename).
- Max 200 entries, max 7 days, images not persisted (only app icon name), actions persisted as labels only
  and restored as non-actionable after a restart (the sending app's D-Bus object may be gone).
- Per-app setting "Show previews: always / when unlocked / never" (default: when unlocked).
- Never displayed on the lock screen by default (L4). Do-Not-Disturb/Focus suppresses banners, keeps history.
- Notifications with `transient` hint or `urgency=low` + `resident=false` are not persisted.

## Consequences
- The shell writes one small file; documented in the notifications spec and privacy notes.
- Revisit if a portal-level notification store becomes standard.
