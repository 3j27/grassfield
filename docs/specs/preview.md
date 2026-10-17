# Preview + Glance spec · apps-engineer · M4

## macOS reference behavior (described in words)
- Preview is one window with a toolbar (sidebar toggle, zoom out/in, fit, rotate, page navigation, search), a
  sidebar (page thumbnails of a document, the list of files when several were opened) and the document. The title is
  the file name. Zoom, rotation and page are properties of the view only.
- Quick Look is a small floating panel that shows the selected file at once: Space opens it, Space or Esc closes it,
  the arrow keys move between the selected files, a button hands the file to the full viewer.

## Purpose and non-goals
View files without editing them. The viewer is "Preview" (code `grassfield-preview`, app id
`org.grassfield.Preview`); the quick look is called "Glance" (app id `org.grassfield.Preview.Glance`; never the Apple
name). Non-goals for v1 (Known limitations): Export, annotations, markup, forms, editing, printing, encrypted PDF,
network streams, image adjustments, HEIC unless a Qt plugin is installed, syntax highlighting, Glance as a persistent
single instance.

## Behavior
1. P1 Command line: `grassfield-preview [--glance] [--] <path-or-file-url>…`. Arguments are validated in
   `src/previewlogic.cpp`: a path (relative ones against the current directory) or a `file:` URL (empty host or
   `localhost`, no query or fragment). Any other scheme (`http`, `ftp`, `smb`, `data`…), a remote file host, a
   directory, a device, a FIFO or a missing file is refused with one message on stderr and in the window. At most 200
   files, duplicates removed.
2. P2 Window (`qml/Viewer.qml`): toolbar with Sidebar, zoom out, zoom label, zoom in, Fit, Rotate, previous/next page
   and a search field (PDF); title = file name; opaque; light/dark and Reduce Motion follow `grassfield.json` (read
   only, watched). The sidebar lists the files when more than one was given and the page thumbnails of a PDF.
3. P3 Images (`ImageView.qml`): any format Qt can decode (`qt6-imageformats`, SVG through `qt6-svg`); fit (shrinks
   only) or zoom (0.05 to 16, Ctrl+wheel, pinch, + / - / 0 for 100 %, Ctrl+9 for Fit); rotation by quarter turns
   (Ctrl+R / Ctrl+L, view only); EXIF orientation applied; multi-page TIFF steps through pages (PgUp/PgDn, toolbar);
   animated GIF and WebP play through `AnimatedImage`. Decoding goes through `image://preview/<frame>/<file index>`.
4. P4 PDF (`PdfView.qml`): QtPdf (`PdfMultiPageView`, pdfium, no JavaScript): continuous pages, zoom, fit to width,
   rotation, page navigation (PgUp/PgDn, Home/End, arrows turn pages, toolbar), thumbnails, text search (Ctrl+F,
   Enter next, Shift+Enter previous, Esc closes). Encrypted documents show a notice ("not supported yet").
5. P5 Text and code (`TextView.qml`): read only, monospace, always `PlainText` (never markup), selectable; zoom
   scales the font. Files over 2 MiB show "This file is too large to preview"; files with NUL bytes in the first 8 KB
   show "This file is not text". Decoded as UTF-8. Playlists (M3U, PLS, XSPF, WPL, every ASX suffix: asx, wax, wvx,
   wmx) are text, never handed to the player and never followed or fetched: decided by the canonical MIME type,
   its aliases and ancestors, the suffix, and the first 512 bytes (extensionless files).
6. P6 Audio and video (`MediaView.qml`): QtMultimedia `MediaPlayer`, only the local `file:` URL of a validated file;
   play/pause (button, Space in the viewer), a position slider, elapsed and total time. Glance starts playing at
   once. A decode failure shows the player's message.
7. P7 Glance (`qml/Glance.qml`): same binary with `--glance`. A normal toplevel with app id
   `org.grassfield.Preview.Glance`, sized for the content of the first file (image: native size capped at 70 % of the
   screen; PDF, text, video and audio fixed token sizes), header with the file name, "n of N" and "Open with Preview".
   Space, Esc and Ctrl+W close it; Left/Right move through the files (wrapping, fitted into the same window);
   + / - / 0 zoom; Ctrl+O or the button opens the full viewer (`grassfield-preview -- <files>`, detached) and quits.
   The Hyprland rule `gf-glance` (`config/hypr/grassfield/windows.lua`) floats and centers it and sets
   `decorate = false` so the compositor plugin draws no titlebar.
