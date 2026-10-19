# F1 reference gaps: macOS 26 captures vs Grassfield tokens

Status: analysis only (2026-10-18). Nothing in Grassfield was changed. The numbers below are our own
measurements, proportions and behaviour notes, taken from two privately held macOS 26 ("Tahoe") training guides. This file
contains no image, crop or text from those guides. The guides, their extracted images and the per-image index
(`design/reference/macos/INDEX.md`) stay in `design/reference/`, which is git-ignored and never committed or packaged.
Gate F1 (master-prompt §11) still needs the owner's side-by-side sign-off. These numbers are input for that sign-off,
not a substitute for it.

## Method

1. **Images.** The two guides hold 552 embedded images. 260 are alpha masks: they were dropped as images and used only
   to find exact edges in their parent capture. A further 32 decorations were dropped: chapter banners, cover art and
   icons under about 300 px wide, unless the crop showed a specific control. That left **260 kept images**.
2. **Triage.** Every kept image was viewed on contact sheets and classified by Grassfield surface. About 50 show Apple
   app content and are useful only as window, toolbar or menu context.
3. **Measurement.** Measurements come from luminance profiles and ASCII edge maps of the original pixels, with no
   resampling. Edges are taken at the 50 % antialiasing crossing.
   - Radii are circle-equivalent values from the 45° point of the corner, r = d / 0.293. They were checked against the
     Settings window alpha mask, where the method gives 25.1 pt against 26 ± 1.5 pt.
   - macOS draws continuous corners, so its visual curve starts further along each edge. The circle-equivalent value is
     the one a circular Grassfield radius should match.
4. **Conversion.** Pixel values were converted to points with each image's scale (next section), rounded to 0.5 pt. The
   uncertainty covers ±1 source pixel plus JPEG blur.
5. **Comparison.** The Grassfield values come from:
   - `ui/tokens/tokens.json`, mirrored by `ui/Grassfield/Ui/Tokens.qml`;
   - `compositor/src/core/Theme.hpp` (titlebar);
   - `config/hypr/grassfield/looknfeel.lua` (window rounding and gaps);
   - the specs in `docs/specs/`;
   - the nested screenshots `.dev/shots/visual-*.png`. These are 1920x1080 at scale 1, so token px = pt.

   No nested session was started for this analysis.

**Severity scale.** Δ is the Grassfield value minus the reference value; u is the uncertainty of the reference value.
- **match**: |Δ| ≤ max(1 pt, u).
- **small**: |Δ| − u ≤ 3 pt, or |Δ| ≤ 5 % of the reference value.
- **large**: anything larger.
- **missing**: the element or behaviour is absent, or organised differently.

## Scale assumptions

| Image family | px per pt | How it was established | Confidence |
|---|---|---|---|
| Full-screen captures (91, 1549-1580 px wide) | image width / 1470 (1.054-1.075) | Aspect ratio 1.5376 matches a 13.6-in notebook at its default 1470x956 pt; the About pane names that machine. 13-pt menu text has a 9.7 px cap height (9.8 expected); the 1280 or 1710 pt modes would give 11.3 or 8.4 px. The Settings window measures 763 px here = 722 pt, against 723 pt in the 2x capture. | medium-high (±2 %, edges ±1 pt) |
| Settings window captures (1446 px) and content crops (~1000 px) | 2.0 | Native Retina, not resampled: 13-pt text cap height = 19 px; window width 723 pt agrees with the full-screen capture above | high (±0.5 pt) |
| 17 close-up crops (status area, menu-bar left side, context menu, tiling popover, sheets, Apps search) | 2.0 | Cap height 19 px; battery glyph 51 px in three separate crops; traffic light 28 px; 24-pt default button 48 px; Apps panel 1688 px = 2 x 844 pt | high |
| Other crops | per image | Cap height of 13-pt text or a known element. Zoomed illustrations were used for structure only. | low-medium |

In a full-screen capture one pixel is about one point, so values from those images carry ±1 pt at best. Gate F1 asks for
±1 px at scale 1. Only the 2x captures can support that: Settings, menus, sheets, traffic lights, menu-bar glyphs and
Quick Settings radii.

## Per-surface comparison

