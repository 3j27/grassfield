# Files spec · apps-engineer · M4

## macOS reference behavior (described in words — no reference images in design/reference yet)
- The file manager is one opaque window: a sidebar on the left (Favorites with the standard user folders,
  Locations with volumes and the network, Tags), a unified toolbar (back/forward, folder title, view switcher for
  icons/list/columns/gallery, action menu, search field), the folder contents, and optional path and status bars
  at the bottom ("12 items, 120 GB available").
- Icon view shows large icons or thumbnails with names below; a selected item gets a grey rounded backdrop and an
  accent pill behind its name. List view has sortable columns (Name, Date Modified, Size, Kind), folders show "--"
  as size, dates read "Today at 14:05". Column view shows one column per folder level with a preview column for a
  selected file.
- Tabs appear only from the second tab (Cmd+T). Get Info opens a small separate window per item. Space opens
  Glance. Type-to-select jumps to the first matching name. Drag and drop moves on the same volume and copies
  across volumes.

## Purpose and non-goals
Browse and manage files on KDE Frameworks KIO (owner decision D6): the feature is called "Files" (code
`grassfield-files`, app id `org.grassfield.Files`; never "Finder"). Trash, mounts, network protocols and thumbnailers
are KIO/Solid's, never reimplemented. Non-goals for v1: gallery view, tags, recursive/indexed search (the shell
Search covers files), Recents, sharing, Group By, a built-in viewer (Space
starts Glance of `grassfield-preview`, see `docs/specs/preview.md`).

