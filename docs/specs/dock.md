# dock spec · shell-engineer · M1 (spike S1)

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
Not yet measured (F1 pending). Assumed: centered rounded translucent shelf at the bottom with large icons, a dot below running apps; click launches or focuses.

## Purpose and non-goals
Pinned and running apps with launch and focus. Non-goals now: magnification, autohide, minimize targets, folders/stacks, trash, drag reordering, per-monitor differences, tooltips.

## Functional requirements
1. One layer-shell window per screen, namespace `grassfield-dock`, bottom-anchored (compositor centers it), exclusive zone = dock height + bottom margin.
2. Items: pinned ids from `Settings.dockPinned` (default `foot`, `chromium`, `org.gnome.Nautilus`; uninstalled ids are skipped), then running apps that are not pinned.
3. Running indicator dot under items with at least one toplevel.
4. Click, Enter, Return or Space: focus the first toplevel (foreign-toplevel `activate`), else `DesktopEntry.execute()`.
5. Items are Tab-focusable, with a visible focus ring, `Accessible.role: Button` and a name (suffixed ", running").

## Acceptance criteria
- Screenshot shows three pinned icons and a dot under foot after launching it (L2). qmllint 0 warnings (L0).

## Interfaces / contracts (versions)
`grassfield.json` `dock.pinned` (version 1). Uses `Compositor.toplevels` and `Compositor.activate`.

## Dependencies (verified versions)
Quickshell 0.3.1: DesktopEntries, IconImage, WlrLayershell, ToplevelManager.

## Degraded behavior
No desktop entry for a running app: shown with the app id and a theme icon of the same name (generic icon if missing).

## Automated tests · Manual verification steps
Manual only: nested-up, launch foot, shot, click tests not automated.

## Performance · Accessibility · i18n
Model rebuilt on toplevel, application or pin changes. Strings use `qsTr()`.

## Known limitations
- No magnification, autohide, tooltips, bounce, drag, context menu, trash, stacks.
- Only the first window of an app is focused on click; no window cycling.
- Pinning/unpinning from the UI does not exist; edit grassfield.json.
- Dock icons come from the installed theme and are not Grassfield artwork.
- Click activation was not exercised in the nested session (visual NOT verified for click behavior).