### Menu bar

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Height, non-notch display | 24 ± 1 | `menubar.height` 24 | 0 | match |
| Height, notched notebook | 33-36 (indirect) | 24 | n/a | device-specific (see limits) |
| Background | none by default (wallpaper shows through; a "show background" option exists) | material band always drawn (screenshot: 24-px band) | — | missing (owner decision, master-prompt §5.5) |
| Left inset to system mark | 20.5 ± 1 | bar margin `spacing.xs` + button padding `spacing.sm` = 12 (`menubar.itemPadding` 10 is defined but unused) | −8.5 | large |
| System mark size | 13 x 15.5 ± 0.5 | `menubar.iconSize` 14 | ~0 | match |
| System mark to app name | 22 ± 0.5 | 2 x `spacing.sm` = 16 | −6 | large |
| Gap between menu titles, glyph edge to edge | 22-22.5 ± 0.5 (~11 per side) | 2 x `spacing.sm` = 16 | −6 | large |
| Menu title font | 13; app name bold, other titles regular | `typography.menuSize` 13, `menuWeight` 500, `menuBoldWeight` 700 | weight +100 | small |
| Status glyph height | 12-13.5 ± 0.5 (Wi-Fi 17 x 12.5, battery 25.5 x 12, search 12.5, Quick Settings 13 x 13.5) | `menubar.iconSize` 14 | +0.5-2 | match |
| Gap between status glyphs | 18.5-20 ± 0.5 | 2 x `spacing.sm` = 16 | −2.5 to −4 | small |
| Clock | 13 regular; weekday, month, day, wider gap, time; no seconds | translatable pattern, `menuWeight` 500 | weight | small |
| Right inset, clock end to screen edge | 18-19 ± 1 | `spacing.xs` + `spacing.sm` = 12 | −6.5 | large |
| Highlight behind an open title or icon | capsule ~23 ± 2 tall, fully rounded, ~14 padding around the text | rect inset 1/2 (21 tall), `radius.control` 6 | shape | small |
| Status-item order, right to left | clock, assistant, Quick Settings, search, battery, Wi-Fi; Sound shown only while active by default | clock, Quick Settings, battery, volume, network | no search glyph; volume always shown | missing (minor) |

### Dock

Both Dock captures are auto-shrunk to fit a full Dock (about 95 % of the screen width), so the absolute icon size is not
the default. The proportions hold in both captures: visible icon body / pitch = 0.735, height / body = 1.64. The values
below are scaled to Grassfield's 48-pt tile, taking the visible body as about 80 % of the tile.

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Distance from screen bottom | 6 ± 1 | `dock.bottomMargin` 6 | 0 | match |
| Corner radius | ~24 ± 3 (rounded rectangle, not a capsule) | `radius.dock` 20 | −4 | small |
| Vertical padding, tile edge to shelf edge | ~9.5 ± 1.5 | `dock.padding` 7 | −2.5 | small |
| Gap between tiles | ~5 ± 1.5 | `dock.spacing` 4 | −1 | match |
| End margin, shelf edge to first tile | ~10 ± 1.5 | `dock.padding` 7 | −3 | small |
| Running dot | 4 across; centre ~5 above the shelf's bottom edge | `dock.indicatorSize` 4 | 0 | match (placement to verify) |
| Separator | 1-1.5 wide; shelf height − 18 (≈ 44 for a 62 shelf) | `separatorWidth` 1, `separatorHeight` 40 | −4 | small |
| Tooltip | capsule 24.4 tall, 13-pt text, ~13.5 side padding, downward tail 12.6 x 7.3, tip 8 above the shelf | `dock.tooltipGap` 8, `radius.tooltip` 6, `control.tooltipPadding` 6, no tail | gap 0 | gap match; shape missing |
| Icon context menu | rounded panel with a tail pointing at the icon | plain popup | — | missing |
| Magnification default | off | `dock.magnificationEnabled` default true | — | missing (default) |
| Full Dock | shrinks to fit the screen width | not specified | — | missing (minor) |

### Window chrome

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Corner radius, toolbar windows | 26 ± 1.5 | `rounding` 12 (looknfeel.lua, all windows) | −14 | large |
| Corner radius, titlebar-only windows | ~13 ± 3 | 12 | −1 | match |
| Traffic-light diameter | 14 ± 0.5 | `kButtonDiameter` 12 | −2 | small |
| Gap between lights (pitch) | 9 ± 0.5 (23) | `kButtonSpacing` 8 (20) | −1 | match |
| Titlebar height, titlebar-only window | ~32 ± 2 | `kTitlebarHeight` 28 | −4 | small |
| First light centre, titlebar-only window (x, y) | ~15.6, 15.6 ± 1 | 18, 14 | +2.4 / −1.6 | small |
| First light centre, toolbar window (x, y) | 25.75, 25.75 ± 0.5 (inside the floating sidebar) | n/a: Grassfield apps sit under a separate titlebar | — | missing |
| Unified toolbar height | 52 ± 1; traffic lights and items share one row | Files: 28-px titlebar + 52 toolbar (two rows); `files.toolbarHeight` 52 | +28 overall | missing |
| Toolbar items | separate 36-pt glass capsules (back/forward pair 72.5 x 36, view group, actions group, search circle opening to a ~200-pt field); group gaps 16-20; insets 8 | `files.toolbarButtonSize` 28, `preview.toolbarButtonSize` 28, flat buttons | −8 | large |
| Window title in toolbar windows | ~15 bold, left-aligned after back/forward | centred 13-pt semibold title in the plugin titlebar, plus a folder title in the toolbar | — | missing |
| Traffic-light colours (sampled, JPEG/ICC caveat) | close ≈ #FF5C60, minimise ≈ #FAC800, zoom ≈ #35C759; inactive ≈ #D4D4D4 | own values #E5534B / #D9A93B / #4FA64F | deliberate | n/a (own palette) |
| Tiling margins | 8 ± 1 outer and between windows (off by default in Settings) | `gaps_out` 8, `gaps_in` 4 (8 between) | 0 | match |
| Tiling popover on green-button hover | Move & Resize (4 halves), Fill & Arrange (fill, 2-up, 3-up, quarters), Full Screen submenu, move to display; 230 x 251, radius 12 | none (Window menu only) | — | missing |

