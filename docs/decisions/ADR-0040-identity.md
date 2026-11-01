# ADR-0040: Grassfield identity: wallpapers, brand, lock screen and session transitions
Status: Accepted (the owner answered the twelve questions and B-5 on 2026-10-29: "Owner decisions (2026-10-29)", with the
integrator's conditions for the four non-recommended choices, W1 C, W2 C, W3 A and L1 C). Step 0 merged (pull request
#46, e16fa8c), steps 1a, 1b and 1c merged (pull requests #52 a5488a6, #55 12bcda9, #69 837dd2b); the owner's brand green
and warm neutrals of 2026-10-30 under way. Every other choice follows the owner's rule of 2026-10-28 ("the closest to
macOS 27, no technical step for the end user") and is listed in "Decisions taken under the owner's rule" (ID-1 to ID-21), which the
owner can revisit. Revised after the integrator's opus review of
b44d17e (FAIL: two MAJORs, five MINORs) and again after the re-review of ed21d46 (FAIL: one MAJOR, one MINOR, two
NITs), and after the review of step 1a's 6c310a8 (FAIL: one MAJOR, one MINOR, three NITs), answered in "Review
history"; each changed place says which review. · Date: 2026-10-29 · Decider: owner (IQ), integrator (merge; ID under the rule) · Number: 0040
(0039 is the design-polish ADR, pull request #45, merged as e03c859; the open pull requests #47 and #48 add none)

This ADR proposes one identity for Grassfield across its wallpapers, its brand (mark, name, accent, About, app icons),
its lock screen and every session transition. The audit it rests on is `docs/audits/identity-2026-10-29/audit.md`
(findings W-1 to W-12, B-1 to B-12, L-1 to L-7, T-1 to T-17, with file and line). The mockups are SVG files in
`docs/audits/identity-2026-10-29/mockups/`, written by `mockups.py` next to them; they are design documents, never
shipped. Legal points are marked "needs legal review" (master-prompt §14); none is a conclusion.

**Read with ADR-0039 (design polish, merged as e03c859, the owner's answers of 2026-10-29 recorded there).** That ADR
sets one grammar for materials, controls, windows and accessibility settings; this one covers what makes Grassfield
recognisable and how it appears. The nine places where they meet have one owner each: the table "Coordination with
ADR-0039" below repeats ADR-0039's own, unchanged. ADR-0039 merged first, so this ADR is the one that follows it: its
D-Q4 (switches and slider fills on the selection fill, as macOS 27) and D-Q1 (sheet buttons measured on macOS 27) hold,
and IQ-B3 here changes the palette only, not which controls read it.

## Context

### The owner's brief (2026-10-29)
- One pull request per step towards main. Step 0: an audit and a proposal, no code, on the wallpapers (the shipped
  collection, the default, light and dark, videos; ADR-0016), the brand (logo, name, accent colour, the About screen,
  the icons of Grassfield's apps), and the lock screen with every transition: boot, login, logout, sleep, wake,
  restart, desktop loading. **Nothing may flicker or jump; everything appears once, in its place.**
- An "identity" ADR with concrete proposals (SVG or QML mockups, no Apple material) and the owner's questions, each with
  two or three options, their pros and cons, and a recommendation. Plus STATE.

### Rules this ADR works under
- **The Grassfield logo is the owner's mark, all rights reserved (decision of 2026-10-27).** Nothing here changes it:
  every mockup uses the path of `branding/icons/symbolic/grassfield-logo.svg` unchanged, and the proposals concern only
  where it appears and in which colour, which the owner decides (IQ-B1, IQ-B2). This ADR calls it "the Grassfield mark".
  **2026-10-30: the owner replaced the drawing** with a new mark of their own, an AI-assisted concept
  (`branding/concepts/grassfields-original-refined/`) redrawn as SVG in the proposed brand kit (`branding/brandkit-proposal/`,
  1342d2d9); its final adoption and legal clearance are the owner's, pending (`docs/legal/visual-review.md` E33). It now
  lives in two files on the 24 grid: `grassfield-logo-full.svg`, the full mark, unchanged, for 32 px and more (the brand
  kit, the website, future large About surfaces; no shell or app surface draws it today, and `tests/unit/tst_visualaudit.qml`
  keeps it loadable), and `grassfield-logo.svg`, its optical version for 16-24 px (the same blades over the same base, fewer
  and wider gaps), which every place listed under IQ-B1 draws at run time (14-25 px). The step 0 mockups show the old
  drawing (a grass tuft); they are dated design documents and were not redrawn.
  **2026-10-31: the owner replaced the drawing again** (« Je pars sur le B »): direction B, "Deux reliefs", of the v6
  directions drawn from four reference images the owner shared (`branding/concepts/grassfield-sommet-v6/`: a summit drawn
  as a band of constant width and a nearer relief as a filled shape, parted by one parallel channel; geometric, filled,
  no letter). The same two files carry it: `grassfield-logo-full.svg` is B's drawing (for 32 px and more) and
  `grassfield-logo.svg` its optical version for 16-24 px (the same slopes; measured perpendicular to them, the band from
  about 1.17 to 1.35 px and the channel from about 0.54 to 1.15 px at 16 px; the base on the 16 px pixel grid). The places, colours and rules of IQ-B1 do not change; the
  brand kit's symbol and lockups follow. Legal clearance of the new shape is the owner's, pending (`docs/legal/visual-review.md` E33).
- Every illustration is made here or under a compatible licence, documented in `docs/legal` (E39). No Apple asset and
  no Apple trademark name (master-prompt §14).
- The lock screen (`shell/security/lock`) and idle handling are security modules: only `WlSessionLock`,
  `PamContext("omarchy-lock-password")` and Quickshell's polkit; any change, even visual, needs an opus security review
  before merge, and every failure leaves the session locked (R12).
- Tokens only; real glass (ADR-0024).
- Areas under way in other branches are not touched and are planned after their merge: `shell/dock`, `shell/desktop`,
  `shell/menubar`, `ui/Grassfield/Ui/Appearance.qml`, `ui/Grassfield/Ui/Material.qml`, `apps/store`, `apps/files`,
  `apps/portal`, `apps/activity`, the Software Update pane.
- Where this container cannot render Grassfield, the text says **NOT VERIFIED**; the integrator makes the nested pass.

### What Grassfield has today (audit, short)
- **Wallpapers.** One procedural artwork, the same in both appearances, its colours outside the tokens (W-1 to W-3).
  Videos are the user's own (W-5). **At every login and shell restart the artwork shows first and the user's picture
  crossfades in over it, and the menu bar's text colour switches after login** (W-7, W-8). **The lock always shows the
  blurred artwork, never the user's wallpaper** (W-9).
- **Brand.** The mark appears in the menu bar, Settings > About, Search and as the default glyph of shell dialogs, never
  in the shell's About panel (B-3, B-9). The default accent is the Grassfield green but is called "Multicolour", next to
  a second, pickable green; Settings > About draws its Grassfield tile in that second green (B-7, B-8). Grassfield's own
  apps show the composed pack's icons in the session, except Store (B-10). No boot splash or login window of our own
  (B-11).
- **Lock.** Sound layout and contrast (L-1, L-2, L-5); hard cuts in and out, a black first frame, and an avatar and name
  that can change after the lock shows (L-3, L-4).
- **Transitions.** No ground colour and no single entrance: `#1C1C1E`, then the menu bar alone, then the artwork,
  then the picture (T-1 to T-8; since main 8b5efac, "startup-settle", the Dock and the desktop icons already wait until
  they are final and appear once, which removes T-7 and the Dock's part of T-3, T-4 and T-6); idle and display-off paths undim or light the desktop for a moment (T-10 to
  T-12); the lock clock can jump after a wake (T-14); a shell restart replays the whole start and, when locked, shows the
  compositor's red screen (T-15); the session ends with layers vanishing one by one (T-16).
- Storyboards of today and of the proposal: `mockups/t1-transitions.svg`.

## Decision (proposed)

### 1. Principles: everything appears once, in its place
- **P-1 One ground.** Before any Grassfield surface has drawn and after the last one is gone, the screen shows one
  colour, the *ground*: the mean colour of the wallpaper the session shows (the helper's sidecar already measures it,
  ADR-0016 §2; for an artwork it is a palette value). Hyprland's background colour, the wallpaper window's own colour,
  the lock surface's colour (under its scrim) and the exit cover all take it (ID-2).
- **P-2 The first frame is the final frame.** A surface is shown only with its final content: the settings read, the
  wallpaper's prepared still decoded, the bar tone known, the Dock's items and the icons' positions loaded. Nothing
  shows a default and then corrects itself (ID-3 to ID-6).
- **P-3 One entrance.** At session start the wallpaper comes first, out of the ground; then the menu bar, the Dock and
  the desktop icons appear together, once (ID-20). Nothing slides away right after appearing.
- **P-4 Continuity across the lock.** The lock shows the desktop's own picture. Windows go at once (the protocol leaves
  no choice), the picture stays, the scrim and text fade in; on unlock they fade out while the session is still locked,
  then it is released (IQ-T2, IQ-W4).
- **P-5 Security first.** No animation delays the lock: it is engaged at once and its fade happens inside the lock
  surface. The unlock fade happens before the release, and a failure during it leaves the session locked. Displays and
  sleep never wait for an animation.
- **P-6 Bounded waits.** Every "wait until ready" has a token-bounded timeout after which the surface shows what it has;
  a missing helper, a broken file or a slow disk never leaves the session blank.
- **P-7 Reduce Motion** turns every fade here into a cut or a crossfade of at most `motion.reducedMax`; the order rules
  still hold.
- **P-8 Measured.** Each surface logs once when it is shown; a nested test fails on a second showing, a wallpaper that
  changes kind at start, or a bar tone that changes at start (section 7).

### 2. Wallpapers
- **Collection (IQ-W2, owner: C, artworks and photographs).** Four Grassfield-made procedural artworks, each with a
  light and a dark variant: **Grassfield** (the hills of today), **Meadow** (grass blades close up, not the mark's
  shape), **Field Rows** (a field seen from above), **Ridgeline** (one quiet hill line, the calmest backdrop for glass);
  the eight colours of today; and **photographs** under the integrator's conditions (below). The artworks are drawn by
  one shared QML component from token palettes (ID-1), crisp at any size, with the menu bar tone known from the
  palette, never measured late. Mockup: `mockups/w2-collection.svg`.
- **Photographs (IQ-W2 C; the integrator's conditions, 2026-10-29).**
  - Each photograph is CC0 or CC BY, or commissioned with a written licence, and has its own provenance and licence
    entry in `docs/legal` (source, author, licence, date, changes made); its credit shows in About This Wallpaper.
  - None may resemble a well-known OS wallpaper (the side-by-side check of E32 covers them).
  - The list (a thumbnail, the source and the licence of each) goes to the owner for the legal call before any file
    ships.
  - The pull request states the total package weight. They install under `/usr/share/grassfield/wallpapers/` and go
    through the helper like any picture (ADR-0016: the shell decodes only the helper's output).
- **Default (IQ-W1, owner: C, the time of day).** The Grassfield hills through the day: **Dawn**, **Day**, **Evening**
  and **Night**, like macOS's dynamic desktop. Light and dark still choose the variant set: four light palettes in the
  light appearance, four dark ones in the dark appearance (the same scenes, darker; the dark Evening is today's
  artwork), so the dark desktop never shows the bright Day. Mockup: `mockups/w1-default-wallpaper.svg` (option C strip;
  its Day and Night panels are the light Day and the dark Night).
- **The time-of-day rule (the integrator's condition: the exact rule before building it).**
  - **Times from the time zone only.** No location service, no network. The zone is the system's (`timedatectl`'s
    zone, which is the target of `/etc/localtime` under the zoneinfo directory). Its reference point, in this order
    (review of 6c310a8: zones tzdata now treats as aliases, the owner's Europe/Amsterdam among them, have no row in
    `zone1970.tab`):
    1. its row in tzdata's `zone1970.tab` (the coordinates of the zone's principal city);
    2. its row in `zone.tab`, which keeps one for those aliases (Europe/Amsterdam, Africa/Douala, Europe/Stockholm,
       Europe/Oslo, Europe/Copenhagen, Arctic/Longyearbyen, ...);
    3. the zone it links to (`tzdata.zi` "L" lines), looked up in 1 and 2;
    4. none: the fixed hours.
    Sunrise and sunset for the local date come from the NOAA approximation (solar zenith 90.833°).
  - **Probe** `docs/audits/identity-2026-10-29/timeofday-probe.py` (12 checks, exit 1 on a failure): Europe/Paris on
    2026-10-29 07:31 and 17:37 CET and on 2026-06-21 05:46 and 21:57 CEST; America/New_York on 2026-10-29 07:21 and
    17:57 EDT; Europe/Amsterdam on 2026-12-21 08:47 and 16:28 CET from `zone.tab` (the review's own figures); Africa/Douala
    and Europe/Stockholm from `zone.tab`; America/Montreal through its link to America/Toronto; Arctic/Longyearbyen
    in polar night and polar day (the fixed hours); UTC (no point); and two explicit points for the short-day and
    short-night rules. With `zone1970.tab` alone (the first rule's behaviour: no `zone.tab`, no links) six checks fail,
    Amsterdam and Montreal among them (re-checked for step 1b with a scratch zoneinfo directory holding that file only). An
    independent formula agrees within 3 minutes (the integrator's check); agreement with published times is NOT
    VERIFIED (no network here).
  - **Phases.** Dawn from 30 min before sunrise; Day from 90 min after sunrise; Evening from 90 min before sunset; Night
    from 30 min after sunset (tokens `wallpaper.phase*`). A day shorter than 3 h has no Day (Dawn runs to the middle of
    the daylight, then Evening); a night shorter than 1 h has no Night.
  - **Fixed hours** where the zone gives no point after the four lookups (UTC, `Etc/*`) or the sun neither rises nor
    sets that day (polar day or night): Dawn 06:00, Day 08:00, Evening 18:00, Night 20:30, local time.
  - **Changes.** A slow crossfade through the two-slot model (`wallpaper.phaseFadeMs`, 20 s; Reduce Motion: a cut),
    never during a pointer drag or while a full-screen window is on that output: deferred to the first moment neither
    holds.
  - **Scheduling.** One timer to the next boundary; recomputed at shell start, after a resume, at a time-zone change and
    at local midnight. No polling.
  - **Gate A2.** The bar's tone follows the wallpaper, so the band must hold 4.5:1 at every phase: the token test
    computes the chosen tone (and the band where it is needed) over the strip at t = 0, 0.25, 0.5, 0.75 and 1 of each
    of the eight transitions (four per set). ADR-0039 owns the role table; these are this ADR's roles.
  - **Choice in Settings.** The Grassfield tile offers "Time of Day" (the default), "Automatic" (Day in the light
    appearance, Evening in the dark one), "Light" (Day) and "Dark" (Evening). The other three artworks follow the
    appearance only.
- **Following the appearance.** A switch of appearance crossfades between the two variant sets through the existing
  two-slot model (one fixed `wallpaper.crossfadeMs`), the bar tone switching at the crossfade's midpoint from the
  palette; Reduce Motion cuts (ID-14). Settings shows each artwork as one tile in the current appearance, with
  "Automatic / Light / Dark" for the chosen one (macOS's pop-up for its dynamic wallpapers, ASSUMPTION). Settings >
  Appearance draws the real dark variant instead of darkening the art (W-3). The lock also draws the artwork
  (`LockView.qml:80`): `WallpaperArt` without a parameter keeps today's drawing, so step 2 edits nothing in
  `shell/security` and the lock's output stays as it is until step 4a changes it under the security review (reviews of
  b44d17e and ed21d46).
- **Videos (IQ-W3, owner: A, the drawn animation in 1.0).** No video file ships; the user's own videos stay as built
  (ADR-0016 W7). The default artwork gets a **moving** variant drawn live (clouds drift, the light changes slowly), also
  a screen saver kind (in `shell/saver`; nothing in `shell/security`, review of 6c310a8). The integrator's conditions
  (2026-10-29): off by default; it pauses like a video, when hidden,
  in Low Power Mode or on battery, under a full-screen app, while locked (and when idle, with Reduce Motion and in the
  Reduced profile, as the video policy already does); P1 and P3 are measured with it on before its pull request asks
  for a merge, and a cost over budget blocks it.
- **First frame (ID-3).** The wallpaper window shows the **last applied wallpaper's prepared still** from the cache as
  its first frame, with the bar tone from its stored statistics, and maps only then (bounded by
  `wallpaper.firstShowTimeoutMs`, after which the artwork). When the feed's result is the same file, nothing fades.
  This removes the artwork-then-picture sequence (W-7) and the late tone switch (W-8), and keeps ADR-0016's rule that
  the shell decodes only the helper's own output.
- **Lock still.** ADR-0016 §6 (W8) as already specified, plus the preloaded still of ID-7 (section 4).
- **Legibility (A2).** Every variant goes through `tests/visual/contrast.sh` (menu bar strip, desktop labels, lock);
  the artworks' tones come from their palettes.

### 3. Brand
- **The mark (IQ-B1, owner: B, few places, green; the file is not touched).** Where it appears, in what colour, and the rules of its
  use (clear space, smallest size, what is never done to it) are the owner's to set, so all three are in IQ-B1 (review
  of b44d17e). Places under B: the menu bar's system button (monochrome, the bar's text colour), About This Computer and
  Settings > General > About (the Grassfield green), Software Update's Grassfield release row (the brand green, as About's,
  since 9903e56d), the Search result for About; shell dialogs show their subject's symbol instead of the mark. Only the file's path is used, at run time. Mockup: `mockups/b1-logo-use.svg`.
  The owner replaced the drawing on 2026-10-30 and again on 2026-10-31 (see "Rules this ADR works under"); the places and colours stay as listed,
  and the places above draw `grassfield-logo.svg`, its optical version (menu bar 16 px, About This Computer's product line 14,
  Settings rows 15, Search 25), and `grassfield-logo-full.svg` (the full mark, 32 px and more) has no surface under B (a
  48 px full mark in the dialogs was reverted for that reason, 1bdd69e3).
  Step 1d as built: the shell dialogs show their subject's symbol. `Popups.notice(title, message, symbol)` names it (Sleep's
  dev notice the moon, Restart's and Shut Down's the power symbol, an app already quit the Force Quit cross, a document
  that cannot be opened the document); a notice without one shows the information symbol (`PopupKinds.noticeSymbol`: a
  missing symbol through a string-typed parameter arrived as "undefined" and drew an empty frame, the review of 52b2bec),
  and so does a confirmation whose action has no symbol; neither dialog draws the mark. `tests/ci/mark_places.py` (logic
  layer) holds the places: the menu bar, About This Computer, General > About, Software Update's Grassfield row and Search
  draw the mark, in any string that names it, a file path included; nothing else does; every notice names a symbol that
  `ui/Grassfield/Ui/icons` holds.
- **The name (ID-12, IQ-B2).** "Grassfield" names the product in running UI ("Grassfield menu", "Grassfield
  Settings"); "Grassfield Desktop" where the product and its version are stated (About, the session's comment);
  "Grassfield OS" only from M6 (§14). App names keep the owner's decisions (L1, ADR-0038 AQ1). The greeter's "Grassfield
  (uwsm)" suffix stays (Omarchy's theme needs it to pick the session, B-6), a documented limit. No lockup or wordmark
  (IQ-B2, owner: A, "no logotype"); the mark alone is the symbol.
- **The accent (IQ-B3, owner: A, "Grassfield").** The default is named "Grassfield" (a green swatch first in the row, in place
  of the Multicolour wheel), the pickable Green moves to a value clearly apart from the brand green with its own 4.5:1
  text, and the brand green is the existing default-accent tokens (`color.light.accent`, `#26763F` until the owner's
  choice of 2026-10-30 made it the deeper `#195E3F`, white text 7.7:1; `color.dark.accent` `#4FB36B`; no new brand
  token). Settings > About's tile uses it (ID-11). The pickable Green also colours Settings
  tiles (the sidebar's Battery and Motion, `apps/settings/qml/Main.qml:27, 32`; rows of Accessibility, Menu Bar, Software
  Update and Storage): moving it moves them (review of b44d17e). Mockup: `mockups/b2-accent.svg`.
  Step 1c as built: Settings > Appearance's first swatch is "Grassfield", one disc of the brand green (the colour wheel is
  gone); the stored value stays `multicolor` (no grassfield.json to migrate). The pickable Green is `#6DB53C` with dark
  text `#10240A` (6.5:1) in the light appearance, the owner's choice B of 2026-10-30 (below): OKLab distance 0.21 from the
  brand green `#26763F` and 0.29 from the deeper `#195E3F` of 2026-10-30, where `#3A7512` was 0.04; the dark appearance keeps `#8BD34E` (0.12 already). Like yellow it holds dark
  text, so its dark-appearance selection pair is its light pair (`color.selectionDark.green`, the rule that a selection
  is never darker than the light accent), its focus ring falls back to the text colour on light grounds
  (`Accent.focusRing`), its thin marks in the GTK themes are pinned at 2.32:1 and 2.46:1 (2.48:1 before the warm neutrals; `tests/ci/gtk_themes.py`), and
  the white glyphs of the Settings tiles drawn in it are 2.5:1, as macOS draws them. General > About's Grassfield row
  draws its tile in the brand green (`SettingsRow` `tileColor: "grassfield"`, ID-11), and so does Software Update's
  Grassfield release row. Text and glyphs drawn in the accent colour read `colors.accentInk`: in the light appearance a
  light accent's darker shade (`color.accentInkLight`: yellow, green and pink, 4.5:1 on an app window; macOS draws a light
  accent's text darker), the accent itself elsewhere (the integrator's review of 5391761, below).
- **About This Computer (ID-19, the macOS model; review of b44d17e).** Computer first, as macOS 27 and as Settings >
  About already do: the
  Grassfield-drawn picture of the computer (`DevicePicture`, by chassis), its model name, processor, memory, graphics,
  then "Grassfield Desktop 1.0" with the mark in the brand green, "More Info…" (opens Settings > General > About) and
  "Built for Omarchy · based on Arch Linux" (§14 wording). Mockup: `mockups/b3-about.svg`. Its form (step 1b, chosen on
  2026-10-29 when the step started, « Fenêtre de Réglages », the recommended option): Settings' own small window,
  `grassfield-settings --about` (`apps/settings/qml/AboutWindow.qml`), of fixed size, in the titlebar-only style (role
  "info"), mapped once hostname1 and lspci have answered (asynchronously: nothing waits on the GUI thread), at the latest
  after `settings.aboutWindowRevealTimeout` (P-2, P-6). Settings becomes one instance per user (the review of ce69dc6,
  MINOR 3; chosen on 2026-10-29, « Instance unique ici », recommended; Activity Monitor's AM1 pattern, ADR-0038 AD34): the
  running Settings owns `org.grassfield.Settings` on the session bus, a second launch hands it `--section` or `--about`,
  so there is one About window and one Settings window, in one process; More Info… brings that Settings window to
  General > About, and the shell's Settings… and section links bring it to their page instead of opening a second one.
  The shell's sheet (`shell/overlay/AboutPanel.qml`) and its popup kind are retired. Weighed: the
  shell's own window or sheet (no window of its own in the Dock, the Overview and the switcher; macOS's About This Mac
  is a window).
- **App icons (IQ-B5, owner: C, own icons where the pack has none).** Grassfield's own icons where the pack has no system app
  of that role: Store, Activity Monitor and the Dock's Apps tile; Files, Settings and Preview keep the pack's drawings,
  as the owner ruled on 2026-10-23. The own icons follow one grammar: one tile (104 on the 128 grid, radius 23.4, which
  is ADR-0014's plate radius 0.225), a top-to-bottom gradient and a light inner rim, one drawing in the brand palette
  inside 72 % of the tile (so ADR-0014's Dark, Clear and Tinted plates take it), no text. Activity Monitor is a gauge on
  a light tile and the Apps tile three fanned cards, drawn away from macOS's own Activity Monitor (a dark screen with a
  green graph) and Apps (a grid of coloured squares) icons; whether they are far enough is the owner's legal call
  (E39), asked again with the drawings before step 8 ships them. Mockup: `mockups/b4-app-icons.svg`.
- **Boot and login (IQ-L1, owner: C, an SDDM theme and a Plymouth theme).** Grassfield's look from power-on: a
  login theme in the lock screen's layout for SDDM's own greeter, and a boot theme with the mark for the disk password.
  The integrator's conditions (2026-10-29):
  - its own ADR first, and an opus security review; SDDM's own PAM service, no PAM file; no change to Omarchy's Limine
    or disk-encryption flow beyond the theme. The ADR shows how R12 holds for both themes:
    - SDDM: a theme for SDDM's own greeter, not a greeter; master-prompt §4 allows "SDDM theming later";
    - **Plymouth is outside today's allowance** (review of 6c310a8): plymouthd runs as root inside the boot image and
      draws the disk-password prompt, and master-prompt §4 allows SDDM theming only. The L1 ADR needs the owner's
      explicit go-ahead for Plymouth, inside that ADR, before any Plymouth work;
  - every root step (install, initramfs rebuild, enabling the theme) is a command the owner runs;
  - a broken theme must never hide the disk-password prompt: a tested fallback to the text prompt;
  - the last identity step, after the lock steps.
  Until then Omarchy's path stays, and Grassfield's identity starts at the ground colour.

### 4. Lock screen (security module: display only, opus security review, R12)
- **Backdrop (IQ-W4, owner: A, sharp, banded scrim).** The prepared still of the output's current wallpaper, sharp (the artwork, drawn
  as today, when the wallpaper is an artwork); the scrim `lock.dimOpacity` 0.6 under the date and clock band and under
  the name and field band, `lock.scrimClearOpacity` 0.25 between them, the band edges `lock.scrimFeather` wide and
  outside every text line at every text scale. A2 is computed per band (`test_contrast_tokens.py` lock roles) and
  measured (`contrast.sh --surfaces lock`). Mockup: `mockups/l1-lock.svg`.
- **Ready before it is needed (ID-7).** The lock keeps one decoded still per output, loaded when the wallpaper changes,
  not when the session locks; the avatar picture and the full name are resolved at shell start and on account change;
  the lock surface's colour is the ground under the scrim, not black; the clock is refreshed on resume, before the first
  frame after a wake (T-14). Once the lock shows, nothing on it changes but its own fade (L-3, L-4).
- **Motion (IQ-T2, owner: A, 200 ms fades).** Lock: engaged at once; inside the surface, scrim and text fade in over
  `lock.fadeInMs` 200 (from the idle dim's level when the lock follows it, ID-8). Unlock: after PAM success a new
  machine state `releasing` fades text and scrim out over `lock.fadeOutMs` 200 and only then sets `locked = false`.
  Reduce Motion: cuts. The fades take ADR-0039's `motion.*` role where one fits (its Q6), else these tokens.
- **Unchanged.** The layout and its tokens, the field, the shake, the messages, the reserved hint line (L-5), one surface
  per output, gate L4 (no window or notification content).
- **Invariants for the reviewer.** Engaging the lock never waits for the still, the avatar, the name, the settings or a
  fade. The release happens only after PAM success and after the fade; any event during `releasing` (a lock request, a
  lost lock, an error, a timeout, a shell exit) leaves the session locked and brings the content back, and unlocking
  then needs a new PAM success: the interrupted one is spent (review of ed21d46). The still is
  Grassfield's own JPEG in the 0700 cache, a regular file of at most `wallpaper.lockStillMaxBytes`, decoded at screen
  size; any failure shows the artwork; no user original and no video decoder enters the module (ADR-0016 §6). Tests:
  L1 to L5, `tests/security/reload_locked.sh`, and new cases (a fade interrupted by a new lock; a missing still; a
  release refused during the fade; the first lock right after shell start).

### 5. Session transitions (the proposed sequence of each; storyboards in `mockups/t1-transitions.svg`)

| Transition | Today (audit) | Proposed | Where; step |
|---|---|---|---|
| Boot to session | Omarchy's boot, disk password, autologin; Hyprland `#1C1C1E` (T-1) | Omarchy's path until step 10 brings the login and boot themes (IQ-L1 C); the session's Hyprland background is the default artwork's ground; the shell sets the current ground at start and on change (ID-2) | `config/hypr/grassfield/looknfeel.lua`, shell; step 3 |
| Login to desktop, desktop loading | `#1C1C1E`, the menu bar alone, the artwork fading in, then the picture and a bar tone switch; the menu bar from the defaults before the settings; an auto-hidden menu bar slides away (T-2 to T-8; the Dock and the desktop icons already appear once, final, since 8b5efac) | ground; the wallpaper's cached still (ID-3); once the settings are read (ID-5) and every surface has its final content, menu bar, Dock and desktop icons in one 250 ms fade (ID-20), the Dock's own one-frame reveal joining it; the menu bar's auto-hide starts at rest as the Dock's does (ID-6); P5 counts the wallpaper | `shell/desktop`, `shell/menubar`, `shell/dock`, `shell.qml`, `windows.lua`; steps 3 and 6 |
| Lock | black first frame [inference], blurred artwork, no fade (L-3, W-9) | same picture, windows go, scrim and text fade in (IQ-T2 A, IQ-W4 A) | `shell/security/lock`; steps 4a and 4b |
| Unlock | hard cut to another picture (L-3) | fade out while locked, then release | step 4b |
| Idle dim, then lock | the dim drops before the lock is up [inference] (T-10) | the dim stays until the lock holds; the lock's content starts at the dim's level (ID-8) | `shell/security/idle`; step 5 |
| Displays off, then lock | the displays light up to draw the lock (T-11) | lock at display-off or at the inactivity limit, whichever comes first; at display-off the lock is drawn just before the displays go off (IQ-T4 A) | `shell/security/idle`, Settings > Lock Screen; step 5 |
| Screen saver, then lock | the saver goes before the lock is up [inference] (T-12) | the saver stays until the lock holds (ID-8) | `shell/saver`; step 5 |
| Sleep | locked before sleep when confirmed; exceptions show the desktop on wake (T-13) | unchanged path; the exceptions stay a documented limit (the budget is the system's) | — |
| Wake | the clock may show the sleep time, then jump (T-14) | clock refreshed on resume before the first frame (ID-7); the lock's picture and name already final | step 4a |
| Shell restart | bars vanish, windows over `#1C1C1E`, the whole start again; red screen when locked (T-15) | windows over the ground; the cached still and the single entrance; the red screen delayed past a normal restart, black meanwhile (IQ-T5 A) | steps 3, 5, 6 |
| Log out, restart, shut down | no countdown; layers vanish one by one (T-16) | 60 s countdown (ID-21); after the windows close, one fade of the whole screen to the ground then black, then the session ends (ID-10) | `shell/overlay/SystemMenu.qml`, `packaging/bin/grassfield-session-end`; step 7 |
| Output added or removed | black lock surface [inference] (L-6) | the new output's wallpaper and lock surfaces start at the ground and show its still (ID-15) | step 3 (the wallpaper), step 4a (the lock surface) |
| Appearance switch | the wallpaper does not change (W-3) | crossfade between the artwork's variant sets; tone at the midpoint (ID-14) | step 2 |
| Time of day | (none) | a 20 s crossfade at each phase boundary, deferred during a drag or a full-screen window (IQ-W1 C) | step 2 |
| Wallpaper change | crossfade (ADR-0016) | unchanged | — |

### 6. Tokens and contract (proposed; every value an estimate until F1 and P3)
| Token or key | Value | Note |
|---|---|---|
| `artwork.<name>.<variant>.<role>` | the palettes of `mockups.py` (`PAL`, `meadow`, `rows`, `ridgeline`) | ID-1; `evening` keeps today's values (`GrassfieldArtwork.qml:12-21`) |
| `session.settingsWaitMs` | 500 | ID-5 |
| `session.revealTimeoutMs` | 1500 | the latch's bound (P-6) |
| `session.revealMs` | 250 | ID-20 (ASSUMPTION for macOS); an ADR-0039 `motion.*` role where one fits |
| `session.exitFadeMs`, `session.exitWaitMs` | 400, 1000 | ID-10 |
| `wallpaper.firstShowTimeoutMs` | 1500 | ID-3 |
| `lock.fadeInMs`, `lock.fadeOutMs` | 200, 200 | IQ-T2 A |
| `lock.scrimClearOpacity`, `lock.scrimFeather` | 0.25, 48 | IQ-W4 A; A2 per band |
| `wallpaper.artwork` | `grassfield` \| `meadow` \| `rows` \| `ridgeline` | additive key, default `grassfield` |
| `wallpaper.artworkVariant` | `timeOfDay` \| `automatic` \| `light` \| `dark` | additive, default `timeOfDay` (IQ-W1 C; the Grassfield artwork only) |
| `wallpaper.phaseFadeMs` | 20000 | IQ-W1 C, the slow crossfade between two phases |
| `wallpaper.phaseDawnBeforeSunriseMin`, `phaseDayAfterSunriseMin`, `phaseEveningBeforeSunsetMin`, `phaseNightAfterSunsetMin` | 30, 90, 90, 30 | IQ-W1 C |
| `wallpaper.phaseFixedDawn`, `phaseFixedDay`, `phaseFixedEvening`, `phaseFixedNight` | "06:00", "08:00", "18:00", "20:30" | IQ-W1 C, where the zone gives no point or the sun neither rises nor sets |
| `artwork.grassfield.<dawn\|day\|evening\|night>.<light\|dark>.<role>` | the light set from `mockups.py`; the dark set derived and A2-checked in step 2 | IQ-W1 C; `evening.dark` keeps today's values |
| `wallpaper.moving` | bool, false | IQ-W3 A, in 1.0 |
| `lock.requirePasswordAfterDisplayOff` | `immediately` \| `5s` \| `1m` \| `5m` \| `15m` \| `1h` \| `never`, default `immediately` | IQ-T4 A; beside `lock.idleMinutes`, which stays the ceiling, so nothing migrates (ADR-0020 row) |
| `$XDG_STATE_HOME/grassfield/wallpaper.json` | gains the last shown still per output (path, statistics, ground) | ID-3; ADR-0020 row in that step |

### 7. How "appears once" is measured
- **Journal.** Each surface logs `grassfield-shell: shown <surface> <output> <ms>` when it becomes visible and `hidden`
  when it goes; the wallpaper also logs its first kind and source.
- **Test** `tests/visual/appear-once.sh` (nested, light appearance, a picture wallpaper, a non-default accent): at shell
  start and at a restart, the first wallpaper kind equals the final one, no surface is shown twice without being
  hidden, the bars come after the wallpaper, the bar tone does not change in the first 3 s; at lock and unlock, the
  journal order and `grim` captures every 50 ms (the still's pixels outside the text bands equal the desktop's).
  Captures are the visual evidence.
- **Gates.** P5 counts the wallpaper and the entrance (≤ 2 s from the uwsm start line); P3 covers the appearance
  crossfade and the lock fades; P2 the preloaded stills (one per output); A2 the new artworks and the lock bands;
  L1 to L5 every lock and idle step; Q2 no QML error on any path.

## Owner questions (as asked; answered on 2026-10-29, see "Owner decisions (2026-10-29)")

**IQ-W1. The default wallpaper, light and dark.** Mockup `w1-default-wallpaper.svg`.
| Option | For | Against |
|---|---|---|
| **A. Day in the light appearance, today's artwork ("Evening") in the dark one (recommended)** | the default dark desktop stays exactly as today; the light appearance gets a matching daylight scene; one geometry, recognisable in both | the dark variant keeps a bright sun and horizon; light-appearance users see a new picture |
| B. Day, and a new darker "Night" (stars, a small moon); today's artwork stays in the collection as "Evening" | a truly dark desktop at night, less glare | the default desktop changes for everyone; near-black hills make the dark glass read as near-black plates |
| C. The time of day: Dawn, Day, Evening, Night by local time | macOS's dynamic-desktop idea, a living desktop | four crossfades a day and a changing bar tone during work; needs sunrise times (location) or fixed hours; not tied to the appearance |

**IQ-W2. The shipped collection.** Mockup `w2-collection.svg`.
| Option | For | Against |
|---|---|---|
| **A. Four procedural artworks, light and dark: Grassfield, Meadow, Field Rows, Ridgeline; plus the colours (recommended)** | made here (CC-BY-SA-4.0), crisp at any size, almost no package weight, tone and A2 known by construction | six new palettes to tune and test (A2, F1, the side-by-side legal check); less rich than photography |
| B. Only the Grassfield pair and the colours | least work, one strong image | little choice before the user brings pictures |
| C. A and photographs (commissioned, or CC0 / CC BY from Wikimedia Commons) as image files | macOS-like richness | a licence and provenance per file, 3-6 MB per 5K picture, the helper's parse path, possible resemblance with well-known OS photos |

**IQ-W3. Videos** (recommendation changed by the review of b44d17e).
| Option | For | Against |
|---|---|---|
| A. No video file; an optional moving variant of the default drawn live, off by default, with the video pause rules; also a screen saver kind | no package weight, no codec, no new licence; motion in the brand scene; pauses like a video | a new feature during the release candidate; GPU work while visible (the Dock and popups re-blur every frame, as with any video), so P1 and P3 first |
| **B. No motion in 1.0; A after 1.0 (recommended)** | nothing new to stabilise before 1.0; nothing to measure now | no answer to macOS's video wallpapers in 1.0 but "add your own" |
| C. Pre-rendered H.264 loops of the artwork | hardware decode, same path as user videos | 20-60 MB per loop, a build-time renderer, FFmpeg (G9) in the shell by default |

**IQ-W4. The lock screen's backdrop** (ADR-0016 Q4 was settled on 2026-10-20 as its recommended option, a sharp still
under the existing scrim, an integrator decision the owner can revisit; this asks whether the scrim stays flat now that
the identity is designed). Mockup `l1-lock.svg`.
| Option | For | Against |
|---|---|---|
| **A. The user's wallpaper, sharp; scrim 0.6 only under the text bands, 0.25 between (recommended)** | shows the wallpaper as macOS does (ASSUMPTION) and as the desktop does; A2 holds where text is | band geometry to prove at every text scale; security review |
| B. Sharp, with today's flat 0.6 scrim (ADR-0016 Q4 as settled) | simplest; A2 already computed | the picture reads dim and grey |
| C. Blurred, flat scrim (today's look with the user's wallpaper) | calm; hides busy pictures | blur cost per output; less continuity with the desktop |

**IQ-B1. The mark: where it appears, in what colour, and the rules of its use** (the mark itself is not changed; the
rules are the owner's to set, review of b44d17e). Mockup `b1-logo-use.svg`.
- Rules proposed with every option (the owner may change any of them): clear space of a quarter of the mark's height on
  every side; 14 px smallest; never stretched, rotated, outlined, given a gradient or a shadow, or redrawn; only the
  file's own path, at run time.

| Option | For | Against |
|---|---|---|
| A. As today: monochrome everywhere, also as the default glyph of shell dialogs | no change | the mark stands for "a dialog" (restart, notices); no brand moment |
| **B. Fewer, deliberate places: the menu bar (monochrome), About and Settings > About (Grassfield green), Search; dialogs show their subject's symbol (recommended)** | the mark means "Grassfield" only; colour on brand moments, a neutral chrome | each dialog needs its own symbol (most exist in the symbolic set) |
| C. As B, in the user's accent instead of the Grassfield green | follows personalisation | the brand colour disappears when the accent changes |

**IQ-B2. The name next to the mark.**
| Option | For | Against |
|---|---|---|
| **A. No lockup in 1.0: the mark alone as the symbol, the name in running text (recommended)** | nothing new to protect or clear; the macOS UI has no wordmark either | no single "mark and name" image for the README or packages |
| B. A fixed lockup: the mark and "Grassfield" in Inter Display Semibold (mockup) | cheap and consistent | not distinctive (a common font); its rights status is the owner's to set; needs legal review (OFL font in a logo) |
| C. A designer-made wordmark, with ADR-0014's planned icon redraw | distinctive, protectable | cost and time; after 1.0 |

**IQ-B3. The default accent's name and the second green** (asked with ADR-0039's Q4, already answered as D-Q4: the
switches and slider fills move to the selection fill; IQ-B3 changes the palette, not which controls read it). Mockup
`b2-accent.svg`.
| Option | For | Against |
|---|---|---|
| **A. The default is named "Grassfield" (a green swatch); the pickable Green moves away from the brand green (recommended)** | the brand colour is named; no two near greens | departs from macOS's "Multicolour"; users who chose Green see it change; **the Settings tiles drawn in that Green change with it** (the sidebar's Battery and Motion, `Main.qml:27, 32`; rows of Accessibility, Menu Bar, Software Update and Storage) |
| B. Keep "Multicolour" and both greens | macOS's model and name | "Multicolour" means one green here; two greens read alike |
| C. Keep "Multicolour", drop the pickable Green | no near-duplicate | seven colours; users of Green move to the default; the Settings tiles in Green need another colour |

**IQ-B5. The icons of Grassfield's own apps** (the owner decided on 2026-10-23 that system apps take the pack's icons;
recommendation changed by the review of b44d17e). Mockup `b4-app-icons.svg`.
| Option | For | Against |
|---|---|---|
| A. As today: the pack for Files, Settings and Preview, Store's own icon, Activity Monitor and the Apps tile from the pack | one look with the pack | Grassfield-only apps carry no brand; Store differs from the rest |
| B. Grassfield's own icons on one grammar for every Grassfield app; the `org.grassfield.*` aliases go | the apps carry the brand; Grassfield's drawings instead of the macOS look-alike pack for its own apps | reverses the 2026-10-23 rule for three apps; our drawings sit beside the pack's richer ones until a designer redraw |
| **C. Own icons, on one grammar, only where the pack has no system app of that role: Store, Activity Monitor, the Apps tile; the pack for Files, Settings, Preview (recommended)** | keeps the owner's rule of 2026-10-23; the brand appears on the apps only Grassfield has | two looks among Grassfield's own apps; the two new drawings need the owner's legal call (E39) |

**IQ-L1. From power-on to the desktop.**
| Option | For | Against |
|---|---|---|
| **A. Omarchy's path unchanged (Limine, disk password, SDDM autologin); Grassfield starts at the ground (recommended)** | no greeter or boot change (a non-goal; R12), no root work | the boot and disk-password screens are Omarchy's look |
| B. A Grassfield SDDM theme in the lock screen's layout, for machines without autologin (own ADR, opus security review, SDDM's own PAM service) | a macOS-like login window | a non-goal today ("allowed later"); SDDM runs as its own user (no access to the user's wallpaper: the default artwork only); owner-only tests |
| C. B and a Plymouth theme with the mark for boot and the disk password | identity from power-on | initramfs and boot configuration (root, owner-run, M6 territory); a broken theme can hide the disk prompt |

**IQ-T2. Lock and unlock motion.** Mockups `l1-lock.svg`, `t1-transitions.svg`.
| Option | For | Against |
|---|---|---|
| **A. Lock at once, then scrim and text fade in (200 ms); unlock: fade out while still locked (200 ms), then release (recommended)** | continuity; the release still follows PAM, any failure stays locked | unlock 200 ms longer; a new lock-machine state; security review |
| B. No motion (today) | nothing to review | hard cuts both ways |

**IQ-T4. When the displays turn off before the lock** (rewritten by the review of ed21d46: following display-off
alone is not stricter than today). Defaults today: displays off after 2 min on battery and 10 min on AC
(`lock.displayOffBattery`, `lock.displayOffPower`), lock after 5 min (`lock.idleMinutes`), screen saver off. A lock that
only followed display-off would come at 10 min on AC instead of 5, and never with display-off set to Never and the
saver off; that form is not offered.
| Option | For | Against |
|---|---|---|
| **A. Lock at display-off or at "Require password after inactivity" (`lock.idleMinutes`), whichever comes first; at display-off the lock is drawn just before the displays go off; a new "Require password after the display turns off" (Immediately by default, as macOS) (recommended)** | no lit flash with the defaults; never later than today (the inactivity limit stays the ceiling), earlier where the displays go off first (2 min on battery by default instead of 5) | on battery, more password prompts by default (2 min instead of 5); one more setting; with a delay other than Immediately the lock comes while the displays are off and the flash returns for those users (unless Hyprland confirms a lock without drawing: VERIFY) |
| B. Keep the inactivity model; turn the displays off only once the lock holds | no flash, no new setting, the lock time unchanged | on battery by default the screen stays lit 5 min instead of 2; "Turn display off after" is no longer honoured when it is shorter than the lock |
| C. Today: lock after N minutes of inactivity; the displays light up to draw it | no change | a lit flash with the default settings on battery (off at 2 min, lock at 5) |

**IQ-T5. The compositor's red "lock screen died" screen during a shell restart** (was ID-9; it reverses a security
choice, H10, so it is the owner's: review of b44d17e). Hyprland 0.56.2 has `misc:lockdead_screen_delay` (the
integrator's check). The session stays locked by the compositor either way (`allow_session_lock_restore`); only what is
drawn while the shell restarts changes.
| Option | For | Against |
|---|---|---|
| **A. Delay it past a normal restart (the shell is back in about 1-2 s): the screen stays black meanwhile; a shell that does not come back still shows the red screen after the delay (recommended)** | no red flash on a crash-and-restart that recovers by itself | the user learns later that the lock died; the nested pass must show only black during the delay |
| B. Keep it at once (H10 as decided) | the failure is visible at once | a red screen on every locked restart, even one that recovers within a second |

**Not a design question (needs legal review).** STATE records that the owner did the "Grassfield" trademark check
(2026-10-18); the legal dossier says no clearance search was made and the owner decided "no logo clearance"
(2026-10-27) (B-5). Which record is right is the owner's to say; this ADR changes neither.

## Owner decisions (2026-10-29)
Asked by the integrator from this ADR's options, with the recommendations shown; recorded on pull request #46
("The owner's answers to ADR-0040's questions"). The owner's choices as shown, in French, then the option.

| Question | Owner's choice | Option |
|---|---|---|
| IQ-W1 default wallpaper | « Selon l'heure » | **C**: the time of day (Dawn, Day, Evening, Night) |
| IQ-W2 collection | « Dessins + photos » | **C**: the four artworks and photographs |
| IQ-W3 videos | « Animation dessinée » | **A**: a moving variant drawn live, off by default, with the video pause rules, in 1.0 |
| IQ-W4 lock backdrop | « Net, voile par bandes » | **A** (recommended) |
| IQ-B1 the mark | « Peu d'endroits, vert » | **B** (recommended) |
| IQ-B2 the name | « Pas de logotype » | **A** (recommended) |
| IQ-B3 accent | « Grassfield » | **A** (recommended) |
| IQ-B5 app icons | « Propres là où le pack n'a rien » | **C** (recommended) |
| IQ-L1 power-on | « Connexion + démarrage » | **C**: an SDDM theme and a Plymouth theme |
| IQ-T2 lock motion | « Fondus de 200 ms » | **A** (recommended) |
| IQ-T4 display-off | « Au 1er des deux » | **A** (recommended, as rewritten after the review of ed21d46) |
| IQ-T5 red lock-died screen | « Le retarder » | **A** (recommended) |
| B-5 trademark record | « J'ai vérifié le nom » | The owner checked the **name** "Grassfield" on 2026-10-18 and **not the logo** (no logo clearance, 2026-10-27). The legal dossier is corrected (E33, Q7, section 7); STATE stays. |

**Step 1c's Green (2026-10-30).** Asked when step 1c started, the brand green and the pickable Green being 0.04 apart
(OKLab) in the light appearance; two values shown against today's (a capture of the accent row and the tiles in both
appearances): « B : vert clair, comme macOS » (`#6DB53C`, dark text; not the recommended A, a dark green `#2D5A04` with
white text). The costs named in the question and taken: the white glyphs of the green Settings tiles at 2.5:1, and green
joins yellow among the light accents with dark marks (its selection pair; ADR-0039 step 11's knob on the "on" fill).

**The brand green and the neutrals (2026-10-30).** Shown a comparison board (the current brand green and a deeper,
calmer one, each with today's cool neutrals and with warm ones, in both appearances, on the default artwork with a
Settings window): « B en clair seulement, et neutres chauds ». The brand green of the light appearance becomes `#195E3F`
(white text 7.7:1, where `#26763F` gave 5.6:1); the dark appearance keeps `#4FB36B` (its deeper candidate `#4F9F77`
was 4.5:1 on the window, 5.2:1 under its dark text). The neutrals turn warm in both appearances, an explicit choice over
the "closest to macOS 27" rule; they come in their own pull request (they cross ADR-0039's neutrals and glass and the
plugin's title bar), measured first in a scratch copy: every A2 role holds, three pinned values move.
As built (after pull request #71): 34 neutral tokens move to hue 85, chroma 0.0075 in OKLCH, each keeping its lightness
(so each contrast stays), the pure white to `#FDFCF9`: `color.light` and `color.dark` text, secondary texts, window,
group, sidebar, field, chip and material tint; the plugin's `titlebar.*` (background, title, inactive buttons, the
preview tint); `window.inactiveLight*`; `folderIcon.plateBackdrop*`; `menu.swatchMark`, `preview.paperInk`,
`store.accountCircleFill`. Kept: the black and white inks drawn at an alpha (hover, separators, shadows, fills, borders),
the opaque white knob, the Graphite accent and its selection, Files' Gray tag and the drawing of the computer
(`settings.device*`).
Re-pinned: the light glass's worst-case alpha 0.78 to 0.79 (`test_contrast_tokens.py`, `tst_glasstint.qml`), the GTK
themes' thin marks under high contrast (yellow 1.97:1, green 2.46:1), and the tests that named the old greys.

**The integrator's conditions for the non-recommended choices** (2026-10-29, under the owner's rule: closest to macOS
27, no technical step for the end user), written into the sections they shape:
- **W1 C, the time of day** (section 2, "The time-of-day rule"): the times from the time zone with no location and no
  network (the zone's reference point, or fixed hours where the zone gives none); slow crossfades, never during a drag
  or a full-screen app; A2 proven for the band at every phase; light and dark still choose the variant set; the exact
  rule in this ADR before it is built.
- **W2 C, artworks and photographs** (section 2, "Photographs"): a licence and provenance entry per photograph (CC0 or
  CC BY, or commissioned with a written licence); no resemblance to a well-known OS wallpaper; the list to the owner for
  the legal call before it ships; the package weight stated in the pull request.
- **W3 A, the drawn animation in 1.0** (section 2, "Videos"): off by default; it pauses like a video (hidden, battery
  saver, a full-screen app, locked); P1 and P3 measured with it on before the pull request asks for a merge; a cost
  over budget blocks it.
- **L1 C, SDDM and Plymouth** (section 3, "Boot and login"): its own ADR, an opus security review, SDDM's own PAM
  service, nothing changed in Omarchy's Limine or disk-encryption flow beyond the theme; every root step is the owner's
  command; a broken theme never hides the disk-password prompt (a tested fallback to the text prompt); the last identity
  step, after the lock steps.

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **ID-1** The artwork palettes become tokens (`artwork.*`, section 6) with source notes; the written exception in
  `GrassfieldArtwork.qml:5-7` goes, so the "tokens only" rule has no exception left in the wallpaper. ADR-0039's step 2
  allowlists those colours until then.
- **ID-2** One ground colour (P-1). The session's Hyprland `background_color` is the default artwork's ground; the shell
  sets the current one at start and on change through the session's own compositor path (mechanism VERIFY on 0.56.2;
  fallback: the static default). The wallpaper window's colour (step 3) and the exit cover (step 7) use it; the lock
  surface's colour is the security module's and comes with step 4a (review of b44d17e).
- **ID-3** The wallpaper's first frame is the cached still of the last applied wallpaper, with its tone (section 2).
- **ID-4** The wallpaper layer gets `no_anim` like the bars; every entrance animation belongs to the shell (one owner of
  motion), so the compositor never fades a layer in under the shell's own fade.
- **ID-5** No surface is shown before the settings are read (`Settings.loaded`), bounded by `session.settingsWaitMs`;
  the Dock already waits for them (8b5efac), the menu bar and the wallpaper follow.
- **ID-6** The menu bar's auto-hide starts at rest at session start, as the Dock's has since 8b5efac (macOS, ASSUMPTION),
  instead of showing and sliding away.
- **ID-7** The lock prepares everything ahead (section 4): the still per output, the avatar, the full name, the surface
  colour, and the clock refresh on resume.
- **ID-8** The idle dim and the screen saver stay until the lock holds; the lock's content starts at the dim's level.
  The lock request itself is not delayed; when it fails, the dim lifts and the failure is logged as today.
- **ID-9** Moved to the owner as IQ-T5 (review of b44d17e).
- **ID-10** The exit cover: `grassfield-session-end` asks the shell for one full-screen fade to the ground then black
  (`session.exitFadeMs`) after the windows have closed, and waits at most `session.exitWaitMs`.
- **ID-11** Settings > About's Grassfield tile uses the brand green, not the pickable Green (B-8).
- **ID-12** Docs and comments call the logo "the Grassfield mark" (B-4: four names today), as each step touches them.
- **ID-13** The copy `ui/Grassfield/Ui/icons-bar/grassfield-logo.svg` gets its row in `branding/LICENSES.md` (all rights
  reserved, the owner's mark): done in this pull request (B-2).
- **ID-14** An appearance switch crossfades between the artwork's variants (two-slot model, one fixed length); the tone
  switches at the midpoint; Reduce Motion cuts.
- **ID-15** A hotplugged output's wallpaper surface (step 3) and lock surface (step 4a, security review) start at the
  ground and show its still.
- **ID-16** The measurement of section 7 lands with step 3 and grows with each step.
- **ID-17** The legal dossier's identity entries are brought up to date as each step lands (E12, E32, E33 now; E2,
  E26, E28 and section 4, stale in passing, at the next legal pass).
- **ID-18** Artwork names avoid the names of macOS wallpapers ("Ridgeline", not "Horizon"; checked from memory only,
  ASSUMPTION: the side-by-side legal check before release covers names and pictures).
- **ID-19** (was IQ-B4; review of b44d17e) About This Computer is computer first, as macOS 27's About This Mac: the
  computer's picture and model name, then the hardware rows, then the product line with the mark and More Info…, which
  opens Settings > General > About. macOS reason: About This Mac leads with the Mac, and the system's name and version
  are one line under it. Options weighed: brand first (unlike macOS 27 and unlike Settings > About), today's sheet (no
  picture, no mark). It becomes a small window; ADR-0039's steps 4 and 10 then no longer touch it.