## Functional requirements
1. F1 Launcher `apps/files/src/main.cpp`: `QApplication` (KIO's conflict/Open With/undo dialogs are widgets),
   `setDesktopFileName("org.grassfield.Files")`, `grassfield-files [locations...]` opens one window per location
   (default: home). QML from `GRASSFIELD_FILES_QML` or the baked-in directory (installed
   `/usr/share/grassfield/files/qml`). Image providers `image://icon/<theme name>` and `image://thumbnail/<id>`.
2. F2 Listing: `FolderModel` = KIO `KDirModel` (+`KDirLister`) behind a `QSortFilterProxyModel` with flat QML roles
   (name, url, iconName, isDir, size(Text), modified(Text), kind, thumbnail, selected, hidden, canPreview, emblem).
   Sort by name (natural, case-insensitive), kind, date or size; Keep Folders on Top; ascending/descending (name and
   kind default ascending, date and size descending); show hidden files; name filter (search field).
3. F3 Selection: click, Shift (range), Ctrl (toggle), Ctrl+A, rubber band (icon view), keyboard arrows, Home/End,
   PageUp/PageDown, type-to-select (1 s reset). The selection is keyed by URL and survives re-sorting.
4. F4 Views: Icon (thumbnails), List (sortable headers), Columns (miller columns + preview column); Ctrl+1/2/3 and
   the toolbar switcher; the view, sort and hidden-files choices persist (QSettings `Grassfield/Files`).
5. F5 Sidebar: Favorites = Home, Desktop, Documents, Downloads, Pictures, Music, Videos when the folder exists;
   Locations = Computer (`/`), Solid storage volumes (not ignored, filesystem usage) with mount on click and eject
   (`Solid::StorageAccess::setup/teardown`), Network (`remote:/`) only when a KIO `smb` or `sftp` worker exists (its
   listing hides kio-extras' "Apple Devices" `afc:` entry, an Apple trademark in the UI, master-prompt §14:
   `FileLogic::hiddenNetworkEntry`),
   Trash (`trash:/`, full/empty icon from a KIO listing). Items accept drops.
6. F6 Operations, all KIO jobs: copy/cut/paste (`KIO::paste`, `text/uri-list` + KDE cut flag + GNOME format),
   Move to Trash (`KIO::trash`), Put Back (`KIO::restoreFromTrash`), Delete Immediately (only in `trash:/`,
   confirmed), Empty Trash (`KIO::emptyTrash`, confirmed), New Folder (`KIO::mkdir`, "untitled folder", inline
   rename), Rename (`KIO::moveAs`, inline, F2, base name preselected), Duplicate ("name copy.ext", `KIO::copyAs`),
   drop (`KIO::move`/`copy`), undo/redo (`KIO::FileUndoManager`, Ctrl+Z / Ctrl+Shift+Z). Errors show in a banner.
   Pasting copies into the same folder makes duplicates instead of a conflict.
7. F7 Opening: folders navigate; files open with `KIO::OpenUrlJob` (MIME associations, executables never run);
   Open With lists `KApplicationTrader::queryByMimeType` apps and launches with `ApplicationLauncherJob`.
8. F8 Context menus (Grassfield `PopupMenu`): item menu (Open, Open With, Open in New Tab, Move to Trash, Get Info,
   Rename, Duplicate, Glance, Copy, Cut, Show in Enclosing Folder while searching), Trash item menu
   (Put Back, Delete Immediately…, Get Info, Copy), background menu (New Folder or Empty Trash…, Get Info, Paste,
   View As, Sort By, Show Hidden Files). The toolbar Action menu offers the same items. Submenus (Open With, View As,
   Sort By) open to the left of the menu, or move up, when they would leave the window (`PopupMenu.bounds`).
9. F9 Get Info window: icon/thumbnail, name, kind, size (folders: `KIO::directorySize`), where, created, modified,
   opened, link target, owner, group, permissions, access (read only).
10. F10 Window: tabs (Ctrl+T, Ctrl+W, Ctrl+Tab, middle click), new window (Ctrl+N), back/forward (Ctrl+[ / ],
    Alt+Left/Right), enclosing folder (Ctrl+Up), open (Return, Ctrl+Down), Go to Folder (Ctrl+Shift+G / Ctrl+L:
    `~`, paths, `trash:/`), Home (Ctrl+Shift+H), reload (Ctrl+R/F5), hidden files (Ctrl+H), search (Ctrl+F),
    context menu (Menu, Shift+F10). Path bar (clickable, drop targets) and status bar ("N items, X available",
    "K of N selected", job progress).
11. F11 Drag and drop: items drag out as `text/uri-list` (Drag.Automatic, works with other apps); drops on the
    background, folders, sidebar items and path segments; same filesystem moves, otherwise copies; Ctrl/Alt forces
    a copy.
12. F12 Glance: Space and the menu item "Glance at “name”" call `FilesApp.glance(urls)`, which starts
    `grassfield-preview --glance -- <paths>` detached for the local regular files of the selection (folders and remote
    items are skipped, at most 50 files). The Glance window takes the focus; Space or Esc there closes it. Blocked by
    `GRASSFIELD_FILES_NO_LAUNCH=1` like every launch. A missing binary raises the usual failure banner.
13. F13 Appearance: light/dark and Reduce Motion follow `grassfield.json` (read only, watched); app windows are
    opaque; tokens only (`files.*` group of `ui/tokens/tokens.json`). Error banners use the destructive colour.
14. F14 Global menu (T1, master-prompt 5.7, ADR-0008): each browser window exports its menus through DBusMenu
    (`qml/GlobalMenu.qml`, a `Qt.labs.platform` MenuBar) when `com.canonical.AppMenu.Registrar` is on the session bus
    at start (`apps/globalmenu.h`); without it nothing is created and the bar keeps the T0 menus. File (New Window,
    New Folder, New Tab, Open, Open With for the selection, Close Tab/Window, Get Info, Rename, Duplicate, Glance,
    Move to Trash or Put Back, Delete Immediately… and Empty Trash… in the Trash, Find), Edit (Undo, Redo, Cut, Copy,
    Paste, Select All), View (as Icons/List/Columns, Sort By, Show Hidden Files, Show Previous/Next Tab, Reload),
    Go (Back, Forward, Enclosing Folder, the sidebar places, Go to Folder…). The app menu and Window are the shell's
    T0 menus. Items run the same BrowserTab actions as the window and show the window's shortcuts; a key registered
    by both a menu item and an in-window Shortcut runs once (the Shortcut also acts on `activatedAmbiguously`). An
    operation error shows in the window that was active last (a global menu action runs while the shell's menu holds
    the keyboard).

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| F2 sort keys, sizes, dates, F10 path segments, F6 names, F5 hidden Network entry | `tests/unit/files/tst_filelogic.cpp` (gtest, 18 tests, run by `scripts/dev/test.sh`) | L0 |
| F3/F10 keyboard moves, history, type-to-select, header sort, rubber band, column prefix | `tests/unit/tst_filesnav.qml` (9 cases) | L0 |
| F6 copy/paste, F2 rename, new folder + inline rename, undo/redo, duplicate, trash + Put Back, Ctrl+W quit, no app launch, no QML errors, owner Trash untouched | `tests/apps/files_sandbox.sh` (nested, keyboard + pointer, 19 checks) | L1 |
| F4/F5/F8/F9/F10/F13 | nested screenshots: icon view with thumbnails, list sorted by date, columns, Get Info, item menu, two tabs with Trash, light icon/list, search, hidden files | L1 |
| F11 | nested: drag of a file onto a folder moved it (sandbox), Ctrl+Z moved it back | L1 |
| F14 | nested, private bus with the bridge: File, Edit, View, Go in the bar; File > New Folder and Edit > Undo clicked with the pointer created and removed the folder (sandbox); Open With lists the selection's applications; `tests/integration/global_menus.sh` covers the same T1 path with Preview | L1 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**`) and `check-textformat.py` | L0 |
| F5 mount/eject, removable media | not testable without a removable device | L2 (owner) |

## Interfaces / contracts
- `grassfield.json` version 1 (read only): `appearance`, `accessibility.reduceMotion`; location like the shell
  (`GRASSFIELD_CONFIG_HOME` → `$XDG_CONFIG_HOME/grassfield` → `~/.config/grassfield`).
- QSettings `~/.config/Grassfield/Files.conf`: `view/mode` (icons|list|columns), `view/sortKey` (0 name, 1 kind,
  2 date, 3 size), `view/sortDescending`, `view/foldersFirst`, `view/showHidden`.
- Desktop entry `org.grassfield.Files.desktop`: `Exec=grassfield-files %U`, `Icon=system-file-manager`,
  `MimeType=inode/directory;`.
- Environment: `GRASSFIELD_FILES_QML` (dev QML dir), `GRASSFIELD_FILES_NO_LAUNCH=1` (scripted tests: opening
  reports an error instead of starting apps, logged), `QT_LOGGING_RULES="grassfield.files.debug=true"` (listing
  times, selection and expectation traces).
- Glance: `FilesApp.glance(QList<QUrl>)` runs `grassfield-preview --glance -- <paths>`; the program is
  `GRASSFIELD_PREVIEW_CMD` (dev, may carry arguments), else `grassfield-preview` next to the Files binary, else the PATH.

## Dependencies (verified 2026-10-17)
Qt 6.11.2 (Core, Gui, Widgets, Qml, Quick), KDE Frameworks 6.29 (KIOCore, KIOGui, KIOWidgets, CoreAddons, Service,
Solid), gtest (tests only). No new package. Build: `apps/files/build-direct.sh` (g++, parallel units, explicit
`/usr/include/KF6/*`, `KF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00`); `CMakeLists.txt` for when cmake/ECM are
installed (not built here).

## Degraded behavior
- No thumbnailer for a type: the theme icon for the MIME type.
- No udisks2/Solid backend: only Computer under Locations.
- No KIO network worker: no Network entry.
- No job-tracker service (kuiserver): progress shows in the status bar (jobs run with `HideProgressInfo`).
- Compositor plugin absent (nested dev): no titlebar; the window still works (title in the toolbar).
- Icon theme missing a name: generic MIME icon, then `text-x-generic` / `folder`.

## Automated tests · Manual verification steps
- `scripts/dev/test.sh` (gtest + QML), `scripts/dev/qmllint.sh`, `tests/apps/files_sandbox.sh [output]` (needs
  `scripts/dev/nested-up.sh` and `apps/files/build-direct.sh`; all files under `.dev/files-sandbox`, XDG dirs in
  `.dev/files-sandbox/.scenario-env` so the Trash is a sandbox Trash).
- Manual (L2, owner): plug a USB stick (mount on click, eject), open a text file and an image with the default app,
  drag files to and from another app, Empty Trash on a test item.

## Performance (gates affected) · Accessibility · i18n
- Nested, 2000 empty files: listing completes in 0.6–1.0 s (cold); RSS ≈164 MB idle, 171–181 MB with the folder
  listed and scrolled (baseline with a 2-item folder ≈166 MB); wheel scrolling through the icon and list views:
  103/102 frames, render median 15 ms, max 16–17 ms (≥ 99 % under 16.7 ms), polish ≤ 1 ms
  (`QSG_RENDER_TIMING`). Not measured on the reference hardware (L2).
- Thumbnails are requested by created delegates and cancelled when the delegate is destroyed (a request not yet
  started is dropped); the newest request is served first (LIFO, `previewqueue.h`), jobs hold at most 32 items,
  and at most 512 thumbnails are kept (oldest evicted, re-requested when shown again). Measured with 2000 PDFs:
  the visible page after End is thumbnailed in ~0.3 s; paging through the whole folder generated ~140 thumbnails.
- The lister uses delayed MIME types: the Kind sort uses the extension/name guess (memoized) until an item's type is
  known, and rows a view displays refine their type from content once (never the whole folder on the GUI thread).
  Kind sort of 2000 extension-less files: 529 ms (was ~3100 ms).
- Names with line breaks show on one line with `⏎` in place of each break (display only).
- Accessibility: `Accessible.role/name` on every control, list item, header, banner and dialog; full keyboard
  operation; untrusted text (file names, KIO messages) is `Text.PlainText`.
- i18n: every visible string is `qsTr()` / `tr()`; plurals use singular/plural pairs (no catalogs with numerus forms).

## Known limitations (honest, user-visible gaps vs macOS)
- Thumbnails come from KIO's thumbnail plugins (kio-extras, installed 2026-10-17: images, PDF, video); a type without
  a plugin keeps its MIME icon. The Network place (kio-extras smb/sftp workers) lists MTP devices and SMB shares; the
  "Apple Devices" entry is hidden (§14).
- No gallery view, tags, Recents, Group By, sharing; search filters the current folder by name only.
- Space does not close a Glance from Files by itself; the Glance window has the focus and closes on Space/Esc.
- KIO's own dialogs are QWidget dialogs, not Grassfield-styled: file-exists conflicts (paste/drop), the Open With
  chooser when no application is associated, and the undo confirmation for deleting copied files.
- Terminal applications (for example `nvim.desktop`, the default for text files here) fail to open: KIO starts them
  through `kdeglobals` `[General] TerminalApplication` (default konsole, not installed on Omarchy). Observed in a
  nested run as the banner "Terminal konsole not found…". Workaround: set `TerminalApplication` (owner config).
- Open With lists the registered applications only (no "Other…" chooser, no "change default").
- Mount, eject and removable media are implemented with Solid but not exercised (only ignored internal volumes here).
- Empty Trash and Delete Immediately are implemented with confirmations but were never run by tests (the real Trash is
  never emptied); Put Back cannot be undone (KIO keeps no undo record for restores).
- The global menu has no Help menu (there is no help content) and no Window menu of its own: tab switching is under
  View, the window actions are the shell's T0 Window menu. Info windows export no menu (the bar shows T0 there).
- Return opens (as specified), unlike macOS where Return renames; F2 renames.
- View settings are global, not per folder; window size/position are not remembered; a new window opens exactly over
  the previous one (the compositor centres floating windows).
- Rubber band selection only in the icon view; no spring-loaded folders; no link-on-drop.
- The path bar shows home-relative paths inside home, otherwise from `/` ("Computer"); long paths are clipped on the left.
- The sidebar shows "Trash full" only if the icon theme has `user-trash-full-symbolic`.
- Accessibility tree not verified with a screen reader (no AT-SPI bus in the nested session).
- French catalog: `translations/grassfield_fr.ts` (gate I1, `just check-i18n`).
