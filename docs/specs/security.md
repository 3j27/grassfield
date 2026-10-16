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
| L1 | lock in nested, `kill -9` the shell → nested stays locked (screenshot), restart shell → lock re-acquired | L1, then L2† |
| L2 | wrong password ×3 → error, still locked, field empty. **Never more than 3 wrong attempts per run**: the PAM service counts failures against the owner's real account (faillock deny=10). | L1 |
| L3 | lock shown before sleep | L2† owner |
| L4 | screenshot of lock with pending notifications → none visible | L1 |
| L5 | `pkexec --help` is safe: use `pkcheck --action-id org.freedesktop.policykit.exec --process $$ -u` in nested → agent dialog appears; Cancel → pkcheck fails; no auto-approve | L1 |

## Known limitations
- Successful-unlock tests need the owner's password: the agent only verifies failure paths (L2 owner check).
- L3 cannot be verified in nested.
- UNKNOWN (to verify first): polkit agents register per logind session. The nested shell shares the owner's
  session, where omarchy-shell already owns the agent, so registration in nested is expected to fail with
  "agent already exists". The module must handle that (log + no dialog, never auto-approve). If confirmed,
  L5 functional checks move to L2 (owner); L1 covers only the refusal path and unit tests of the dialog model.
- Nested runs must not take a real logind sleep inhibitor (it would delay the owner's real suspend): the
  inhibitor code path is disabled when `GRASSFIELD_DEV=1` and verified in L2.
