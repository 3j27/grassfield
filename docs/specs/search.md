# Search spec · shell-engineer · M2

## macOS reference behavior (described in words)
- `Cmd+Space` opens a centered floating search field (~680 pt wide, ~1/4 from the top), large type
  (~22 pt), magnifier glyph, material background, rounded ~26 pt.
- Typing shows grouped results below (Top Hit, Applications, Documents, Folders, Settings,
  Calculator/Conversion inline answers). Arrow keys move, Return opens, Cmd+Return reveals in Files,
  Esc clears then closes. The top hit is preselected.

## Purpose and non-goals
Providers: apps (DesktopEntries), Grassfield settings pages, calculator, unit conversion, commands
(lock, sleep, restart… as real actions), files (localsearch/TinySPARQL via `localsearch` CLI or D-Bus;
`plocate` fallback), recent documents (`~/.local/share/recently-used.xbel`). Non-goals: own indexer, web search.

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
- Groups: Top Hit (best app, else command, else document; absent when an inline answer exists), Calculator, Conversion, Applications, Commands, Documents, Recent. Recent documents are also shown for an empty query.
- Calculator never uses eval/Function: own tokenizer and recursive-descent parser, depth limit 250, input limit 200 chars, function/constant lookup by `switch`.
- Files: `localsearch search -f -l 20 -- term`, then `plocate -i -b` when localsearch returns nothing or is unusable (on the dev machine `localsearch status` reports 0 files indexed, so plocate answers). Results are limited to `$HOME` and exclude hidden path segments. argv arrays only, wrapped in `timeout 2`, stale queries ignored by sequence number. Dev knobs: `GRASSFIELD_SEARCH_ROOT`, `GRASSFIELD_SEARCH_PLOCATE_DB`.
- Usage boost: `$GRASSFIELD_STATE_HOME` or `$XDG_STATE_HOME/grassfield/search-usage.json`, mode 0600, directory 0700, at most 500 entries.
- Apps: entries with NoDisplay, or hidden by OnlyShowIn/NotShowIn for `$XDG_CURRENT_DESKTOP`, are not listed. Search uses the same list as the Apps window (`Apps.isListed()` in `shell/services/Apps.qml`, fed by `launchpad/hidden-entries.sh`); the list is rebuilt, debounced, when desktop entries change and Search re-ranks on `Apps.listChanged`.
- Commands: Sleep, Restart, Shut Down, Log Out reuse `Power` and the confirmation dialogs; Lock Screen stays hidden until a lock IPC target exists (`Search.lockAvailable`).
- Latency is logged by the shell: `search open->visible N ms` (IPC call to first frame) and `search keystroke->results N ms`.

- Filter chips (F2c): with a query that has results in two or more of Applications, Commands and Documents (files and recents), a chip row sits under the field (`Filters.js`; the capsule is the Apps category chip). A click narrows the results to that kind (the Top Hit joins its kind; inline answers are hidden) and a second click clears it; a new query clears it. IPC `search filter <apps|commands|documents|"">` is the test hook. Chips take no keyboard focus: the field keeps it and Tab keeps moving between groups.
- No-results notice: a non-empty query that nothing answers, once the file search settled (`filesPending`), shows "No Results for ...", centred under the field.

## Limitations (v1)
- Ctrl+Return reveals with `gio open <parent folder>` (default file manager) until Grassfield Files exists (M4).
- localsearch output parsing (`file://` URIs per line) could not be verified against real results: nothing is indexed on the dev machine.
- Settings pages provider is not included (no Settings app yet).
