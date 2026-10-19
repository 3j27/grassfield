# ADR-0013: Stages (stage manager equivalent): model in the plugin, live transforms with input blocking, feature flag
Status: Proposed (spike positive, plugin prototype behind a flag; applied provisionally) · Date: 2026-10-18 · Decider: owner

## Context
M5 asks for "Stage Manager (plugin layout + shell strip), behind a feature flag", UI name **Stages** (master-prompt
§5.6 item 6, §12, §14). macOS behaviour (assumption, from memory): the current app's windows centred and usable, other
apps as live thumbnails in a left strip, a click swaps a stage in, animated, drag and drop to regroup, the strip hides
when overlapped. Hyprland 0.56.2 has no such layout; the plugin already renders real windows live at any rect through
`Render::IWindowTransformer` (overview v2). Three questions: where the stage model lives, how windows of inactive stages
are hidden while shown live in the strip without taking input, and how the feature is gated.

## Options
Model location:
1. **Plugin** owns membership and the active stage per workspace; the shell owns presentation (tiles, chrome, hover,
   drag and drop, the setting) and sends requests.
2. Shell owns the model; the plugin only transforms and blocks what the shell lists.

Mechanism for inactive stages:
A. **Same workspace, window stays mapped at its real place, drawn into its tile by a transformer, input blocked by a
   plugin-owned `CWindow::setInputBlocked` reason.**
B. Park on a special workspace and show snapshots.
C. `CWindow::setHidden`.
D. Move the real geometry off every monitor.

Gate: a `config` key versus a separate verb or a build option.

## Decision (proposed)
- **Option 1.** Membership must change synchronously with Hyprland's window events (no window flashes in the centre
  before a reassignment; a closed window's stage updates before Hyprland picks a successor), the input block is a safety
  property that must not depend on the shell staying alive, and one unload must undo everything. The shell keeps all UI.
- **Option A.** Live (the window is rendered, so frame callbacks keep flowing), no client is moved, resized or configured,
  and Hyprland's hit test skips windows whose `acceptsInput()` is false, which covers pointer focus, clicks, hovers and
  titlebar presses. Thumbnails are drawn only where the shell's strip surface (namespace `grassfield-stages`, Top or
  Overlay layer) and its input region cover the tiles, so a click on a thumbnail never reaches a hidden window.
  B freezes clients (no frame callbacks off the visible workspace) and moves windows between workspaces; C and D are not
  rendered at all, so no live thumbnail.
- **Flag:** `hl.plugin.grassfield.config("stagesEnabled", "true"|"false")`, off at every load; capability
  `stages-available` (the toggle can be shown) and `stages` (the flag is on). Verb `hl.plugin.grassfield.stages(json)`
  with ops `on`, `off`, `activate`, `move`, `merge`; event `stages` (state, coalesced). Additive within `gfc/1`
  (ADR-0007). Contract: `docs/specs/stages.md` "Shell contract".

## Evidence
Nested Hyprland 0.56.2, plugin 0.6.0-stages: `tests/compositor/stages.sh check` 40/40 (grouping, thumbnails live in
their tiles, no input at strip windows' real places, animated swap, regrouping, new/closed windows, focus by dispatch,
hidden strip, workspace switch, minimize, full screen, overlap, strip surface gone, invalid payloads, a 1000-request flood, unload during
Stages); `stages.sh perf 30`: idle 0.1 % of one core, a ticker in a strip tile 4.4 % (3.2 % with Stages off), a swap per
second 12.0 %; the special-workspace alternative ~0 % but frozen. Details: `docs/specs/stages.md` "Spike results".
Fix pass after the R13 review of 46b3e9b (plugin 0.6.1-stages, nested Hyprland v0.56.2 commit efb50993): `stages.sh check`
45/45 (adds a click without motion after a swap and after a new window, a swap under an Exclusive layer, minimizing the
only window of the active stage, window cycling), `minimize.sh stages` PASS, `soak.sh 660 stages` PASS; the pre-fix build
fails the three review sequences in the same session. Fix pass 2 after the R13 counter-review of 17208af (plugin
0.6.2-stages): `stages.sh check` 51/51 (adds window actions after a swap under an Exclusive layer, strip menus, focus
reasons); the pre-fix build fails the new active-window and menu checks in the same session. Details:
`docs/specs/stages.md`.

## Consequences
- Depends on Hyprland internals: `CWindow::setInputBlocked` with an unused reason bit (`1 << 6`), `acceptsInput()` in the
  hit test, `m_transformers`, `CEventLoopManager::doLater`. Re-verify on every Hyprland update (the ABI hash check stops
  a mismatched build).
- Requests are applied once per event loop pass: Hyprland's own `activewindow` events are not throttled, and a flood of
  per-request focus changes dropped the shell's socket2 connection in the spike.
- The input block alone is not enough (R13 review of 46b3e9b): Hyprland updates pointer focus on pointer motion only and
  delivers buttons, scrolls and keys to its current focus without checking blocks, and it cannot pick a blocked successor
  for the keyboard. The plugin therefore re-runs Hyprland's pointer focus logic (`CInputManager::simulateMouseMovement`)
  whenever a block changes, checks the pointer focus before every button and scroll and the keyboard focus before every
  key (moving a stale focus off a blocked window, never cancelling button events), and gives the keyboard to the active
  stage's front window, or to nothing, when Hyprland's successor may not hold it (minimize, close). Hyprland restoring its
  last window (`FFM`, e.g. when an Exclusive layer releases the keyboard) is not a user choice, so a swap made under an
  Exclusive layer is kept. Spec `docs/specs/stages.md` ST6, ST9, ST10, ST23.
- Hyprland's active window (what window bindings, window dispatchers without a window and the menu bar act on) is never a
  strip window (R13 counter-review of 17208af: after a swap under an Exclusive layer `hl.dsp.window.close()` closed the
  hidden outgoing window). Hyprland refuses every window focus while an Exclusive layer is mapped, so the plugin makes the
  incoming front window the active window behind the layer by setting Hyprland's Exclusive-layer list aside for that one
  focus call (the keyboard stays on the layer; Hyprland gives the window the keyboard when the layer releases it), and
  checks the active window after every retarget and before every key. A menu (popup grab) of a window going to the strip
  closes as a click outside it would (Hyprland's grab refuses the keyboard to every other surface). Only real user focus
  reasons bring a strip stage forward. Spec ST6, ST10, ST23, ST24. More internals to re-verify on Hyprland updates:
  `CInputManager::m_exclusiveLSes`, `CFocusState::fullWindowFocus` with an explicit surface, `CSeatManager::setGrab`,
  `Desktop::eFocusReason` (mapped one to one; a new reason is a compiler warning).
- Window cycling stays within the active stage (Hyprland's `cycle_next` skips windows that do not take input): the macOS
  model keeps Cmd+` (windows of the current app) inside the stage, and app switching (Cmd+Tab: Dock, Search, the coming
  app switcher) brings a stage forward through a focus by dispatch. A stage-aware ALT+TAB would need a function hook on
  `CWindowQuery::cycle` (rejected as fragile) or a session binding to a plugin verb.
- Popups of strip windows are not transformed; a strip revealed over an overlapping window draws under it; no persistence
  of stages across restarts; multiple outputs not verified yet.
- The shell strip, Control Center toggle and Settings entry are the shell-engineer's next step (contract only here).
- ADR-0002's "revisit option 2 (custom floating algorithm) when Stages needs placement control": not needed; Stages
  never changes window geometry.
