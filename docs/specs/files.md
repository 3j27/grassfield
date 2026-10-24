# Files spec · apps-engineer · M4

## macOS reference behavior (described in words — no reference images in design/reference yet)
- The file manager is one opaque window: a sidebar on the left (Favorites with the standard user folders,
  Locations with volumes and the network, Tags), a unified toolbar (back/forward, folder title, view switcher for
  icons/list/columns/gallery, action menu, search field), the folder contents, and optional path and status bars
  at the bottom ("12 items, 120 GB available").
- Icon view shows large icons or thumbnails with names below; a selected item gets a grey rounded backdrop and an
  accent pill behind its name. List view has sortable columns (Name, Date Modified, Size, Kind), folders show "--"
  as size, dates read "Today at 14:05". Column view shows one column per folder level with a preview column for a
  selected file. Gallery view shows a large preview of the selected item above a strip of thumbnails, with an optional
  preview pane on the right (name, kind, size, dates, tags); Left/Right walk the strip, Space opens the quick look.
- Colour tags: the item menu ends with a row of seven colour dots; clicking one tags the selection (or removes the tag
  when every item has it). Tagged items show small coloured dots next to their names in every view; the sidebar's
  Tags section lists the tags in use, and clicking one shows the tagged items.
- Tabs appear only from the second tab (Cmd+T). Get Info opens a small separate window per item. Space opens
  Glance. Type-to-select jumps to the first matching name. Drag and drop moves on the same volume and copies
  across volumes.