### Quick Settings (macOS Control Center)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Organisation | no shared panel: every module is its own glass shape on a 4-column grid | one 320-pt material panel with tiles and rows | — | missing (reorganisation) |
| Total width | 291 ± 1 | `panel.controlCenterWidth` 320 | +29 | large |
| Grid | cells 63, gaps 12.5-13.3, pitch 76 | `spacing.md` 12 | — | n/a |
| 1x1 module | 63 circle | none (`panel.ccIconButton` 30 buttons inside tiles) | — | missing |
| 2x1 module | 139 x 63 capsule, 36-pt icon disk, bold title + status line | `panel.tileHeight` 56, `ccIconButton` 30 | −7 / −6 | large |
| 2x2 module (Now Playing) | 138 x 139, radius ~30 ± 3 | `panel.ccArtSize` 34 art inside a tile | — | missing |
| Slider module | 291 x 62.5, radius ~20 ± 3, bold title top-left, ~4-pt track | sliders in rows, `control.sliderTrack` 4 | track 0 | track match, module missing |
| Position | 14 ± 1 from the right edge, ~13 below the bar | anchored under the icon | — | small |
| Default modules | Wi-Fi, Bluetooth, AirDrop (2x1 each); Now Playing (2x2); Stage Manager, Screen Mirroring, an appearance toggle, Screenshot (1x1); Focus (2x1); Display and Sound sliders; an edit-controls pill | Wi-Fi/Bluetooth/Airplane in one tile, Do Not Disturb, Now Playing, Display, Sound, keyboard brightness, Appearance row | — | missing: Stages toggle, Screenshot, per-module sizes |
| Edit mode | minus badges, a "+" capsule in the bar, a controls gallery, Small/Medium/Large and remove per module | none | — | missing |
| Active toggle | solid accent fill, white glyph | accent-filled icon circle | — | match |

### Notifications and widgets

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Banner width | 344-345 ± 1 | `notification.bannerWidth` 344 | 0 | match |
| Banner radius | ~18 ± 2 | `radius.banner` 16 | −2 | match |
| Gap between stacked cards | 6 ± 1 | `notification.bannerGap` 8 | +2 | small |
| Right inset / offset below the bar | 15 ± 1 / ~15 | `spacing.lg` 16 | +1 | match |
| App icon | ~32 (visible ~28) at a 13-15 inset; text column 57-58 from the card edge; padding ~15; line pitch ~16 | `notification.bannerIconSize` 36 | +4 | small |
| Card height | 71-73 for 3 lines, 105 for 5 lines | content-driven | — | n/a |
| Notifications panel | the same 344-pt column as banners; cards float with no full-height panel; footer: edit-widgets pill 87 x 23 + 24-pt close circle | `notification.centerWidth` 380, full-height panel | +36 | large / missing (panel) |
| Small widget | 164 ± 2 | `widget.cell` 158 | −6 | small |
| Medium widget | 343 x 164 ± 2 | 2 x 158 + 16 = 332 x 158 | −11 / −6 | small |
| Large widget | not captured | 332 x 332 | — | unverified |
| Widget radius | ~26 ± 2 | `widget.radius` 20 | −6 | large |
| Gap between widgets | 15-17 | `widget.gap` 16 | 0 | match |
| Desktop margin | 16 ± 1 from the left; top aligned with the notification column (~16 below the bar) | `widget.desktopMargin` 24 | +8 | large |
| Placement | widgets start top-left; desktop icons take the right column | "Add to Desktop" uses the first free cell from the right edge | — | small (organisation) |
| Widget gallery | panel anchored bottom-left, 241-pt sidebar, previews at ~0.67x; the notification column becomes a drop zone | overlay inside the Notifications panel | — | missing (organisation) |

### Search (macOS Spotlight)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Panel width with results | 639 ± 1 | `search.width` 680 | +41 | large |
| Panel radius | ~24 ± 3 | `radius.search` 26 | +2 | match |
| Field row | 56 ± 1 | `search.fieldHeight` 60 | +4 | small |
| Query text size | ~26 ± 1.5 | `search.fieldSize` 22 | −4 | small |
| Result row (one and two lines) | 56 ± 1 | `search.rowHeight` 44 | −12 | large |
| Result icon | ~32 | `search.rowIconSize` 28 | −4 | small |
| Panel top | ~0.20 of the screen height | `search.topFraction` 0.22 | +0.02 | match |
| Filter chips under the field | 23.5-tall capsules, 7.6 gap, scroll sideways | none | — | missing |
| Empty-query state | ~317 x 48 pill field + four ~45-pt round mode buttons (apps, files, actions, clipboard); low-confidence scale | field only | — | missing |