- **ID-20** (was IQ-T1) Session start: the wallpaper first, then menu bar, Dock and desktop icons together in one fade
  (`session.revealMs`) once all are final, bounded by `session.revealTimeoutMs`. macOS reason: at login the desktop
  picture is there first and the menu bar and Dock come in once (ASSUMPTION; no capture). Weighed: no fade (a hard cut
  from the ground), a splash (not macOS).
- **ID-21** (was IQ-T3) Log out, restart and shut down confirm with macOS's 60-second countdown that proceeds by itself
  ("… automatically in 60 seconds", ASSUMPTION from memory), then the exit cover (ID-10). macOS reason: the same dialog
  and countdown on a Mac. Weighed: today's confirmation with the fade only (not macOS), no confirmation (a misclick ends
  the session).

## Coordination with ADR-0039 (design polish)
The owners are those of ADR-0039's own table ("Coordination with the identity lane"), unchanged. ADR-0039 merged first;
this ADR follows it, and any later pull request of either lane that meets one of these rebases on the other.

| Overlap | Owner | The other lane |
|---|---|---|
| The greens: ADR-0039 Q4 and its step 11 ↔ IQ-B3 | ADR-0040: the accent palette (`color.accent*`, the default's name and swatch) | ADR-0039: which controls read the accent and which the selection fill |
| The neutrals: the owner's warm neutrals of 2026-10-30 ↔ ADR-0024's greys, ADR-0039 Q3 (dark secondary text), Q8 and step 21 (third-party title bars on the window tokens) | ADR-0040: the neutrals' warmth (`color.light` and `color.dark` surfaces and text, `titlebar.*`, `window.inactiveLight*`, the icon plates' backdrop; hue 85, chroma 0.0075, each lightness kept) | ADR-0039: which roles read them, the glass classes and their alphas; its values read warm now (#FFFFFF and #292929 are `#FDFCF9` and `#2B2925`) |
| About: ADR-0039 steps 4 and 10 ↔ ID-19; IQ-B1's dialog glyphs | ADR-0040: About This Computer's form, the glyphs of `NoticeDialog` and `ConfirmDialog` | ADR-0039: `Dialog`'s and `Sheet`'s grammar (radius, buttons, blur radius) |
| `looknfeel.lua`, `windows.lua`, `Compositor.qml`: ADR-0039 steps 6 and 20 ↔ ID-2, ID-4, IQ-T5 | ADR-0040: the ground colour, the first frame and the transitions | ADR-0039: the window border colour per appearance and the compositor's animation curves |
| Motion tokens: ADR-0039 Q6 ↔ the session and lock fades | ADR-0039: `motion.*` | ADR-0040: `session.*` and `lock.*` fades, naming a `motion` role where one fits |
| `shell/saver` | ADR-0040: the saver's transitions (ID-8) | ADR-0039 step 5: its slide crossfade under Reduce Motion |
| Settings' Appearance and Wallpaper pages | ADR-0040: the wallpaper page and the accent row | ADR-0039: the shared controls and the glass preview (its step 15) |
| `GrassfieldArtwork.qml`'s colours | ADR-0040 (ID-1) | ADR-0039 step 2 drops them from its allowlist when ID-1 lands |
| The Dock's and menu bar's auto-hide: ADR-0039 step 25 ↔ step 6 here | ADR-0040: the reveal at login | ADR-0039: Reduce Motion and the easing of auto-hide |
| `tests/visual/test_contrast_tokens.py`, `contrast-roles.json` | ADR-0039: the role table's repair (its step 0b) | ADR-0040: the roles of its own surfaces (the lock's scrim bands) |

