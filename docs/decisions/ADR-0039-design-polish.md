# ADR-0039: Design polish: one grammar for materials, controls, windows and accessibility settings
Status: Proposed (owner brief "Cohérence et finition", 2026-10-29, step 0: docs only, no code). The owner answered Q1 to Q8
on 2026-10-29 (AskUserQuestion), recorded in "Owner decisions (2026-10-29)"; revised after the integrator's review of step 0
(FAIL: one MAJOR, four MINORs; "Review history"); the steps start one pull request each ·
Date: 2026-10-29 · Decider: owner (Q1 to Q8), integrator (the steps, the review, the nested pass) · Number: 0039 (free on
main 11c9e69 when step 0 began; #41 and #43, open then, have merged since)

Builds on ADR-0024 (macOS 27 structure, macOS 26 glass) and does not change its direction or its values: it closes the
seams ADR-0024's lots left between surfaces, and the places where an accessibility setting stops short. Measurements:
`docs/audits/design-polish-2026-10-29.md` (cited "audit §n"), captures in `docs/audits/design-polish-2026-10-29/shots/`.

## Context

### The owner's brief (2026-10-29)
- One pull request per step toward main. Step 0 (this one): an audit from `docs/audits/ui-finesse-2026-10-25.md`,
  `docs/audits/visual-tahoe-2026-10-25.md` and ADR-0024, on coherence (materials, typography, icons, windows, accessibility)
  and finish (motion, Files, Settings, Preview, Store, panels and menus); an ADR with the measured gaps, a prioritised list of
  small steps, and the owner's questions, each with two or three options, their pros and cons and a recommendation.
- Tokens only; real blur only (BackgroundEffect or layer rules); no Apple asset or Apple trademark name in the UI.
- Not touched until merged, and planned after: `apps/files` and `apps/portal` (pull request #41), `apps/store` (step 3c), the
  Software Update panel (step 3: `apps/settings/qml/SoftwareUpdate*.qml`, `shell/services/SoftwareUpdate.qml`,
  `ui/Grassfield/Ui/SoftwareUpdateLogic.js`), `apps/activity`, `shell/dock`, `shell/desktop`, `shell/menubar`,
  `ui/Grassfield/Ui/Appearance.qml` and `Material.qml` (fixes in progress). `shell/security` is out of this work.
- What the container cannot verify (the nested session, rendering with blur, motion) is written NOT VERIFIED; the integrator
  runs the nested pass.
- Since step 0 was written, pull requests #41 (Files and the portal), #43 (tiling step 5) and #44 (Software Update step 3)
  merged (main 35e62c5, merged into this branch): `apps/files`, `apps/portal` and the Software Update panel are free now.

### What holds on main 11c9e69 (audit §2)
- ADR-0024's lots 1 to 6, T-1 and T-3 are merged. On the renders of the real `Grassfield.Ui` and Settings: white text on the
  selection fill in both appearances, white windows (255) with light groups (247) and an edge-to-edge sidebar (236), the
  traffic lights on whole pixels, stroke-2 symbols (34.5–40.4 % solid pixels against 13–26 % before).
- Tokens: no literal radius, font size, opacity, geometry value or animation duration in the QML of `ui/`, `shell/` and
  `apps/`; 20 literal colours, none of them a UI colour (audit §5).

### Measured gaps (audit §3 and §4)

| ID | Gap | Measure | Evidence |
|---|---|---|---|
| G1 | Glass surfaces without a glass class take the pre-ADR-0024 single tint | 4 classes exist; the Overview band, widget gallery, widgets, switcher, tooltips, Stages badges and the tails of the Dock menu, stack popup and tooltip draw 0.85 at the default slider (targets: band and gallery 0.15, widgets 0.92; tails: their body's class, which adapts) | audit §3.1; `Appearance.qml:160` |
| G2 | The shell's sheets ask for a blur 2 pt squarer than they are drawn | blur radius 24 (`radius.alert`), shape 26 (`radius.sheet`) | `shell/overlay/Overlay.qml:132-144`, `Dialog.qml:25` |
| G3 | Three button grammars, two sheet grammars | default 32-pt radius-6 rectangle (every app sheet), push 24-pt capsule (Settings rows, shell sheets), capsule 28 (alerts) | audit §3.6; `shots/gallery-light-2x-controls.png` |
| G4 | Sheets rounder than the windows they sit on | sheet 26, alert 24, window 16.0 (circle-equivalent of Hyprland's 20 at power 2.6; macOS 27: 16.6) | audit §3.2 (C-2) |
| G5 | Non-concentric inner shapes | switcher selection 26 for 10.5, sheet controls 6 for 10, Now Playing artwork 6 for 16 and 10, Force Quit rows 6 for 2, stack rows 6 for 1–7 | audit §3.2 |
| G6 | One role, eight hover or selection fills | accent; `text` 0.12; `fill` 0.06, 0.14, 0.28, 0.42; `hover` 0.12; a rim token 0.22 | audit §3.6 |
| G7 | About twenty hand-made focus rings | the shared `FocusRing` used once in the shell; rings inside the shape, in the accent, or shown after a click (`activeFocus`) | audit §3.7.3 |
| G8 | Increase Contrast cuts the inline pop-up's label | its border is drawn around a bezel-less pop-up whose text starts at 0: "Icon theme" reads "\|con theme" | `shots/increase-contrast-popup-light-zoom4.png`; `ComboBox.qml:104, :123` |
| G9 | Increase Contrast leaves switches and sliders unoutlined | off track on its backdrop 1.14:1, knob on track 1.57:1, with or without the setting (closed under Increase Contrast by steps 1 and 2: tracks, knobs, the slider outline above its fill; with the setting off the knob stays 1.25:1 against its off track on opaque material, the integrator's measure on #61: step 28) | `shots/gallery-light-ic-2x-controls.png`; `Toggle.qml`, `Switch.qml`, `Slider.qml` |
| G10 | Reduce Motion shortens instead of replacing | of 80 timed animations, 55 are only capped at 100 ms, so slides still move: banners and the Notification Center slide in, knobs, Overview tiles, Search's height; 1 is not gated (the saver's 1500-ms crossfade) | audit §3.7.4 |
| G11 | Preview is outside ADR-0024's window rules | window `materialTint` #F3F4F6 / #1D1F24 instead of #FFFFFF / #292929; no `windowSurface`; the macOS 26 floating sidebar; floating glass toolbar groups with 28-pt buttons; text selection in the accent | audit §4.4; `apps/preview/qml/Viewer.qml:51, :618-630` |
| G12 | Settings reach only part of the apps | Increase Contrast and Text size: not in Files or Preview; Settings' glass preview ignores Reduce Transparency | audit §3.3, §3.7 |
| G13 | No text hierarchy in dark app windows | secondary #DCDCE4 10.67:1 against text 13.36:1 on #292929 (luminance ratio 1.27; light: 14) | `shots/settings-desktop-dark-2x-crop.png`; audit §3.7.1 |
| G14 | Two greens for "on" in the dark appearance | switches and slider fills #4FB36B (white knob 2.63:1), checkboxes, radios, default buttons #2E8049 (4.88:1) | `shots/gallery-dark-2x-controls.png` |
| G15 | Light windows have no dark contact edge (C-4) | `col.active_border` white 0.15 in both appearances; macOS 27 about black 0.25 in the light one | `config/hypr/grassfield/looknfeel.lua:13-14` |
| G16 | Four toolbar edges, three capsule drawings, four search fields | none / 1-px rule / gradient fade / none; `RimmedCapsule` / plain fill / floating glass; the shared `SearchField` used nowhere; no tooltip on icon-only toolbar buttons | audit §3.5, §3.6, §3.4 |
| G17 | Menus re-implemented with other metrics | section headers ignore the check column (`PopupMenu.qml:316-328`); Volume rows 4 apart; the tiling popover's neutral highlight and 13-pt headers; stack labels at 34; the Dock menu's "Recent Documents" as a greyed row | audit §4.6 |
| G18 | Inactive windows change only their lights | the accent sidebar selection, the toolbar title and glyphs stay as in the key window | audit §3.5 |
| G19 | Third-party title bars are a grey band | #ECECEE (236) on a light window | `tokens.json` `titlebar.backgroundLight` |
| G20 | Motion without a reference | 7 easing types besides linear, no spring, all motion tokens "estimate"; shell and compositor on different curves | audit §4.1 |
| G21 | Distance-field text | 13 px: 7.7 % less ink than native at 1x, 19.5 % at 2x (T-2 still open) | `shots/metrics.txt` |
| G22 | Small finish defects per app | Settings: hand-built buttons without hover, two empty-list styles, 34 literal hairlines; Files: dark wells in Customize Folder (0.14 in the light appearance), no in-view loading; Store: buttons without hover or pressed state, disabled 0.45 against 0.38, three progress indicators across the apps | audit §4.2–§4.5 |
| G23 | Pixel-grid leftovers | the check box label and the inline pop-up's chevron disc on half pixels (the right-aligned menu shortcuts keep a whole right edge by design, corrected in step 1) (14 of 62 items off the grid, mostly text widths) | `shots/gallery-light-1x-walker.txt` |
| G24 | Gate A2's role table is red on main | `test_contrast_tokens.py` exits 1: 15 file-and-class counts of contrast-relevant colour uses differ from `contrast-roles.json` (13 on 11c9e69); every one is a table out of date, no colour fails; the check is in `scripts/dev/test.sh`, not in `just check-quick` | audit §3.7.5 |

## Decision

### Rules every step follows
1. **One material per role.** Every glass surface names a glass class; a part of a surface (a tail, a plate, a close
   capsule) takes its body's tint. Real blur only.
2. **One radius per role, concentric inside.** An inner shape's radius is the outer radius minus its inset, unless a measured
   macOS value says otherwise and cites it (Search's 17.8-pt row). A role reuses a token of its own role, not another
   surface's (`radius.menu` is not the Settings group radius).
3. **Shared controls first.** A surface uses the `Grassfield.Ui` control when one exists: one push-button shape per size, one
   search field, one menu host, one indeterminate and one determinate progress indicator, one focus ring (`FocusRing`: 3 px,
   outside the shape, `focusRingColor`, keyboard focus only).
4. **One window grammar.** Every app window sets `Appearance.windowSurface`, draws the window neutrals and secondary text,
   an edge-to-edge sidebar, toolbar capsules from shared `toolbar` tokens, and one toolbar edge once content scrolls under it.
5. **A setting reaches every surface.** Increase Contrast outlines every control and frosts every glass; Reduce
   Transparency makes every translucent fill opaque; Reduce Motion turns movement into crossfades of at most 100 ms
   (master-prompt §5.5); Text size follows the answer to Q7. A new surface is added to the matching test.
6. **Tokens only, kept by CI.** No literal design value; UX timings become tokens.
7. **Measured or marked.** A value cites its measurement or stays "estimate"; nothing is claimed on screen without a capture
   (NOT VERIFIED otherwise).

### Decisions taken under the owner's rule ("the closest to macOS 27, no technical step for the end user")
- **D1 Measured per-app values stay.** Settings' 232-pt sidebar with 32-pt rows and the accent selection, Finder's 32-pt
  rows and neutral selection, the App Store's 220-pt sidebar, 38-pt rows and radius 9, Search's 17.8-pt row radius are macOS
  27's own differences between apps, not incoherence. Estimates (Files' 184-pt sidebar, Preview's 28-pt rows) are measured
  before they change.
- **D2 Reduce Motion** keeps the compositor's crossfades (GF-063) and makes the QML do the same: a position, scale or size
  change jumps; opacity and colour crossfade within `motion.reducedMax`.
- **D3 Toolbar edge:** the 1-px rule once content scrolls under the toolbar (Files' behaviour) for every app, until ADR-0024
  phase 3 (the scroll-edge glass) is built and judged by the owner.
- **D4 Progress indicators:** Settings' `Spinner` (indeterminate) and the Store's `ProgressRing` (determinate) move into
  `Grassfield.Ui` beside `ProgressBar`; no new kind.
- **D5 Hairlines:** separators and borders of controls are one point, through one token; glass rims are one device pixel
  (ADR-0024 §2.5).
- **D6 The Store's measured type sizes stay** (the App Store's own type, converted from cap heights), recorded as exceptions
  next to the shared ramp; the shared ramp is named after macOS's text styles in the tokens' sources.
- **D7 Timers stay literals** (debounces, polls, retries); a timing the user perceives (the OSD's hide delay, a notice's
  lifetime) becomes a token.

### Steps, in priority order
One pull request each, with `just check`, the tests and captures (`docs/audits/design-polish-2026-10-29/tools/run.sh` for
the shared controls and Settings; `just shot` in the nested session, integrator). "Free" means no frozen file. Sizes: S (a
few files), M (a surface family).

| # | Step | Where | When | Verify | Size | Closes |
|---|---|---|---|---|---|---|
| 0b | **Gate A2's role table:** the 15 undeclared uses of audit §3.7.5 added to the roles that already cover them (exempt ones with their reason), `test_contrast_tokens.py` added to `just check-quick`; the three `shell/security` entries confirmed by the security reviewer (no security code changes) | `tests/visual/contrast-roles.json`, `justfile` | first, now (the menu bar's band fix, fix/bar-tone-video, merged in 1048307 with its own entries) | `test_contrast_tokens.py` exit 0; `just check-quick` fails with a planted undeclared use | S | G24 |
| 1 | **Increase Contrast and pixel grid in the shared controls:** no border around the bezel-less inline pop-up (only its chevron disc), its disc on whole pixels; Toggle, Switch and Slider outlined under Increase Contrast; the check box label on a whole pixel (the menu shortcuts keep their whole right edge: not a defect) | `ui/Grassfield/Ui/ComboBox.qml`, `Toggle.qml`, `Switch.qml`, `Slider.qml`, `CheckBox.qml`; `tests/unit/tst_pixelgrid.qml` and `tst_increasecontrast.qml` | free, now | renders (`tools/run.sh`), unit tests, A2 | S | G8, G9, G23 |
| 2 | **CI guard for literals:** `tests/ci/qml_literals.py` from the audit's tool, run by `just check-quick`; zero literal radius, font size, opacity, geometry value and animation duration; the 20 colours allowlisted per file and timers not counted (the OSD's hide delay was already `osd.hideDelay`; its 1500 is an arming delay after start, logic; the Store's 6000-ms notice lifetime becomes a token after step 3c) | `tests/ci/`, `tests/inventory.json`, `justfile` | free, now | the guard fails on a planted literal | S | rule 6 |
| 3 | **Preview's window and settings:** `windowSurface`, window neutrals in Viewer and Glance, `windowSecondary`, text selection in `highlight`, Increase Contrast and Text size read by the backend and bound (Q7). With step 2's review: the literals guard reads a ternary's branches, an offset to a token, `Layout.*`, declared properties, groups, `scale`, `sourceSize`, literal alphas and named colours, outside JavaScript blocks and object literals; `tst_increasecontrast` grabs a knob in the scene and checks that nothing is outlined with the setting off | `apps/preview/qml/Viewer.qml`, `Glance.qml`, `Theme.qml`, `TextView.qml`, `apps/preview/src/previewapp.{h,cpp}` | free, now | build, unit tests, a render or nested capture | S–M | G11 (part), G12 |
| 4 | **Shell sheets' blur radius** from the dialog's own corner | `shell/overlay/Overlay.qml` | free, now | nested capture (NOT VERIFIED here) | S | G2 |
| 5 | **Reduce Motion as crossfades** on the free surfaces: banners and the Notification Center fade instead of sliding, knobs, Overview tiles, Search's height, the stack fan and the OSD jump (the Files tab bar with step 23); the saver's slide crossfade capped; Preview's animated images and Settings' spinner still | `shell/notifications`, `shell/overview`, `shell/search`, `shell/overlay`, `shell/osd`, `shell/saver`, `ui/Grassfield/Ui/Toggle.qml`, `Switch.qml`, `apps/preview`, `apps/settings/qml/Spinner.qml` | free, now (a shared helper in `Appearance.qml` after its merge) | unit tests with `reduceMotion`, nested `reduce-motion-compositor.sh` unchanged | M | G10 |
| 6 | **Window edge per appearance (C-4):** border tokens per appearance, pushed by the shell with the appearance as it pushes the blur | `shell/platform/Compositor.qml`, `Minimized.js`, `tokens.json`, `config/hypr/grassfield/looknfeel.lua` | free, now | a unit test of the call; nested capture of a light window's edge | S–M | G15 |
| 7 | **One focus ring** on the free surfaces: `FocusRing` or `focusRingColor`, outside the shape, keyboard focus only; Clear All in the Notification Center and the Stages tiles on the keyboard | `shell/overlay`, `shell/notifications`, `shell/launchpad`, `shell/overview`, `shell/switcher`, `shell/widgets`, `shell/stages`, `ui/Grassfield/Ui/LinkText.qml`, `WindowLight.qml`; Settings' `ArrangeSheet`, `ColorWell`, `WallpaperSection`, `PrivacyCategoryPage`, `LoginItemsPage` | free, now | unit tests (ring after a key, none after a click) | M | G7 |
| 8 | **Menu grammar:** section headers aligned with the check column; Volume, the tiling popover and the stack list on `PopupMenu`'s metrics (the tiling popover against ADR-0036's spec first) | `ui/Grassfield/Ui/PopupMenu.qml`, `shell/overlay/VolumeMenu.qml`, `TilingPopover.qml`, `StackPopup.qml` | free, now | renders, unit tests | S–M | G17 (part) |
| 9 | **Dark secondary text** in app windows (Q3) | `tokens.json` `color.dark.windowTextSecondary`, `tests/visual/test_contrast_tokens.py` | decided (Q3: #A1A1A6) | A2, renders | S | G13 |
| 10 | **Sheet buttons and radii** (Q1, Q2): the shared `Sheet`'s buttons, its radius and concentric controls; `radius.sheet` and `radius.alert` | `ui/Grassfield/Ui/Sheet.qml`, `tokens.json`, `shell/overlay/Dialog.qml` | radii now (Q2); buttons after the macOS 27 sheet measurement (D-Q1) | renders of a Settings sheet, nested capture of the shell's | S–M | G3, G4 |
| 11 | **One green for "on"** (Q4) | `Toggle.qml`, `Switch.qml`, `Slider.qml` | after the macOS 27 dark check (D-Q4) | A2 (knob 3:1), renders | S | G14 |
| 12 | **Hover and selection roles:** one token per role (control hover, neutral row selection on glass, accent menu selection, grid selection) replacing the multipliers | `shell/overlay/StackPopup.qml`, `shell/overview`, `shell/switcher`, `shell/overlay/TilingPopover.qml`, `tokens.json` | free, now | renders, A2 | S–M | G6 |
| 13 | **Radius roles and concentric shapes:** `radius.group` for Settings' groups, the inner radii of G5, rounded tiling-suggestion thumbnails; the switcher's selection measured first; `radius.dialog` stays (the polkit dialog's, outside this lane) | `tokens.json`, `apps/settings/qml/SettingsGroup.qml` and its readers, `shell/overlay/ForceQuitPanel.qml`, `StackPopup.qml`, `controlcenter/NowPlaying.qml`, `shell/widgets/builtin/nowplaying/NowPlaying.qml`, `shell/notifications/NotificationContent.qml`, `TilingSuggestions.qml` | free, now (Sheet with step 10) | renders | S–M | G5 |
| 14 | **Shared toolbar and search field:** `toolbar.*` tokens (capsule 36, button 34, divider) replacing the borrowed `files.*` and `settings.*`; `RimmedCapsule` on them; `SearchField` as the rimmed 28-pt capsule with a clear button, used by Settings; icon-only `ToolButton`s show their name as a tooltip | `ui/Grassfield/Ui/RimmedCapsule.qml`, `SearchField.qml`, `ToolButton.qml`, `tokens.json`, `apps/settings/qml/Main.qml` | free, now (Files and Store with steps 23 and 24) | renders, unit tests | M | G16 (part) |
| 15 | **Settings finish** (Software Update excluded): `InfoButton` and `MoreButton` on `ToolButton`'s states, the colour well's field and popover on `TextField` and `Material`, one empty-list style, `ErrorNote` in `windowSecondary`, the 34 literal hairlines on the token, content that scrolls under the toolbar with its rule (D3), the glass preview on the class tints and Reduce Transparency, unused tokens removed | `apps/settings/qml/*` | free, now | renders (`settings.py`), unit tests | M | G22 (Settings), G12 (preview) |
| 16 | **Preview's structure:** the edge-to-edge sidebar, toolbar capsules on the shared tokens with 34-pt buttons, scroll bars, the toolbar rule | `apps/preview/qml/Viewer.qml`, `ToolbarGroup.qml`, `ImageView.qml`, `TextView.qml` | free, after step 14 | nested capture | M | G11 |
| 17 | **Inactive windows:** the selection of a window that is not key turns neutral; the toolbar title and glyphs dim | `ui/Grassfield/Ui/UnifiedToolbar.qml`, `apps/settings/qml/Main.qml`, `apps/preview` | free, now; Files and Store after their merges | renders with `Window.active` false; a macOS 27 capture of an inactive window (NOT VERIFIED until then) | S–M | G18 |
| 18 | **Text size everywhere** (Q7): Preview (with step 3) and Files (with step 23); the apps' text tokens follow `textScale` | `tokens.json`, `apps/preview`, `apps/files` | decided (Q7: every app) | unit tests at 130 % | S | G12 |
| 19 | **Native text in the apps** (Q5) | the apps' `main.cpp` (Settings, Preview now; Files, Store, Activity Monitor after their merges) | decided (Q5: the apps' static text) | `shots/metrics.txt` method, the owner's side-by-side | S | G21 |
| 20 | **Motion tokens** (Q6): a panel-and-sheet curve, one easing per role (enter, exit, move), Hyprland's curves aligned with them | `tokens.json`, the free surfaces, `config/hypr/grassfield/looknfeel.lua`, `shell/platform/Minimized.js` | decided (Q6: the 650-ms stand-in) | nested recordings, P3 | M | G20 |
| 21 | **Third-party title bars** (Q8) | `tokens.json` `titlebar.*`, the plugin's theme (nested only, gates C1–C3) | decided (Q8: the window tokens) | nested capture | S | G19 |
| 22 | **Glass classes for every surface:** classes for the Overview band and gallery (0.15) and widgets (0.92); the switcher, tooltips, Stages badges and the About This Wallpaper card on a class; tails and close capsules on their body's tint, the Increase Contrast frost and Reduce Transparency; Material's inner rim stronger toward the top left (ADR-0024 §2.5) and its dark edge raised by Increase Contrast | `Appearance.qml`, `Material.qml`, `Tooltip.qml`, `shell/overview`, `shell/widgets`, `shell/switcher`, `shell/stages`, `shell/overlay/DockMenu.qml`, `StackPopup.qml`, `shell/notifications` | **after the Appearance and Material fixes merge** | A2 per class and appearance, nested captures (blur) | M | G1 |
| 23 | **Files finish:** `windowSecondary`, Increase Contrast and Text size, Customize Folder's wells on `Appearance.fillOpacity`, a rounded tags ring, capsules and search on step 14's pieces, an in-view loading indicator, keyboard paths for the column headers, path bar and preview-pane actions, native text (Q5) | `apps/files` | free now (#41 merged); the Files findings re-measured on main first | renders, unit tests, nested | M | G12, G16, G22 (Files) |
| 24 | **Store finish:** buttons with hover and pressed states and the shared disabled opacity, the shared progress indicators (D4), menu host and search field (28), an empty state on the category page, the hairline token, rings on keyboard focus, native text (Q5) | `apps/store` | **after step 3c merges** | renders (store shots), unit tests | M | G16, G22 (Store), G7 |
| 25 | **Dock, desktop and menu bar:** the Dock shelf's darker outer edge (ADR-0024 §2.5), the Dock menu's "Recent Documents" as a header, one bar-button ring on keyboard focus, the Dock's auto-hide jumping under Reduce Motion, its easings per role, the menu bar's band under Reduce Transparency and Increase Contrast; the desktop icon labels follow the wallpaper tone under them as the menu bar does (dark text without the heavy halo on a bright wallpaper, as macOS; dark labels need a new A2 role over the light wallpapers the tone is chosen for, as the menu bar's dark foreground has, beside today's white-label roles; the integrator's finding of 2026-10-29 on #45, a capture on the owner's machine) | `shell/dock`, `shell/desktop`, `shell/menubar`, `shell/overlay/DockMenu.qml` | **after their fixes merge** | nested | M | G1, G7, G10, G17 |
| 26 | **Software Update panel:** step 15's Settings rules on its three files | `apps/settings/qml/SoftwareUpdate*.qml` | free now (#44 merged) | renders (`settings.py --update`) | S | G22 |
| 27 | **Activity Monitor:** its window built on these rules from the start (a checklist in its step, ADR-0038) | `apps/activity` | at its window step | its own review | — | — |
| 28 | **The switch knob's edge with Increase Contrast off** (G9, from the review of step 2): the knob of Toggle and Switch gets the drop shadow that sets the macOS 27 knob apart from a light off track, measured on the reference (a real shadow, in tokens). Until then a white knob is 1.25:1 against its off track on opaque material, and Increase Contrast outlines it (steps 1 and 2) | `ui/Grassfield/Ui/Toggle.qml`, `Switch.qml`, `ui/tokens/tokens.json` | needs the reference measure (F1) | a render on the material, a unit test of the knob's edge | S | G9 (setting off) |

Step 0b and steps 1 to 8 need neither an answer nor a merge (the review's clashes of steps 6 and 20 with #43, and of steps
14, 15 and 17 with #44, are gone: both merged before these steps start). Steps 9 to 11 and 18 to 21 follow the owner's answers of 2026-10-29
("Owner decisions (2026-10-29)" below): step 10's buttons and step 11's colour start with a measurement of the macOS 27
reference the owner named (Q1, Q4); every other answered step can start in this order.

## Questions for the owner (answered on 2026-10-29)

**Q1. The buttons at the foot of a sheet.** A Settings sheet ends with 32-pt rounded rectangles; the shell's sheets (About,
Force Quit) with 24-pt capsules; alerts with 28-pt capsules (`shots/gallery-light-2x-controls.png`). The reference library has
no macOS 27 sheet.
- (a) 24-pt push capsules in every sheet, as Settings' rows and the shell's sheets. Pros: one shape for push buttons (43 of
  the 64 `Button`s are push capsules already); no new value. Cons: a smaller target than today's 32 pt in app sheets; the
  macOS 27 sheet is not measured.
- (b) The 32-pt rectangle in every sheet, the shell's included. Pros: larger targets. Cons: a shape no other Grassfield
  control uses next to capsules everywhere else; further from the macOS 26 and 27 controls.
- (c) 28-pt capsules, as alerts, in every sheet and alert. Pros: one shape for every dialog button, a middle size. Cons: a
  third height next to Settings' 24-pt rows inside one window.
- **Recommendation: (a),** checked again when a macOS 27 sheet capture exists.
- **Owner's answer (2026-10-29):** « Il faut la même que sur Mac OS 27 » ("the same as on macOS 27"): see D-Q1.

**Q2. The corner of sheets and alerts.** Windows have one corner: Hyprland's 20 at power 2.6 has the 45° point of a 16.0-pt
circle (macOS 27 measures 16.6; ADR-0024). Sheets are 26 and alerts 24 (macOS 26 values), 8–10 pt rounder than the window
under them.
- (a) The window's radius for sheets and alerts too (16 in QML, the circle that matches the window corner's 45° point). Pros:
  "one radius for every window", as macOS 27 does for every window measured, the Force Quit panel among them. Cons: not
  measured on a macOS 27 sheet or alert.
- (b) Keep 26 and 24. Pros: measured, on macOS 26. Cons: the sheet's corners stand out against its window's.
- (c) Wait for a macOS 27 sheet and alert capture from the owner. Pros: certainty. Cons: the step waits.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** the window's radius for sheets and alerts.

**Q3. Secondary text in dark app windows.** Today #DCDCE4: 10.67:1 on the window against 13.36:1 for the primary text, so
secondary lines read like titles (`shots/settings-desktop-dark-2x-crop.png`). Every option keeps A2 (4.5:1).
- (a) #A1A1A6, about white at 0.55 over the window: 5.66:1 on the window, 5.06 on groups, 6.11 on the sidebar. Pros: a
  visible hierarchy (the text has 2.55 times its luminance), close to macOS's secondary label. Cons: not measured on a dark
  macOS 27 capture; a smaller margin above 4.5 on groups.
- (b) #B4B4BA: 7.05, 6.31 and 7.62. Pros: a wide margin. Cons: a weaker hierarchy (luminance ratio 2.0).
- (c) Keep #DCDCE4. Pros: the highest contrast. Cons: no hierarchy.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** #A1A1A6.

**Q4. One green for "on" in the dark appearance.** Switches and slider fills use the bright green #4FB36B; checkboxes,
radio buttons, default buttons and selected rows the deeper #2E8049 chosen for white text (owner decision of 2026-10-26).
- (a) Switches and slider fills on #2E8049 too (each accent's dark selection fill). Pros: one green for "on"; the white knob
  goes from 2.63:1 to 4.88:1 (WCAG 1.4.11), and from 1.82–2.77:1 to 4.85–4.89:1 for every other accent but yellow. Cons: a
  darker switch than macOS's bright one; with the yellow accent the knob stays under 3:1 (2.02:1 on #E0B000, 1.50:1 today),
  because the yellow pair keeps dark marks.
- (b) Keep both greens. Pros: brighter switches. Cons: two greens side by side in one Settings row; the knob under 3:1.
- (c) Checkboxes and radio buttons on #4FB36B with a dark mark. Pros: one bright green. Cons: breaks white-on-accent (F1,
  2026-10-26) with a dark checkmark, which macOS never draws.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29):** « Même chose que sur Mac OS 27 » ("the same as on macOS 27"): see D-Q4.

**Q5. Native text rendering in the apps (T-2, open since 2026-10-26).** Distance-field text carries 7.7 % less ink than
native glyphs at 1x and 19.5 % less at 2x (13 px), so it reads greyer and softer than macOS text.
- (a) Native rendering for the apps' static text (Settings, Files, Preview, the Store, Activity Monitor); distance fields
  stay where text is scaled or animated (Dock labels, Overview). Pros: closer to macOS's weight where reading happens; one
  line per app. Cons: apps and shell rasterise text differently; judged on the owner's screen first, as decided on
  2026-10-26.
- (b) Native rendering everywhere, the shell's static text included. Pros: uniform. Cons: more surfaces to check, and
  shell text that moves must be excluded one by one.
- (c) Keep distance fields. Pros: no change. Cons: the gap stays.
- **Recommendation: (a),** after the side-by-side on the owner's screen.
- **Owner's answer (2026-10-29): (a),** native rendering for the apps' static text.

**Q6. Motion of panels and sheets.** No motion was ever recorded on a Mac (2026-10-26 decision 6); today panels use 120,
220 and 350 ms on one curve, and nothing springs.
- (a) Apple's documented default spring as a fixed-duration stand-in for panels and sheets (650 ms, cubic-bezier 0.24, 0.24,
  0.15, 1.04), menus still instant, small controls unchanged. Pros: no recording needed; Apple's own default for app
  animations. Cons: not measured on the system's panels; P3 must hold for longer animations.
- (b) The owner records five clips on a Mac (a menu, Control Center, Notification Center, Spotlight, a sheet) and the tokens
  follow them. Pros: exact. Cons: needs a Mac and the owner's time.
- (c) Keep today's durations; only one easing per role. Pros: cheapest. Cons: motion stays the least macOS-like trait.
- **Recommendation: (a),** calibrated later with (b) if a Mac is at hand.
- **Owner's answer (2026-10-29): (a),** Apple's default spring as a 650-ms stand-in.

**Q7. How far Text size reaches.** Today: the shell's panels, Settings and the Store; not Files or Preview; menus never.
- (a) Every Grassfield app (Files and Preview too); menus keep their size, as now. Pros: one setting behaves the same
  everywhere. Cons: Files' list and icon metrics need checking at 130 %.
- (b) Keep today's reach; the pane already says what it scales. Pros: no work. Cons: two apps out of five ignore it.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** every Grassfield app.

**Q8. Title bars of third-party windows.** The compositor draws them #ECECEE in the light appearance and #28282C in the dark
one; Grassfield's own windows are #FFFFFF and #292929, and the macOS reference draws the window's own colour (visual-tahoe,
low confidence).
- (a) The window tokens: #FFFFFF and #292929, the title bar told apart by the hairline under it. Pros: coherent with every
  Grassfield window and with macOS. Cons: a white bar above an app whose content is grey looks detached.
- (b) A near-white #F6F6F6 (dark unchanged). Pros: softer above grey apps. Cons: still a band, a value of its own.
- (c) Keep #ECECEE. Pros: no change. Cons: the grey band the 2026-10-25 audit noted.
- **Recommendation: (a).**
- **Owner's answer (2026-10-29): (a),** the window tokens #FFFFFF and #292929.

## Owner decisions (2026-10-29)
Asked with AskUserQuestion after step 0 was written; the answers verbatim where the owner wrote their own.

| | Answer | What the steps do |
|---|---|---|
| Q1 sheet buttons | « Il faut la même que sur Mac OS 27 » | D-Q1 below (step 10) |
| Q2 sheet and alert corners | (a) the window's radius | step 10: `radius.sheet` and `radius.alert` take the window's circle-equivalent (16), inner controls concentric |
| Q3 dark secondary text | (a) #A1A1A6 | step 9: `color.dark.windowTextSecondary` #A1A1A6, A2 asserted on window, group and sidebar |
| Q4 "on" in the dark appearance | « Même chose que sur Mac OS 27 » | D-Q4 below (step 11) |
| Q5 native text | (a) the apps' static text | step 19: native rendering in Settings and Preview first, then Files, the Store and Activity Monitor after their merges; distance fields where text is scaled or animated; the owner's side-by-side on the reference screen before it is kept (decision of 2026-10-26) |
| Q6 motion | (a) Apple's default spring as a 650-ms stand-in | step 20: a panel-and-sheet curve token (650 ms, cubic-bezier 0.24, 0.24, 0.15, 1.04); menus stay instant; P3 measured |
| Q7 Text size | (a) every Grassfield app | step 18: Files and Preview follow Text size; menus keep their size |
| Q8 third-party title bars | (a) the window tokens | step 21: `titlebar.backgroundLight` #FFFFFF, `backgroundDark` #292929, a hairline under the bar |

- **D-Q1 (the owner's answer, read by the integrator).** Sheets take the push buttons macOS 27 draws in its sheets: shape,
  height, width rule and placement. The reference library holds no macOS 27 sheet (C-2), so step 10's buttons start by
  measuring one: macOS 27 release captures of a sheet found by web research (data only, never stored in the repository, as in
  `docs/audits/ui-finesse-2026-10-25.md` §7), or a capture from the owner. Until that measurement exists, step 10 changes
  only the radii (Q2) and the buttons keep today's shapes. The measured shape then applies to the shared `Sheet` and to the
  shell's sheets alike (one grammar), and alerts follow the macOS 27 alert if the same source shows one.
- **D-Q4 (the owner's answer, read by the integrator).** macOS draws switches, checkboxes, radio buttons and slider fills in
  one accent fill with white marks, in both appearances (ui-finesse §7.2: white text on the accent in the dark menu, F1).
  Grassfield's fill that holds white marks in the dark appearance is the selection colour (#2E8049 for the green, the derived
  shade per accent of 2026-10-26), so "the same as on macOS 27" is option (a): switches and slider fills move to it. Step 11
  first checks this on the dark macOS 27 release captures (a switch and a checkbox side by side); if they show two fills, the
  step follows what they show and records it here. The fill is each accent's dark selection colour: the white knob reaches
  4.85–4.89:1 for every accent but yellow, whose pair keeps dark marks; there the knob stays at 2.02:1 (1.50:1 today), and
  step 11 gives it the outline Increase Contrast draws (step 1) or records the limit.

## Coordination with the identity lane (ADR-0040, pull request #46)
The integrator's review named nine overlaps. Whichever pull request merges second rebases; the owner of each is:

| Overlap | Owner | The other lane |
|---|---|---|
| The greens: this Q4 and step 11 ↔ IQ-B3 (the default accent named "Grassfield") | ADR-0040 owns the accent palette (`color.accent*`, the default's name and swatch) | this lane owns which controls read the accent and which the selection fill |
| About: steps 4 and 10 (the shell's sheets) ↔ IQ-B4 (About as a small window), IQ-B1 (the glyphs of `NoticeDialog` and `ConfirmDialog`) | ADR-0040 owns About This Computer's form and the dialogs' glyphs | this lane owns `Dialog`'s and `Sheet`'s grammar (radius, buttons, blur radius); if About becomes a window, steps 4 and 10 no longer touch it |
| `looknfeel.lua`, `windows.lua`, `Compositor.qml`: steps 6 and 20 ↔ ID-2, ID-4, ID-9 | ADR-0040 owns the session's ground colour, first frame and transitions | this lane owns the window border colour per appearance and the compositor's animation curves |
| Motion tokens: Q6's roles ↔ the session and lock fades | this lane owns `motion.*` (the roles of panels, sheets, controls) | ADR-0040 owns `session.*` and `lock.*` fades, which name a `motion` role where one fits |
| `shell/saver` | ADR-0040 owns the saver's transitions (ID-8) | step 5 only gates its slide crossfade under Reduce Motion |
| Settings' Appearance and Wallpaper pages | ADR-0040 owns the wallpaper page and the accent row | this lane owns the shared controls on them and the glass preview (step 15) |
| `GrassfieldArtwork.qml`'s colours: step 2's allowlist ↔ ID-1 (artwork tokens) | ADR-0040 | step 2's guard drops them from its allowlist when ID-1 lands |
| The Dock's and menu bar's auto-hide: step 25 ↔ ADR-0040 step 6 | ADR-0040 owns the reveal at login | this lane owns Reduce Motion and the easing of auto-hide |
| `tests/visual/test_contrast_tokens.py` and `contrast-roles.json` | this lane owns the role table's repair (step 0b) | ADR-0040 adds the roles of its own surfaces (lock scrim bands) |

The owner answered Q3, Q7 and Q8 directly on 2026-10-29, where the review would have had the integrator decide them under
the macOS model; the answers are the options that model gives. Q4 was answered before IQ-B3 is asked; IQ-B3 changes the
palette, not which controls read it.

## Review history
- **Integrator review of step 0 (independent opus, 2026-10-29): FAIL, one MAJOR, four MINORs.** Accuracy: 19 of 20 claims
  exact.
  - MAJOR: `radius.dialog` is used by the polkit dialog (`shell/security/polkit/AuthAgent.qml:250, :316`, `AuthDialog.qml:24`),
    so step 13 no longer removes it. Every "unused" or "rename" claim was checked again over the whole tree, `shell/security`
    included: the three unused Settings tokens hold; "the shared `FocusRing` is used once in the shell" now says outside
    `shell/security`; `SearchField` is used by no surface (only by unit tests).
  - MINOR: the clashes with #43 and #44 are gone (both merged); Q4 now gives the yellow accent's 2.02:1; the audit says what
    the render tools need (and that Qt's `offscreen` platform is not a substitute); the STATE key is 108, above main's 106 and
    the open pull requests' 107.
  - Also in scope: gate A2's role table, red on main: audit §3.7.5 lists the 15 entries (13 on 11c9e69, two more from the
    startup-settle fix), each a table out of date; step 0b repairs it and wires the check into `just check-quick`.
  - Coordination with #46: the section above.

## macOS reference
- macOS 27: one window radius, edge-to-edge sidebars, bars with a rule once content scrolls, white text on the accent, its
  per-app sidebar metrics (System Settings, Finder, App Store), measured on release captures (ADR-0024, ui-finesse §7,
  f1-macos27.md, settings-parity and store audits).
- macOS behaviour, not measured here: a window that is not key shows an unemphasized (grey) selection and dimmed toolbar
  items; Reduce Motion replaces motion with dissolves; Increase Contrast outlines controls; toolbar items show their label as
  a tooltip. Each step that relies on one of these confirms it on a capture or marks it NOT VERIFIED.

## Alternatives rejected
- **One large "design system" pass.** Against the brief (one pull request per step) and against the frozen areas; reviews
  would not see the change for the rewrite.
- **Aligning every app on one app's measured values** (one sidebar width, one row pitch). macOS 27's apps differ; copying
  one would move Grassfield away from each of the others (D1).
- **Waiting for every frozen area before starting.** Steps 1 to 8 touch none of them.
- **New per-surface tokens for every hover multiplier.** Step 12 names roles instead; a surface picks a role.

## Consequences
- Tokens: per-appearance window border tokens, `toolbar.*`, `radius.group`, role fills for hover and selection, the UX
  timings, the glass classes of step 22, the dark secondary and sheet values (Q2, Q3); removed: the three unused Settings tokens of
  audit §4.2 (`radius.dialog` stays: the polkit dialog uses it). Each with its source.
- Code: the role table first (step 0b), the shared controls next (steps 1, 10, 11, 14), then the surfaces; the areas still
  frozen after their merges (steps 22, 24, 25; steps 23 and 26 are free since #41 and #44 merged).
- Tests: gate A2's role check in `just check-quick`, `tst_pixelgrid` and an Increase Contrast case, a CI guard for literals, A2 cases for every new role or class, unit
  tests for Reduce Motion and focus rings; `tests/visual` captures per step (nested, integrator).
- Gates: A1 (keyboard: steps 7, 23), A2 (every colour step), F1 (the owner's side-by-side), P3 (steps 5, 20, 22), C1–C3 (step
  21, plugin).
- Specs: `docs/specs/ui.md` gains the rules above when step 1 lands; each step updates its surface's spec.
- Legal: nothing new; no Apple asset or name; the sidebar tile colours stay on the legal-review list (2026-10-26).

## Evidence
- Report: `docs/audits/design-polish-2026-10-29.md`.
- Captures and logs: `docs/audits/design-polish-2026-10-29/shots/` (the shared controls in both appearances, with and without
  Increase Contrast, at 1x and 2x; Settings > Appearance light, dark and with Increase Contrast; Desktop & Dock dark at 2x;
  Accessibility > Display; the text lab; `metrics.txt`, `corners.txt`; the pixel-grid walker and the control sizes).
- Tools: `docs/audits/design-polish-2026-10-29/tools/` (`run.sh`, `gallery.qml`, `qml-literals.py`) and the 2026-10-25 tools
  they reuse.
