# Visual regression and contrast (gates F1, A2; master-prompt §11 item 3)

Scope: `tests/visual/`. Reference machine only, nested dev session only, never part of `just check`
(it needs a GPU, the nested Hyprland and the installed fonts/apps of the reference machine).

## Commands

All of them must be started as **bare** commands (Claude Code sandbox exclusion; the scripts spawn
the dev scripts as child processes).

| Command | What it does |
|---|---|
| `just visual` / `tests/visual/run.sh` | Runs every scenario in `en` and `fr`, compares with `tests/visual/baselines/`, exit 1 on regression. |
| `just visual --update` | Writes **candidate** baselines to `.dev/visual/candidates/` only. |
| `just visual --determinism` | Runs everything twice and compares run 1 with run 2. |
| `just visual --only menubar,dock --lang en --keep` | Subset; `--keep` leaves the nested session up. |
| `just contrast` / `tests/visual/contrast.sh` | A2: capture 5 wallpapers x light/dark x transparency 0.25/0.6 (four glyph modes each), print the contrast table. |
| `tests/visual/scenarios/<name>.sh` | One scenario on its own (shot in `.dev/visual/shots/<name>.<lang>.png`; `VISUAL_LANG=fr`). |
| `tests/visual/ipc.sh <target> <fn> [args]` | `qs ipc --pid <.dev/shell.pid> call` against the nested shell only (refuses the owner's socket/instance). |
| `python3 -I tests/visual/test_contrast.py` | Unit tests of the contrast tooling on synthetic images (also run by `scripts/dev/test.sh`). |

`run.sh` and `contrast.sh` tear down the nested session they started on any exit (failure, Ctrl-C); a session that was
already running (`--keep`, `just nested-up`) is left alone.

## Determinism contract

`tests/visual/lib.sh` brings the nested session into a known state before every capture:

- Reference output `GF-REF`, 1920x1080, scale 1; the capture is `grim -o GF-REF` (`scripts/dev/shot.sh`).
- A **fresh shell per scenario** on a private D-Bus; `.dev/state` and `.dev/config` of the worktree are wiped
  (default settings, no notification history). The nested compositor is reused within a language.
- Frozen clock: `GRASSFIELD_FIXED_TIME=2026-10-17T09:41:00`. Dev-only (`GRASSFIELD_DEV=1`) hook in
  `shell/services/FixedTime.qml`, used by the menu bar and lock screen clocks.
- Wallpaper: the built-in artwork is static (no animation, no time of day). Dev-only override
  `GRASSFIELD_WALLPAPER_FILE=<png>` (trusted, set by dev scripts) or `qs ipc call wallpaper set <path>`
  (`shell/desktop/Wallpaper.qml`), used by the contrast run. The IPC path must be absolute, end in `.png`, `.jpg`
  or `.jpeg` and name an existing regular file of at most 64 MB (checked with `stat` before use); the image is decoded
  at most at screen size. Anything else is refused with a reason (`wallpaper status`: `idle`, `validating`,
  `applied`, `refused: <reason>`). Outside a dev session every call answers `refused`.
- Transparency 0.25, dark appearance, reduce-motion on (no animation in flight), Inter (a warning is printed
  when the family is missing), `LC_ALL=en_US.UTF-8`, language through `GRASSFIELD_LANG` (`en`, `fr`).
- Pointer parked at (24, 540) on GF-REF by `vs_park` before every capture (and waited on, 0.8 s, so hover state is
  settled). That spot is in the left margin, where no scenario surface extends: Apps grid cells start at x=200, Search,
  popups and windows are centred or anchored at the top/right, the Dock is at the bottom centre, Overview thumbnails
  start at x=395. The old spot (200, 700) was inside an Apps cell, so the tile hover highlight was a race (603 px
  between two runs). The cursor is part of the screenshot at that fixed position. (Parking on the second nested
  output would also remove the cursor, but the focus then leaves GF-REF and Search, Apps and the banners close.)
- Fixtures, so a capture carries no data of the machine it runs on (`GRASSFIELD_VISUAL_FIXTURES=1`, honoured only with
  `GRASSFIELD_DEV=1`, `shell/services/VisualFixtures.qml`): Wi-Fi "Grassfield" connected, Bluetooth on with no
  devices, volume 50 %, brightness 50 %, no keyboard backlight, no battery, no media player, user name `grassfield`
  (system menu, About, lock screen; no account picture). Actions stay behind their dev guards. The notification
  history is empty (private D-Bus, wiped state) apart from the scenario's own test notifications.
- Desktop icons from `.dev/visual/desktop/`, Files sandbox folder `.dev/visual/files-sandbox` (fixed mtimes; the
  absolute path is under the worktree, so the breadcrumb is masked), foot with `tests/visual/fixtures/foot.ini`,
  windows opened one at a time so the map order is fixed.
- Machine-dependent text (the Files breadcrumb with the user name and worktree path, free disk space) is blacked out
  (`VS_MASK`).
- Isolation: every client the suite starts (`vs_spawn`: Settings, Files, foot) runs through `scripts/dev/isolated.sh`:
  `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`, `GRASSFIELD_CONFIG_HOME` and
  `GRASSFIELD_STATE_HOME` under `.dev/` (the two Grassfield homes are the nested shell's `.dev/config` and `.dev/state`,
  so an app shows the settings the shell wrote). The visual temp files live in `.dev/visual/`, never `/tmp`.
  `tests/tools/check-isolation.py` (run by `scripts/dev/test.sh`) fails when a test or dev script starts one of these apps
  without the helper.
- Known dependency, not fixtured: the Apps page (page 1 of the installed applications), Search results and the
  Dock's launcher entries come from the machine's installed `.desktop` files, and Files uses KIO. The reference-machine
  baselines therefore show its installed applications; install or remove an app and the Apps/Search baselines change.
  Contrast regions of the Apps surface assume the current first page (Aether, Chromium, Disks, Files).

Surfaces: `menubar`, `systemmenu`, `appmenu`, `controlcenter`, `notificationcenter` (3 test notifications,
opened by a click on the clock), `dock` (magnification 1.7, pointer at x=927), `search` (query "files"), `apps`
(page 1), `overview` (4 foot windows), `lock` (never typed into; the nested instance is torn down afterwards
because a locked nested session cannot be unlocked without a password), `settings` (Appearance page), `files`,
`titlebar` (plugin titlebar of a foot window; needs `compositor/build/grassfield-compositor.so`).
Each is captured for `en` and `fr`: baseline file names are `<surface>.<lang>.png` (26 files).

## Comparison and threshold

`compare -metric AE -fuzz 2%`: a pixel counts when a channel differs by more than 2 %. Hinting and
antialiasing noise stays below that. A shot **regresses** when more than **150 px** of the 2 073 600 differ
(`VISUAL_MAX_PX` overrides; about 72 ppm). Missing baseline, size mismatch, compare error or a failed scenario also
exit 1. Red diff images are written to `.dev/visual/diffs/`.

Why 150 px (the old 500 ppm = 1 037 px would have accepted a whole Apps tile hover highlight, 603 px):

| Measured | Pixels at fuzz 2 % |
|---|---|
| Run-to-run noise, 26 shots, two full runs (after the pointer fix) | 0 for all 26 (9 px on the lock screen in the previous full run) |
| Run-to-run noise at fuzz 0 | 0-18 |
| Hover highlight of one Apps tile (the old race) | 603 |
| Selection or hover state of any row/tile/button | several hundred to thousands |

150 px is 16x the worst measured noise and 4x below the smallest state change seen, so a single hover or selection
change fails while sparse noise does not. A change smaller than 150 px (a few glyphs) is not caught by the
whole-image count; per-surface regions of interest are the next step if that matters.

Determinism criterion (`--determinism`): run 1 vs run 2 differ by at most 50 px at fuzz 2 % (`VISUAL_DET_MAX_PX`; 5x
the worst measured noise, 3x below the regression threshold). A compare error (size mismatch, unreadable file) is a
failure, never a pass.

## Baseline approval (F1)

Baselines are owner-approved and agents never commit them.

1. `just visual --update` on the reference machine.
2. Owner reviews `.dev/visual/candidates/*.png` against `design/reference/` (side-by-side, F1).
3. Owner copies the accepted files to `tests/visual/baselines/` and commits them.
4. `just visual` must then pass; a legitimate design change repeats 1-3.

## A2 contrast

`tests/visual/contrast.sh` sets, through IPC, each of 5 wallpapers (`white`, `black`, `gray`, saturated
yellow/green `noise`, 2 px `checker`; generated by `contrast.py gen`) x `light`/`dark` x transparency
`0.25`/`0.6` and captures: desktop (icon labels directly on the wallpaper), system menu, Control Center,
Search, Apps, banners, Notification Center. `tests/visual/contrast-regions.json` lists the bounding boxes
(GF-REF pixels) of known text items and icons with a kind: `text` >= 4.5:1, `large`/`icon` >= 3:1.

### Primary evidence: exact token calculation (L0)

`python3 -I tests/visual/test_contrast_tokens.py` (run by `scripts/dev/test.sh`, no compositor) is the primary evidence of
gate A2. For each text role of `tests/visual/contrast-roles.json` it composites the effective text colour (token colour x the
item's opacity) over the backdrop (material tint at alpha `1 - t * (1 - tintAlphaMin)`, with and without a fill overlay; solid
accent; the Apps dim; the desktop label shadow core) for both appearances, t in {0, 0.25, 0.4, 0.6} and 9 worst-case flat
wallpaper colours (black, white, mid-grey, red, blue, the yellow/green noise palette; the checker is black and white), and
asserts 4.5:1 (3:1 for large text and icons). The role table is cross-checked against the QML (secondary-text, text-alpha,
text-opacity and danger-colour uses per file): a new use without a role fails the test. Exempt roles are listed with a reason
(disabled controls; the Overview strip and the Apps drag ghost are outside this pass).

Tokens changed in the A2 pass, and why:

| Token | Before | After | Why |
|---|---|---|---|
| `color.dark.textSecondary` | #B8B8C0 | #C4C4CC | 2.5:1 on a white wallpaper at t = 0.6 |
| `color.light.textSecondary` | #55555D | #4A4A52 | 2.7:1 on a black wallpaper at t = 0.6 |
| `color.dark.danger` | #FF6B63 | #FFB3AD | danger text on material 2.9:1 |
| `color.light.danger` | #D93025 | #8F1E18 | danger text on material 2.6:1 |
| `material.tintAlphaMin` | 0.4 | 0.85 | tint floor: at t = 0.6 the tint was 64 % opaque, so the wallpaper decided the contrast |
| `material.bodyOpacity` | 0.85 | removed | notification body drawn at opacity 0.85 measured 4.2-4.4; the rename field backing uses `desktopIcon.renameFillOpacity` |
| `search.selectedSubtitleOpacity` | 0.8 | 0.9 | subtitle on the accent 4.2-4.4 |
| `apps.backdropOpacity` | 0.5 | 0.6 | white labels 2.8:1 on a white wallpaper |
| `apps.searchFillOpacity` | new, 0.25 | | the Apps search field is a darker inset (shadow colour) so its placeholder reaches 4.5:1 |
| `desktopIcon.labelShadowOpacity/Blur/OffsetY` | new, 1.0 / 0.22 / 0 | | desktop labels: white text, three stacked soft shadow passes; 4.8:1 measured on a white wallpaper |

Other changes: desktop labels use the always-dark palette text (white) with the accent text colour on the accent highlight
when selected; the rename error text uses the dark danger colour; the Apps "No results" text uses the primary text colour;
the search calculator badge fill dropped from 2x to 1x fill opacity. The frosted look keeps its default (t = 0.25: tint alpha
0.96 instead of 0.90); only the high-transparency end of the slider is less transparent.

### Method: glyph mask

Taking a box median as the backdrop and the extreme pixels as the glyph (the first method) is unsound on textured
wallpapers: it picks wallpaper black and white instead of glyphs and gave false passes of 12.7-17.2 for desktop
labels on the checker. The measurement now separates glyphs from backdrop exactly:

1. Every surface is captured four times in the same state, switching only the glyph colour through the dev-only
   IPC `qs ipc call visual glyphs <mode>` (`shell/services/VisualFixtures.qml`; `Appearance.devGlyphMode`; refused
   outside `GRASSFIELD_DEV=1`). It replaces the text and icon colours (`text`, `textSecondary`, `accentText`, and so
   every label, icon and caret that uses them) and nothing else: material, outlines and shadows around text stay.
   `normal` (A) is the real rendering, `hidden` (B) makes the glyphs transparent (the exact backdrop, label shadow
   included), `white` (W) and `black` (K) paint them pure white/black.
2. Coverage per pixel: `W = a*255 + (1-a)*B` and `K = (1-a)*B`, so `a = (W - K) / 255` exactly, whatever the backdrop
   (an object that does not follow the glyph colour has `W = K` and `a = 0`). Glyph pixels are those with `a >= 0.5`.
   An invisible glyph (white on white) is still found, because W and K differ.
3. The true glyph colour of a pixel is `c = (A - (1-a)*B) / a`. Its WCAG ratio is taken against the local backdrop:
   the mean linear luminance of B in the 5x5 window around the pixel (the eye averages a 2 px texture).
4. The cell value is the 5th percentile of the ratios of the box's glyph pixels: the worst case, not a median. A box
   with no glyph pixel is reported as `NO GLYPH` (box misplaced) and fails the run; image icons (the desktop file-type
   icons, marked `"image": true`) are not colour-driven and are skipped, listed in the summary.

`tests/visual/test_contrast.py` checks the tooling on synthetic images: raw-RGB reading gives exactly w x h pixels for an
80x13 box (the old txt parser counted every non-named pixel twice, n=1514 instead of 1040), black text on white
scores 21, 60 % covered black on white still scores 21 (true glyph colour), gray 118 on white scores 4.54, white on
white scores 1, white text on a 1 px checker scores about 1.9 (the old method read about 21).

## Results (reference machine, 2026-10-17)

Determinism, two full runs (26 shots, `just visual --determinism`): PASS. Every shot is identical at fuzz 2 % (0 px);
at fuzz 0 the shots differ by 0-18 px (sparse gradient/caret noise; the first scenario of a fresh session is the
noisiest). Limit 50 px.

A2 (`just contrast`, glyph-mask method, exit 1): 900 cells = 45 regions x 20 combinations; 860 measured, 40 skipped
(2 image icons x 20), 0 boxes without glyph; **677 PASS, 183 FAIL**. These are findings, not tool errors. Failing cells
by region (of 20, minimum ratio):

- Search selected row subtitle (dark text on the accent green): 20/20 at 3.9-4.2.
- Control Center "Display" label 14/20 (min 1.74) and "Appearance" value 13/20 (min 1.73); "Airplane Mode" 3/20 (min 3.17).
- Apps search placeholder 14/20 (min 1.32); Apps icon labels (always white text, backdrop dimmed by a fixed
  `appsBackdropOpacity`): Chromium 8, Disks 8, Aether 4, Files 4 of 20 (min 2.76-3.25), on white and noise wallpapers.
- Desktop icon labels directly on the wallpaper (text colour follows the appearance; the outline is faint): 12/20 each,
  min 1.02: white text on the white or light-gray wallpaper in dark appearance, black on black in light appearance,
  and both on the noise and checker wallpapers.
- Search section headers "Top Hit" 8, "Applications" 6, Neovim subtitle 8 (min 1.94-2.07); query 2; Neovim title 1.
- Banner time label 5/20 (min 2.73); Notification Center "Clear All" 2/20 (min 3.40), group/item text 1/20 each (3.3-4.2).
- Menu bar app name, clock, system menu items and Control Center labels fail only in the white/dark/0.6 corner
  (3.2-4.5), banner titles/body 1/20 (3.9-4.0).
- Menu bar status icons (min 4.5), page dots (min 4.3), the selected-row title and the Control Center title pass.

Compared with the first (median/extremes) method the desktop labels on the checker no longer show false passes of
12.7-17.2: they read 1.6-1.9 (white text on the checker) in dark appearance. The full matrix is
`.dev/visual/contrast/contrast.csv`. Tiny boxes (9 px sublabels) are the least reliable cells. No UI colour was changed
for this report; the fixes come with a later pass.

## Limitations

- Nested rendering (Hyprland inside the owner's session, headless GF-REF) is not real DRM output: blur,
  color management, cursor and timing can differ. F1 still needs the owner's sign-off on real hardware.
- Reference machine only: the Apps page, Search results and Dock depend on installed applications (not fixtured, see
  the determinism contract), the fonts on installed families, Files on KIO. A different machine needs its own
  baselines.
- Sparse single-pixel noise (gradient rounding, text caret) exists between runs; the 2 % fuzz absorbs most of it.
- A whole-image pixel count cannot see a change smaller than 150 px; per-surface regions would.
- The glyph mask recolours `Appearance.colors.text`, `textSecondary` and `accentText` (and the Apps surface's
  `Appearance.darkColors` text colours). Text or icons that use another colour are not recoloured (their W and K
  captures are equal, coverage 0): they are not measured, and a box containing only such items reports `NO GLYPH`.
  Image icons (file-type icons on the desktop) are skipped. Caret blink between the four captures of one surface can
  add or drop a few glyph pixels. The four captures of the banners must fit in the banners' on-screen time (14 s).
- Boxes are fixed pixel rectangles: re-measure them when a layout changes (the Apps boxes also follow the installed
  application list).
- The lock screen is only checked at rest (no password entry, no error states).