## Purpose and non-goals
Browse and manage files on KDE Frameworks KIO (owner decision D6): the feature is called "Files" (code
`grassfield-files`, app id `org.grassfield.Files`; never "Finder"). Trash, mounts, network protocols and thumbnailers
are KIO/Solid's, never reimplemented. Non-goals for v1: an indexed search (the shell Search covers files; the tag
search walks one folder tree, F16), named tags created in Files (only the colour tags are set here; tags of other
applications are shown, kept and searchable), Recents, sharing, Group By, a built-in viewer (Space
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
4. F4 Views: Icon (thumbnails), List (sortable headers), Columns (miller columns + preview column), Gallery (F15);
   Ctrl+1/2/3/4, View As (item and background menus), the global View menu and the toolbar switcher; the view, sort,
   hidden-files and gallery info panel choices persist (QSettings `Grassfield/Files`; view settings are global, there
   is no per-folder view memory). Tag search results (F16) in the column mode show as a list.
5. F5 Sidebar: Favorites = Home, Desktop, Documents, Downloads, Pictures, Music, Videos when the folder exists; Tags
   (F16);
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
    (`qml/GlobalMenu.qml`, a `Qt.labs.platform` MenuBar) while `com.canonical.AppMenu.Registrar` is on the session
    bus: `apps/globalmenu.h` watches the name (QDBusServiceWatcher) for the life of the app, creates the MenuBar when it
    appears (an app started before the bridge), destroys it when it goes away and recreates it on an owner change (a
    bridge restart); without it the bar keeps the T0 menus and the in-window controls stay usable. File (New Window,
    New Folder, New Tab, Open, Open With for the selection, Close Tab/Window, Get Info, Rename, Duplicate, Glance,
    Tags (the seven colours, checked when every selected item has one), Move to Trash or Put Back, Delete Immediately…
    and Empty Trash… in the Trash, Find), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (as
    Icons/List/Columns/Gallery, Show Info Panel, Sort By, Show Hidden Files, Show Previous/Next Tab, Reload), Go (Back,
    Forward, Enclosing Folder, the sidebar places without the tags, Go to Folder…). The app menu and Window are the shell's
    T0 menus. Items run the same BrowserTab actions as the window and show the window's shortcuts; a key registered
    by both a menu item and an in-window Shortcut runs once (the Shortcut also acts on `activatedAmbiguously`). An
    operation error shows in the window that was active last (a global menu action runs while the shell's menu holds
    the keyboard).
15. F15 Gallery view (`qml/GalleryView.qml`): a large preview of the current item above a horizontal strip of
    thumbnails, and an info panel on the right (name, kind and size, colour dots, Created, Modified, Last opened,
    Where, Tags) shown or hidden with View > Show Info Panel (Ctrl+Shift+P, `view/galleryInfo`, on by default). The
    preview is a KIO thumbnail at `files.galleryPreviewSize` x `files.thumbnailOversample` px (at most the 1024 px
    xx-large cache size) from the same pipeline as the icon thumbnails: FolderModel runs two channels (icon size, role
    `thumbnail`; gallery size, role `largeThumbnail`), each with its LIFO request queue, 32-item PreviewJobs and an LRU
    cap (512 and 8). Each preview page asks for its thumbnail when created and drops the request when destroyed, so the
    neighbours kept around the current page are ready before the arrows reach them; until then the icon-size
    thumbnail, then the type icon, is shown (never enlarged past its pixels). The first item is selected once the
    folder is listed. Keyboard: Left/Right move along the strip, Home/End, PageUp/PageDown by the visible thumbnails
    (`Nav.stripMove`), Space opens Glance, Return opens, Ctrl+Up/Down as everywhere. In the strip a click selects (Shift
    extends, Ctrl toggles), a double click opens, items drag out and folders accept drops; a right click opens the item
    menu, on the empty area the folder menu. The name under the preview is also the inline rename field (F2).
16. F16 Tags (`src/taglogic.*`, `src/tagstore.*`, `src/tagsearch.*`):
    - Storage: the extended attribute `user.xdg.tags` (freedesktop Common Extended Attributes, as Dolphin, Baloo and
      KFileMetaData write it), UTF-8, tags separated by commas, read and written with `lgetxattr`/`lsetxattr`/
      `lremovexattr` on local files and folders only; an empty value removes the attribute. Files edits the stored bytes,
      not a parsed list (`TagLogic::applyTag`): it adds one entry at the end or removes the entries of one name,
      and every other entry stays byte for byte and in order (spaces, duplicates, line breaks, invalid UTF-8). Decided
      (as macOS, which matches tag names without regard to case): a colour tag matches case-insensitively everywhere,
      so a foreign `red` is Red: the row shows it checked, one click removes it (every spelling of it, the entry the
      user removes); adding Red next to an existing `red` is a no-op; the menu, the toggle, dots, sidebar and tag search
      all use that one rule. Other tags match exactly. Nothing is written from a failed read: only ENODATA means "no
      tags"; any other error (permission, I/O, a vanished file) stops the change and shows the banner ("The tags of
      … couldn't be read/changed"), so other applications' tags are never replaced by a guess
      (`TagStore::readRawChecked`). The seven colour tags are stored under fixed English keys (Red, Orange, Yellow, Green,
      Blue, Purple, Gray: the attribute does not depend on the UI language), matched case-insensitively, shown under
      translated names (context `Tags`) in the colours of tokens `files.tagRed` … `files.tagGray`. Symbolic links are
      never followed (Linux keeps no user attributes on links; tagging a link must not tag its target).
    - Setting: the item menu ends with a colour row (PopupMenu swatch row): each colour shows whether all, some or no
      selected item has it; a click adds it to every item, or removes it when all have it. The same row is in Get Info
      (with every tag name of the item) and File > Tags in the global menu. Items that can't carry tags (not local, in
      the Trash, links, missing, FIFOs and other special files, read-only items (no write permission, read-only mount),
      on a filesystem without user extended attributes such as some network or FAT volumes) get the row disabled; the
      reason shows as the row's caption and, in Get Info, as a tooltip. Symbolic links stay untaggable on purpose: a link
      is never followed, so its target is never tagged by accident. A write that still fails (a race, a sticky folder)
      shows in the error banner with the system's reason. Get Info lists the item's tag names live, also after tagging
      from the window itself; on a read-only item the swatches still show its tags (checked, disabled) and the caption
      names the tags with the reason in brackets (the tooltip carries the reason). Files' own writes refresh every window at once.
    - Showing: coloured dots (at most `files.tagDotsMax`, overlapping) before the name in the icon view, after it in the
      list view, before the chevron in the column view and in its preview column, on the gallery strip thumbnails and
      in the gallery info panel (roles `tags`, `tagColors`; one attribute read per shown item, cached).
    - Sidebar Tags section: the tags in use, colour tags first (a hollow ring for a tag without a colour). "In use"
      means seen on an item Files has shown, or set in Files; the list is kept across sessions (QSettings
      `tags/known`, at most 64). Remove from Sidebar (right click) hides the tag for good, as in the macOS Finder: the
      tag stays on the files and stays usable, but it is not listed again when a folder holding it is shown (QSettings
      `tags/hidden`, at most 256). Setting that tag again from Files (colour row, drop) lists it again, and so does the
      Tags section's context menu (a right click on a tag or on the "Tags" header): "Show Hidden Tag" is a submenu of the
      removed tags (shown by name); choosing one lists it at once. A drop on a tag tags
      the dropped local items. Tags are not places of the Go menu.
    - Tag search: a click on a sidebar tag opens the location `grassfield-tag:/<tag>?in=<folder>` (Files-internal,
      never handed to KIO): the items tagged so in the folder shown at the click (a local folder; from a remote place or
      the Trash, the home folder) and below. TagSearch walks the tree on a worker thread without an index: breadth
      first, on the folder's filesystem only, never through symbolic links, hidden entries only with Show Hidden Files,
      bounded to 50,000 entries, 2,000 matches and 32 levels, cancelled when the tab navigates elsewhere or closes.
      Matches arrive in batches, each carrying its search's generation: `SearchRunner` forwards only the current one, so a
      tag or folder switch or a reload never shows the old search's matches or its end (queued signals survive a
      `disconnect`); the status bar reads "Searching…" and tells when a bound stopped the search. The
      results follow KIO's change notifications (KDirNotify: renamed, moved, removed, changed) and Files' tag writes (an
      item that loses the tag leaves, one under the folder that gets it joins). The path bar shows the folder then the
      tag; history, tabs and Back work as for folders. In the results, rename, cut, copy, Move to Trash and tags work;
      nothing can be created (New Folder, Paste, Duplicate are off); Show in Enclosing Folder opens the item's folder
      with the item selected; a drop on the results or on the tag's path segment tags the dropped items.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| F2 sort keys, sizes, dates, F10 path segments, F6 names, F5 hidden Network entry | `tests/unit/files/tst_filelogic.cpp` (gtest, 18 tests, run by `scripts/dev/test.sh`) | L0 |