### Apps launcher (macOS 26 Apps; Launchpad successor)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Organisation | floating panel, 844 ± 1 wide, radius ~28 ± 2, top ~190: header with title and a more-menu, 7 category chips (~23 tall), a recents row, then an alphabetical scrolling grid; grid/list view option | floating panel (`launcher.panelWidth` 844, `launcher.panelRadius` 28, `launcher.topFraction` 0.18), search field, 6 category chips, alphabetical scrolling grid; no header, recents row or list view (not requested) | — | match (layout), missing (header, recents, list view) |
| Columns | 7 | 7 (`launcher.columns`) | 0 | match |
| Cell | 114.7 x 101.6 ± 1 | `launcher.cellHeight` 102, cell width = grid width / 7 ≈ 115 | 0 | match |
| Icon | 62 visible (~76 canvas) | `launcher.iconSize` 62 | 0 | match |
| Label | ~12 | `launcher.labelSize` 12 | 0 | match |
| Search | typing filters the grid in place (macOS 26; an earlier note of a 56-pt-row list is superseded); a store-search fallback row | `launcher.searchHeight` 36 capsule at the top of the panel, filters the grid in place (ranked by `shell/search/Ranking.js`) | — | match (filtering), missing (store row) |

### Overview (macOS Mission Control)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Spaces bar | full-width tinted band, 164 ± 1 tall when expanded; menu bar hidden, Dock kept | tiles only, `overview.barTopMargin` 12 | — | small (organisation) |
| Space thumbnail | 138 x 90 ± 1, name below in 13 pt | `overview.tileWidth` 168 x `tileHeight` 104, label inside | +30 / +14 | large |
| Thumbnail gap (pitch) | 32 (170) | `overview.tileGap` 14 | −18 | large |
| Add-space button | 32 circle, 18 from the right edge | tile-sized "+" tile | — | small |
| Current space | blue outline | `overview.selectionWidth` 3 outline | — | match |

### Stages (macOS Stage Manager)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Strip thumbnails | 157-167 wide ± 3, perspective-tilted, left inset 11-16, app icon badge ~30 at lower left, up to ~4 groups, group pitch 160-170 | strip metrics live in the compositor (`Stages.hpp`), not tokenised; no tilt | — | missing (tilt), unverified sizes |

### App switcher

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Surface | centred frosted panel: ~104-pt visible icons (128 canvas) at ~134 pitch, ~123 rounded-square selection with the name below, radius ~30 ± 4 | not implemented ("the coming app switcher", stages.md) | — | missing |

### Desktop

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Icon grid | 112 x 112 ± 1 | `desktopIcon.cellWidth` 104 x `cellHeight` 112 | −8 / 0 | large / match |
| Icon / label | 64 / 12 white with shadow | `desktopIcon.size` 64 / `labelSize` 12 | 0 | match |
| First icon centre from the right edge | 66 ± 2 | 16 + 104/2 = 68 | +2 | match |
| Arrangement | from the top-right corner, downward | right column | — | match |
| Stacks | group by kind; a click fans items upward with names in glass capsules and a round open button | none | — | missing |

### Files (macOS Finder)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Sidebar | floating inset panel: 8 from the window edges, radius ~18, translucent | flush sidebar | — | missing |
| Sidebar width | ~159 as shown (resizable) | `files.sidebarWidth` 184 | — | n/a (resizable) |
| Sidebar row | 32 ± 0.5 | `files.sidebarItemHeight` 26 | −6 | large |
| Section header | 11 bold grey; ~16 extra space above | `files.sidebarHeaderHeight` 28 | — | small |
| Toolbar | see window chrome (one 52-pt row, 36-pt capsules) | 28 titlebar + 52 toolbar, 28 buttons | — | missing / large |
| Search | 36 circle opening to a ~200-pt field | `files.searchWidth` 180 field | — | small |
| Tab bar | 28 ± 1; selected tab is a 137 x 25 white capsule, "+" circle at the right | `files.tabHeight` 28 | 0 | match |
| List row | 20 ± 0.5, zebra stripes ≈ 4 % | `files.listRowHeight` 24, `stripeOpacity` 0.04 | +4 / 0 | large / match |
| List header | ~28 ± 3 | `files.listHeaderHeight` 26 | −2 | match |
| Column view | 245 ± 2 wide, 22-pt rows | `files.columnWidth` 230, rows = 24 | −15 / +2 | large / small |
| Icon view cell | 112 x 112 ± 1 | `files.iconCellWidth` 104 x `iconCellHeight` 108 | −8 / −4 | large |
| Icon / label | 64 / 12, two lines | `files.iconSize` 64, 2 lines | 0 | match |
| Gallery strip | ~44 thumbnails at ~60 pitch, selection box 54 x 55 | strip cell 64, icon 48 | +4 | small |
| Inspector panel | ~248 ± 3, floating inset, info rows 23 | `files.galleryInfoWidth` / `previewWidth` 260 | +12 | small |
| Get Info window | 264 ± 1.5 wide, titlebar-only, disclosure sections | `files.infoWindowWidth` 320 | +56 | large |
| Tag dot | ~10 ± 1, several overlapping by about half | `files.tagDotSize` 10, overlap 4 | 0 | match |

