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
  (`shell/desktop/Wallpaper.qml`), used by the contrast run; the accepted path is kept in `VisualFixtures.wallpaperFile`
  (always empty outside dev), which the desktop and the lock screen backdrop both draw. The IPC path must be absolute, end in `.png`, `.jpg`
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

Contrast surfaces of the Dock (`contrast.sh --surfaces dock,dockdrag`, captured last in each combination with two foot windows
`gfdockA`/`gfdockB` that are closed again): `dock` (running dots, the tooltip capsule of the hovered tile, the notification
badge count) and `dockdrag` (the "Remove" capsule while the pinned foot tile is dragged up; it is brought back to its slot
before the release, so nothing is removed). The dot follows the appearance (white in dark, black in light) over a shelf tint
alpha per appearance (`dock.tintAlphaDark/Light`), 3:1 or more over any backdrop (computed in `tst_bartone.qml`, measured by
`contrast.sh` and `tests/visual/dock-backdrop.sh` with a white and a black window under an autohidden shelf).

Surfaces: `menubar`, `systemmenu`, `appmenu`, `controlcenter` (Quick Settings modules), `controlcenter-detail` (the Wi-Fi
module opened by a click on its text), `notificationcenter` (2 test notifications on a cleared history, the floating column,
opened by a click on the clock) with `notificationcenterhover` (pointer on the first card: its x and the group x) and
`notificationcenterclear` (pointer on the group x: the "Clear All" pill), `dock` (magnification 1.7, pointer at x=927), `search` (query "files"), `apps`
(page 1), `overview` (4 foot windows), `lock` (never typed into; the nested instance is torn down afterwards
because a locked nested session cannot be unlocked without a password; in dev the lock shows "dev: password checks
disabled" under the field: PAM is suppressed unless `GRASSFIELD_DEV_ALLOW_PAM=1`, which no automated test sets, see
docs/specs/security.md "Test safety"), `settings` (Appearance page), `files`,
`titlebar` (plugin titlebar of a foot window; needs `compositor/build/grassfield-compositor.so`).
Each is captured for `en` and `fr`: baseline file names are `<surface>.<lang>.png` (28 files).

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

## Reference screenshots (F1, owner-provided)

The owner captures macOS 27 on a real Mac and drops the files in `design/reference/` (git-ignored: never committed,
never packaged, never used as an asset; measurement data only). Default appearance settings (accent, text size,
"Reduce transparency" off), a plain wallpaper, no third-party menu bar items. Name files
`<surface>-<light|dark>[-<variant>].png` and add `design/reference/scale.txt` with the display's scale (e.g. `2`).
Light and dark for each item when possible:

| Surface | What to capture |
|---|---|
| `menubar` | menu bar at rest; `menubar-appmenu`: an app menu open; `menubar-system`: the Apple menu open |
| `dock` | Dock with 6–8 apps, running indicators, one folder stack; `dock-hover`: magnification off, tooltip shown |
| `titlebar` | a Finder window, active and inactive (`-inactive`), traffic lights at rest and hovered (`-hover`) |
| `quicksettings` | Control Center open; `quicksettings-module`: one module expanded (Wi-Fi or Display) |
| `notifications` | one banner; Notification Center open with 3 notifications and widgets |
| `search` | Spotlight empty; with a query and results |
| `overview` | Mission Control with 4–6 windows and the Spaces bar |
| `apps` | the Apps view (floating panel with category chips; macOS 26/27) |
| `desktop` | desktop with 4 icons, one selected; `desktop-menu`: its context menu |
| `widgets` | desktop widgets small/medium/large; the widget gallery |
| `lock` | lock screen at rest (no password typed) |
| `stages` | Stage Manager with 3 stages |
| `files` | Finder list, icon and gallery views; the sidebar with tags |
| `glance` | Quick Look on an image and on a PDF |
| `preview` | Preview with a PDF and the sidebar |
| `settings` | System Settings: General, Wi-Fi, Bluetooth, Sound, Displays, Desktop & Dock, Notifications |
| `osd` | volume and brightness indicators |

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
Search, Apps, banners, Notification Center and, last, the lock screen. `tests/visual/contrast-regions.json` lists the bounding boxes
(GF-REF pixels) of known text items and icons with a kind: `text` >= 4.5:1, `large`/`icon` >= 3:1.

