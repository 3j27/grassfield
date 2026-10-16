# Overview spec (Mission Control equivalent) · shell-engineer + compositor-engineer · M2 (v1), M3 (v2)

## macOS reference behavior (described in words)
- Ctrl+Up or a 3/4-finger swipe up zooms out: all windows of the current Space spread without overlap,
  scaled, keeping relative positions, with app name labels under hovered windows; the desktop dims slightly.
- A Spaces bar at the top shows thumbnails of each Space (labelled "Desktop 1", …) and a "+" to add a Space;
  dragging a window onto a Space moves it.
- Click a window to focus it and zoom back in; Esc or Ctrl+Up again exits. Animations ~300 ms, spring-like.

## Purpose and non-goals
v1 (M2): shell surface with ScreencopyView thumbnails of toplevels (Quickshell `ScreencopyView` with
Hyprland toplevel capture), layout algorithm, Spaces bar, keyboard nav, drag to Space.
v2 (M3): live transforms of real windows by `grassfield-compositor` (`grassfield:overview on`) when the
capability is present. Non-goal: capturing protected surfaces.

## Functional requirements
1. O1 Toggle via IPC `overview toggle` (CTRL+UP) and gesture (owner config, L2).
2. O2 Layout: non-overlapping grid preserving relative positions, max scale 0.8, min gap 24 px; unit-tested.
3. O3 Thumbnails live-update (Full profile) or snapshot once (Reduced profile).
4. O4 Spaces bar: one tile per workspace on the monitor + "+" creates the next workspace.
5. O5 Drag a window thumbnail onto a Space tile → `movetoworkspacesilent`.
6. O6 Keyboard: arrows move selection, Return focuses, Esc exits.
7. O7 Minimized windows appear in a separate strip (M2 with minimize).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| O2 | layout unit tests (QML TestCase) | L0 |
| O1/O4/O6 | nested scenario with 6 windows + screenshots | L1 |
| P3 | frame timing open/close | L2† |
| S4 spike | ScreencopyView cost of 9 toplevels recorded in ADR-0006 notes | L1 |

## Known limitations
- v1 shows thumbnails, not the real windows moving; real-window transforms need the plugin (v2).