8. P8 Triggers: Files (Space, item menu "Glance at …", `docs/specs/files.md` F12) and desktop icons (Space toggles
   it, `docs/specs/desktop.md`; OFF in desktop keyboard safe mode, back with the macOS-model redesign). There is no single-instance logic in the app: a second launch is a second window.
   (Off in safe mode.) The desktop toggles through `shell/services/GlanceApp.qml`, which owns the process and closes it when Space is
   pressed again (a layer surface keeps the keyboard focus when a window maps, so the Glance cannot always close
   itself there: click it to use the arrow keys).
9. P9 Untrusted input: only local regular files; `QImageReader::setAllocationLimit(256)` for every decoder (also QML
   `Image`/`AnimatedImage`); images over 16384 px per side or 256 MiB at 4 bytes per pixel are refused before decoding
   with a notice; PNG headers are sniffed so that a huge image gets the right message; the file is never opened for
   writing and never executed; no network access; text is `PlainText`.

## Acceptance criteria
| ID | Test | Level |
|---|---|---|
| P1 URL validation, P9 size caps, P5 caps, routing by type | `tests/unit/preview/tst_previewlogic.cpp` (gtest, 9 tests, run by `scripts/dev/test.sh`) | L0 |
| lint | `scripts/dev/qmllint.sh` (covers `apps/**`) and `check-textformat.py` | L0 |
| config | `Hyprland --verify-config` for `dev.lua` and `session.lua` with `GRASSFIELD_CONFIG_DIR` | L0 |
| P2-P7 | nested screenshots: image + zoom, multi-page TIFF, GIF, PDF with thumbnails, text, binary and 3 MB text notices, video, audio, Glance from Files and from a desktop icon, multi-file Glance, light and dark | L1 |
| P9 | nested: 50000 x 50000 PNG header shows the "too large" notice (RSS stays near 160 MB), `http://` and `file://host/` arguments refused | L1 |
| Encrypted PDF, HEIC, real audio output, compositor titlebar skip (`decorate = false`) | not testable here (no encrypted sample, no HEIC plugin, plugin not loaded in nested) | L2 (owner) |

## Interfaces / contracts
- Desktop entry `org.grassfield.Preview.desktop`: `Exec=grassfield-preview %U`, MIME types of the common image, PDF,
  text, video and audio formats. Glance has no desktop entry.
- Environment: `GRASSFIELD_PREVIEW_QML` (dev QML dir), `GRASSFIELD_PREVIEW_CMD` (callers: program and arguments of
  the dev build; `--glance` in it is ignored), `GRASSFIELD_CONFIG_HOME` (appearance file), `QT_QUICK_CONTROLS_STYLE`
  (default Basic, for QtPdf's views).
- Tokens: `preview.*` group of `ui/tokens/tokens.json`, plus `typography.monoFamily`.

## Dependencies (verified 2026-10-17)
Qt 6.11.2 (Core, Gui, Qml, Quick; runtime QML modules QtQuick.Pdf from `qt6-webengine`, QtMultimedia from
`qt6-multimedia`, image plugins from `qt6-imageformats`/`qt6-svg`), gtest (tests only). No new package in the repo
environment. Build: `apps/preview/build-direct.sh` (g++), `CMakeLists.txt` for the package (not built here, cmake
is not installed).

## Known limitations
- Read only: no Export, annotations, page editing or printing.
- Toolbar buttons are text (no zoom/rotate icons in the design system yet).
- The PDF page view does not scroll by arrow keys (it is a TableView): arrows turn pages, wheel scrolls.
- A Glance is sized once, for its first file; later files of a multi-file Glance are fitted into that window.
- Glance opened from the desktop (OFF in desktop keyboard safe mode, back with the macOS-model redesign) does not
  take the keyboard focus (layer-shell on-demand focus): Space on the desktop closes it; click it before using
  the arrow keys.
- libtiff prints "foo: Not a TIFF or MDI file" to stderr while Qt probes multi-page TIFF; harmless.
