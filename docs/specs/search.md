# Search spec · shell-engineer · M2

## macOS reference behavior (described in words)
- `Cmd+Space` opens a centered floating search field (~680 pt wide, ~1/4 from the top), large type
  (~22 pt), magnifier glyph, material background, rounded ~26 pt.
- Typing shows results below, ordered by group (Top Hit, Applications, Documents, Folders, Settings,
  Calculator/Conversion inline answers) without group headers (macOS 27). Arrow keys move, Return opens, Cmd+Return
  reveals in Files, Esc clears then closes. The top hit is preselected and drawn on a neutral light fill, not the accent.

## Purpose and non-goals
Providers: apps (DesktopEntries), Grassfield settings pages, calculator, unit conversion, commands
(lock, sleep, restart… as real actions), files (localsearch/TinySPARQL via `localsearch` CLI or D-Bus;
`plocate` fallback), recent documents (`~/.local/share/recently-used.xbel`). Non-goals: own indexer, web search.
The clipboard history (⌘4, the Clipboard view) has its own spec: `docs/specs/clipboard.md` (ADR-0034).

## Functional requirements
1. S1 Open/close via IPC `search toggle` (bound to SUPER+SPACE) within 100 ms warm (P4).
2. S2 App results ≤ 50 ms per keystroke on 300 desktop entries; fuzzy + prefix ranking, usage boost.
3. S3 Calculator: arithmetic, parentheses, %, ^, constants; result copyable with Return (clipboard via wl-copy).
4. S4 Units: length, mass, temperature, data sizes; currency excluded (needs network).
5. S5 Files: query localsearch asynchronously (max 20 results, ≤ 300 ms on 100k files), cancel stale queries.
6. S6 Keyboard: ↑/↓, Tab between groups, Return open, Ctrl+Return reveal in Files, Esc clear/close.
7. S7 Results show icon, name, subtitle (path/category); no network calls.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| S2/S3/S4 | QML TestCase for ranking, calculator parser, unit converter | L0 |
| S1/S2 | timestamped log scenario in nested | L1 |
| S5 | `localsearch` provider latency test on the owner's index | L2† |

## Known limitations
- File results depend on localsearch indexing settings of the user.