## Delivery plan (one pull request per step towards main; split by the review of b44d17e)
| Step | Content | Blocked by | Review |
|---|---|---|---|
| 0 | This ADR, the audit, the mockups, E39, STATE | — | integrator |
| 1a | `DevicePicture` moves from the Settings app into `Grassfield.Ui` (so the shell can draw it), the Settings pages unchanged | — | reviewer; `ui_api.py` and `docs/specs/ui-api.md` |
| 1b | About This Computer as a small window, computer first (ID-19): Settings' own window (`grassfield-settings --about`), the shell's sheet retired | step 1a | reviewer |
| 1c | The accent's name and the second green (IQ-B3 A) with the Settings tiles, the About tile (ID-11) | coordinate with ADR-0039 step 11 | reviewer; A2 |
| 1d | The mark's places and the dialogs' symbols (IQ-B1 B) | — | reviewer |
| 2 | Artworks: one component, `artwork.*` tokens (the four artworks, the Grassfield hills in four phases and two sets), the time-of-day rule (IQ-W1 C), the Settings > Wallpaper "Grassfield" section and its Time of Day / Automatic / Light / Dark choice, the Settings > Appearance thumbnail, A2 runs at every phase, the desktop following the appearance (ID-1, ID-14; IQ-W1 C, IQ-W2 C's artworks). Nothing in `shell/security`; the lock's output unchanged: `WallpaperArt` without a parameter keeps today's drawing, so `LockView.qml` (`:80`) is not edited before step 4a (review of ed21d46) | `shell/desktop` merged (today `WallpaperArt.qml` passes no parameter, so the desktop cannot show the choice before) | reviewer; F1 shots |
| 3 | The wallpaper's first frame from the cache, the ground on Hyprland and the wallpaper window, wallpaper `no_anim`, a hotplugged output's wallpaper, the measurement (ID-2 to ID-4, ID-15's wallpaper part, ID-16). Nothing in `shell/security` | `shell/desktop` merged | reviewer |
| 4a | Lock, the still and the data: the user's wallpaper (ADR-0016 W8), the preloaded still, the scrim (IQ-W4), the surface colour on the ground and on a hotplugged output (ID-2, ID-15), avatar and name once, the clock on resume (ID-7) | step 3; `shell/desktop` merged (LockView imports `qs.desktop`) | **opus security review**, L1 to L5 |
| 4b | Lock, the motion: the fades and the `releasing` state (IQ-T2) | step 4a | **opus security review**, L1 to L5 |
| 5 | Idle, saver and display-off order (ID-8, IQ-T4 A); the red-screen delay, black meanwhile (IQ-T5 A; the nested pass shows only black during the delay) | step 4b | **opus security review** |
| 6 | Session entrance: the ready latch, menu bar, Dock and icons together (ID-20), the menu bar's auto-hide at rest (ID-6), settings first (ID-5), P5 with the wallpaper | `shell/menubar`, `shell/dock`, `shell/desktop`, Appearance.qml merged | reviewer; P5 owner logins |
| 7 | Exit: the countdown (ID-21), the exit cover (ID-10) | — | reviewer |
| 2c | Photographs (IQ-W2 C): first the list (thumbnail, source, licence) to the owner for the legal call; then the files, their `docs/legal` entries, the helper path, the package weight in the pull request | the owner's legal call on the list | reviewer; legal rows |
| 8 | App icons (IQ-B5 C): own icons for Store, Activity Monitor and the Apps tile on one grammar; the two new drawings to the owner's legal call first | `apps/store`, `apps/activity` merged | reviewer; legal row |
| 9 | The moving variant (IQ-W3 A, in 1.0): off by default, the video pause rules, also a screen saver kind in `shell/saver`; nothing in `shell/security` (review of 6c310a8); P1 and P3 measured with it on before the merge request, over budget blocks it | step 2 | reviewer; P1, P3 |
| 10 | Login and boot themes (IQ-L1 C): their own ADR first; SDDM theme in the lock's layout; Plymouth theme with the mark only with the owner's explicit go-ahead inside that ADR (outside master-prompt §4's allowance; plymouthd runs as root in the boot image); a tested fallback to the text disk-password prompt; every root step an owner command | steps 4a, 4b and 5 (the last identity step) | **opus security review**; owner runs |

## Not verified, assumptions, unknowns
- **NOT VERIFIED:** every proposal's rendering in Grassfield (no nested session in this container); the mockups were
  rendered in the container's Chromium only to check the drawings. Every runtime visual claim marked [inference] in the
  audit waits for the integrator's nested pass.
- **ASSUMPTION (macOS, from memory):** the lock screen shows the wallpaper sharp; at login the wallpaper comes first,
  then the menu bar and Dock; auto-hidden bars start hidden; the restart, shut down and log out confirmations count
  down 60 s; Settings offers "Automatic / Light / Dark" for dynamic wallpapers; the lock fades in and out. The owner's
  references have no capture of any of these (`docs/testing/f1-reference-gaps.md:317-321`).
- **VERIFY on Hyprland 0.56.2:** changing `background_color` at run time (ID-2); whether a session lock is confirmed
  while the displays are off (IQ-T4 A with a delay). `misc:lockdead_screen_delay` exists (the integrator's check, review
  of b44d17e); the owner chose IQ-T5 A, so step 5's nested pass shows that only black is drawn during the delay.
- **NOT VERIFIED (step 1c, nested pass):** the accent row, the green tiles' white glyphs and the brand-green tile of
  General > About in the session (offscreen Qt 6.10 draws no `Icon` here); a GTK app with the Green accent (the pinned
  thin marks); the shell's surfaces with the Green accent (menu highlights, focus rings falling back to the text colour).
- **NOT VERIFIED (step 1b, nested pass):** About This Computer in the session: the window's look and size, the mark
  in the brand green (the container's offscreen Qt 6.10 renders no `Icon`: MultiEffect draws nothing there), the shell
  bringing an open window forward. That rests on Hyprland's window data carrying `xdgTag`, which
  `tests/compositor/client_chrome.sh` already reads in the nested session. The single instance (review of ce69dc6): not
  built or run in this container (no Qt development files); the nested pass checks Settings… and a section link with
  Settings open, More Info… with Settings open on another pane, two quick About requests, and the window coming forward
  without a token from the shell (`misc:focus_on_activate` is on). ASSUMPTION (macOS, from memory): About This Mac has no
  title on its bar and only its close light enabled.
- **VERIFY on the owner's machine:** that Arch's tzdata installs `zone1970.tab`, `zone.tab` and `tzdata.zi` under
  `/usr/share/zoneinfo` (they are in this container; IQ-W1 C reads them, and falls back to the fixed hours without
  them).
- **UNKNOWN:** the look of Omarchy's boot and disk-password screens on the owner's machine (not readable here).

## Alternatives rejected
- A cover window that hides the desktop until everything is ready: a splash under another name, not macOS (ID-20).
- A blurred snapshot of the desktop on the lock: window content on the lock breaks gate L4.
- Fading the desktop out before engaging the lock: delays the lock (P-5).
- Shipping photographs that resemble Apple's wallpapers, or any Apple asset: §14.
- Recolouring the mark in its file or drawing variants of it: the mark is the owner's; colour is applied at run time
  only, as IQ-B1 decides.
- A new "brand" colour token beside the default accent: the default accent tokens already are the brand green (R5).
- The first drawings of Activity Monitor (a dark tile with a green line graph) and of the Apps tile (a three-by-three
  grid of coloured squares): too close to macOS's own icons for those apps (review of b44d17e); redrawn as a gauge and
  as fanned cards.

## Legal
- New entry E39 in `docs/legal/visual-review.md`: the mockups (made here, CC-BY-SA-4.0; the existing app icons embedded
  from `branding/icons/apps`, CC-BY-SA-4.0; the mark embedded unchanged, all rights reserved). E12, E32 and E33 carry an
  "Update 2026-10-29" pointing here.
- The proposed artworks inherit E32's flag (`distinct`, side-by-side check before release); names included (ID-18).
- The lock and About layouts stay `close` (E2, E12). The proposed Activity Monitor and Apps tile drawings are flagged
  for the owner's legal call: they were redrawn away from macOS's icons for those apps, and no claim is made that they
  are far enough; the owner chose IQ-B5 C, and the drawings go to the owner's legal call before step 8 ships them. No
  lockup (IQ-B2 A). B-5: the owner checked the name "Grassfield" on 2026-10-18, not the logo; the dossier says so (E33,
  Q7, section 7). Photographs (IQ-W2 C): a licence and provenance entry each, and the owner's legal call on the list
  before any ships.

## Evidence
- The audit's spot checks 1 to 13 (`docs/audits/identity-2026-10-29/audit.md`, section 5), each with its command and
  exit status, on main 11c9e69, and the re-check on main e03c859 (its section "After main e03c859").
- `python3 -I docs/audits/identity-2026-10-29/mockups.py` → exit 0, eight SVG files; `xmllint --noout` on them → exit 0;
  `git diff --check origin/main...HEAD` → exit 0; each SVG rendered with Playwright Chromium in the container (scratch
  PNGs, not committed) and inspected.

## Review history
- **Opus review of b44d17e (integrator, 2026-10-29): FAIL, two MAJORs, five MINORs.** 18 claims checked, all exact.
  - MAJOR 1, step 3 changed the lock surface under a normal review (ID-2, ID-15): the lock surface's colour and a
    hotplugged output's lock surface move to step 4a, under the opus security review; step 3 touches nothing in
    `shell/security`.
  - MAJOR 2, the proposed Activity Monitor and Apps tile icons looked like macOS's: both redrawn (a gauge on a light
    tile; three fanned cards), the "less resemblance" claim removed, E39 flags them for the owner's legal call.
  - MINOR 3, trailing spaces in `b4-app-icons.svg`: `mockups.py` now strips the embedded icons' whitespace and every
    line it writes; `git diff --check` exits 0.
  - MINOR 4, step 2a could not show the artwork choice before `shell/desktop` merges, and the lock draws the artwork:
    step 2 now waits for that merge and keeps the lock's drawing unchanged until step 4a.
  - MINOR 5, IQ-B3 omitted the Settings tiles in the pickable Green: named in section 3 and in the question.
  - MINOR 6, ID-9 reversed H10: now the owner question IQ-T5.
  - MINOR 7, steps 1 and 4 too big: step 1 split into 1a (`DevicePicture` into `Grassfield.Ui`) to 1d, step 4 into 4a
    (the still and the data) and 4b (the fades and `releasing`).
  - Questions: IQ-W3 now recommends B for 1.0; IQ-B1 carries the mark's rules; IQ-B3 names the tiles and goes with
    ADR-0039's Q4 (answered as D-Q4); IQ-B5 now recommends C, the closest to the owner's rule of 2026-10-23; IQ-B4,
    IQ-T1 and IQ-T3 are decided under the macOS model (ID-19 to ID-21); IQ-T5 added.
  - Overlaps with ADR-0039: the section "Coordination with ADR-0039", one owner per overlap, as ADR-0039 lists them.
  - Main e03c859 merged in: the startup-settle fix (8b5efac) already makes the Dock and the desktop icons appear once;
    the audit records it, and ID-5 and ID-6 now cover the menu bar and the wallpaper only.
- **Opus re-review of ed21d46 (integrator, 2026-10-29): FAIL, one MAJOR, one MINOR, two NITs.** Both earlier MAJORs and
  the earlier MINORs fixed (step 2 in part).
  - MAJOR 1, IQ-T4 A was "stricter than today" only on battery: following display-off alone moves the AC default from
    5 to 10 min and never locks with display-off Never and the saver off. Option A now keeps the inactivity limit as the
    ceiling (whichever comes first), so it is never later than today; the question states the defaults and why the
    display-off-only form is not offered; the recommendation, re-checked, stays A.
  - MINOR 2, step 2 could have edited `LockView.qml` under a normal review: step 2 now says "nothing in
    `shell/security`; the lock's output unchanged" (`WallpaperArt` without a parameter keeps today's drawing).
  - NIT 3, stale line references in `visual-review.md` after the merge: `MenuBar.qml:870`, `STATE.md:120, 233`.
  - NIT 4, an interrupted `releasing` needs a new PAM success: said in section 4.
- **Opus review of 6c310a8 (step 1a, pull request #52; integrator, 2026-10-29): FAIL, one MAJOR, one MINOR, three
  NITs.** The answers table, the conditions and the `DevicePicture` move were confirmed.
  - MAJOR 1, the time-of-day rule read `zone1970.tab` only, so aliased zones (the owner's Europe/Amsterdam, Africa/Douala,
    Stockholm, Oslo, Copenhagen) fell to the fixed hours: the rule now looks up `zone1970.tab`, then `zone.tab`, then
    the linked zone (`tzdata.zi`), and the probe checks Amsterdam, Douala, Stockholm, a link, the polar branch (which now
    runs: Longyearbyen has a `zone.tab` row), UTC, and the new short-day and short-night rules (12 checks; with
    `zone1970.tab` alone, 6 fail: corrected in step 1b, it said 5).
  - MINOR 2, the R12 argument covered SDDM only: Plymouth is now outside today's allowance and needs the owner's explicit
    go-ahead inside the L1 ADR (section 3, step 10).
  - NIT 3, step 9 says "nothing in `shell/security`"; NIT 4, the stale IQ-T5 wording is fixed; NIT 5, commit 135f0ef's
    author: not rewritten (no history rewrite), the later commits are authored as the owner.
- **Opus re-review of 8a75435 (integrator, 2026-10-29): PASS, one NIT** (merged as a5488a6). The NIT, "five checks fail"
  where the first rule (`zone1970.tab` alone) fails Montreal too, is fixed in step 1b: six (section 2 and the line above).
- **Opus review of ce69dc6 (step 1b, pull request #55; integrator, 2026-10-29): PASS on code, four MINORs, two NITs.**
  - MINOR 1, any lock failure kept About from opening, MINOR 3, More Info… opened a second Settings window when Settings
    was open: Settings is one instance per user over the session bus (AM1's pattern), the lock file is gone.
  - MINOR 2, lspci and `pacman -Q` ran on the GUI thread: shared queries; the window waits for hostname1 and lspci within
    the same bound.
  - MINOR 4, the retired `about` popup kind could still map an empty overlay: Popups refuses any kind its Overlay does not
    draw (`shell/services/PopupKinds.js`, held to the Overlay by `tst_popupkinds.qml`, checked on the real Popups by
    `lock_surfaces`).
  - NITs: "Logiciel" in both places; tests for Esc and Ctrl+W, the hidden empty lines and the window lookup
    (`Minimized.hasTag`).
- **Opus re-review of c6cf328 (integrator, 2026-10-30): FAIL, one MAJOR, one MINOR, one NIT.** The four MINORs above
  confirmed fixed.
  - MAJOR 1, a second launch gave up after 2 s and opened its own Settings while the first was still starting (3.7 to
    7.7 s under load): the hand-over is Activity Monitor's `claimOrHandOver` (up to 25 s; a launch leaves whatever the
    answer and runs only when the name has no owner left). Reproduced with the real binary and a Settings window that takes
    5 s to start: the old hand-over left two instances, the new one one.
  - MINOR 2, nothing tested the single instance: `tests/unit/settings/tst_settingsinstance.cpp` (the name and its suffix,
    the cleaning, the hand-over on a private dbus-daemon, a dev run beside the owner's), built by `build-direct.sh --tests`.
  - NIT 3, `Backend::query` checks its allow-list only in dev: About's commands go through `Backend::readOnlyQuery`, which
    checks it in every session (`tst_backend.cpp`).
- **Opus re-review of 85c2c10 (integrator, 2026-10-30): PASS** (6 races on a private bus at load 8 to 13.5, no second
  instance; a frozen Settings bounds a launch at 25 s per attempt). A MINOR left for a follow-up: a Settings that dies while
  a launch waits on it answers NoReply, not "no owner", so that click was lost; the launch now retries whenever the name has
  no owner after any error (`tst_settingsinstance.cpp`: the owner, this test binary run again, killed during the call).
- **Nested pass of 85c2c10 (integrator, 2026-10-30): single instance PASS; FAIL scenario 6, one MINOR.**
  - Scenario 6, the pointer resting on About's disabled (grey) zoom light opened the full tiling popover: the plugin posted
    `tile-hover` for every `org.grassfield.*` window with app-drawn lights. A window of fixed size (minimum = maximum on both
    axes, core `tiling::fixedSize`) now posts no `tile-hover` from its zoom light and `tile_popover` (Super+Ctrl+L) is
    refused for it, on hover or click; the `hyprctl grassfield-tiling` reply lists such windows (`fixed`), and the Window
    menu greys their Zoom, Enter Full Screen, Full Screen Tile and tiling items (Unzoom and Exit Full Screen stay); the
    tiling keys refused them already (TL9). Tests: `TilingFixed` (core), `tst_windowtiling.qml`, `tst_appmenumodel.qml`
    and the nested case `fixed` of `tests/compositor/tiling.sh` (About's hover and click: no event, no popup, its box kept).
  - MINOR, in French About's processor wrapped to three lines: the window shows the processor's name alone (About This Mac
    names the chip alone; the French thread count alone cut the model), shortened (`SysInfo.cpuShortName`: no "(R)",
    "(TM)", "CPU", clock, generation prefix, integrated graphics or trailing "Processor"), on one line cut in the middle,
    the full model name in a tooltip while the pointer rests on it when it was shortened or cut. General > About keeps the
    thread count after the same short name.

- **Opus review of 5391761 (step 1c, pull request #69; integrator, 2026-10-30): FAIL, one MAJOR, two MINORs, NITs.** The
  design held; the nested pass (French, light and dark, the accent row, About, the controls, the Dock and the menu bar in
  Green) was legible.
  - MAJOR 1, the new About test's fake system had `act()` alone: three TypeErrors in the full unit run, which gate Q2
    (`tests/ci/qml_warnings.py`) counts. The fake now has what AboutPage and DevNote read (`queryBus`, `errors`,
    `suppressedNote`); Q2 exits 0 on the full run.
  - MINOR 2, Software Update's Grassfield release row drew the mark's tile in the pickable Green: it uses the brand green.
  - MINOR 3, text drawn in the accent colour fell to 2.1-2.5:1 with the light Green (yellow already had it). The
    integrator's decision, under the owner's rule of 2026-10-27: as macOS, a light accent's text is drawn darker. A role,
    `colors.accentInk`: `color.accentInkLight` gives yellow `#816500`, green `#467427` and pink `#BD2F6C` (pink was 4.34:1
    under a rimmed capsule), each the lightest shade of its accent with 4.5:1 on an app window; every other accent and the
    dark appearance draw in the accent itself. Two A2 roles: on an app window (4.5:1, every accent, both appearances) and
    on glass (exempt: no accent holds 4.5:1 over the worst wallpaper, the Grassfield green 2.36:1; every ink keeps 2.2:1,
    tested). Ten texts and glyphs moved to it (the widgets' weekday, a Control Center checkmark, the alert glyph, Files'
    Show All and Show More and sidebar glyphs, the Store button label and its sidebar and category glyphs); a test fails
    when a text or glyph reads the bare accent.
  - NITs: ADR-0039's knob wording and the comments of `RadioRow.qml` and `StoragePage.qml` now name green beside yellow;
    main merged (STATE only).

## Consequences
- The owner's answers of 2026-10-29 decide steps 1c to 10 (section "Owner decisions (2026-10-29)"); step 1 starts first.
- ADR-0016 is extended, not replaced: its §6 (the lock still) is step 4a here; its §10 P5 promise is kept by ID-3.
- ADR-0014 and ADR-0017: under IQ-B5 C (decided) the pack keeps Files, Settings and Preview; own icons for Store,
  Activity Monitor and the Apps tile.
- A new ADR for the login and boot themes (IQ-L1 C) before step 10.
- ADR-0020 gains rows for the new keys and the wallpaper state when steps 2, 3 and 5 write them.
- Security: steps 4a, 4b and 5 are security-module changes (R12), each with an opus security review.
