# ADR-0040: Grassfield identity: wallpapers, brand, lock screen and session transitions
Status: Proposed (step 0 of the owner's brief "Identité Grassfield", 2026-10-29; documents only, no code). The owner
questions IQ-W1 to IQ-T4 are open; every other choice follows the owner's rule of 2026-10-28 ("the closest to macOS 27,
no technical step for the end user") and is listed in "Decisions taken under the owner's rule" (ID-1 to ID-18), which
the owner can revisit. · Date: 2026-10-29 · Decider: owner (IQ), integrator (merge; ID under the rule) · Number: 0040
(0001 to 0038 are on main 11c9e69; 0039 is the design-polish ADR of the open pull request #45; #41, #43 and #44 add none)

This ADR proposes one identity for Grassfield across its wallpapers, its brand (mark, name, accent, About, app icons),
its lock screen and every session transition. The audit it rests on is `docs/audits/identity-2026-10-29/audit.md`
(findings W-1 to W-12, B-1 to B-12, L-1 to L-7, T-1 to T-17, with file and line). The mockups are SVG files in
`docs/audits/identity-2026-10-29/mockups/`, written by `mockups.py` next to them; they are design documents, never
shipped. Legal points are marked "needs legal review" (master-prompt §14); none is a conclusion.

**Read with ADR-0039 (design polish, pull request #45, same day).** That ADR sets one grammar for materials, controls,
windows and accessibility settings; this one covers what makes Grassfield recognisable and how it appears. Two questions
touch each other and are best answered together: its Q4 (one green for "on" in the dark appearance) with IQ-B3 here
(the accent's name and the second green), and its Q1 (the buttons at the foot of a sheet, the shell's About among them)
with IQ-B4 here (About This Computer as a small window). Neither ADR changes the other's scope.

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
- **Transitions.** No ground colour, no "ready" gate, no single entrance: `#1C1C1E`, then the bars alone, then the
  artwork, then the picture (T-1 to T-8); idle and display-off paths undim or light the desktop for a moment (T-10 to
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
  the desktop icons appear together, once (IQ-T1). Nothing slides away right after appearing.
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
- **Collection (IQ-W2, recommended A).** Four Grassfield-made procedural artworks, each with a light and a dark variant:
  **Grassfield** (the hills of today), **Meadow** (grass blades close up, not the mark's shape), **Field Rows** (a field
  seen from above), **Ridgeline** (one quiet hill line, the calmest backdrop for glass); plus the eight colours of today.
  Mockup: `mockups/w2-collection.svg`. No image file ships: each is drawn by one shared QML component from token
  palettes (ID-1), crisp at any size, with the menu bar tone known from the palette, never measured late.
- **Default (IQ-W1, recommended A).** "Grassfield, Automatic": a new **Day** variant in the light appearance and
  today's artwork, named **Evening**, in the dark one (the default appearance is dark, so a new user sees today's
  desktop). Same geometry, only the palette changes. Mockup: `mockups/w1-default-wallpaper.svg` (also the option B
  Night variant and the option C time-of-day set).
- **Following the appearance.** A switch of appearance crossfades between the two variants through the existing
  two-slot model (one fixed `wallpaper.crossfadeMs`), the bar tone switching at the crossfade's midpoint from the
  palette; Reduce Motion cuts (ID-14). Settings shows each artwork as one tile in the current appearance, with
  "Automatic / Light / Dark" for the chosen one (macOS's pop-up for its dynamic wallpapers, ASSUMPTION). Settings >
  Appearance draws the real dark variant instead of darkening the art (W-3).
- **Videos (IQ-W3, recommended A).** No video file ships. The user's own videos stay as built (ADR-0016 W7). The
  default artwork gets an optional **moving** variant drawn live (clouds drift, the light changes slowly), off by
  default, under the video pause policy (idle, battery, full screen, lock, Reduce Motion, the Reduced profile), and
  offered as a screen saver kind. It is built only after P1 and P3 are measured on the owner's hardware.
- **First frame (ID-3).** The wallpaper window shows the **last applied wallpaper's prepared still** from the cache as
  its first frame, with the bar tone from its stored statistics, and maps only then (bounded by
  `wallpaper.firstShowTimeoutMs`, after which the artwork). When the feed's result is the same file, nothing fades.
  This removes the artwork-then-picture sequence (W-7) and the late tone switch (W-8), and keeps ADR-0016's rule that
  the shell decodes only the helper's own output.
- **Lock still.** ADR-0016 §6 (W8) as already specified, plus the preloaded still of ID-7 (section 4).
- **Legibility (A2).** Every variant goes through `tests/visual/contrast.sh` (menu bar strip, desktop labels, lock);
  the artworks' tones come from their palettes.

### 3. Brand
- **The mark (IQ-B1, recommended B; the file is not touched).** Proposed rules for any option: clear space of a
  quarter of the mark's height on every side; 14 px minimum; never stretched, rotated, outlined, given a gradient or a
  shadow, or redrawn; only the file's path is used, at run time. Places under B: the menu bar's system button
  (monochrome, the bar's text colour), About This Computer and Settings > General > About (the Grassfield green), the
  Search result for About; shell dialogs show their subject's symbol instead of the mark. Mockup: `mockups/b1-logo-use.svg`.
- **The name (ID-12, IQ-B2).** "Grassfield" names the product in running UI ("Grassfield menu", "Grassfield
  Settings"); "Grassfield Desktop" where the product and its version are stated (About, the session's comment);
  "Grassfield OS" only from M6 (§14). App names keep the owner's decisions (L1, ADR-0038 AQ1). The greeter's "Grassfield
  (uwsm)" suffix stays (Omarchy's theme needs it to pick the session, B-6), a documented limit. No lockup or wordmark
  in 1.0 (IQ-B2 A); the mark alone is the symbol.
- **The accent (IQ-B3, recommended A).** The default is named "Grassfield" (a green swatch first in the row, in place
  of the Multicolour wheel), the pickable Green moves to a value clearly apart from the brand green with its own 4.5:1
  text, and the brand green is the existing default-accent tokens (`color.light.accent` `#26763F`, `color.dark.accent`
  `#4FB36B`; no new brand token). Settings > About's tile uses it (ID-11). Mockup: `mockups/b2-accent.svg`.
- **About This Computer (IQ-B4, recommended A).** Computer first, as macOS 27 and as Settings > About already do: the
  Grassfield-drawn picture of the computer (`DevicePicture`, by chassis), its model name, processor, memory, graphics,
  then "Grassfield Desktop 1.0" with the mark in the brand green, "More Info…" (opens Settings > General > About) and
  "Built for Omarchy · based on Arch Linux" (§14 wording). Mockup: `mockups/b3-about.svg`.
- **App icons (IQ-B5, recommended B).** Grassfield's own apps carry Grassfield's own icons, on one grammar: one tile
  (104 on the 128 grid, radius 23.4, which is ADR-0014's plate radius 0.225), a top-to-bottom gradient and a light inner
  rim, one drawing in the brand palette inside 72 % of the tile (so ADR-0014's Dark, Clear and Tinted plates take it),
  no text. Files keeps its folder on a tile (so the app no longer looks like a folder on the desktop); Settings,
  Preview and Store keep their drawings; Activity Monitor and the Dock's Apps tile get new ones. Under B the
  `org.grassfield.*` aliases to the pack go. Mockup: `mockups/b4-app-icons.svg`.
- **Boot and login (IQ-L1, recommended A).** Omarchy's path stays (Limine, the disk password, SDDM autologin); a
  greeter of our own is a non-goal and R12 forbids writing one. Grassfield's identity starts at the ground colour.

### 4. Lock screen (security module: display only, opus security review, R12)
- **Backdrop (IQ-W4, recommended A).** The prepared still of the output's current wallpaper, sharp (the artwork, drawn
  as today, when the wallpaper is an artwork); the scrim `lock.dimOpacity` 0.6 under the date and clock band and under
  the name and field band, `lock.scrimClearOpacity` 0.25 between them, the band edges `lock.scrimFeather` wide and
  outside every text line at every text scale. A2 is computed per band (`test_contrast_tokens.py` lock roles) and
  measured (`contrast.sh --surfaces lock`). Mockup: `mockups/l1-lock.svg`.
- **Ready before it is needed (ID-7).** The lock keeps one decoded still per output, loaded when the wallpaper changes,
  not when the session locks; the avatar picture and the full name are resolved at shell start and on account change;
  the lock surface's colour is the ground under the scrim, not black; the clock is refreshed on resume, before the first
  frame after a wake (T-14). Once the lock shows, nothing on it changes but its own fade (L-3, L-4).
- **Motion (IQ-T2, recommended A).** Lock: engaged at once; inside the surface, scrim and text fade in over
  `lock.fadeInMs` 200 (from the idle dim's level when the lock follows it, ID-8). Unlock: after PAM success a new
  machine state `releasing` fades text and scrim out over `lock.fadeOutMs` 200 and only then sets `locked = false`.
  Reduce Motion: cuts.
- **Unchanged.** The layout and its tokens, the field, the shake, the messages, the reserved hint line (L-5), one surface
  per output, gate L4 (no window or notification content).
- **Invariants for the reviewer.** Engaging the lock never waits for the still, the avatar, the name, the settings or a
  fade. The release happens only after PAM success and after the fade; any event during `releasing` (a lock request, a
  lost lock, an error, a timeout, a shell exit) leaves the session locked and brings the content back. The still is
  Grassfield's own JPEG in the 0700 cache, a regular file of at most `wallpaper.lockStillMaxBytes`, decoded at screen
  size; any failure shows the artwork; no user original and no video decoder enters the module (ADR-0016 §6). Tests:
  L1 to L5, `tests/security/reload_locked.sh`, and new cases (a fade interrupted by a new lock; a missing still; a
  release refused during the fade; the first lock right after shell start).

### 5. Session transitions (the proposed sequence of each; storyboards in `mockups/t1-transitions.svg`)

| Transition | Today (audit) | Proposed | Where; step |
|---|---|---|---|
| Boot to session | Omarchy's boot, disk password, autologin; Hyprland `#1C1C1E` (T-1) | unchanged up to the session (IQ-L1 A); the session's Hyprland background is the default artwork's ground; the shell sets the current ground at start and on change (ID-2) | `config/hypr/grassfield/looknfeel.lua`, shell; step 3 |
| Login to desktop, desktop loading | `#1C1C1E`, bars alone, the artwork fading in, then the picture and a bar tone switch; defaults before the settings; auto-hidden bars slide away (T-2 to T-8) | ground; the wallpaper's cached still (ID-3); once the settings are read (ID-5) and every surface has its final content, menu bar, Dock and desktop icons in one 250 ms fade (IQ-T1 A); auto-hidden bars start hidden (ID-6); P5 counts the wallpaper | `shell/desktop`, `shell/menubar`, `shell/dock`, `shell.qml`, `windows.lua`; steps 3 and 6 |
| Lock | black first frame [inference], blurred artwork, no fade (L-3, W-9) | same picture, windows go, scrim and text fade in (IQ-T2 A, IQ-W4 A) | `shell/security/lock`; step 4 |
| Unlock | hard cut to another picture (L-3) | fade out while locked, then release | step 4 |
| Idle dim, then lock | the dim drops before the lock is up [inference] (T-10) | the dim stays until the lock holds; the lock's content starts at the dim's level (ID-8) | `shell/security/idle`; step 5 |
| Displays off, then lock | the displays light up to draw the lock (T-11) | lock just before the displays go off (IQ-T4 A) | `shell/security/idle`, Settings > Lock Screen; step 5 |
| Screen saver, then lock | the saver goes before the lock is up [inference] (T-12) | the saver stays until the lock holds (ID-8) | `shell/saver`; step 5 |
| Sleep | locked before sleep when confirmed; exceptions show the desktop on wake (T-13) | unchanged path; the exceptions stay a documented limit (the budget is the system's) | — |
| Wake | the clock may show the sleep time, then jump (T-14) | clock refreshed on resume before the first frame (ID-7); the lock's picture and name already final | step 4 |
| Shell restart | bars vanish, windows over `#1C1C1E`, the whole start again; red screen when locked (T-15) | windows over the ground; the cached still and the single entrance; the red screen delayed past a normal restart (ID-9) | steps 3, 5, 6 |
| Log out, restart, shut down | no countdown; layers vanish one by one (T-16) | 60 s countdown (IQ-T3 A); after the windows close, one fade of the whole screen to the ground then black, then the session ends (ID-10) | `shell/overlay/SystemMenu.qml`, `packaging/bin/grassfield-session-end`; step 7 |
| Output added or removed | black lock surface [inference] (L-6) | the new output's wallpaper and lock surfaces start at the ground and show its still (ID-15) | steps 3, 4 |
| Appearance switch | the wallpaper does not change (W-3) | crossfade between the artwork's variants; tone at the midpoint (ID-14) | step 2b |
| Wallpaper change | crossfade (ADR-0016) | unchanged | — |

### 6. Tokens and contract (proposed; every value an estimate until F1 and P3)
| Token or key | Value | Note |
|---|---|---|
| `artwork.<name>.<variant>.<role>` | the palettes of `mockups.py` (`PAL`, `meadow`, `rows`, `ridgeline`) | ID-1; `evening` keeps today's values (`GrassfieldArtwork.qml:12-21`) |
| `session.settingsWaitMs` | 500 | ID-5 |
| `session.revealTimeoutMs` | 1500 | the latch's bound (P-6) |
| `session.revealMs` | 250 | IQ-T1 A (ASSUMPTION for macOS) |
| `session.exitFadeMs`, `session.exitWaitMs` | 400, 1000 | ID-10 |
| `wallpaper.firstShowTimeoutMs` | 1500 | ID-3 |
| `lock.fadeInMs`, `lock.fadeOutMs` | 200, 200 | IQ-T2 A |
| `lock.scrimClearOpacity`, `lock.scrimFeather` | 0.25, 48 | IQ-W4 A; A2 per band |
| `wallpaper.artwork` | `grassfield` \| `meadow` \| `rows` \| `ridgeline` | additive key, default `grassfield` |
| `wallpaper.artworkVariant` | `automatic` \| `light` \| `dark` (\| `timeOfDay` under IQ-W1 C) | additive, default `automatic` |
| `wallpaper.moving` | bool, false | IQ-W3 A |
| `lock.requirePasswordAfter` | `immediately` \| `5s` \| `1m` \| `5m` \| `15m` \| `1h` \| `never` | IQ-T4 A; migrates `lock.idleMinutes` (ADR-0020 row) |
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

## Owner questions (each with two or three options; the recommended one in bold)

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

**IQ-W3. Videos.**
| Option | For | Against |
|---|---|---|
| **A. No video file; an optional moving variant of the default drawn live, off by default, with the video pause rules; also a screen saver kind (recommended)** | no package weight, no codec, no new licence; motion in the brand scene; pauses like a video | GPU work while visible (the Dock and popups re-blur every frame, as with any video): built only after P1 and P3 on the owner's hardware |
| B. No motion in 1.0 | nothing to measure | no answer to macOS's video wallpapers but "add your own" |
| C. Pre-rendered H.264 loops of the artwork | hardware decode, same path as user videos | 20-60 MB per loop, a build-time renderer, FFmpeg (G9) in the shell by default |

**IQ-W4. The lock screen's backdrop** (ADR-0016 Q4 was settled on 2026-10-20 as its recommended option, a sharp still
under the existing scrim, an integrator decision the owner can revisit; this asks whether the scrim stays flat now that
the identity is designed). Mockup `l1-lock.svg`.
| Option | For | Against |
|---|---|---|
| **A. The user's wallpaper, sharp; scrim 0.6 only under the text bands, 0.25 between (recommended)** | shows the wallpaper as macOS does (ASSUMPTION) and as the desktop does; A2 holds where text is | band geometry to prove at every text scale; security review |
| B. Sharp, with today's flat 0.6 scrim (ADR-0016 Q4 as settled) | simplest; A2 already computed | the picture reads dim and grey |
| C. Blurred, flat scrim (today's look with the user's wallpaper) | calm; hides busy pictures | blur cost per output; less continuity with the desktop |

**IQ-B1. Where and in what colour the mark appears** (the mark itself is not changed). Mockup `b1-logo-use.svg`.
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

**IQ-B3. The default accent's name and the second green.** Mockup `b2-accent.svg`.
| Option | For | Against |
|---|---|---|
| **A. The default is named "Grassfield" (a green swatch); the pickable Green moves away from the brand green (recommended)** | the brand colour is named; no two near greens | departs from macOS's "Multicolour"; users who chose Green see it change |
| B. Keep "Multicolour" and both greens | macOS's model and name | "Multicolour" means one green here; two greens read alike |
| C. Keep "Multicolour", drop the pickable Green | no near-duplicate | seven colours; users of Green move to the default |

**IQ-B4. About This Computer.** Mockup `b3-about.svg`.
| Option | For | Against |
|---|---|---|
| **A. Computer first (macOS 27): picture, model, hardware, then "Grassfield Desktop 1.0" with the mark, More Info… (recommended)** | matches Settings > About and macOS; the brand once, quietly | a small window instead of a sheet (shell/overlay work) |
| B. Brand first: the mark large, "Grassfield Desktop", the version, then the computer | a strong brand moment | unlike macOS 27 and unlike Settings > About |
| C. Today's sheet of rows | no work | no picture and no mark |

**IQ-B5. The icons of Grassfield's own apps** (the owner decided on 2026-10-23 that system apps take the pack's icons;
this asks whether Grassfield's own apps are the exception). Mockup `b4-app-icons.svg`.
| Option | For | Against |
|---|---|---|
| A. As today: the pack for Files, Settings, Preview; own icons for Store and Activity Monitor | one look with the pack | the brand is absent from most of its own apps; inconsistent (Store own, the rest the pack) |
| **B. Grassfield's own icons on one grammar for every Grassfield app; the `org.grassfield.*` aliases go (recommended)** | the apps carry the brand; less resemblance with Apple's icons for our own apps; the tile matches the pack's plate | our drawings sit beside the pack's richer ones until a designer redraw; partly reverses the 2026-10-23 decision |
| C. Own icons only where the pack has no twin (Store, Activity Monitor, the Apps tile) | a compromise | two looks among Grassfield's own apps |

**IQ-L1. From power-on to the desktop.**
| Option | For | Against |
|---|---|---|
| **A. Omarchy's path unchanged (Limine, disk password, SDDM autologin); Grassfield starts at the ground (recommended)** | no greeter or boot change (a non-goal; R12), no root work | the boot and disk-password screens are Omarchy's look |
| B. A Grassfield SDDM theme in the lock screen's layout, for machines without autologin (own ADR, opus security review, SDDM's own PAM service) | a macOS-like login window | a non-goal today ("allowed later"); SDDM runs as its own user (no access to the user's wallpaper: the default artwork only); owner-only tests |
| C. B and a Plymouth theme with the mark for boot and the disk password | identity from power-on | initramfs and boot configuration (root, owner-run, M6 territory); a broken theme can hide the disk prompt |

**IQ-T1. Session start.**
| Option | For | Against |
|---|---|---|
| **A. The wallpaper first, then menu bar, Dock and desktop icons together in one 250 ms fade once all are ready (at most 1.5 s) (recommended)** | one entrance; nothing corrects itself afterwards (macOS order, ASSUMPTION) | the bars come a few hundred ms later than today's instant map (P5 counts it) |
| B. Everything at once without a fade, when ready | fastest feel | a hard cut from the ground to the full desktop |
| C. A splash (the mark on the ground) until ready, then the reveal | identity at start | not macOS; one more surface; a splash that lingers when something is slow |

**IQ-T2. Lock and unlock motion.** Mockups `l1-lock.svg`, `t1-transitions.svg`.
| Option | For | Against |
|---|---|---|
| **A. Lock at once, then scrim and text fade in (200 ms); unlock: fade out while still locked (200 ms), then release (recommended)** | continuity; the release still follows PAM, any failure stays locked | unlock 200 ms longer; a new lock-machine state; security review |
| B. No motion (today) | nothing to review | hard cuts both ways |

**IQ-T3. Log out, restart, shut down.**
| Option | For | Against |
|---|---|---|
| **A. macOS: the confirmation counts down 60 s and proceeds by itself; after the windows close, one fade to the ground then black (400 ms) (recommended)** | macOS behaviour; no layer vanishes one by one | proceeding alone can surprise (macOS does the same); new strings (en, fr) |
| B. Today's confirmation, plus the fade | smaller change | not macOS |
| C. No confirmation from the menu, the fade only | fastest | a misclick ends the session (the apps still get to ask) |

**IQ-T4. When the displays turn off before the lock.**
| Option | For | Against |
|---|---|---|
| **A. macOS: "Require password after the screen saver begins or the display turns off: Immediately (default) …"; the session locks just before the displays go off (recommended)** | no lit flash; a dark display is a locked one by default (stricter than today) | `lock.idleMinutes` changes meaning (migration); with a delay other than Immediately the flash can return (unless Hyprland confirms a lock without drawing: VERIFY) |
| B. Today: lock after N minutes of inactivity; the displays light up to draw it | no change | a lit flash with the default settings on battery (off at 2 min, lock at 5) |
| C. Keep the inactivity model, turn the displays off only once locked | no flash, no new setting | on battery by default the screen stays lit 5 min instead of 2; "Turn display off after" is no longer honoured |

**Not a design question (needs legal review).** STATE records that the owner did the "Grassfield" trademark check
(2026-10-18); the legal dossier says no clearance search was made and the owner decided "no logo clearance"
(2026-10-27) (B-5). Which record is right is the owner's to say; this ADR changes neither.

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **ID-1** The artwork palettes become tokens (`artwork.*`, section 6) with source notes; the written exception in
  `GrassfieldArtwork.qml:5-7` goes, so the "tokens only" rule has no exception left in the wallpaper.
- **ID-2** One ground colour (P-1). The session's Hyprland `background_color` is the default artwork's ground; the shell
  sets the current one at start and on change through the session's own compositor path (mechanism VERIFY on 0.56.2;
  fallback: the static default). The wallpaper window's colour, the lock surface's colour and the exit cover use it.
- **ID-3** The wallpaper's first frame is the cached still of the last applied wallpaper, with its tone (section 2).
- **ID-4** The wallpaper layer gets `no_anim` like the bars; every entrance animation belongs to the shell (one owner of
  motion), so the compositor never fades a layer in under the shell's own fade.
- **ID-5** No surface is shown before the settings are read (`Settings.loaded`), bounded by `session.settingsWaitMs`.
- **ID-6** Auto-hidden menu bar and Dock start hidden at session start (macOS, ASSUMPTION), instead of showing and
  sliding away.
- **ID-7** The lock prepares everything ahead (section 4): the still per output, the avatar, the full name, the surface
  colour, and the clock refresh on resume.
- **ID-8** The idle dim and the screen saver stay until the lock holds; the lock's content starts at the dim's level.
  The lock request itself is not delayed; when it fails, the dim lifts and the failure is logged as today.
- **ID-9** Hyprland's red "lock screen died" screen (kept on purpose, H10) is delayed past a normal shell restart with
  `misc:lockdead_screen_delay` (VERIFY the option and its default on 0.56.2); the session stays locked by the compositor
  meanwhile (`allow_session_lock_restore`), so only what is drawn changes.
- **ID-10** The exit cover: `grassfield-session-end` asks the shell for one full-screen fade to the ground then black
  (`session.exitFadeMs`) after the windows have closed, and waits at most `session.exitWaitMs`.
- **ID-11** Settings > About's Grassfield tile uses the brand green, not the pickable Green (B-8).
- **ID-12** Docs and comments call the logo "the Grassfield mark" (B-4: four names today), as each step touches them.
- **ID-13** The copy `ui/Grassfield/Ui/icons-bar/grassfield-logo.svg` gets its row in `branding/LICENSES.md` (all rights
  reserved, the owner's mark): done in this pull request (B-2).
- **ID-14** An appearance switch crossfades between the artwork's variants (two-slot model, one fixed length); the tone
  switches at the midpoint; Reduce Motion cuts.
- **ID-15** A hotplugged output's wallpaper and lock surfaces start at the ground and show its still.
- **ID-16** The measurement of section 7 lands with step 3 and grows with each step.
- **ID-17** The legal dossier's identity entries are brought up to date as each step lands (E12, E32, E33 now; E2,
  E26, E28 and section 4, stale in passing, at the next legal pass).
- **ID-18** Artwork names avoid the names of macOS wallpapers ("Ridgeline", not "Horizon"; checked from memory only,
  ASSUMPTION: the side-by-side legal check before release covers names and pictures).

## Delivery plan (one pull request per step towards main)
| Step | Content | Blocked by | Review |
|---|---|---|---|
| 0 | This ADR, the audit, the mockups, E39, STATE | — | integrator |
| 1 | Brand without blocked areas: About This Computer (IQ-B4), Settings > About tile (ID-11), the accent's name and the second green (IQ-B3), dialogs' symbols (IQ-B1) | the owner's answers; coordinate the accent with the Appearance.qml branch | reviewer |
| 2a | Artworks: one component, `artwork.*` tokens, Settings > Wallpaper "Grassfield" section and its Automatic/Light/Dark choice, Settings > Appearance thumbnail, A2 runs (IQ-W1, IQ-W2) | the owner's answers | reviewer; F1 shots |
| 2b | The desktop follows the appearance (ID-14) | `shell/desktop` merged | reviewer |
| 3 | First frame from the cache, ground colour, wallpaper `no_anim`, hotplug, the measurement (ID-2 to ID-4, ID-15, ID-16) | `shell/desktop` merged | reviewer |
| 4 | Lock: still (ADR-0016 W8), preload, scrim (IQ-W4), fades and `releasing` (IQ-T2), avatar and name once, clock on resume (ID-7) | steps 3; `shell/desktop` merged (LockView imports `qs.desktop`) | **opus security review**, L1 to L5 |
| 5 | Idle, saver and display-off order (ID-8, IQ-T4), the red-screen delay (ID-9) | step 4 | **opus security review** |
| 6 | Session entrance: the ready latch, menu bar, Dock and icons together (IQ-T1), auto-hide start (ID-6), settings first (ID-5), P5 with the wallpaper | `shell/menubar`, `shell/dock`, `shell/desktop`, Appearance.qml merged | reviewer; P5 owner logins |
| 7 | Exit: countdown (IQ-T3), the exit cover (ID-10) | — | reviewer |
| 8 | App icons (IQ-B5): the family in `branding/icons/apps`, the aliases | `apps/files`, `apps/store`, `apps/activity` merged | reviewer; legal row |
| 9 | Moving variant (IQ-W3) | P1 and P3 measured | reviewer |
| later | IQ-L1 B or C (own ADR), a designer wordmark (IQ-B2 C) | owner | security review for B |

## Not verified, assumptions, unknowns
- **NOT VERIFIED:** every proposal's rendering in Grassfield (no nested session in this container); the mockups were
  rendered in the container's Chromium only to check the drawings. Every runtime visual claim marked [inference] in the
  audit waits for the integrator's nested pass.
- **ASSUMPTION (macOS, from memory):** the lock screen shows the wallpaper sharp; at login the wallpaper comes first,
  then the menu bar and Dock; auto-hidden bars start hidden; the restart, shut down and log out confirmations count
  down 60 s; Settings offers "Automatic / Light / Dark" for dynamic wallpapers; the lock fades in and out. The owner's
  references have no capture of any of these (`docs/testing/f1-reference-gaps.md:317-321`).
- **VERIFY on Hyprland 0.56.2:** `misc:lockdead_screen_delay` (ID-9); changing `background_color` at run time (ID-2);
  whether a session lock is confirmed while the displays are off (IQ-T4 A with a delay).
- **UNKNOWN:** the look of Omarchy's boot and disk-password screens on the owner's machine (not readable here).

## Alternatives rejected
- A cover window that hides the desktop until everything is ready: a splash under another name (IQ-T1 C), not macOS.
- A blurred snapshot of the desktop on the lock: window content on the lock breaks gate L4.
- Fading the desktop out before engaging the lock: delays the lock (P-5).
- Shipping photographs that resemble Apple's wallpapers, or any Apple asset: §14.
- Recolouring the mark in its file or drawing variants of it: the mark is the owner's; colour is applied at run time
  only, as IQ-B1 decides.
- A new "brand" colour token beside the default accent: the default accent tokens already are the brand green (R5).

## Legal
- New entry E39 in `docs/legal/visual-review.md`: the mockups (made here, CC-BY-SA-4.0; the existing app icons embedded
  from `branding/icons/apps`, CC-BY-SA-4.0; the mark embedded unchanged, all rights reserved). E12, E32 and E33 carry an
  "Update 2026-10-29" pointing here.
- The proposed artworks inherit E32's flag (`distinct`, side-by-side check before release); names included (ID-18).
- The lock and About layouts stay `close` (E2, E12); the app-icon family lowers resemblance for Grassfield's own apps
  (IQ-B5 B); a lockup in Inter (IQ-B2 B) and the trademark records (B-5) need legal review.

## Evidence
- The audit's spot checks 1 to 13 (`docs/audits/identity-2026-10-29/audit.md`, section 5), each with its command and
  exit status, on main 11c9e69.
- `python3 -I docs/audits/identity-2026-10-29/mockups.py` → exit 0, eight SVG files; `xmllint --noout` on them → exit 0;
  each rendered with Playwright Chromium in the container (scratch PNGs, not committed) and inspected.

## Consequences
- Answers to IQ-W1 to IQ-T4 decide steps 1 to 9; until then nothing is built.
- ADR-0016 is extended, not replaced: its §6 (the lock still) is step 4 here; its §10 P5 promise is kept by ID-3.
- ADR-0014 and ADR-0017: IQ-B5 B removes the aliases for `org.grassfield.*` only; the pack stays for every other app.
- ADR-0020 gains rows for the new keys and the wallpaper state when steps 2a, 3 and 5 write them.
- Security: steps 4 and 5 are security-module changes (R12), each with an opus security review.
