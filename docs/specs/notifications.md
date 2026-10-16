# Notifications spec · shell-engineer · M2

## macOS reference behavior (described in words)
- Banners slide in at the top-right under the menu bar, ~344 pt wide, rounded ~16 pt, material background,
  app icon left, bold title, body up to 4 lines, relative time ("now", "2m ago") top-right. They stay ~5 s
  (alerts stay until acted on), hovering pauses dismissal, a swipe/drag to the right dismisses, a close (×)
  button appears on hover at the top-left corner.
- Multiple banners stack vertically with 8 pt gaps; same-app notifications group with a count in the
  Notification Center.
- Notification Center opens from the clock in the menu bar (click) as a full-height panel on the right;
  it shows grouped notifications (newest first) and widgets below; "Clear" per group; Esc or click outside closes.
- Focus / Do Not Disturb (from Control Center) silences banners; the menu bar shows a moon icon.

## Purpose and non-goals
Single `org.freedesktop.Notifications` server for the session (Quickshell `Quickshell.Services.Notifications`),
banners, history (ADR-0004), Notification Center panel, DND. Non-goals: notification sounds beyond one
Grassfield sound (later), cross-device sync.

## Functional requirements
1. N1 Server registers `org.freedesktop.Notifications`; capabilities: body, body-markup (sanitized subset),
   actions, icon-static, persistence, inline-reply only if Quickshell supports it.
2. N2 Banner per notification; timeout = hint/expire_timeout, default 5 s; `urgency=critical` never auto-expires.
3. N3 Hover pauses the timeout; drag right > 30 % width or × button dismisses (calls `dismiss()`).
4. N4 Clicking the banner invokes the `default` action if present and focuses the sender window if known.
5. N5 Actions render as buttons (max 3 visible, rest in a "More" menu); each invokes the real action.
6. N6 History persisted per ADR-0004 (0600, ≤ 200 entries, ≤ 7 days, transient not stored).
7. N7 Notification Center: opens from the clock or `SUPER+N`; grouped by app; per-group Clear; "Clear all".
8. N8 DND: toggle (Control Center); suppresses banners except critical; menu bar moon indicator.
9. N9 Markup is sanitized (allow b, i, u, a href shown as text); images limited to 256 px.
10. N10 Never shown on the lock screen by default (L4).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| N1 | `notify-send` from inside nested → banner screenshot; `busctl --user` shows the name owned by qs | L1 |
| N2/N3 | scripted: send 3, wait 6 s, only critical remains | L1 |
| N5 | `notify-send -A ok=OK` → click via `wtype`/IPC → `notify-send` prints `ok` | L1 |
| N6 | restart shell → history restored; file mode 0600 | L1 |
| N9 | unit test of the sanitizer (QML TestCase) | L0 |

## Interfaces
D-Bus `org.freedesktop.Notifications` 1.2 (spec). Settings keys `notifications.dnd`, `notifications.previews`.
IPC target `notifications`: `toggleCenter()`, `dnd(on)`.

## Degraded behavior
If another server owns the name (e.g. mako), show one warning and run banners-only off.

## Known limitations
- Inline reply depends on Quickshell support; otherwise hidden (not faked).
- No per-app notification sounds in M2.
