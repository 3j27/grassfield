# Search spec · shell-engineer · M2

## macOS reference behavior (described in words)
- `Cmd+Space` opens a centered floating search field (~680 pt wide, ~1/4 from the top), large type
  (~22 pt), magnifier glyph, material background, rounded ~26 pt.
- Typing shows grouped results below (Top Hit, Applications, Documents, Folders, System Settings,
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
