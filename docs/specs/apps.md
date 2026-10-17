# Apps spec · shell-engineer · M3

## macOS reference behavior (described in words)
- A full-screen overlay over a blurred, dimmed desktop. Search field at the top centre, a paged grid of
  large icons with names under them (7 x 5 on a large display), page dots at the bottom.
- Swipe, scroll or arrow keys change page. Folders are icons containing mini icons; clicking opens a
  rounded panel with the folder's apps and an editable name. Dragging reorders and, dropped onto
  another icon, creates a folder. Esc or a click on empty space closes; launching an app closes it.

## Purpose and non-goals
Browse and launch installed applications. The feature is called "Apps" (code: `apps`, `AppsGrid`).
Non-goals: app installation or removal, jiggle-delete mode, reordering inside an open folder.

## Functional requirements
1. A1 IPC target `apps`: `toggle()`, `open()`, `close()`, `status()` (JSON: open, page, pageCount, query, selected, keyNav, folder, total, cols, rows, visible ids). The hot-corner action `apps` calls `toggle()`.
2. A2 Grid from DesktopEntries (NoDisplay and OnlyShowIn/NotShowIn respected), saved layout order then name. Columns/rows from the screen size and tokens (`apps.*`; icon 96 px at 1080p gives 7 x 5).
3. A3 Paging: wheel, PageUp/PageDown, arrows across page edges, horizontal swipe on empty space, clickable dots. Pages slide (`motion.normal`); Reduce Motion crossfades (<= `motion.reducedMax`).
4. A4 Search: typing filters across all pages with `shell/search/Ranking.js` (imported), Return launches the first result, Esc clears then closes.
5. A5 Folders: drop on the middle of an icon creates "Untitled" (renamable inline, name field focused) or fills a folder; drop elsewhere reorders; dragging an app out of the folder panel removes it; empty folders disappear.
6. A6 Persistence: `$GRASSFIELD_STATE_HOME` (dev) else `$XDG_STATE_HOME/grassfield/apps-layout.json`, mode 0600, directory 0700, atomic writes, `version: 1`; removed apps are pruned, new apps appended by name; corrupt files yield the default layout.
7. A7 Launch through `DesktopEntry.execute()`, then close.
8. A8 Keyboard: arrows move the selection (visible focus ring), Return launches or opens a folder, Tab switches between the search field and the grid, Esc closes folder / clears / closes. Typing in the grid focuses the field. Accessible names and roles on cells, dots, field.
9. A9 Performance (P3): open to first frame < 300 ms with about 150 entries; only the current page and its neighbours have cells.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| A2/A3/A5/A6 | `tests/unit/tst_appslayout.qml`: pruning, appending, folder create/add/remove, persistence round trip, grid and paging math, keyboard step | L0 |
| A1-A8 | nested scenario: IPC open, real pointer wheel/drag/click, wtype keys, screenshots | L1 |
| A9 | log line `apps open->visible N ms` | L1 |

## Implementation notes (v1, `shell/launchpad/`)
- `Model.js` pure layout model and paging math; `AppsController.qml` state, IPC, persistence; `AppsWindow.qml` layer-shell window `grassfield-apps` per screen (focused screen only, keyboard exclusive, blur region); `AppsGrid.qml`, `AppsCell.qml`, `AppsIcon.qml`; `hidden-entries.sh` lists ids hidden by OnlyShowIn/NotShowIn (Quickshell does not expose them).
- Drag is owned by the window (`beginDrag`/`dragMove`/`endDrag`); the model is edited only on drop. Edge dwell flips the page while dragging.
- Search usage (`search-usage.json`) is read for ranking only; launching from Apps does not bump it.

## Known limitations
- Reordering inside an open folder is not supported; folders keep the order apps were added.
- A folder that keeps one app stays a folder.
- Folder names and layout are matched by desktop entry id; renamed entry ids lose their position.
- Open timing measured with 57 entries (88-223 ms to first frame in the nested session); 150 entries were not measured.
- Without compositor blur (nested dev session) the folder panel and backdrop are only dimmed; legibility there relies on the dim layer.
- Touch and touchpad swipe use wheel events only; there is no momentum drag of the page row.
- Apps launched from the grid do not feed the Search usage boost.
- Multi-screen: the overlay shows on the focused screen only; folders and layout are shared.
