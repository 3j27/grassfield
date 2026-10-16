# menubar spec · shell-engineer · M1 (spike S1)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
Not yet measured (F1 pending). Assumed: 24 px translucent bar across the top; Grassfield mark and bold active-application name on the left; clock and status items on the right.

## Purpose and non-goals
Per-screen top bar. Non-goals for this slice: application menus (T0/T1/T2, M2+), status menus, Control Center entry, system menu contents.

## Functional requirements
1. One layer-shell window per screen, namespace `grassfield-menubar`, layer Top, exclusive zone 24 px (`Tokens.menubarHeight`).
2. Frosted `Material`; blur region declared through `BackgroundEffect.blurRegion`.
3. Left: own leaf glyph (decorative, not a button) and the focused app name (desktop entry name when it resolves, otherwise the app id; "Desktop" with no focus).
4. Right: locale-aware clock, battery percentage only when UPower reports a laptop battery.
5. No placeholder menus (R11).

## Acceptance criteria
- Screenshot `s1-foot` shows "foot" while a foot window is focused (L2). qmllint 0 warnings (L0).

## Interfaces / contracts (versions)
Reads `Compositor.focusedAppId` (shell/platform), `Settings`, `Appearance`.

## Dependencies (verified versions)
Quickshell 0.3.1: PanelWindow, WlrLayershell, BackgroundEffect, SystemClock, DesktopEntries, UPower.

## Degraded behavior
No UPower or no battery: battery text hidden. No compositor plugin: nothing changes (app name comes from foreign-toplevel).

## Automated tests · Manual verification steps
No automated test for surfaces yet. Manual: nested-up, open foot, `shot.sh`.

## Performance · Accessibility · i18n
Static text items expose `Accessible.name`; nothing is interactive yet so nothing is focusable. Strings use `qsTr()`. Clock date part uses a fixed "ddd d MMM" pattern (translatable), time follows the locale short format.

## Known limitations
- No system menu, application menus, status icons or Control Center entry.
- The Grassfield mark is not clickable (no menu exists to open).
- Clock format differs from macOS with some locales (e.g. 12 h "1:06 AM" in en_US).
- Per-screen focus is global: every bar shows the globally focused app.