Lock screen: the session is locked once, after every other surface, through the same IPC as `scenarios/lock.sh` (`lock lock`;
nothing is ever typed: the PAM service is the owner's real account). Wallpaper, appearance and transparency are then set through
IPC for each of the 20 combinations (they reach the shell while it is locked; the lock backdrop draws the dev wallpaper override,
`VisualFixtures.wallpaperFile`, like the desktop) and the lock is captured in the four glyph modes. `lock status` must still say
`locked` after each capture. The nested session is torn down at the end, also when it was already running. Measured at rest: date,
clock, initials, user name and placeholder; the error and notice lines, typed dots, caret, return arrow (shown once something is
typed) and the focus ring are covered by the token calculation only.

### Primary evidence: exact token calculation (L0)

`python3 -I tests/visual/test_contrast_tokens.py` (run by `scripts/dev/test.sh`, no compositor) is the primary evidence of
gate A2. For each text role of `tests/visual/contrast-roles.json` it composites the effective text colour (token colour x the
item's opacity) over the backdrop (material tint at `Appearance.tintAlpha(t)`: linear from 1 to `tintAlphaMin` 0.4, clamped to
`tintAlphaClamp` 0.82 up to t = 0.6, with and without a fill overlay; solid
accent; the Apps dim; the desktop label shadow core; the lock scrim, alone or with the lock's password field, avatar disc or
return arrow disc) for both appearances, t in {0, 0.25, 0.4, 0.6} and 9 worst-case flat
wallpaper colours (black, white, mid-grey, red, blue, the yellow/green noise palette; the checker is black and white), and
asserts 4.5:1 (3:1 for large text and icons). The role table is cross-checked against the QML by a structural scan
(`tests/visual/qml_scan.py`: palette aliases, `colors["textSecondary"]`, an opacity on any ancestor, one-line items,
`Qt.darker/lighter/alpha/tint/rgba`, `opacity :`, computed palette keys; inside `shell/security/` every palette read, primary
text and backdrop colours included, however it is spelled (`root.colors.text`, `colors.shadow`, `Tokens.colorDark.shadow`); one
self-test sample per form, each must fail the check): a new use without a role fails the test. Exempt roles are listed with a
reason (disabled controls, fades whose steady state is opacity 1, the idle dim layer, which draws no text, the Overview strip
(known limitation in `docs/specs/overview.md`) and the Apps drag ghost). The lock roles are asserted, must be identical in both
appearances and at every transparency (the lock uses the dark palette and no material), and their model is checked against the
`LockView.qml`/`PasswordField.qml` lines it mirrors.
The desktop-label rows are a ceiling (white on the opaque shadow core, 19:1), not a bound: the rendered contrast of those labels is
measured by `contrast.sh --surfaces desktop` (glyph mask).

Tokens changed in the A2 pass, and why:

| Token | Before | After | Why |
|---|---|---|---|
| `color.dark.textSecondary` | #B8B8C0 | #DCDCE4 | 2.5:1 on a white wallpaper at t = 0.6 |
| `color.light.textSecondary` | #55555D | #3A3A42 | 2.7:1 on a black wallpaper at t = 0.6 |
| `color.dark.danger` | #FF6B63 | #FFD3CF | danger text on material 2.9:1 |
| `color.light.danger` | #D93025 | #7A1812 | danger text on material 2.6:1 |
| `material.tintAlphaMin` | 0.4 | 0.4 (kept) | the frosted look: tint 0.85 at the default t = 0.25 |
| `material.tintAlphaClamp` / `tintClampUntil` | new | 0.82 / 0.6 | the tint never drops below 0.82 for t <= 0.6 (at t = 0.6 it was 0.64 and the wallpaper decided the contrast); text colours carry the rest |
| `material.bodyOpacity` | 0.85 | removed | notification body drawn at opacity 0.85 measured 4.2-4.4; the rename field backing uses `desktopIcon.renameFillOpacity` |
| `search.selectedSubtitleOpacity` | 0.8 | 0.9 | subtitle on the accent 4.2-4.4 |
| `apps.backdropOpacity` | 0.5 | 0.6 | white labels 2.8:1 on a white wallpaper |
| `apps.searchFillOpacity` | new, 0.25 | | the Apps search field is a darker inset (shadow colour) so its placeholder reaches 4.5:1 |
| `desktopIcon.labelShadowOpacity/Blur/OffsetY` | new, 1.0 / 0.22 / 0 | | desktop labels: white text, three stacked soft shadow passes; 4.8:1 measured on a white wallpaper |
| `lock.dimOpacity` | 0.28 | 0.6 | lock clock 1.83:1 on a white wallpaper; white text on the scrim now 5.27:1 over any wallpaper |
| `lock.fieldFillOpacity` | 0.22 (white fill) | 0.45 (shadow colour) | placeholder 1.41:1 on a white wallpaper; the field is a dark frosted inset: placeholder (`textSecondary`) 8.59:1, dots and caret 10.75:1, return arrow 3.12:1 when hovered |
| `lock.avatarFillOpacity` | 0.3 | 0.2 | initials 2.7:1 on a white wallpaper, now 3.41:1 (large text) |
| `lock.focusRingOpacity` | new (was material.highlightOpacity x 2 = 0.44) | 0.7 | the field's focus ring 3.51:1 against the scrim |
| `lock.textShadowOpacity/Blur/OffsetY` | new, 0.4 / 0.5 / 1 | | macOS-like soft shadow under the lock text; decoration only (the scrim carries the contrast) |

Other changes: desktop labels use the always-dark palette text (white) with the accent text colour on the accent highlight
when selected; the rename error text uses the dark danger colour; the Apps "No results" text uses the primary text colour;
the search calculator badge fill dropped from 2x to 1x fill opacity. The frosted look keeps its default (t = 0.25: tint alpha
0.85, as before the A2 pass). A first A2 attempt raised the tint floor to 0.85 (0.9625 at the default, 0.91 at 0.6), which
made the material nearly opaque; it was reverted in favour of lighter and darker text colours and a clamp that only acts at high
transparency.

Tint alpha per transparency (`Appearance.tintAlpha`): t = 0 -> 1.00, 0.25 -> 0.85, 0.4 -> 0.82 (clamped, linear 0.76), 0.6 -> 0.82
(clamped, linear 0.64), 1 -> 0.40; between 0.6 and 1 it falls linearly from 0.82 to 0.4.

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
3. The item's own opacity `o` is the largest coverage found in the box (measured, never declared). Glyph pixels are those
   covered at least 0.85 `o` in every colour channel (0.7 or 0.5 when thin text has fewer than 4 such pixels: the text
   renderer's gamma makes half covered edge pixels unreliable). The colour a fully covered pixel has is
   `e = B + o * (A - B) / a` per channel (rendered pixels A and B only, opacity included). Its WCAG ratio is taken against
   the local backdrop: the mean linear luminance of B in the 5x5 window around the pixel.
4. The cell value is the 5th percentile of the ratios of the box's glyph pixels: the worst case, not a median. A box with no
   glyph is reported as `NO GLYPH` and fails the run; image icons (the desktop file-type icons, `"image": true`) are not
   colour-driven and are skipped, listed in the summary. `contrast.sh --surfaces desktop,search` limits a run.

`tests/visual/test_contrast.py` checks the tooling on synthetic images: raw-RGB reading gives exactly w x h pixels for an
80x13 box (the old txt parser counted every non-named pixel twice, n=1514 instead of 1040), black text on white
scores 21, a Text item at opacity 0.6 scores its rendered gray 102 (about 5.7), gray 118 at opacity 0.5 scores about 1.9 where its declared colour scored 4.54, a sub-pixel fringe is read exactly, gray 118 on white scores 4.54, white on
white scores 1, white text on a 1 px checker scores about 1.9 (the old method read about 21).

## Results (reference machine, 2026-10-17)

Determinism, two full runs (26 shots, `just visual --determinism`): PASS. Every shot is identical at fuzz 2 % (0 px);
at fuzz 0 the shots differ by 0-18 px (sparse gradient/caret noise; the first scenario of a fresh session is the
noisiest). Limit 50 px.

A2, screenshots (`tests/visual/contrast.sh`, exit 0, after the token pass): 860 cells measured (45 regions x 20
combinations, less 40 skipped image icons), **860 PASS, 0 FAIL, 0 boxes without a glyph, 0 missing captures**. Per-region
minimum over the 20 combinations: desktop icon labels 4.8-5.2 (white wallpaper is the worst case), menu bar and system menu
11.1-12.0 (status icons 10.8), Control Center 5.5 ("Display" label, "Appearance" value) to 12.6, Search 4.8 (selected row
subtitle) to 11.5, Search section headers 6.4-6.5, banners 6.6 (time) to 12.5, Notification Center 7.9 ("Clear All") to 12.4,
Apps labels 5.0-5.1, Apps placeholder 4.7, page dots 6.2. Before the pass the same run had 183 FAIL (min 1.02). The first
full run after the fixes found 7 "no glyph" cells (Search not shown on GF-REF in the very first combination): the run now
retries the open, checks the state and the pixels, and fails otherwise.

Lock screen added to the run (2026-10-18, `tests/visual/contrast.sh`, exit 0): **960 cells, 960 PASS, 0 FAIL**, 0 boxes without
a glyph, 0 missing captures, 40 skipped image icons (the 860 cells above plus 5 lock regions x 20 combinations). Lock minimum
over the 20 combinations (white wallpaper is the worst case; identical in both appearances and at both transparencies): date 5.0,
user name 5.0, clock 5.2, initials 3.4, placeholder 8.5 (token calculation: 5.27, 5.27, 5.27, 3.41, 8.59). The same run's lock
captures, taken after banners and Notification Center notifications were posted in that session, show no notification content
(gate L4). Before the change the token calculation gave 1.83 (clock) and 1.41 (placeholder) on a white wallpaper.

Method change of the third fix: the glyph colour is measured from the rendered pixels (see "Method" below), so the opacity of
a Text item counts (the banner body at opacity 0.85 used to pass by its declared colour). Surfaces are asserted open before
they are measured: `search`/`apps` by IPC state and a pixel difference from the bare desktop (up to three attempts), banners
and the Notification Center by `notifications status` (the center is toggled by a clock click and read back, three attempts),
the system menu and Control Center by a pixel difference. The shell is restarted once GF-REF exists (`vs_wait_output` in
`lib.sh`), so the desktop icons are always there. A box without a glyph, or a surface without captures, fails the run.

## Limitations

- Nested rendering (Hyprland inside the owner's session, headless GF-REF) is not real DRM output: blur,
  color management, cursor and timing can differ. F1 still needs the owner's sign-off on real hardware.
- Reference machine only: the Apps page, Search results and Dock depend on installed applications (not fixtured, see
  the determinism contract), the fonts on installed families, Files on KIO. A different machine needs its own
  baselines.
- Sparse single-pixel noise (gradient rounding, text caret) exists between runs; the 2 % fuzz absorbs most of it.
- A whole-image pixel count cannot see a change smaller than 150 px; per-surface regions would.
- The glyph mask recolours `Appearance.colors.text`, `textSecondary` and `accentText` (and the `Appearance.darkColors` text
  colours of the Apps surface and the lock screen). Text or icons that use another colour are not recoloured (their W and K
  captures are equal, coverage 0): they are not measured, and a box containing only such items reports `NO GLYPH`.
  Image icons (file-type icons on the desktop) are skipped. Caret blink between the four captures of one surface can
  add or drop a few glyph pixels. The four captures of the banners must fit in the banners' on-screen time (14 s).
- Boxes are fixed pixel rectangles: re-measure them when a layout changes (the Apps boxes also follow the installed
  application list).
- The lock screen is only captured at rest (no password entry, no error states): the error and notice lines, typed dots, caret,
  return arrow and focus ring rest on the token calculation. The caret blinks between the four captures: the placeholder box
  starts right of it. The lock's text shadow vanishes with the glyphs in the hidden capture, so the measured backdrop is the scrim
  without the shadow (conservative).