| F3/F10 keyboard moves, history, type-to-select, header sort, rubber band, column prefix; F4/F15 view modes (Ctrl+1..4, saved value fallback, tag results as a list), strip moves, initial gallery row | `tests/unit/tst_filesnav.qml` (15 cases) | L0 |
| F15 gallery on a stand-in listing: first item shown, Left/Right/Home/End along the strip, Up/Down still, Space and Return reach the tab, large previews asked for on the way, info panel preference | `tests/unit/tst_filesgallery.qml` (5 cases) | L0 |
| F16 tag parse/serialize, colour keys, selection states, search locations; byte-for-byte edits (`applyTag`, the reviewer's foreign value), sidebar hiding, `user.xdg.tags` write/read/remove, raw round trip, foreign tags, long values, links, FIFOs, read-only files, the probe cache, folders on files under the test sandbox (`GRASSFIELD_TEST_TMP` in `.dev/`; skipped without user xattrs) | `tests/unit/files/tst_tags.cpp` (gtest) | L0 |
| F16 a superseded search's queued batches and done never arrive (switch, stop); done once | `tests/unit/files/tst_tagsearch.cpp` (gtest, 3 tests) | L0 |
| F16 tag dots and swatch marks reach 3:1 (fill or darker edge) on the window colour | `tests/visual/test_contrast_tokens.py` | L0 |
| F16 palette from tokens, swatch models, dots cap, swatch row states, pointer, keyboard, disabled reason; PopupMenu swatch rows | `tests/unit/tst_filestags.qml` (5 cases), `tst_popupmenu.qml`, `tst_menunav.qml` | L0 |
| F6 copy/paste, F2 rename, new folder + inline rename, undo/redo, duplicate, trash + Put Back, Ctrl+W quit, no app launch, no QML errors, owner Trash untouched | `tests/apps/files_sandbox.sh` (nested compositor, own private D-Bus bus, app through `scripts/dev/isolated.sh`, refuses the owner's bus; keyboard + pointer, 19 checks) | L1 |
| F15 | `tests/apps/files_tags_shots.sh [en\|fr]`: nested screenshots of the gallery view with a thumbnail preview, the strip and the info panel; Right moves the preview (`.dev/shots/files-tags-<lang>-2-gallery.png`, `-3-gallery-next.png`) | L1 |
| F16 | `tests/apps/files_tags_shots.sh [en\|fr]` (sandbox files only): dots in the icon view and the sidebar's Tags section (`-1-icons`), the gallery panel's tags, Get Info before and after tagging from the window (caption names the tag, `-5-info`, `-6-info-tagged`), a read-only file's disabled row with its reason (`-7-info-readonly`), the tag search (`-8-tag-search`); earlier evidence: item menu colour row, a tag set (sandbox file), dots in the icon, list, column and gallery views, Get Info tag row, sidebar Tags section and a tag search listing the tagged files of the sandbox tree | L1 |
| F14 registrar | `tests/apps/files_registrar.sh` (nested, private bus, stand-in registrar `tests/apps/files_registrar_stub.py`): no menu bar before a registrar; one appears with it; destroyed when the registrar is killed (SIGKILL, like a crash) and when it exits cleanly; back with the next owner; no QML error. Observed: the menu bar object (a `created`/`destroyed` log line of the Loader) and the app's own registrar log; the DBusMenu reaching the shell's bar needs the compositor plugin and the menu bridge (covered for Preview by `tests/integration/global_menus.sh`) | L1 |
| F4/F5/F8/F9/F10/F13 | nested screenshots: icon view with thumbnails, list sorted by date, columns, Get Info, item menu, two tabs with Trash, light icon/list, search, hidden files | L1 |
| F11 | nested: drag of a file onto a folder moved it (sandbox), Ctrl+Z moved it back | L1 |
| F14 | nested, private bus with the bridge: File, Edit, View, Go in the bar; File > New Folder and Edit > Undo clicked with the pointer created and removed the folder (sandbox); Open With lists the selection's applications; `tests/integration/global_menus.sh` covers the same T1 path with Preview | L1 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**`) and `check-textformat.py` | L0 |
| F5 mount/eject, removable media | not testable without a removable device | L2 (owner) |

## Interfaces / contracts
- `grassfield.json` version 1 (read only): `appearance`, `accessibility.reduceMotion`; location like the shell
  (`GRASSFIELD_CONFIG_HOME` → `$XDG_CONFIG_HOME/grassfield` → `~/.config/grassfield`).
- QSettings `~/.config/Grassfield/Files.conf`: `view/mode` (icons|list|columns|gallery, anything else reads as icons),
  `view/sortKey` (0 name, 1 kind, 2 date, 3 size), `view/sortDescending`, `view/foldersFirst`, `view/showHidden`,
  `view/galleryInfo` (default true), `tags/known` (the sidebar's tags, stored names in display order, at most 64),
  `tags/hidden` (tags removed from the sidebar, at most 256).
- Extended attribute `user.xdg.tags` (F16): UTF-8 tag names separated by commas, no escaping (a comma inside a tag
  becomes a space when Files writes it); colour tags under the keys Red, Orange, Yellow, Green, Blue, Purple, Gray.
- Tag search location `grassfield-tag:/<tag>?in=<percent-encoded folder URL>` (Files-internal: history, tabs, the
  path bar and Go to Folder; never passed to KIO).
- Desktop entry `org.grassfield.Files.desktop`: `Exec=grassfield-files %U`, `Icon=org.grassfield.Files` (own icon, branding/icons/apps, hicolor),
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
  `scripts/dev/nested-up.sh` and `apps/files/build-direct.sh`; all files under `.dev/files-sandbox`; the app runs
  through `scripts/dev/isolated.sh` with its XDG homes in `.dev/isolated/files-sandbox`, so the Trash is a sandbox
  Trash, on a private dbus-daemon started by the script with the same homes and the nested Wayland socket, so KIO's
  D-Bus-activated helpers (kiod6, kpasswdserver6, kioexecd6) never run with the owner's environment; the script
  refuses to run on the owner's session bus and stops the app's and the bus's process groups on exit).
- Tags on real files: only under `.dev/` (the gtests use `GRASSFIELD_TEST_TMP`; nested evidence tags sandbox files).
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
- Tags cost one `lgetxattr` per shown item (cached per URL; 8-17 us each measured, so a screenful costs about 1 ms);
  sorting and filtering never read them. The menus ask the tag state of the whole selection on every selection change:
  measured with 1000 selected files, 41 ms (untagged) and 66 ms (tagged) per change before; now one probe pass
  (lstat, access, one lgetxattr per file, 19-28 ms) the first time and 2-3 ms from the 3 s cache (`TagStore::Cache`,
  dropped for the files Files writes; another application's change shows on the next lookup (one `lstat`, the ctime moves; two changes inside one kernel clock tick may be missed until the 3 s expire); a write always reads afresh). The tag search runs
  off the GUI thread (one `readdir` per folder, one `lgetxattr` per entry, one `lstat` per subfolder) and hands
  matches over in batches (64 items or 100 ms). Gallery previews: at most 8 gallery-size thumbnails are kept (up to
  4 MB each at 1024 px). Not measured on the reference hardware (L2).
- Names with line breaks show on one line with `⏎` in place of each break (display only).
- Accessibility: `Accessible.role/name` on every control, list item, header, banner and dialog; full keyboard
  operation; untrusted text (file names, KIO messages) is `Text.PlainText`.
- i18n: every visible string is `qsTr()` / `tr()`; plurals use singular/plural pairs (no catalogs with numerus forms).

## Names, Unicode and case (GF-105)
- Grassfield Files follows the file system: Linux is case-sensitive, so `Report.txt` and `report.txt` are two items and renaming `a` to `A` is a real rename (macOS's default volume is case-insensitive; the Sort and the folder filter ignore case, collisions do not).
- Names that differ only by Unicode normalization (NFC "e acute" and NFD "e" + combining accent) are the same name to a person, like on macOS: the folder filter folds case and accents in both forms (`FileLogic::nameMatchesFilter`), and rename, new folder, duplicate, copy, move and drop refuse to create a second entry that is an NFC/NFD twin of an existing one (`FileLogic::sameName`, `equivalentName`; an exact match is left to the conflict handling of the file operation). The file system keeps both forms apart; Files never renames an existing file to normalise it.
- Every file name shown (views, titles, Info, menus, messages, Preview, desktop icons, Dock stacks) goes through `DisplayName.text` (QML) or `FileLogic::displayName` (C++): line breaks become the return symbol and the bidi override, embedding and isolate controls (U+202A-U+202E, U+2066-U+2069) are written out as `<U+202E>`, as Finder shows them; the marks LRM and RLM stay. `tests/shell/display_names.sh` fails when a view shows a raw name (`raw-name-ok` marks one that is never shown).

## Known limitations (honest, user-visible gaps vs macOS)
- Thumbnails come from KIO's thumbnail plugins (kio-extras, installed 2026-10-17: images, PDF, video); a type without
  a plugin keeps its MIME icon. The Network place (kio-extras smb/sftp workers) lists MTP devices and SMB shares; the
  "Apple Devices" entry is hidden (§14).
- No Recents, Group By, sharing; search filters the current folder by name only.
- Tags: only the seven colour tags can be set in Files (no "Tags…" editor for named tags; tags of other applications
  are shown in Get Info and the gallery panel, kept, searchable from the sidebar and droppable onto). Tag changes are
  not part of Undo. The sidebar lists the tags seen in use, not an index of the disk: a tag no longer used stays until
  Remove from Sidebar. The tag search walks one folder tree with bounds (no global search, no live query: an item
  tagged by another application while the results are open appears after Reload). A tag written by another
  application shows once the folder is listed again (KIO's refresh does not always report attribute changes).
  Symbolic links, items in the Trash, remote items and filesystems without user extended attributes cannot be tagged
  (the row says why). Copies keep their tags (KIO copies extended attributes); a copy made by another tool may not.
- Gallery view: the info panel exists in the gallery view only (macOS shows a preview pane in every view); no quick
  actions (rotate, markup) in the panel; the preview changes in place without the macOS slide.
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

## Folder colours and Customize Folder (owner request 2026-10-19; macOS 26 model)
macOS 26 colours folders (System Settings > Appearance > Folder Color: the accent or a colour) and "Customize Folder…" gives one folder its own colour and an optional symbol or emoji drawn on it; a folder follows the global colour until it has its own. Grassfield copies that model.
- **Global**: `icons.folderColor` (`theme` = the icon theme's own folder colour, the default; `accent`; `#rrggbb`), Settings > Appearance > Folder colour (Theme, Accent, eight swatches). Applies live to every folder icon Grassfield draws: Files (icon, list, column and gallery views, the column preview, Get Info) and the desktop. Dock stacks and Search folder results do not exist today (the Dock has apps, minimized windows and the Trash; Search file rows use one generic document icon), so there is nothing to colour there; when they appear they use `FolderIcon`.
- **Per folder**: context menu "Customize Folder…" (fr « Personnaliser le dossier… »; also File menu, and a button in Get Info), a window with a live preview, Colour (Default = follow the global colour, Accent, the seven tag colours, or a typed `#rrggbb`), Symbol (30 suggestions, or any typed or pasted emoji or symbol; the field holds one grapheme cluster at all times, so the preview is what Done saves), Reset, Cancel, Done. Keyboard: Tab walks colour swatches, hex field, symbol grid (the focus ring is on the chosen symbol, else the first, as soon as it has the focus; arrows move it, Return/Space chooses, Delete clears), symbol field, Reset, Cancel, Done; Esc cancels, Return in the window applies. Several folders can be customised at once (the window starts from the first one). A folder's own colour wins over the global one; `theme` as the own colour keeps the theme's colour while a global colour is set.
- **Rendering** (`ui/Grassfield/Ui/FolderIcon.qml`, `FolderEffect.qml`, `FolderStyle.js`; separate from the icon modes of ADR-0014): a `TintedIcon` (mode unchanged) recoloured by one `MultiEffect` layer in default mode and, in an icon mode, by the icon shader itself on the artwork only (the system plate and its rim are not recoloured), with the same arithmetic (colorization 1: the luminance of the theme's folder, flap and shading, mapped onto the colour, alpha kept; tokens `folderIcon*`). No layer or effect exists for a folder without a colour (no extra cost). The colour step runs after the mode step, so Dark/Clear/Tinted still apply; in Tinted mode the folder colour wins for folders that have one, because the shader recolours the already tinted artwork (the plate and its rim keep the tint). A folder in a selected, focused row (an accent fill: Files list and column views) is drawn with `overAccent`, like every icon over an accent fill. The symbol is a `Text` over the effect inside a clipped box the size of the icon (a hostile value cannot draw outside it). Emoji are drawn opaque in their own colours (no alpha, no recolour; with an emoji font without colour glyphs the text fallback uses the shade below). A plain symbol is an engraved shade of the plate under it (macOS 26 model, `FolderStyle.glyphShade`): the plate's colour (the folder colour, or the theme's own folder colour) darkened in its hue (HSL lightness) until it reaches `folderIcon.glyphMinContrast` (3.0, gate A2 icons) plus `glyphContrastMargin` against the plate, with a 1 px light edge under it (`glyphHighlight`); a plate too dark for a darker symbol (black, very dark colours) gets a lightened shade instead. **The plate is computed from the raw icon, never grabbed from the visible one** (`FolderPlate`, `FolderStyle`; first a pass that grabbed the visible icon once per colour, size and mode, one 150 to 200 ms frame each time, so symbols popped in late and the "one frame" this spec claimed was false). A plate is a function of (icon file, size bucket, icon mode, mode tint, appearance, folder colour), and Qt's MultiEffect is arithmetic: the compiled shader's source says, on premultiplied colour c with alpha a, `c = (c - 0.5a)(1 + contrast) + 0.5a`, `c += brightness a`, `gray = dot(c, (0.299, 0.587, 0.114))`, `c = tint gray w + c (1 - w)` (w = colorization), `c = mix(gray, c, 1 + saturation)`, alpha x opacity. So the RAW icon's pixels under the symbol are read once per (icon file, size bucket 32/64/128/256: `folderIcon.plateBuckets`) as a grid of at most 12 x 12 samples (`FolderStyle.sampleBox`; a `Canvas` with `Canvas.Image`, CPU only, loads the icon by URL, draws it at the bucket size and reads back only the box under the symbol: 0 ms measured on the GUI thread, the icon's own decode is that of its provider: `image://icon` of Files is a synchronous pixmap provider, theme file URLs decode asynchronously; the read itself costs nothing on the GUI thread either way), by one `FolderIcon` at a time in the whole application (`FolderPlate.claim`), in an event-loop turn of its own and never from the visible icon or a layer. The plate of any combination is then computed from those samples (`FolderStyle.plateThrough`: the icon mode's stage (`IconModes.effect`) and then the folder colour's (`effect`) through `effectSamples`, each clamped to 8 bits like the layer, composited over the view behind a translucent Clear plate (`folderIcon.plateBackdropDark/Light`), reduced to the darkest and lightest quarter's mean, the mean hue and the luminance of the mode's own folder plate) and cached per full key (4096 entries at most), so 100 distinct folder colours, a new icon mode or a change of appearance cost 0.1 ms each and never another read. The model of the icon modes is a port of `shaders/icon.frag` (`FolderStyle.modeSamples`, `underlay`): the shader's recolouring of the artwork depends on the pixel alone (no plate or stroke analysis), so the model is its arithmetic, not an estimate. Dark darkens and slightly desaturates the folder and lifts its dark parts (the colour identity is kept), Clear makes it a flat ink whose opacity follows the folder's luminance, Tinted maps the luminance onto the two-tone ramp of the tint. The folder sits on the system plate (scaled by `iconMode.sysGlyphScale` about the centre together with the symbol) and the symbol's plate is the artwork over that system plate over the view behind it (`FolderStyle.underlay`: graphite, tinted, or the glass of Clear, light on a dark material, smoked on a light one or over the bare wallpaper, composited over the backdrop `folderIcon.plateBackdropDark/Light`); only Clear's artwork is translucent, so only there does the backdrop matter. The model is checked against the rendered pixels on a GPU scene graph (`tests/unit/tst_iconshader.qml` `test_folderModelMatchesTheShader`, run by `tests/visual/icon-a2.sh`: the Breeze folder (the WhiteSur one before 2026-10-21) and two synthetic folders, three modes, both appearances, window and wallpaper: at most 4/255 per channel; measured 1/255 at most for the WhiteSur folder and 0 for the flat ones; not re-run on the Breeze folder (test-icons is refused in the agent sandbox: NOT VERIFIED)). The folder-colour step (MultiEffect) is the arithmetic above on straight colour, exact for opaque pixels (the clamp differs from the layer's premultiplied one only where a pixel is translucent). The cache of raw reads evicts its least recently used quarter past 512 icons, so the icons on screen keep their plates. The software scene graph of the offscreen unit runner cannot draw the recolour or the shader, but the model is plain JavaScript and is tested there. Until the samples arrive (the next turns of the event loop, once per icon file) the symbol is drawn at once with the estimate of `FolderStyle.plateOf` (colour x `plateDefault` ...; calibrated on one icon theme, never used once the icon is read) and settles on the computed plate with a colour cross-fade of one motion token (`motionNormal`, at most 100 ms with Reduce Motion), no pop; an icon with no file to read keeps the estimate. An emoji is opaque and in its own colours and needs no plate.

  **One engraving rule per mode** (`FolderStyle.prefersLighter`, `glyphShade`): the shade is the plate's hue, darker or lighter than the plate until it reaches `glyphMinContrast` + `glyphContrastMargin` against the darkest plate (darker) or the lightest (lighter). Default, Dark and Clear engrave the darker shade (macOS 26: a debossed symbol; a Dark folder keeps its colour on the graphite plate); Tinted engraves the lighter shade when the mode's own folder plate (the theme's folder through the mode and the icon tint) has a relative luminance below `folderIcon.glyphLighterBelow` (0.25), darker otherwise, so the light appearance's dark tint plates take lighter symbols and the dark appearance's bright ones darker. The direction depends on the mode and its plate, never on the folder colour; a folder takes the other shade only when its plate cannot reach the contrast the preferred way (a black folder in Default, Dark, Clear and dark-appearance Tinted; the white folder in light-appearance Tinted; the accent folder in light-appearance Default, whose plate is darker than 0.115). Same colour, same mode, same appearance: same shade. Measured (nested, `tests/visual/folder-glyphs.sh` and `folder_glyph_contrast.py`, 12 folders x 4 icon modes x 2 appearances): 96/96 cells at 3:1 or more on Breeze (the base icon theme, 2026-10-21, min 3.28; the same on the former base theme) and 288/288 on the desktop and on the fallback theme (min 3.27); every symbol is drawn at the capture (the grab pass left the first captures after a change without symbol: it was still reading). Symbols per view (WhiteSur, 2026-10-20; not repeated on Breeze, only the 3:1 check was): Default and Clear in both appearances all darker except Black (and the accent folder in light-appearance Default); Tinted in light appearance all 12 lighter, in dark appearance all darker except Black; Dark lighter for 8 of 12, the pale Theme, Yellow, White and Lemon plates darker (a pale symbol on those plates would be under 3:1). Frame cost (`tests/visual/folder-glyph-perf.sh`, `qt.scenegraph.time.renderloop` per frame, nested, WhiteSur (the base theme then), 1000 folders, the first 100 with a symbol, 60 notches down and up): 1238 frames, none over 33 ms on the GUI thread or the render thread, with nothing customised, with one shared colour and with 100 distinct colours; CPU 3, 3 and 4 s (before, with the grab: 3, 3 and 5 s); the read itself, instrumented, costs 0 ms of canvas drawing and readback on the GUI thread (the icon decodes asynchronously, 11 to 45 ms in the background, once). The window's first population has frames over 33 ms in every run, nothing customised included: not attributable to folder icons.
- **Symbol rule** (`FolderStyleLogic::normalizeGlyph`, `FolderStyle.normalizeGlyph`): the first extended grapheme cluster of the trimmed text, by the whole of UAX #29 (GB3 to GB13: CR x LF, controls, Hangul L/V/T/LV/LVT, extending and spacing marks including Thai and Lao SARA AM, GB9b prepended characters, GB9c Indic conjuncts with the exact InCB=Extend class, `ExtPict Extend* ZWJ x ExtPict`, regional indicator pairs); a joiner with nothing to join is dropped; refused when over 16 UTF-16 units or when it holds a control, format (bidi marks, zero width space, ZWNJ), separator, lone surrogate or U+FFFD. Qt's own segmenter is not used (it cuts Indic conjuncts and emoji sequences differently from the standard). Both sides run one algorithm over one set of data: `scripts/dev/gen-glyph-tables.sh` reads Grapheme_Cluster_Break, Extended_Pictographic, Indic_Conjunct_Break, Emoji and the general category from the installed ICU (generation time only, no product code links ICU; ICU 78.3, Unicode 17.0 here) and writes `ui/Grassfield/Ui/GraphemeData.js` and `apps/files/src/graphemedata.inc`; `tests/shell/glyph_tables.sh` fails when they are stale and runs `scripts/dev/glyph-icu-compare.sh`, which compares `normalizeGlyph` and `isEmoji` with ICU's own grapheme segmenter on random sequences (0 differences over 3 x 100000 sequences for the C++ side and 30000 for `FolderStyle.js`); `tests/fixtures/glyph-vectors.json` (161 vectors: ZWJ sequences, flags, skin tones, keycaps, combining marks, Hangul, Indic, prepended characters, Thai and Lao AM, bidi, surrogates; the new ones answered by ICU) is read by the gtest and the QML test. Emoji or plain (`isEmoji`, both sides): the emoji selector U+FE0F, a keycap, or a character with the Emoji property (U+0080 and above: the ASCII digits, # and * have it but are text without a keycap), unless the text selector U+FE0E is present; so U+20000 (CJK) and U+1F130 (enclosed letter) are plain, a mahjong red dragon (U+1F004) is an emoji. Text-by-default emoji characters (an umbrella, a heart suit, an airplane) count as emoji without U+FE0E because this system's fonts draw them in colour (measured with Qt: the umbrella is coloured even with U+FE0E, so it stays an emoji). The heart suggestion carries U+FE0E so it stays an engraved symbol.
- **Storage** (`apps/files/src/folderstylelogic.h`, `folderstylestore.h`): the extended attribute `user.grassfield.folder` on the folder, a UTF-8 JSON object `{"v":1,"color":"#e5484d","glyph":"🎵"}`; `color` is `#rrggbb` (lower case), `accent` or `theme`, a missing `color` follows the global setting, a missing `glyph` draws nothing; unknown keys (a newer version) are kept on edit; an invalid field reads as missing; a value over 4096 bytes reads as empty and is never edited (a write is refused with a reason, a reset too: it would drop keys this version cannot read); an empty look removes the attribute. Same robustness rules as tags: only this attribute is read or written (tags and other applications' attributes are never touched); the write starts from a fresh checked read (`readAttr`) and a failed read (permission, I/O error, vanished folder, value that grows) aborts it with the system's reason; links are never followed or styled; only folders on this computer (not Trash, not remote).
- **Fallback store**: when the attribute cannot be written (a filesystem without user attributes: FAT/exFAT/NTFS, some network mounts; a read-only or immutable folder) the look is stored in the per-user file `folder-styles.json` next to `grassfield.json` (`$GRASSFIELD_CONFIG_HOME`, else `$XDG_CONFIG_HOME/grassfield`), `{"version":1,"serial":N,"folders":{"/abs/path":{"color":"#rrggbb","glyph":"x"}}}`, mode 0600, written atomically (`QSaveFile`), keyed by the cleaned absolute path (the attribute travels with the folder; the entry follows moves made in Files). The window tells the user ("Saved for your account only…"). An entry wins over the attribute (it is the user's explicit choice on this machine) and is dropped once the attribute can be written again. A store that cannot be parsed is never overwritten: writes that need it are refused with a reason, writes to the attribute still work. A reset on a folder whose attribute cannot be removed fails with the reason (the store cannot hide an attribute), but the entry saved for the account is dropped anyway and the message says so. At most 20000 entries (`kMaxFallbackEntries`): a file read with more keeps them all, a new entry is refused with a reason once full (a pruning of vanished folders starts, a later try may find room), nothing is evicted silently. Entries follow Files' renames and moves of the folder (rename, drag move, cut and paste; subfolders too), a new folder created by Files drops an old entry at its path, and entries of folders that no longer exist are pruned by a worker thread after a write (at most once a minute, or at once when a new entry finds the store full), applied at the next write: the worker resolves each entry by its canonical path, one component at a time from the root, following a symbolic link only through components on a currently mounted local disk filesystem (ext4, btrfs, xfs, f2fs, zfs, ... from `/proc/self/mountinfo`, which never touches a mount, plus `/etc/fstab`, mount points normalised so `/backup/` is `/backup`, and the `/run/media`, `/media`, `/mnt` conventions for mount points that are not mounted); every step is checked against the mount table before it is looked at, so `~/nas -> /mnt/share` (cifs) or a link that leads there through a local folder is never statted inside the share; an entry with a component on a network, FUSE or removable filesystem, under an unplugged volume or an empty fixed mount point, or whose state cannot be told is kept. Only `ENOENT`/`ENOTDIR` mean "gone" (`EACCES`, `EIO` and the rest keep the entry: a folder under a parent the user can no longer search is not pruned), an entry under a gone folder goes with it only when it is not found itself, and the worker never runs on the GUI thread. The worker owns copies of what it reads (entries, mount table) and no pointer to the store; the store's destructor cancels it, gives it 150 ms, then abandons it, so Files exits at once even when a stat is stuck in a dead hard mount (the worker ends at its next step; tests inject a fake file system and a blocking stat). Entries follow a move to the destination KIO really used: a cut-paste only for a folder the job reported as created, a move from `copyingDone` (a Rename answer in the conflict dialog gives the new name, Skip nothing). A store whose JSON would exceed 4 MiB (the reader refuses a bigger file as broken; long paths reach it before 20000 entries) is refused on write with a reason. Moves done outside Files, and undo of a Files move, are only caught by that pruning (the look is lost, never wrongly inherited by a different folder except until the next write). Error strings of the store go through `QCoreApplication::translate` (French catalog).
- **Change detection**: the model reads a folder's look once per row, lazily (only rows the views ask for; one `lgetxattr` plus a hash lookup), and drops it when KIO reports the folder changed, after a reload, or when Files writes it (`folderStylesChanged`). KIO does not report an extended attribute change, so the model also watches the shown local folder (`QFileSystemWatcher`: inotify delivers `IN_ATTRIB` of the entries to a watch on the folder; verified by the gtest `AWatchOnTheFolderSeesAnotherToolSettingTheAttributeOfAnEntry`): 200 ms after the last event of a burst, and at the latest 500 ms after its first one (`FolderStyleLogic::debounceDelay`: a change every 50 ms in the folder does not postpone it for ever), the rows whose look was read are read again (one `lgetxattr` each) and only the changed ones are announced, so a look set by `setfattr` shows in an open window without Ctrl+R (`tests/visual/folder-colours-live.sh`). Cost: none while nothing changes in the folder. `FilesApp` watches the store file (QFileSystemWatcher on its directory) and re-reads when its stamp changes (`allFolderStylesChanged`). `serial` moves on every successful write (attribute or store), so one file is the change signal for other processes. The desktop (`shell/desktop/DesktopFiles.qml`) reads its folders' attributes with one `getfattr -h -d -e hex` process per listing change (absent `getfattr`: global colour only) and watches the store file (`FileView`), re-reading when it changes; precedence entry > attribute, same as Files. An attribute written by another tool without touching the store shows on the desktop at its next listing change.
- **Interop**: KDE stores a folder's icon in `.directory` (`Icon=folder-red`, an icon *name*, a file inside the folder); GNOME stores `metadata::custom-icon` in gvfs's metadata database. Grassfield reads and writes neither: `.directory` would cost an extra file open per folder shown, and a theme icon name (Breeze has `folder-<colour>` icons) cannot express a free colour, a symbol or the accent. Folders customised by Grassfield show their colour only in Grassfield (the attribute is ignored by Dolphin/Nautilus).
- **Measurements** (gtest `FolderStyleStore.ThousandFoldersCostLittleWithoutCustomisation`, 1000 folders created under `.dev`, this machine): reading the look of all 1000 takes 26.6 ms cold (one `lgetxattr` each, nothing customised) and 16.6 ms with 100 customised; the model only does this for the rows its delegates ask for, not for the whole folder.
- Tests: `tests/unit/files/tst_folderprune.cpp` (pruning against a fake file system and mount table: a link into a share or through a local folder to one is never statted inside it, link chains and loops, only ENOENT/ENOTDIR is gone, mount points with a trailing slash, exit while a stat is blocked, the debounce max wait), `tests/unit/files/tst_folderstyle.cpp` (format, shared symbol vectors, mount table, pruning off the GUI thread and only of local entries, cap and byte limit, paste re-key, watch premise, grapheme handling, round trip, unknown keys kept, other attributes untouched, failed read aborts the write, read-only folder uses the fallback, entry yields to the attribute, corrupt store never overwritten, links/files/missing refused, reload sees another process, performance), `tests/unit/tst_foldercolors.qml` (the plate arithmetic against the measured plates, A2 and one engraving direction per mode and appearance, one read per icon file whatever the colours, setting and per-folder precedence, stored value, getfattr and store parsers, settings key, live switch of `FolderIcon`: no layer for the theme colour), `tests/unit/tst_settingsstore.qml` parity and `tests/shell/settings_roundtrip` for `icons.folderColor`. Captures: `tests/visual/folder-colours*.sh` (not regression scenarios).
- Limits: the symbol picker is a fixed set plus a text field (no emoji panel); symbols are not translated or described beyond their own glyph for screen readers; the desktop does not show a folder's look when the path contains characters `getfattr` escapes; Search and Dock stacks are not applicable yet.

## Default file manager (owner request 2026-10-20; macOS model)

macOS: the Finder is the first Dock tile, cannot be removed, and opens every folder the system opens. Grassfield Files is the same.

- **Dock:** a fixed first "Files" tile before the Apps tile (docs/specs/dock.md item 20); own icon `org.grassfield.Files` (an original green folder, `branding/icons/apps/`, installed in hicolor; Settings and Preview have `org.grassfield.Settings` / `org.grassfield.Preview`). The generic `system-file-manager` is never used as the Files icon: the theme that was the base until 2026-10-21 (WhiteSur) drew it as a Finder-like face, which is Apple trade dress; Breeze draws a filing cabinet.
- **Folders opened by the shell** (desktop double-click, Dock Trash, Search "Show in folder", Apps `revealExecutable`, any `gio open` / `xdg-open` of a folder) open in Grassfield Files in a REAL session (`GRASSFIELD_SESSION=1`, not dev), whatever the user's default handler is. `Apps.folderAware` / `AppLaunch.folderAwareArgv` rewrite `gio open T...` and `xdg-open T` into `bash shell/services/open-real.sh <opener> T...`, started through the app-scope launch path (`Apps.scoped`, uwsm-app): every folder target (a directory, a `file:` URL of one, `trash:///`) goes to one `grassfield-files` process, every other target to the opener the shell asked for (files keep the user's default handler). Without `grassfield-files` on PATH everything goes to the opener. `gtk-launch`, `gio trash` and the like are unchanged. A dev session keeps the dev open policy (ADR-0011, `scripts/dev/open-policy.sh`).
- Tests: `tests/shell/open_real.sh` (the script with fake Files, gio and xdg-open), `tests/unit/tst_applaunch.qml` (`folderAwareArgv`), `tests/unit/tst_dockmodel.qml`.