## Implementation notes (v1, `shell/search/`)
- Files: `Calc.js`, `Units.js`, `Ranking.js`, `Files.js` (pure, unit-tested in `tests/unit/tst_search*.qml`), `Search.qml` (state, providers, activation, IPC), `SearchPanel.qml` (layer-shell window `grassfield-search`, keyboard exclusive, blur region, one per screen, shown on the focused screen).
- IPC target `search`: `toggle()`, `open(text)`, `close()`, `query(text)` (sets the query without opening), `status()` (JSON of visible groups).
- Groups: Top Hit (best app, else command, else document; absent when an inline answer exists), Calculator, Conversion, Applications, Commands, Documents, Recent. An empty query shows no results at all (macOS Tahoe: the field alone until the first keystroke; there is no browse row to keep); documents, recent ones included, appear from the first keystroke.
- Calculator never uses eval/Function: own tokenizer and recursive-descent parser, depth limit 250, input limit 200 chars, function/constant lookup by `switch`.
- Files: `localsearch search -f -l 20 -- term`, then `plocate -i -b` when localsearch returns nothing or is unusable (on the dev machine `localsearch status` reports 0 files indexed, so plocate answers). Results are limited to `$HOME` and exclude hidden path segments. argv arrays only, wrapped in `timeout 2`, stale queries ignored by sequence number. Dev knobs: `GRASSFIELD_SEARCH_ROOT`, `GRASSFIELD_SEARCH_PLOCATE_DB`.
- Usage boost: `$GRASSFIELD_STATE_HOME` or `$XDG_STATE_HOME/grassfield/search-usage.json`, mode 0600, directory 0700, at most 500 entries.
- Apps: entries with NoDisplay, or hidden by OnlyShowIn/NotShowIn for `$XDG_CURRENT_DESKTOP`, are not listed. Search uses the same list as the Apps window (`Apps.isListed()` in `shell/services/Apps.qml`, fed by `launchpad/hidden-entries.sh`); the list is rebuilt, debounced, when desktop entries change and Search re-ranks on `Apps.listChanged`.
- Commands: Sleep, Restart, Shut Down, Log Out reuse `Power` and the confirmation dialogs. Lock Screen (REQ-SRCH-PRV-d2) locks through the lock module (`Lock.lock("search")`, the singleton behind the `lock` IPC target of shell/security/lock; the System menu calls the same function); `Search.lockAvailable` is true.
- Settings pages provider (REQ-SRCH-PRV-d1, macOS model: Spotlight lists System Settings panes): typing a page name or one of its keywords (title scores like a command, keywords at 0.8 of that) lists the page in a "Settings" group (also as Top Hit when it beats the best app and command) and Return opens Grassfield Settings on it (`SettingsApp.openSection(id)`, `grassfield-settings --section=<id>`). Pure matching in `shell/search/SettingsPages.js` (page ids = the Settings sections); a fourth filter chip "Settings" joins Applications, Commands and Documents. Test: `tests/unit/tst_searchsettings.qml`.
- Rows (ADR-0024 lot 2, macOS 27 Spotlight; measured in `docs/audits/visual-tahoe-2026-10-25.md` § Search — partly close, 6/10
  and `docs/audits/ui-finesse-2026-10-25.md` § 7.1 macOS 27 changed the target): one row per result, no header rows (the groups
  still order the list, Tab moves between them and `status()` reports them); 17 / 15 type (Inter sizes with the cap height of
  macOS's 17.7 / 15); rows 63 tall (two lines), the 36-pt icon 26 and the title and subtitle 80 from the panel edge; the
  selected row 12 from the panel sides, radius 18, a neutral fill (`colors.fill` at `search.selectionFillOpacity`, ordinary
  text colours, inside the A2 material fill overlay).
- Capsule (macOS 27, owner decision 2026-10-26; `docs/audits/ui-finesse-2026-10-25/f1-macos27.md` § Search): the query sits in
  a glass capsule (`search.capsule*`: 520 x 85, fully round, top at 0.157 of the screen, the 26-pt magnifier 32 and the query
  at 22 pt, Inter Display, 75 from its edge), with its own blur region. The chips and results come in a 520-wide panel
  (`search.width`) `capsuleGap` 11 under it, chips 20 from its top and 20 from its sides; the panel exists only when it has
  something to show (chips, results or "No Results").
- Latency is logged by the shell: `search open->visible N ms` (IPC call to first frame) and `search keystroke->results N ms`.

- Filter chips (F2c): with a query that has results in two or more of Applications, Commands and Documents (files and recents), a chip row sits under the field (`Filters.js`; the capsule is the Apps category chip). A click narrows the results to that kind (the Top Hit joins its kind; inline answers are hidden) and a second click clears it; a new query clears it. IPC `search filter <apps|commands|documents|"">` is the test hook. The field keeps the text focus; the chips are reachable by keyboard: Tab past the last result group (Shift+Tab before the first) moves the focus ring to the first (last) chip, Left/Right/Home/End move along them, Space or Return selects or clears, Esc or Tab past the end returns to the field, and any other key (typing, Up, Down) leaves the chips and acts on the field. The ring is the shared outside accent ring (`control.focusOutline`). Test: `tests/shell/search_chips`. The `filter` hook answers only in a visual fixture session (`VisualFixtures.active`).
- No-results notice: a non-empty query that nothing answers, once the file search settled (`filesPending`: the debounce timer and every live `localsearch`/`plocate` process, so the plocate fallback is waited for), shows "No Results for ...", centred under the field.
- Clipboard view (ADR-0034, `docs/specs/clipboard.md`): ⌘4 in the field (Super+4, forwarded as Ctrl+4), the Clipboard button right of the empty field, or Super+Ctrl+V (IPC `search clipboard`, opening only through `show()`) switch the same window to the clipboard history: the clipboard symbol and "Clipboard" in the field, the More button, the history's rows, the row and More menus and a preview panel beside the results. Backspace in the empty field returns to the results. Test: `tests/shell/search_clipboard`.

## Limitations (v1)
- Ctrl+Return reveals with `gio open <parent folder>` (default file manager) until Grassfield Files exists (M4).
- localsearch output parsing (`file://` URIs per line) could not be verified against real results: nothing is indexed on the dev machine.

## Settings > Search (2026-10-26)
Settings > Search (macOS 27's Spotlight pane) chooses which kinds of results Search shows: `search.showApps`,
`showDocuments` (no `localsearch`/`plocate` process runs while it is off, and the results already in are dropped),
`showRecents`, `showCalculator`, `showConversions`, `showSettings`, `showCommands`; a kind turned off never shows, the Top Hit
included. Delete Search History writes `search.historyResetAt` (milliseconds); the shell forgets the results picked before it
(`Ranking.forgetUsageBefore`), in memory and in `search-usage.json`, also when the deletion happened while it was not running.
Tests: `tests/shell/search_chips` (the switches and the deletion on the real controller), `tests/unit/tst_searchranking.qml`.
The clipboard history's group comes last (ADR-0034 step 3, `docs/specs/clipboard.md` CB-13): Results from Clipboard, the time
the history is available (30 minutes, 8 hours, 7 days), Keep clipboard history after logging out, and Clear Clipboard History…
(asks first; "Also delete pinned items" deletes the pins too). Test: `tests/unit/tst_settingssearch.qml`.

