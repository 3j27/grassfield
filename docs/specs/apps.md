# Apps spec · shell-engineer · M3 (floating panel, owner decision 2026-10-18)

## macOS reference behavior (described in words)
- macOS 26 replaced the full-screen paged Launchpad with a floating "Apps" panel: a frosted rounded panel,
  about 844 pt wide, centred near the top of the screen, with a search field, a row of category chips and an
  alphabetical grid of 7 columns that scrolls vertically (no pages, no folders). Our own measurements are in
  `docs/testing/f1-reference-gaps.md` (gap 14 and the Apps launcher table): panel 844 +-1 wide, radius about 28,
  top about 0.2 of the screen height, cell 114.7 x 101.6, icon 62, label about 12, chips about 24 tall with a
  7.6 gap. Typing turns the panel into a result list; Esc or a click outside closes; launching closes.

## Purpose and non-goals
Browse and launch installed applications. The feature is called "Apps" (code: `apps`, directory
`shell/launchpad/` kept as an internal name). Non-goals: app installation or removal, folders, drag to reorder,
a recents row, the header more-menu and the grid/list switch of the reference (not requested).

## Functional requirements
1. A1 IPC target `apps`: `toggle()`, `open()`, `close()`, `status()` (JSON: open, query, category, chips, zone, selected, selectedId, keyNav, total, cols, panel {x, y, w, h}, visible ids = the items whose row is in the view). The hot-corner action `apps` calls `toggle()`.
2. A2 The list comes from DesktopEntries (NoDisplay and OnlyShowIn/NotShowIn respected through `Apps.isListed()`), alphabetical (case-insensitive name, then id). Rebuilt when `Apps.listChanged` fires.
3. A3 Layout (tokens `launcher.*`): a transparent full-screen layer-shell window per screen (shown on the focused screen only, keyboard exclusive, namespace `grassfield-apps`) and a floating panel in it: width `panelWidth` 844 (shrinks to the screen minus `edgeMargin` on narrow outputs), radius `panelRadius` 28, top at `topFraction` 0.18 of the output height, height `heightFraction` 0.62 of the output height (at least `minHeight` 320, never into the `bottomClearance` 96 kept for the Dock; 670 px at 1920x1080, 476 at 1366x768). The panel height is low confidence (not measured): it shows about 5.5 rows at 1080p so the scroll is visible. Inside, with `padding` 20: the search field (`searchHeight` 36, a capsule with the fill overlay), the chip row (`chipHeight` 24, `chipGap` 8, scrolls sideways if it overflows), then the grid down to the panel edge. Material: the standard frosted `Material` (default transparency 0.25) whose geometry is the compositor blur region (BackgroundEffect; never faked; opaque with Reduce Transparency). No dim behind the panel.
4. A4 Grid: `columns` 7 (fewer when the panel is narrower: cell width at least `minCellWidth` 80, at least `minColumns` 3), cell height `cellHeight` 102, icon `iconSize` 62, the name under it in `labelSize` 12, wrapped to at most `labelLines` 2 lines and elided. The grid scrolls vertically (wheel, touch); an overlay scroll indicator shows while scrolling and fades after `scrollbarIdleMs`. A click on a cell launches. Hover shows a rounded highlight behind the icon.
5. A5 Categories. Chips: All, Productivity, Creativity, Utilities, Games, Other (en; fr: Tous, Productivité, Créativité, Utilitaires, Jeux, Autres). Every app belongs to exactly one chip, taken from its `Categories=` values (Quickshell `DesktopEntry.categories`) with the table in `Model.js` (`CATEGORY_MAP`, freedesktop.org Menu Specification names): the first chip in the order Games, Creativity, Productivity, Utilities whose list holds one of the values wins (a game that also lists Utility is a game; a graphics tool that also lists Office is creative); values that match nothing (Network, WebBrowser, X-* extensions, Qt, GTK, an empty list) put the app in Other. Mapping: Games = Game and its sub-categories, Emulator, KidsGame; Creativity = Graphics, 2D/3D/Vector/Raster graphics, Photography, Scanning, OCR, AudioVideo, Audio, Video, Music, Midi, Mixer, Sequencer, Tuner, Recorder, Player, AudioVideoEditing, Publishing; Productivity = Office and its documents, Calendar, ContactManagement, Email, Database, Dictionary, Chart, Finance, FlowChart, PDA, ProjectManagement, Development and its tools, Translation, WebDevelopment, Education, Science, Math, Engineering, Literature, Languages, Maps; Utilities = Utility, System, Settings and its kinds, PackageManager, Monitor, Security, TerminalEmulator, FileManager and file tools, Archiving, Compression, Accessibility, TextEditor, TextTools, Calculator, Clock, Core. A chip with no app is hidden (All is always shown). A click on a chip (or Return/Space on the focused chip) selects it and clears the query; the selected chip is accent-filled.
6. A6 Search: typing filters with `shell/search/Ranking.js` (imported, the same ranking as Search, including its usage boost read from `search-usage.json`, read only). The query ranks every app, whatever the selected chip (while searching no chip is shown selected); the first result is selected, Return launches it; with an empty query and nothing selected Return does nothing. Esc clears the query first, then closes. "No results" is shown for an empty list.
7. A7 Launch through `Apps.launch(entry)` (`DesktopEntry.execute()` through the dev isolation of ADR-0011), then close. No other launch path.
8. A8 Keyboard. Zones: search field, chips, grid. Tab / Shift+Tab cycle search -> chips -> grid (the grid is skipped while empty). Search: Down or PageDown enter the grid; Left/Right/Home/End move the caret. Chips: Left/Right/Home/End move the focus ring along the chips, Return or Space select the chip, Down enters the grid, Up returns to the field. Grid: arrows move the selection by one cell or row (reading order; Down from above a short last row lands on the last item), PageUp/PageDown by the visible rows, Home/End jump, Up from the first row leaves to the chips (to the field while searching), Return launches, the view scrolls to keep the selection in view. Typing in the chips or the grid goes to the field. Esc clears the query, then closes. The focus ring (accent, `selectionWidth` 3) shows on the selected cell while the keyboard owns the selection or a query is active, and on the focused chip. Accessible names and roles on the panel, field, chip row, grid, cells and chips.
9. A9 Motion: the panel fades and scales from `openScale` 0.96 over `motion.normal`; with Reduce Motion it only fades (<= `motion.reducedMax`). The blur region follows an unscaled frame, not the animation. A click outside the panel closes.
10. A10 Performance (P3): open to first frame < 300 ms; a keystroke costs about one frame: the grid is a virtualised `GridView` (only the rows in view and one row of buffer exist, pooled and reused) and a filter replaces the model in two steps (empty, then the items) so the few cells in view are rebound instead of diffing every row.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| A2/A4/A5/A6/A8 | `tests/unit/tst_appspanel.qml`: category mapping and priority, alphabetical order, chip groups, panel and grid metrics (1080p, 768p, small and narrow outputs), grid keyboard steps (short last row, pages, home/end), ranking spans every category, hidden ids | L0 |
| A1-A9 | nested scenario: IPC open/status, real pointer clicks (chips, cells, outside), wtype keys, screenshots en and fr | L1 |
| A10 | `tests/shell/apps_panel_perf` (200 entries: open and keystroke to frame, offscreen); log lines `apps open->visible N ms` and `apps search N ms` (slow keystrokes; all with `GRASSFIELD_APPS_TRACE=1`) | L0/L1 |
| A4 ranking cost | `tests/unit/tst_appssearch.qml` (min-of-N ranking of 194 entries <= 12 ms) | L0 |
| hidden ids | `tests/shell/hidden_entries.sh` (temporary XDG tree) | L0 |
| A2 contrast | `tests/visual/test_contrast_tokens.py`: roles "apps label, chip and field text" (colors.text on material), "apps selected chip text" (accentText on accent), the search glyph and placeholder in "secondary on material" | L0 |