### Glance and Preview (macOS Quick Look, Preview)

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Glance header | 38 ± 1: close + full-screen glyph circles (13, pitch 20) at the left, name, markup/share icons and an "open with app" capsule (~135 x 24) at the right | `preview.glanceHeaderHeight` 40 | +2 | match (controls to verify) |
| Glance size for a PDF | 691 x 768 on a 1470 x 956 screen (content-dependent) | 620 x 780 | — | n/a |
| Glance content inset | ~5 | not tokenised | — | n/a |
| Preview toolbar | floating glass capsule groups ~36-38 tall over the document | `preview.toolbarHeight` 44, `toolbarButtonSize` 28 | −8 | large |

### Settings

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Window width | 723 ± 1 (fixed) | `settings.windowWidth` 715 | −8 | small |
| Window corner radius | 26 ± 1.5 | 12 | −14 | large |
| Sidebar | floating: inset 8, radius 18 ± 1, translucent; the traffic lights sit inside it | flush, below a plugin titlebar | — | missing |
| Sidebar width | 215 ± 0.5 | `settings.sidebarWidth` 215 | 0 | match |
| Sidebar search | 195 x 28 capsule, top at 61 | `settings.searchHeight` 28 | 0 | match |
| Account row | 37 ± 1 avatar, 13 semibold name, 11-pt subtitle | none | — | missing (optional) |
| Sidebar row pitch | 32 ± 0.5 | `settings.sidebarItemHeight` 30 | −2 | small |
| Sidebar groups | +13 space, no divider | not tokenised | — | small |
| Selection | 195 x 32, radius 8 ± 1, inset 10, accent fill, white text | `radius.control` 6 | −2 | small |
| Sidebar icon | 20 ± 0.5 coloured rounded tile (radius ~5), white glyph | `settings.sidebarIconSize` 14, monochrome | −6 | large |
| Toolbar | back/forward capsule 72.5 x 36 + pane title 15 bold in a 52-pt toolbar | page title 20 inside the content (`settings.pageTitleSize`), no back/forward | — | missing |
| Content column | pane 500, margins 20, groups 460 ± 0.5 | `settings.contentMaxWidth` 520 | +60 | large |
| Group radius / fill | 12 ± 1, no stroke | `radius.menu` 10 with a separator-colour border | −2 | small |
| Group gap | 10 ± 0.5 | `settings.groupGap` 20 | +10 | large |
| Section header | 13 bold, 13 above the group, aligned with row text | 11 bold caption (`typography.captionSize`) | −2 | small |
| Hero card on top-level panes | 460 x 164: ~52 icon, 22-bold title, 12-pt subtitle | none | — | missing |
| Row height | 36 plain; 37.5-38.5 with pop-up or slider; 40 with push button; 42 with a 20-pt icon; 48-52 for two lines | `settings.rowHeight` 40 (fixed) | +4 / −2 | large (plain rows) |
| Row padding / separator | 10; 1-pt line inset 10 on both sides | not tokenised | — | n/a |
| Toggle | track 36 x 16, knob 21 x 12 pill | `control.toggleWidth` 38 x `toggleHeight` 22, round `toggleKnob` 18 | +2 / +6 | large (shape) |
| Slider | 6-pt track, ~21 x 16 pill knob ± 2 | `control.sliderTrack` 4, round `sliderKnob` 16 | −2 | small |
| Push button | 24 tall, radius ~6, min width ~64 | `radius.control` 6, `control.buttonMinWidth` 72 | +8 | match / large |
| Pop-up | value text + 17.5 round up/down indicator, no bezel | `settings.pickerWidth` 150 bezel box | — | small (style) |
| Segmented control | 24 tall, radius 5-6, selected segment solid accent | Light/Dark segmented | — | small |
| Help button | 24 circle at the bottom right of each pane | none | — | n/a |
| Sidebar order | network group first; then general/appearance/desktop group; notifications/sound/focus; lock/privacy/users; accounts; input devices and printers; groups separated by space | Appearance, Desktop & Dock, Notifications, Lock Screen, Keyboard, About, plus the new system sections | — | small (order) |

### Dialogs, alerts and sheets

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Alert width | 260 ± 2 (light and dark) | `panel.dialogWidth` 380 | +120 | large |
| Alert radius | ~24 ± 3 | `radius.dialog` 14 | −10 | large |
| Alert layout | app icon top-left (~64 frame); bold title and message left-aligned; two equal-width capsule buttons 110 x 28 side by side, gap 8, padding 16 | centred dialog | — | missing |
| Sheet | centred card over a dimmed parent, radius 26 ± 1.5, padding 20, full-width hairline above a 64-pt footer, buttons 24 tall (radius 6, ≥ 64 wide, 20 from the right and bottom edges, a pair is equal width), "?" at the bottom left | `files.sheetWidth` 420, `radius.dialog` 14 | −12 | large |
| Focus ring | ~3.5, accent colour | `control.focusRing` 2 | −1.5 | small |
| Default button | accent fill, white label (apps use their own accent) | accent | — | match |
| Notification-style alert | 344 x 122, radius ~20, 22-pt buttons | banners with actions | — | match |

### Menus and popovers

| Metric | Reference | Grassfield | Δ | Severity |
|---|---|---|---|---|
| Row height | 24 ± 0.5 (pop-up button lists 21-22) | `menu.itemHeight` 22 | −2 | small |
| Vertical padding | ~4.5 ± 1 | `menu.padding` 5 | 0 | match |
| Highlight inset / radius | 4.5-5 / ~7 ± 1 | `menu.padding` 5 / `radius.control` 6 | 0 / −1 | match |
| Menu radius | 12 ± 1.5 | `radius.menu` 10 | −2 | small |
| Separator block / line / inset | 11 (5 + 1 + 5) / 1 / ~16 | `menu.separatorHeight` 9 / 1 / 15 | −2 / 0 / −1 | small / match / match |
| Text inset (no icon) / with checkmark column / with icon column | 16 / 24 / ~38-40 | 5 + 10 = 15 | −1 | match |
| Icon | ~15 wide monochrome glyphs | `menu.iconSize` 14 | −1 | match |
| Section header | ~11 semibold grey on its own 24-pt row | not tokenised | — | verify |
| Submenu overlap / alignment | ~4.5, first row level with the parent row | `menu.submenuOverlap` 4 | −0.5 | match |
| Tag colour row | 14-15 dots at a 24 pitch, aligned with the text column | `swatchSize` 16 + `swatchGap` 8 (pitch 24) | +1.5 / 0 | small / match |
| Minimum width | none: menus as narrow as ~151 | `menu.minWidth` 220 | +69 on short menus | large |
| Menu-bar menus | open ~1.5 below the bar, detached from it | — | — | verify |
| Popovers | share popover 239 wide, 22-pt rows, arrow toward the button | no arrowed popovers | — | missing (minor) |

### Lock / login, OSD, polkit

No usable reference: neither guide shows a real lock screen, a login window, an authentication dialog or a
volume/brightness overlay. The only related image is a user-list illustration with an unverified scale (avatar ~55 if
2x; `lock.avatarSize` 64). All `lock.*`, `osd.*` and `polkit.*` tokens remain estimates.

### Neutral colours (light appearance, sRGB samples from the 2x captures)

| Element | Reference | Grassfield |
|---|---|---|
| Window content background | 252 grey | opaque app windows use `materialTint` #F3F4F6 (≈ 244) |
| Settings sidebar | 249 grey with a 1-px white rim | — |
| Grouped box | 247 grey, no stroke | fill `fillOpacity` 0.14 black + border |
| Row separator | 234 grey (≈ 8 % black) | `separatorOpacity` 0.16 black (≈ 214) |
| Menu background / separator | 248-251 / 222 | material + `separatorOpacity` 0.16 |
| Toggle off-track / push button / help button | ~230 / 228 / 236 | — |

Light-theme separators and group fills are about twice as dark as the reference (small). Accent colours are
Grassfield's own green on purpose and are not compared.

## Prioritised gap list (top 20)

Ordered by how often the surface is seen, then by how cheap the change is. "Token" means `ui/tokens/tokens.json`
(regenerate Tokens.qml with `ui/tools/gen-tokens.py`).

1. **Window corner radius.** Use 26 for Grassfield's own toolbar windows (Settings, Files, Preview); keep ~12-13 for
   titlebar-only third-party windows. Change: `config/hypr/grassfield/looknfeel.lua` `rounding` plus a window rule for
   the `org.grassfield.*` classes; titlebar drawing in `compositor/src/Titlebar.cpp` follows `w->rounding()`.
2. **Traffic lights and titlebar.** Diameter 12 → 14, gap 8 → 9, titlebar 28 → ~32 (low confidence), first centre at
   ~15.6 from the left. Change: `compositor/src/core/Theme.hpp` `kButtonDiameter`, `kButtonSpacing`, `kTitlebarHeight`,
   `kButtonInsetLeft`. Keep `overview.windowTitlebarHeight` and `Stages.hpp` `kTitlebarHeight` in sync.
3. **Menu bar.**
   - Add a transparent-bar mode with a "show background" option. macOS defaults to transparent; the default here is the
     owner's call against master-prompt §5.5.
   - Left inset 12 → 20.5, right inset 12 → 18.5, item padding 8 → 11 per side. `shell/menubar/BarButton.qml` pads
     with `spacing.sm` (8); `menubar.itemPadding` (10) is defined but unused, so wire it and set it to 11.
   - `typography.menuWeight` 500 → 400 for titles and clock.
   - Open-title highlight becomes a ~23-pt capsule.
   - Change: tokens `menubar.*`, `shell/menubar/MenuBar.qml`, `BarButton.qml`.
4. **Dock.**
   - Default `dock.magnificationEnabled` → false.
   - `radius.dock` 20 → 24, `dock.padding` 7 → 9.5, `dock.separatorHeight` 40 → shelf height − 18.
   - Tooltip becomes a capsule with a downward tail: `radius.tooltip` → height/2, `control.tooltipPadding` 6 → 13.5.
   - Tail on the icon context menu.
   - Change: tokens, `ui/Grassfield/Ui/Tooltip.qml`, `shell/dock/`.
5. **Menus.** `menu.itemHeight` 22 → 24, `menu.separatorHeight` 9 → 11, `radius.menu` 10 → 12, `menu.minWidth` 220 → ~150,
   section-header style token. Change: tokens, `ui/Grassfield/Ui/PopupMenu.qml`, `MenuItem.qml`, `MenuSeparator.qml`.