## Implementation notes (`shell/launchpad/`)
- `Model.js` pure model (categories, order, panel and grid metrics, keyboard step, hidden-entry parsing shared with the `Apps` service and Search); `AppsController.qml` state, ranking, IPC; `AppsWindow.qml` layer-shell window per screen with the panel, field, chip row and scroll indicator; `AppsGrid.qml` the virtualised grid; `AppsCell.qml`, `AppsChip.qml`; `hidden-entries.sh` and `watch-applications.sh` (run by the `Apps` service, `shell/services/Apps.qml`: ids hidden by OnlyShowIn/NotShowIn, which Quickshell does not expose, rebuilt debounced when `DesktopEntries` changes; tested by `tests/shell/hidden_entries.sh` and `tests/shell/watch_applications_pdeathsig.sh`).
- Tokens: `launcher.*` (all sizes above, with the F1 source). `apps.borderWidth` stays: other surfaces (Files, Ui components) use it as their hairline width.
- The earlier full-screen layout (pages, dots, folders, drag, `apps-layout.json`) is gone; an old `apps-layout.json` in the state directory is ignored and never written again.
- Search usage (`search-usage.json`) is read for ranking only; launching from Apps does not bump it.

## Known limitations
- The panel height, the chip padding and the search field height are estimates (not measured in the reference).
- No recents row, no more-menu, no list view; no folders or custom order.
- Without compositor blur (nested dev session) the panel is the tinted material only; legibility relies on the tint (A2 tested at the tint alpha floor).
- Apps launched from the grid do not feed the Search usage boost.
- A filter or an app-list change returns the grid to the top.
- Multi-screen: the panel shows on the focused screen only.
- Performance with 200 entries is measured offscreen with software rendering (not the nested compositor, which has about 60 desktop entries on the reference machine); see the numbers in the commit history and the task report.