6. **Quick Settings layout.** Replace the single 320-pt panel with floating glass modules on a 4-column grid: 63 cells,
   13 gaps, 291 total width, 14 from the right edge.
   - 1x1 modules are 63 circles; 2x1 modules are 139 x 63 capsules with a 36-pt icon disk.
   - Sliders are 291 x 62.5 modules with radius 20.
   - Add an edit pill.
   - Change: `panel.controlCenterWidth` → 291, `panel.tileHeight` → 63, `panel.ccIconButton` → 36, new module tokens,
     `shell/overlay/ControlCenter.qml`, `docs/specs/controlcenter.md`.
7. **Notifications panel.** Use the same 344-pt column as banners, with floating cards instead of a full-height panel and a
   pill + close footer. `notification.centerWidth` 380 → 344, `notification.bannerGap` 8 → 6, `radius.banner` 16 → 18,
   `notification.bannerIconSize` 36 → 32. Change: `shell/notifications/NotificationCenter.qml`,
   `docs/specs/notifications.md`.
8. **Search.** `search.width` 680 → 640, `search.rowHeight` 44 → 56, `search.fieldHeight` 60 → 56, `search.fieldSize`
   22 → 26, `search.rowIconSize` 28 → 32. Add the filter-chip row; consider the four mode buttons (low-confidence scale).
   Change: `shell/search/`, `docs/specs/search.md`.
9. **Unified toolbar for Grassfield apps.** One 52-pt row with the traffic lights inside it (centre 25.75, 25.75). Items
   are 36-pt glass capsules: back/forward 72.5 x 36, grouped view and action capsules, a search circle that opens to
   ~200. Files today stacks a 28-pt titlebar over a 52-pt toolbar.
   - This needs the plugin to skip its titlebar for these clients and let the app draw the lights. That is
     cross-module work and needs an ADR.
   - Change: `files.toolbarButtonSize` / `preview.toolbarButtonSize` 28 → 36, `apps/files`, `apps/settings`,
     `apps/preview`, `compositor/`.
10. **Floating sidebar.** Inset 8, radius 18, translucent, rows 32, coloured 20-pt icon tiles in Settings.
    `settings.sidebarItemHeight` 30 → 32, `files.sidebarItemHeight` 26 → 32, `settings.sidebarIconSize` 14 → 20, new
    `sidebarInset` / `sidebarRadius` tokens.
11. **Settings content.**
    - Groups 460 wide with 20-pt margins: `settings.contentMaxWidth` 520 → 460.
    - `settings.groupGap` 20 → 10; group radius 12 with no border (new token instead of `radius.menu`).
    - Content-driven row heights: 36 base, 42 with an icon (`settings.rowHeight`).
    - 13-pt bold section headers.
    - The pane title moves into the toolbar next to a back/forward capsule; hero card on top-level panes.
    - Change: `apps/settings/qml/SettingsGroup.qml`, `SettingsPage.qml`, `docs/specs/settings.md`.
12. **Toggle shape.** Track 36 x 16 with a 21 x 12 pill knob. `control.toggleWidth` 38 → 36, `control.toggleHeight`
    22 → 16, knob width/height tokens instead of `control.toggleKnob` 18. Change: `ui/Grassfield/Ui/Toggle.qml`.
13. **Alerts and sheets.**
    - Alerts: 260 wide, radius 24, left-aligned icon/title/message, two equal-width 28-pt capsule buttons.
    - Sheets: radius 26, padding 20, a 64-pt footer under a hairline, 24-pt buttons with a 64-pt minimum width.
    - `panel.dialogWidth` 380 → 260 for alerts, `radius.dialog` 14 → 24/26, `control.buttonMinWidth` 72 → 64,
      `control.focusRing` 2 → 3.
    - Change: menubar confirmation dialogs, Files sheets, polkit (security review required).
14. **Apps launcher layout.** An 844-pt floating panel with radius 28 instead of a full-screen paged grid. It has category
    chips, a recents row, an alphabetical scrolling 7-column grid (115 x 102 cells, 62-pt visible icons) and a grid/list
    option; typing filters the grid in place. Change: tokens `launcher.*`, `shell/launchpad/`, `docs/specs/apps.md`. This is
    a UX change: owner decision (done 2026-10-19).
15. **Overview spaces bar.** Thumbnails 138 x 90 (from 168 x 104), gap 32 (from 14), names under the thumbnails, a
    full-width tinted band, a 32-pt round add button 18 from the edge. Change: tokens `overview.tile*`,
    `shell/overview/OverviewWindow.qml`.
16. **Widgets.** `widget.radius` 20 → 26, `widget.desktopMargin` 24 → 16, `widget.cell` 158 → 164. Desktop placement
    starts top-left; the gallery is anchored bottom-left. Change: `shell/desktop/DesktopWidgets.qml`,
    `docs/specs/widgets.md`.
17. **Icon grids and list density.**
    - `files.iconCellWidth` / `iconCellHeight` and `desktopIcon.cellWidth` → 112.
    - `files.listRowHeight` 24 → 20, column-view rows 22, `files.columnWidth` 230 → 245.
    - `files.infoWindowWidth` 320 → 264.
18. **Controls.** Slider track 6 in Settings and 4 in Quick Settings, with a pill knob of about 21 x 16 (`control.sliderTrack`,
    `control.sliderKnob`). Push buttons 24 tall. Light separators about half as dark: `material.separatorOpacity` light
    ≈ 0.08 (non-text, so outside the A2 text-contrast scope).
19. **App switcher (missing surface).** Centred frosted panel: ~104-pt icons at a ~134 pitch, a ~123 selection square
    with the name below, radius ~30. It needs a spec; `docs/specs/stages.md` already expects it.
20. **Tiling popover (missing).** Shown on green-button hover: four halves, Fill & Arrange layouts, Full Screen and move to
    display; 230 x 251, radius 12, 26-pt glyphs at a 52 pitch. Change: compositor hover hook plus a shell popover. This is
    a compositor gate: nested only, C1-C3.

## Limits

- **Version.** The guides show macOS 26 (Tahoe), but the target is macOS 27. Anything macOS 27 changes (likely the glass
  material, radii and Quick Settings) is not covered.
- **Image quality.** Most surfaces come from downscaled JPEG full-screen captures at about 1.06 px/pt. Edges are ±1 pt
  and glass radii ±2-4 pt, which is not enough for F1's ±1 px. Only the Settings window, menus, sheets, traffic lights,
  menu-bar glyphs and Quick Settings radii come from native 2x pixels.
- **Notch height.** The capture machine is a notched notebook. Its menu bar is notch-height, about 33-36 pt and only
  indirectly measurable because the bar is transparent. Positions measured below the bar (Quick Settings, notifications,
  widgets, menus) are given relative to the bar. The 24-pt non-notch height rests on a single medium-confidence crop.
- **Dock size.** Both Dock captures are auto-shrunk, so the default Dock size is unknown; only proportions are given.
- **Appearance and scale.** No dark-mode capture of any shell surface; all comparisons are for the light appearance. The
  scale of 1470 pt per screen width rests on the aspect ratio, the machine named in the About pane, text cap heights and
  the Settings window cross-check. A different scaled mode would shift every full-screen value by the same factor.
- **No usable capture:** lock screen, login window, authentication (polkit) dialog, OSD overlays, large widget, widgets
  inside the notification column, the Force Quit layout (context only), Stage Manager at 2x, the Search empty state at a
  verified scale.
- **Colours.** Colours are sampled from JPEGs with unknown ICC handling, ±3-5 per channel.
- **Low-confidence values:** titlebar-only chrome (titlebar ~32, radius ~13), Search collapsed field and mode buttons,
  Apps and Stage panel heights, slider knob, alert icon frame, compact menu rows, popover radii.

## Fidelity pass 1 status (2026-10-19, branch worktree-agent-abfa6fd971166f537)

Token-level and shape changes only. Values are within the stated uncertainty; `tests/unit/tst_tokens.qml`
`test_referenceMetrics` pins them. Screens: "visual NOT verified" for the items marked so below (see the report).

| Gap | Closed | Value now | Left |
|---|---|---|---|
| 3 Menu bar | insets 20.5 / 18.5, `itemPadding` 11 wired, `statusItemPadding` 9.5, `menuWeight` 400, capsule highlight 23 of 24, transparent by default + `menubar.showBackground` | see tokens `menubar.*` | status-item order, search glyph, notch height; legibility on a light wallpaper needs the contrast run (visual NOT verified after the three-pass shadow) |
| 4 Dock | `radius.dock` 24, `dock.padding` 10, `dock.separatorHeight` 49, capsule tooltip with tail (`control.tooltipPaddingX/Y` 13 / 4, tail 13 x 7), magnification default off | | icon context menu tail, full-Dock shrink; tooltip not captured (pointer missed the tile) |
| 5 Menus | `menu.itemHeight` 24, `separatorHeight` 11, `radius.menu` 12, `minWidth` 150 | | section-header style token |
| 7 Banners | `notification.bannerGap` 6 | | radius, icon size, centre panel (other pass) |
| 8 Search | width 640, field 56, query 26, row 56, icon 32 | | filter chips, empty state (other pass) |
| 12 Toggle | track 36 x 16, knob 21 x 12 | | |
| 13 Alerts, sheets | alert width 260 (`panel.alertWidth`), `radius.alert` 24, `radius.sheet` 26, equal-width capsule buttons 28 tall, `buttonMinWidth` 64 | | alert layout (icon, left aligned), sheet footer and 24-pt buttons, focus ring 3 (kept 2); Force Quit keeps its own 380 width; polkit untouched (security review) |
| 15 Overview | tile 138 x 90, gap 32, round add button 32 | | names under thumbnails, full-width band, button 18 from the edge |
| 16 Widgets | radius 26, margin 16, cell 164, placement from the top-left | | gallery anchored bottom-left |
| 17 Grids | files and desktop cells 112, list rows 20, column rows 22, column 245, Get Info 264 | | |
| 18 Controls | slider track 6 (Quick Settings 4), pill knob 21 x 16, light separators 0.08 | | push button height 24 |
