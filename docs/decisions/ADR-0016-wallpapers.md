# ADR-0016: Wallpapers: local photo, video and carousel (step 1), online daily pictures (step 2)
Status: Accepted (owner decisions 2026-10-20, batch 10/11); step 1 implemented through W6 on its branch (see "Implementation notes"), W7 to W9 and step 2 not started · Date: 2026-10-20 · Decider: owner

## Context

### Owner decisions (2026-10-20, docs/STATE.md:122-125)
- **Step 1, local:** photo, video and carousel wallpapers from local files; a Settings > Wallpaper pane, a rotation
  interval and a crossfade.
- **Step 2, online:** NASA Astronomy Picture of the Day (APOD) and the Wikimedia Commons picture of the day (POTD),
  through this ADR (licences, attribution, network, cache, privacy).
- Cross-module work (desktop, menu bar tone, lock screen, Settings, schema, packaging): an ADR is required (R5).

### Grassfield today (VERIFIED: read in this session)
- **Desktop wallpaper.** `shell/desktop/Wallpaper.qml` maps one `PanelWindow` per screen (:93-115), layer Background,
  namespace `grassfield-wallpaper`, and draws `WallpaperArt` (:167-170): a procedural artwork (sky gradient, sun, four
  hills, `shell/desktop/WallpaperArt.qml:5-7`), no image file. There is no user setting.
- **Dev-only image override** (:13-19, :63-91): `GRASSFIELD_WALLPAPER_FILE` or `qs ipc call wallpaper set <path>`, refused
  outside dev; path checks (absolute, no control characters, `.png/.jpg/.jpeg`, regular file, at most 64 MB through
  `stat`) and an `Image` with `fillMode: Image.Stretch`, `sourceSize` = window size, `cache: false`, `smooth: false`
  (:172-180). The accepted path lives in `VisualFixtures.wallpaperFile` (`shell/services/VisualFixtures.qml:33-38`),
  always empty outside dev. The A2 contrast run uses it (docs/testing/visual.md:34-40, :151-154).
- **Menu bar tone.** The menu bar is transparent by default (docs/specs/menubar.md:10). Its foreground follows the
  wallpaper strip under it, per output (`shell/services/BarTone.qml`, `BarToneLogic.js`; menubar.md:11): the artwork
  reports a known gradient, an image is drawn onto a small `Canvas` and averaged (Wallpaper.qml:122-165). One mean
  luminance per bar with hysteresis (0.175 / 0.18). Known limits (menubar.md:49): one tone per bar (a wallpaper light on
  one side and dark on the other is averaged), "there is no crossfade yet".
- **Lock screen.** `shell/security/lock/LockView.qml:74-107` draws `WallpaperArt` (plus the dev override `Image`),
  blurred by `MultiEffect` (`lock.blurMax`) under a shadow-colour scrim (`lock.dimOpacity` 0.6). The scrim alone carries
  gate A2 for any wallpaper (LockView.qml:16-22; docs/specs/security.md:241-246). Security module (R12): READ ONLY here.
- **Only consumers** of the wallpaper: the desktop and the lock (`grep -rl 'WallpaperArt|wallpaperFile' shell ui apps
  compositor config tests` → Wallpaper.qml, qmldir, LockView.qml, VisualFixtures.qml).
- **Settings.** Wallpaper is a v1 non-goal (docs/specs/settings.md:15-16, :95). The app writes flat dotted keys validated
  by `apps/settings/qml/Store.js` RULES (:41-72: enum, number, integer, boolean and colour types; no array-of-object
  type). The desktop's "Change Wallpaper" menu item is omitted (docs/specs/desktop.md:74).
- **Contract.** `config/schema/grassfield.schema.json` has `additionalProperties: false` at the top level and in every
  group; `scripts/dev/check-schema.py:4-5` evaluates only type, enum, required, properties, additionalProperties (bool),
  items, minimum, maximum and minLength (no `pattern`, no `maxLength`: the stores check those).
- **Image safety precedent.** Preview calls `QImageReader::setAllocationLimit(256)` (`apps/preview/src/main.cpp:27`,
  `previewlogic.h:16`) and refuses images over 16384 px per side or 256 MiB at 4 bytes per pixel before decoding
  (docs/specs/preview.md:57-60). Quickshell QML cannot call `QImageReader::setAllocationLimit`.
- **Process pattern precedent.** The pointer colours (ADR-0014) run a one-shot builder in a `Process`, debounced, one at
  a time, superseded, killed as a group, written atomically, with a status file (`pointer-theme.json`) that the Settings
  app watches (docs/specs/settings.md:60-61). The same pattern fits wallpaper preparation.
- **Packaging.** `grassfield-desktop` already depends on `qt6-multimedia` and `qt6-imageformats`
  (packaging/arch/PKGBUILD:58). QtMultimedia is used today only by Preview (THIRD_PARTY.md:64).
- **Legal.** FFmpeg 9.0.1 is GPL-3.0-only and is loaded by QtMultimedia's backend (docs/legal/licenses-audit.md:79,
  :151-157, gap G9). Owner batch 2 (STATE): "FFmpeg stays the system one loaded by QtMultimedia". The wallpaper is entry
  E32 of docs/legal/visual-review.md (procedural artwork, `distinct`).

### Platform facts (VERIFIED from installed files)
- Qt 6.11.2 image plugins (`/usr/lib/qt6/plugins/imageformats`): gif, icns, ico, jp2, jpeg, mng, pdf, svg, tga, tiff, wbmp,
  webp (PNG and BMP are built in). **No HEIF, AVIF or JPEG XL plugin** (kimageformats is not installed).
- QtMultimedia backend: `/usr/lib/qt6/plugins/multimedia/libffmpegmediaplugin.so` only (no GStreamer backend).
  `QMediaPlayer` has `playbackRate`, `loops` (`/usr/include/qt6/QtMultimedia/qmediaplayer.h:34-35`) and
  `playbackOptions` (:67; `QPlaybackOptions`: playback intent, network timeout, probe size,
  `qplaybackoptions.h:23-31`). QML: `MediaPlayer`, `VideoOutput` (`fillMode`, `endOfStreamPolicy`),
  `/usr/lib/qt6/qml/QtMultimedia/plugins.qmltypes`.
- QtQuick `Image` has `asynchronous`, `sourceSize`, `autoTransform` (EXIF orientation), `sourceClipRect`, `mipmap` and
  `retainWhileLoading` (`/usr/lib/qt6/qml/QtQuick/plugins.qmltypes:7340-7526`).
- QtQuick.Dialogs is installed with qt6-declarative (`/usr/lib/qt6/qml/QtQuick/Dialogs`); platform themes available:
  `libqgtk3.so`, `libqxdgdesktopportal.so` (`/usr/lib/qt6/plugins/platformthemes`). The session inherits
  `QT_QPA_PLATFORMTHEME=gtk3` from Omarchy (`/usr/share/omarchy/default/hypr/envs.lua:14`, included by
  `config/hypr/grassfield/omarchy.lua:43`).
- Quickshell 0.3.1: `HyprlandWorkspace.hasFullscreen` (`Quickshell/Hyprland/_Ipc/quickshell-hyprland-ipc.qmltypes:475`),
  `UPower.onBattery` (`Services/UPower/quickshell-service-upower.qmltypes:450`), `IdleMonitor` (`timeout`, `isIdle`,
  `respectInhibitors`), `ShellScreen` `name`, `model`, `serialNumber`, `devicePixelRatio` (quickshell-core.qmltypes,
  `QuickshellScreenInfo`). No DPMS state is exposed.
- Omarchy's background plugin (`/usr/share/omarchy/shell/plugins/background/Background.qml`, MIT, reference only):
  asynchronous `Image`, `PreserveAspectCrop`, no `sourceSize` (full-resolution decode), a 420-ms reveal that starts only
  when the incoming image's status is `Ready` (:168, :206-247), and `updatesEnabled: true` on purpose: "the background
  layer has been observed to lose its committed buffer while parked with updatesEnabled=false" (:198-202).
- Development machine (master-prompt §2): Intel UHD 630 (i915), 1920x1080, scale 1. Which VA-API driver is installed is
  UNKNOWN (not read: outside this task's read list).

### How macOS 26 does it (from memory, no Apple document consulted: ASSUMPTION; check against design/reference/macos in the F1 pass)
- **Settings > Wallpaper.** At the top, a preview of the current wallpaper with its name and the options that apply to
  it. Below, categories, each a row of thumbnails with "Show All": dynamic (time of day) pictures, landscape, cityscape,
  underwater and earth pictures, video ("aerial") wallpapers, colours, the user's photo library and added folders.
  Buttons add a folder or a single photo.
- **Fit** for a user picture: fill screen, fit to screen, stretch to fill screen, centre, tile; a colour well for the
  area a fit or centred picture leaves empty.
- **Folders and albums** shuffle at an interval: when logging in, when waking from sleep, every 5 seconds, every minute,
  every 5, 15 or 30 minutes, every hour, every day; random order.
- **Per display.** With several displays, each display has its own wallpaper. "Show on all Spaces" keeps one wallpaper
  for every desktop of a display.
- **Video wallpapers** are downloaded on demand. They play on the lock screen and, at login, slow down and come to rest
  as the desktop picture; they move slowly or stop while the Mac is idle; they double as screen savers.
- **Tint.** Translucent materials (menu bar, Dock, sidebars, and windows when "wallpaper tinting" is allowed) pick up
  the wallpaper's colour. The macOS 26 menu bar is transparent over the wallpaper; a setting restores its background.
- macOS accepts only Apple's own videos as video wallpapers; a local video file is a Grassfield extension.

## Options

### A. Where untrusted pictures and videos are parsed
1. **In the shell** (pure QML): `Image { asynchronous; sourceSize; autoTransform }` and `MediaPlayer` on the user's
   file.
   - Pros: least code.
   - Cons:
     - The shell process also holds the lock screen and the polkit agent (it receives the user's password). Image and
       video parsers have a history of memory-safety bugs (for example the 2023 libwebp heap overflow).
     - QML cannot set the allocation limit or read the pixel size before decoding. A large PNG is decoded at full size
       first (only JPEG scales while decoding), a transient spike of up to the allocation limit in the shell.
     - EXIF and colour handling happen per frame of the UI.
2. **One-shot helper process** (`grassfield-wallpaper`, C++/Qt, no daemon). It parses the user's file, applies EXIF
   orientation and the fit mode, converts to sRGB, re-encodes the picture at the output's pixel size and writes a sidecar
   with the luminance statistics of the menu-bar strip. The shell only decodes Grassfield's own output.
   - Pros: untrusted parsing out of the lock/polkit process; bounded memory in the shell; exact BarTone statistics with
     no `Canvas` readback; one file per output that the lock can reuse; the same path validates step 2 downloads.
   - Cons: a new small binary and a cache; a picture change costs one process start (about 0.1-0.6 s for a 24 MP JPEG:
     ASSUMPTION, measured in slice W0).
3. **A separate wallpaper process** (a second Quickshell instance) that draws the wallpaper itself.
   - Pros: isolation, also for video.
   - Cons:
     - A new service (§5.8).
     - The shell's desktop icons share the Background layer with it, so stacking depends on creation order and breaks
       when either process restarts (ordering rules not verified for Hyprland 0.56).
     - The lock still needs a picture file.
     - About +100 MB RSS (ASSUMPTION).

### B. Video playback
| | V1 QtMultimedia in the shell, original file | **V1b QtMultimedia in the shell, file transcoded once** | V2 separate Quickshell instance | V3 libmpv in a C++ QML plugin |
|---|---|---|---|---|
| Decoder input | the user's file (any codec) | Grassfield's own H.264 stream at output size, ≤ 30 fps, no audio | the user's file | the user's file |
| Untrusted parsing | in the shell | in the `ffmpeg` CLI, a separate process | in the second process | in the shell |
| CPU, 1080p30 H.264 with VA-API (ASSUMPTION, slice W0) | ~1-3 % of one core with zero-copy, ~5-10 % if Qt copies frames back | same, and always this case | same | lowest; best hwdec control |
| Codec risk on UHD 630 (Gen 9.5, ASSUMPTION) | AV1 has no hardware decode there: software, 50-200 % of a core at 4K | none: H.264 is decoded in hardware | as V1 | as V1 |
| GPU and battery | full-output repaint at the video's frame rate; the Dock and open popups re-blur every frame (Hyprland cannot reuse a cached blur over a moving backdrop) | same | same | same |
| New dependency | none (qt6-multimedia) | `ffmpeg` CLI, already installed with qt6-multimedia-ffmpeg; declared explicitly | none; a new unit and IPC | mpv/libmpv and C++ |
| Licence | GPL-3.0 FFmpeg inside the MIT shell process (today only Preview loads it) | same | outside the shell process | mpv licence to check |
| Work | S | M | M-L (process, IPC, layer order) | L |

Hybrid of V1/V1b: play directly when the probe finds H.264, HEVC 8-bit or VP9 at or below the output size and ≤ 30 fps,
and transcode otherwise. This is faster, but the user's file is then parsed in the shell.

### C. Lock screen
1. **A still of the current wallpaper** (the prepared picture, or the video's poster frame), drawn sharp under the
   existing scrim. This follows macOS, where the lock shows the wallpaper itself (ASSUMPTION). A2 holds through the scrim
   (security.md:241-246).
2. The same still, blurred as today (`lock.blurMax`).
3. The video plays on the lock. This needs QtMultimedia in LockView, a second decoder path in the security module and
   its own security review.

### D. Menu bar legibility over arbitrary photos
1. **Measured tone plus an automatic assist.** The helper writes the strip's luminance distribution. BarTone picks the
   tone with the best 5th-percentile contrast. If neither tone reaches 4.5:1 on that strip, the frosted band (as
   `menubar.showBackground`) is shown on that output, and Settings says so. This is a Grassfield addition.
2. macOS behaviour only: one mean tone, and the user turns on "Show menu bar background". The failure is a documented
   limit.
3. Two tones per bar (menus on the left, status items on the right), measured separately. This is not the macOS model.

## Decision (proposed): step 1

Option A2 (helper process), V1b for video, C1 for the lock and D1 for the menu bar, subject to the owner questions below.

### 1. Data model: grassfield.json, contract version 1, additive keys
```json
"wallpaper": {
  "source": "builtin",
  "path": "",
  "color": "#000000",
  "fit": "fill",
  "interval": "1h",
  "shuffle": true,
  "videoOnBattery": false,
  "outputs": []
}
```
| Key | Type / values | Default | Notes |
|---|---|---|---|
| `wallpaper.source` | `builtin` \| `color` \| `file` \| `folder` \| `video` (step 2 adds `online`) | `builtin` | `builtin` = the Grassfield artwork |
| `wallpaper.path` | absolute path, no control characters, ≤ 4096 bytes | `""` | for file, folder and video; stores check the rules (no schema `pattern`) |
| `wallpaper.color` | `#rrggbb` | `#000000` | the `color` source, and the backdrop of fit, centre and tile |
| `wallpaper.fit` | `fill` \| `fit` \| `stretch` \| `center` \| `tile` | `fill` | for pictures; video uses `fill` or `fit` only |
| `wallpaper.interval` | `login` \| `5s` \| `1m` \| `5m` \| `15m` \| `30m` \| `1h` \| `1d` | `1h` | folder only; "when waking from sleep" is deferred (it needs a resume signal from the security module) |
| `wallpaper.shuffle` | bool | true | folder: random order without repeats until every picture was shown; false = name order |
| `wallpaper.videoOnBattery` | bool | false | video: keep playing on battery (owner question 3) |
| `wallpaper.outputs` | array (≤ 16) of `{display: {name, model, serial}, source?, path?, color?, fit?, interval?, shuffle?}` | `[]` | per-display overrides; omitted fields come from the top level ("All Displays") |

- **Display identity.** Serial and model when the serial is not empty, else the connector name. The shell (`ShellScreen`)
  and the Settings app (`QScreen`) see the same three strings. An override for a display that is not connected stays
  stored and applies again when it is.
- **Validation.** One pure module, `ui/Grassfield/Ui/WallpaperConfig.js` (like `PointerColors.js`): defaults, validation,
  per-display resolution, the carousel order, the pause policy, the helper's argument vectors and the failure reasons.
  `Store.js` gets one rule type per key (`wallpaperOutputs` for the array). The shell's `SettingsStore` reads through the
  same module. `tst_settingsstore` checks parity with the schema. An invalid hand edit reads as the default and is never
  rewritten (S4).
- **Not in grassfield.json** (runtime state, safe to delete):
  - `$XDG_STATE_HOME/grassfield/wallpaper.json`: carousel position and seed per display, the last change time and the
    video crash marker; written by the shell, atomically.
  - `wallpaper-recent.json`: the sources picked recently, for the Settings grid; written by Settings.
  - `$XDG_CONFIG_HOME/grassfield/wallpaper-state.json`: status for Settings, as `pointer-theme.json` is (`state`,
    `reason`, `code`).
- **Dev guard.** With `GRASSFIELD_DEV=1`:
  - the stores and the shell refuse paths outside `<repo>/.dev/`, so no owner photo can appear in nested captures;
  - the Pictures section uses `.dev/wallpapers` (`GRASSFIELD_PICTURES_DIR`).
  The existing dev override keeps priority over everything, so the A2 run is unchanged.

### 2. The helper: `grassfield-wallpaper` (one-shot, never a daemon)
- C++/Qt Gui only, in `apps/wallpaper-tool/` (a new directory, justified by this step, R5). Installed as
  `/usr/lib/grassfield/grassfield-wallpaper`. Run by the shell and by Settings through `Process`: one argument vector, no
  shell, one job per display at a time, a newer request supersedes the running one (process group killed), a timeout
  (`wallpaper.toolTimeoutMs`). Exit code plus one JSON line on stdout.
- Subcommands:
  - `prepare <src> --size WxH --fit F --color C --out <dir>`
    - Checks: a regular file (no FIFO or device), at most `wallpaper.maxFileBytes` (256 MiB), and the header size at
      most 16384 px per side and 64 MP (Preview's limits); `QImageReader::setAllocationLimit(256)`.
    - Scaled decode where the format allows it.
    - `QImageReader::setAutoTransform(true)` applies EXIF orientation. The embedded ICC profile is converted to sRGB.
    - Composes the fit mode at the output's **physical** size (logical size x `devicePixelRatio`).
    - Writes `<key>.jpg` (quality 95; PNG for centre and tile, so pixels stay exact) and `<key>.json`. The JSON holds
      the size, the mean colour, and the strip luminance statistics (mean, 5th and 95th percentiles over the
      `menubarHeight` rows, in two halves). Metadata is stripped. The write is atomic.
  - `thumb <src> --width 320 --out <dir>`: Settings thumbnails (video: the poster).
  - `list <folder> --max 10000`:
    - one level deep, supported extensions only, sorted by name;
    - hidden files skipped;
    - runs under the timeout, so a hung network mount never blocks the shell.
  - `probe <video>` and `transcode <video> --size WxH --out <dir>` (V1b):
    - runs the `ffmpeg`/`ffprobe` CLI (argument vector);
    - output: H.264 yuv420p, at most the output's physical size, at most 30 fps, no audio, `+faststart`;
    - `-progress` is reported to Settings;
    - limits: duration at most `wallpaper.videoMaxSeconds` (600) and output at most `wallpaper.videoMaxBytes`;
    - also writes the poster frame and its strip statistics.
- Cache: `$XDG_CACHE_HOME/grassfield/wallpapers/{prepared,thumbs,video}/`, directories 0700. Key = SHA-256 of
  (real path, size, mtime, output size, fit, colour). LRU cap `wallpaper.cacheMaxBytes` (512 MiB). Prepared pictures of
  the current wallpapers are never evicted. Dev: `.dev/cache/wallpapers`.
- Supported pictures: JPEG, PNG, WebP, TIFF, BMP, GIF (first frame), intersected at run time with
  `QImageReader::supportedImageFormats()`. HEIF, AVIF and JPEG XL work once the optional `kimageformats` package is
  installed (optdepends; package name to VERIFY). Videos: whatever `ffprobe` can decode (MP4, MOV, MKV, WebM, ...).

### 3. Rendering: picture, colour, artwork
- `Wallpaper.qml` keeps one `PanelWindow` per screen (namespace and layer unchanged; `updatesEnabled` stays true, per the
  Omarchy note). Children:
  - a `Loader` for `WallpaperArt`, active only for `builtin`; the artwork moves to `ui/Grassfield/Ui/` so that Settings
    can draw its tile, and `shell/desktop/WallpaperArt.qml` stays as a thin wrapper, so LockView needs no change for
    this;
  - two `Image` items A and B (`asynchronous: true`, `cache: false`, `sourceSize` = physical size, `smooth: false`
    because the picture is drawn 1:1);
  - a `Loader` for the video item;
  - the dev override on top.
- **The shell decodes only the helper's output.** Until the prepared file exists, the previous wallpaper stays (never a
  blank frame). A new output first shows the closest prepared picture of the same source, scaled with `fillMode`, until
  its own is ready.
- BarTone gets the tone from the sidecar statistics (no `Canvas`, no readback). The artwork keeps `reportGradient`.
- HiDPI and fractional scaling: prepared at physical size. NOT VERIFIABLE on the reference panel (master-prompt §2).

### 4. Carousel
- `list` at the start, then again at each change when the folder's mtime changed. Shuffle = a Fisher-Yates order with a
  seed stored in `wallpaper.json`; no repeat until all were shown; new files join the next cycle.
- **Preload.** `wallpaper.preloadLeadMs` (30 s) before the change, `prepare` the next picture. Then load it into the
  hidden Image (decode on Qt's image thread). Once it is `Ready`, show it at opacity `wallpaper.uploadOpacity` (0.004)
  for one frame, so the texture upload happens before the fade and not on its first frame. Then animate opacity 0 → 1
  over `wallpaper.crossfadeMs` (1000 ms, ASSUMPTION for macOS), and release the old image (`source: ""`).
- Reduce Motion: a crossfade of at most `motion.reducedMax` (100 ms).
- The menu bar tone switches at the crossfade's midpoint, from the incoming sidecar.
- The `login` interval changes the picture once at shell start, not at a shell restart within the same session.
- A file that fails is skipped and remembered as bad for the session (path, size, mtime). If every file fails, the
  current picture stays and Settings shows the reason.

### 5. Video (V1b)
- Selecting a video runs `probe`, then `transcode` (Settings shows progress). The shell then plays the cached H.264 file:
  `MediaPlayer { loops: MediaPlayer.Infinite }`, no `AudioOutput`, and `VideoOutput { fillMode, endOfStreamPolicy:
  KeepLastFrame }`. The poster frame is shown until the first frame.
- **Play only while all of these hold** (pure function in `Wallpaper.js`, re-evaluated on every event, never polled):
  - the session is unlocked;
  - the output's active workspace has no full-screen window (`hasFullscreen`);
  - not idle: its own `IdleMonitor`, timeout `wallpaper.videoIdleSeconds` (60). On idle, the playback rate eases to 0.25
    over 2 s and then pauses (the macOS "settles" feel); with Reduce Motion it pauses at once;
  - on AC power, or `videoOnBattery`;
  - Reduce Motion is off;
  - `material.profile` is not `reduced`.
  A paused video keeps its frame on screen and decodes nothing.
- The wallpaper never creates an idle inhibitor, and the idle lock still fires while a video plays (tested).
- **Crash safety.** Before starting playback the shell writes a marker (`videoStarting`: path, time) and clears it after
  `wallpaper.videoStableMs` (10 s) of playback. If the shell finds a marker at start, it assumes the video crashed it. It
  then shows the poster still, does not retry, and Settings explains this once. This avoids a restart loop.
- Many videos in rotation ("shuffle videos") is out of scope for step 1.

### 6. Lock screen: proposal to the security module (READ ONLY here; security-engineer, opus reviewer PASS, R12)
- New read-only API in `shell/services/` (not in `security/`): `WallpaperState.lockStill(outputName)` returns the path of
  the prepared picture or the video poster for that output, or `""` (the artwork).
- **Proposed LockView diff**, to be written by the security-engineer:
  - the existing `Image` (LockView.qml:83-91) takes `VisualFixtures.wallpaperFile` when it is set (dev), else
    `WallpaperState.lockStill(screen name)`;
  - `sourceSize` capped at the screen size; `asynchronous` stays;
  - the blur depends on owner question 4 (C1: `blur` 0, so the picture is sharp; C2: unchanged);
  - the scrim, the text and the field are unchanged.
- **Security analysis for the reviewer.** The change is display only: authentication, the lock state and input never
  read it, and a failed or slow load leaves the artwork that is already drawn underneath. The file is Grassfield's own
  JPEG in a 0700 cache directory. The lock rejects anything that is not a regular file of at most
  `wallpaper.lockStillMaxBytes` under that directory, and decodes at most the screen size. No video decoder enters the
  security module (option C3 is a later, separate decision). Gates: L1-L5 again, plus the A2 lock run on the new
  wallpapers.

### 7. Desktop, material and legibility (gate A2)
- **Desktop icon labels**: white with three soft shadow passes. White wallpaper is the worst case, 4.8:1, and the token
  calculation covers any backdrop (docs/testing/visual.md:200, :254). Not affected by user wallpapers.
- **Widgets, the Dock shelf, popups** (material): a frosted tint over the backdrop. The composite luminance is monotonic
  in the backdrop luminance, so black and white wallpapers bound the contrast, and the token calculation already uses
  them (`tests/visual/test_contrast_tokens.py`). The Dock's running dot is 3:1 over any backdrop (dock.md:15). Covered by
  construction, not affected.
- **Transparent menu bar**: the only surface whose legibility depends on the picture. Option D1 (owner question 5):
  - `Wallpaper.js` derives, from the sidecar's percentiles, the worst contrast of white and of black text on the strip;
  - BarTone picks the better tone, with the existing hysteresis;
  - if the best is below 4.5:1, that output shows the frosted band (`menubar.showBackground` behaviour, per output) until
    the wallpaper changes;
  - `qs ipc call bartone status` also reports `assist: true|false`.
- **Video**: the tone comes from the poster plus 8 frames sampled at transcode time; the worst case decides; no per-frame
  measurement.
- **Material tint from the wallpaper** (macOS "wallpaper tinting"; owner question 6): a later, optional key
  `material.wallpaperTint`. It shifts the tint's hue towards the sidecar's mean colour at constant relative luminance,
  so the contrast is unchanged by construction; re-checked by the token calculation. Not in the first slices.
- **How A2 covers user wallpapers** (today it does not: 5 uniform or fine-grained images, visual.md:151-154):
  1. `contrast.py gen` adds coarse worst cases:
     - `split` (white left half, black right half);
     - `horizon` (white top 12 px, black below, across the bar);
     - `threshold` (luminance 0.17, the tone crossover, menubar.md:49);
     - `blocks` (64-px random blocks of extreme luminance);
     - a procedural "photo-like" picture (large-scale noise).
     These are generated, never committed photos.
  2. `contrast.sh --surfaces desktop,lock` runs them through the real path: dev override → helper → sidecar → BarTone
     and assist. Expected: every menu-bar cell ≥ 4.5:1, either by tone or by assist.
  3. `tst_bartone.qml` covers the percentile decision and the assist.
  4. **At run time** every applied wallpaper is checked by the same rule, so any user picture keeps A2 by construction.
     Hybrid mode: the shell logs `wallpaper tone=<t> worst=<ratio> assist=<bool>` to its journal, which the owner reads
     in L2.

### 8. Settings > Wallpaper pane (macOS layout; UI text English and French, no Apple names)
- Sidebar entry "Wallpaper" (« Fond d'écran ») after Appearance. A new Grassfield-drawn symbolic glyph `wallpaper`
  (branding/icons/symbolic, listed in branding/LICENSES.md). `--section=wallpaper`.
- **Header group:**
  - a preview tile in the aspect ratio of the selected display (tokens `settings.wallpaperPreview*`, radius
    `settings.displayRadius`);
  - the name: file name, folder name and count, "Grassfield", or the colour;
  - a status caption: "Preparing…", "Changes every hour, shuffled", or the reason from `wallpaper-state.json`, in the
    existing `ErrorNote` style.
- **Rows** (`SettingsRow` and existing components):
  - "Display": All Displays, then each display. Shown only with more than one output.
  - "Fit" (Picker): Fill Screen, Fit to Screen, Stretch to Fill Screen, Centre, Tile.
  - "Colour": `ColorWell`, for colour, fit, centre and tile.
  - "Change picture": When logging in, Every 5 seconds, Every minute, Every 5 minutes, Every 15 minutes, Every 30
    minutes, Every hour, Every day. Folder only.
  - "Shuffle": `Toggle`, folder only.
  - "Play on battery power": `Toggle`, video only.
  - Transcode progress: a slider-less progress row with Cancel.
- **Sections:** grids of 16:10 thumbnails, 4 per row (tokens `settings.wallpaperTile*`), "Show All (n)":
  - "Grassfield": the artwork, drawn live by the shared `WallpaperArt`;
  - "Colours": 8 swatches and a custom colour well;
  - "Pictures": `xdg-user-dir PICTURES`;
  - "Folders and Videos": from `wallpaper-recent.json`; a folder tile reads "Shuffle <name>", a video tile has a play
    badge;
  - step 2: "Online".
  Buttons: "Add Folder…", "Add Picture…", "Add Video…".
- **Pickers.** `QtQuick.Dialogs` `FolderDialog` and `FileDialog`, with name filters from the helper's supported list.
  With the session's gtk3 platform theme this should be the native GTK chooser (ASSUMPTION; it does not look like a
  Grassfield window, a documented limit). Also:
  - dropping a file, folder or video (text/uri-list) on the preview tile sets it;
  - the desktop context menu gets "Change Wallpaper…" (opens this pane);
  - Files and Preview get "Set as Wallpaper" in a later slice.
- **Keyboard and accessibility.**
  - Each grid is one focus stop: arrows move, Home/End, Return/Space apply (the `IconModePicker` pattern).
  - Tiles are `Accessible` radio buttons named after the picture.
  - All text is `qsTr`, en and fr. Untrusted names are `Text.PlainText`.
- **Escape / Reset.**
  - Changes apply at once (macOS: no Apply or Cancel).
  - Esc closes an open picker, popup or dialog, or collapses "Show All"; it never changes the wallpaper.
  - Reset = the "Grassfield" tile (always first, always available). Every error note also offers "Use the Grassfield
    Wallpaper".
  - Removing the `wallpaper` object by hand reads as the defaults.
- **Thumbnails.** `thumb` jobs, two at a time, cached. A placeholder is shown until they are ready; the pane opens without
  waiting for them.

### 9. Failures (the wallpaper is never blank, never a busy loop)
| Case | Detected by | User sees (Settings caption / note) | Desktop shows |
|---|---|---|---|
| File missing (moved, deleted) | helper `ENOENT`; at shell start, a `stat` of the source | "The picture "x" can't be found." | its prepared copy while cached, else the artwork |
| Corrupt or truncated file | decode error | "The picture "x" can't be read." | the previous wallpaper |
| Unsupported format (HEIF without kimageformats) | not in `supportedImageFormats()` | "This picture format isn't supported." | previous |
| Huge file or picture | byte cap, then header size cap, before any decode | "This picture is too large (W x H)." | previous |
| Not a regular file (FIFO, device) | `lstat`/`stat` | "This item can't be used as a wallpaper." | previous |
| Folder unmounted or unreachable | `list` error or timeout (process group killed) | "The folder "x" isn't available." Retried at the next change | current picture kept |
| Folder empty or with no supported files | `list` returns 0 | "No pictures in this folder." | current kept |
| One bad file in a folder | `prepare` fails | (journal only) | next picture |
| Video codec missing, or probe failed | `probe` | "This video can't be played (codec name)." | previous |
| Transcode failed (disk full, timeout) | `transcode` exit | reason, plus Retry | previous |
| Playback error at run time | `MediaPlayer.error` | the player's message | poster still |
| Shell restarted while a video started | crash marker | "The video wallpaper was stopped; a still is shown." | poster still |
| Helper missing (not installed or not built in dev) | exit 127 | "Wallpapers can't be prepared: the helper is missing." | artwork |
| Malformed `wallpaper` keys | stores | file banner (S4) for Settings; the shell reads the defaults | artwork |

### 10. Performance gates (master-prompt §10, ADR-0006; † = L2, owner run, NOT VERIFIED until then)
| Gate | Wallpaper target | How |
|---|---|---|
| P1† idle CPU | unchanged for builtin, colour, picture and carousel at ≥ 1 min: one timer, no polling. A video wallpaper is paused within `videoIdleSeconds`, so the 10-minute idle run measures a paused video | `pidstat`; journal samples (hybrid mode) |
| W-V† video while visible | 1080p30 transcoded H.264: shell ≤ 3 % of one core, Hyprland ≤ 3 %; paused → back to the P1 baseline ±0.2 pt within 1 s | `pidstat` on both pids; battery draw on AC vs paused, informational |
| P2 memory | ≤ 2 frames per output (physical pixels x 4 B) + 10 MB in steady state, i.e. ≤ 27 MB on GF-REF; one image per output after a fade; video: QtMultimedia and its frames ≤ 120 MB; total RSS stays ≤ 608 MB | `/proc/<pid>/status` after 50 changes (no growth) |
| P3† crossfade | ≥ 95 % frames < 16.7 ms during a fade on UHD 630 at 1080p, and no frame > 33 ms at fade start (preload works) | frame-time probe (ADR-0006 method); nested indication in L1 |
| P4 Settings | the pane is visible ≤ 300 ms with an empty thumbnail cache; a thumbnail never blocks input | timestamped logs |
| P5† startup | the wallpaper never delays the menu bar and Dock (≤ 2 s): the cached prepared picture or the artwork shows at once, and preparation runs after | journal |
| Q2 | 0 QML errors through every failure case of section 9 | `journalctl --user` |

### 11. Tests
- **L0 unit:**
  - `tests/unit/tst_wallpaper.qml` (`Wallpaper.js`): validation, defaults, display matching, outputs array limits, shuffle
    without repeats and with a stable seed, the interval table, the pause-policy truth table, argument vectors (no
    injection: paths starting with `-`, newlines), failure reason mapping;
  - `tst_settingsstore` parity for the new keys, plus `tests/shell/settings_roundtrip`;
  - `tst_bartone.qml`: percentile tone and assist.
- **Helper (GTest, generated fixtures, not committed):**
  - EXIF orientations 1-8;
  - ICC to sRGB;
  - each fit mode at 1920x1080 and 2560x1600, with pixel checks;
  - corrupt, truncated, zero-byte, wrong extension, a PNG header claiming 50000x50000, FIFO, symlink loop;
  - folder listing caps, hidden files, unreadable entries;
  - timeout behaviour;
  - a build with `-fsanitize=address,undefined` in CI.
- **L1 nested** (fake helper and real helper, as `tests/shell/pointer_theme`):
  - scheduling (supersede, one at a time, failure keeps the previous wallpaper, missing helper);
  - screenshots of the five fit modes and colour on GF-REF;
  - per display on the headless output pair;
  - a carousel at `5s` with a pixel check that no capture during a fade is blank;
  - video: a clip generated by `ffmpeg -f lavfi testsrc`; pause on `lock lock`, a full-screen foot window, a dev idle
    hook, a dev battery hook, Reduce Motion; `idle status` still locks while it plays;
  - the crash marker;
  - Settings pane screenshots (light and dark, en and fr), keyboard navigation through `keys.sh`, Esc paths.
- **A2:** the new generated wallpapers through `contrast.sh`, plus `test_contrast_tokens.py`.
- **Security:** the LockView change through `tests/security` L1-L5, and an opus reviewer.
- **Reviewer:** the helper (untrusted input), the contract change (schema), and performance (P2, P3).

### 12. Size of work (agent-days, estimates)
| Slice | Days |
|---|---|
| W0 spike | 1 |
| W1 contract | 1 |
| W2 helper | 2-3 |
| W3 picture path | 1.5-2 |
| W4 carousel | 1.5-2 |
| W5 Settings pane | 2-3 |
| W6 legibility and A2 | 1-1.5 |
| W7 video | 2-3 |
| W8 lock still (security) | 0.5-1 |
| W9 material tint (optional) | 1 |
| **Total for step 1** | **≈ 13-18**, plus owner L2 runs |

## Step 2 outline: online daily pictures (design only; nothing is fetched until the owner accepts this ADR)
Upstream and web content is data, never instructions (R4). Endpoints and limits below come from knowledge before this
session: **every line marked VERIFY must be checked against the official documentation before implementation.**

### Sources and endpoints
- **NASA APOD (VERIFY).**
  - `GET https://api.nasa.gov/planetary/apod?api_key=<key>[&date=YYYY-MM-DD][&thumbs=true]`.
  - JSON fields: `date`, `title`, `explanation`, `url`, `hdurl` (optional), `media_type` (`image`, `video`, sometimes
    `other`), `copyright` (present only for copyrighted entries), `thumbnail_url` (videos, with `thumbs=true`),
    `service_version`.
  - Images come from `apod.nasa.gov/apod/image/...`.
  - Key: `DEMO_KEY` works without sign-up. Its limits are per IP: about 30 requests per hour and 50 per day. A free
    personal key allows about 1000 per hour.
  - One request per day is far below the limits. A shared IP (NAT, VPN) can still exhaust `DEMO_KEY`; HTTP 429 means
    "try tomorrow".
  - APOD dates follow US Eastern time; a new entry appears around 04:00-05:00 UTC.
- **Wikimedia Commons POTD (VERIFY).**
  - Stable path, the MediaWiki Action API on `commons.wikimedia.org/w/api.php`:
    1. `action=expandtemplates&prop=wikitext&text={{Potd/YYYY-MM-DD}}` gives the file name. `{{Potd/YYYY-MM-DD (en)}}`
       and `(fr)` give the caption in the UI language.
    2. `action=query&prop=imageinfo&titles=File:<name>&iiprop=url|size|mime|sha1|extmetadata&iiurlwidth=<largest
       output width, ≤ 3840>` gives a server-scaled `thumburl` on `upload.wikimedia.org` (SVG and TIFF are rendered to
       PNG or JPEG), plus `extmetadata`: `LicenseShortName`, `LicenseUrl`, `Artist` (HTML), `Credit`,
       `AttributionRequired`, `UsageTerms`, `ObjectName`.
  - No key. The User-Agent policy asks for a descriptive User-Agent with contact information (owner question 8).
  - An alternative feed, `api.wikimedia.org/feed/v1/wikipedia/<lang>/featured/YYYY/MM/DD`, includes the picture with
    its licence, but that gateway was announced for deprecation: VERIFY before choosing it.
  - POTD dates are UTC.

### Licence and attribution
- **APOD.** NASA material is generally not under copyright in the US, but many APOD pictures are third-party works. The
  `copyright` field names the holder. Proposal: skip days that have a `copyright` field (keep the previous picture) by
  default (owner question 7). For any shown picture, Settings and an "About This Wallpaper" item in the desktop menu show
  the title, the credit and a link to the APOD page. No NASA insignia or logo is ever used. "NASA" appears only as the
  source's name. Needs legal review.
- **Commons.** A licence per file. Commons hosts only free licences and public domain. Show attribution as Title,
  Author, Source, Licence ("TASL", the CC practice) in the same two places. Accept only licences in an allow-list
  (public domain marks, CC0, CC BY, CC BY-SA; anything else is skipped). `Artist` and `Credit` are HTML: converted to
  plain text, never rendered as rich text. Needs legal review: whether resizing and caching for local display needs
  anything beyond attribution.

### Network policy
- **Opt-in.** Off by default. Turning it on shows what is contacted: "Grassfield contacts api.nasa.gov and apod.nasa.gov
  once a day. These services see your IP address."
- **Never from the shell process.** `grassfield-wallpaper fetch apod|commons --out <dir>` runs `curl` (an argument
  vector, a base system tool) with:
  - `--proto =https --proto-redir =https --max-redirs 3`;
  - `--connect-timeout 10 --max-time 60`;
  - `--max-filesize` (VERIFY its behaviour without Content-Length on the installed curl);
  - a fixed User-Agent; no cookies, no Referer.
  The helper itself checks that every URL from JSON is `https` and that its host is on the allow-list `api.nasa.gov`,
  `apod.nasa.gov`, `commons.wikimedia.org`, `upload.wikimedia.org`. An APOD `http://apod.nasa.gov` URL is upgraded to
  https; anything else is refused. Optional hardening: run through `systemd-run --user` with `ProtectSystem`,
  `ReadWritePaths=<cache>`, `RestrictAddressFamilies`, `MemoryMax` (VERIFY which options work in the user manager).
- **Schedule.** At most one successful fetch per source per calendar day, at a random time in a window after the new
  picture appears. Only when NetworkManager reports full connectivity, and not on a metered connection. Backoff after a
  failure: 1 h, 3 h, then the next day. Never in a dev session, except against a loopback test server
  (`GRASSFIELD_DEV=1`, `--base-url http://127.0.0.1:<port>`).
- **Offline.** The last cached picture stays. With nothing cached, the artwork and "Waiting for a connection".

### Cache
`$XDG_CACHE_HOME/grassfield/wallpapers/online/{apod,commons}/YYYY-MM-DD.{jpg,json}`, 0700. Keep 14 days or 200 MiB per
source, whichever is smaller (owner question 9). The prepared copies go in the step 1 cache. Removing the cache only
costs a new download.

### Privacy
- No account, no identifier, no cookie, no machine ID. The User-Agent is constant: product name and major version.
- What each request reveals:
  - APOD: the IP address, the time, the User-Agent, the date asked for and the key. `DEMO_KEY` is shared by everyone;
    a personal key is linked to the e-mail address used to sign up, so it is an identifier.
  - Commons: the IP address, the time, the User-Agent with the project contact, and the file name. Wikimedia's
    privacy policy covers its retention of IP addresses.
  - The DNS resolver sees the host names.
- No other host is ever contacted: no YouTube or Vimeo for APOD videos, no linked pages.

### Downloaded content is untrusted
- **Download.** Checks: `Content-Type` in {image/jpeg, image/png, image/webp}, magic bytes matching it, size ≤ 40 MiB
  (streamed count), then the step 1 `prepare` checks (header ≤ 16384 px per side and 64 MP, allocation limit,
  re-encode, metadata stripped). The original is deleted once prepared.
- **JSON** (≤ 256 KiB) is parsed by the helper only. Text fields are reduced to plain text: control and bidi characters
  removed, title ≤ 200 and credit ≤ 300 characters. The shell receives only the helper's sanitized sidecar.
- **Aspect.** Panoramas and portrait pictures are common on both sources. If the picture's aspect ratio is within
  ±35 % of the output's, use Fill; otherwise use Fit on the picture's mean colour.

### When the picture is a video (APOD `media_type` `video` or `other`)
Keep the previous picture and say so in Settings ("Today's entry is a video; yesterday's picture is shown"). Never
download the video and never use the third-party thumbnail. An animated GIF uses its first frame.

### Settings (step 2)
An "Online" section with two tiles, "Astronomy Picture of the Day (NASA)" and "Picture of the Day (Wikimedia
Commons)". Choosing one asks for the opt-in, shows the disclosure, then the current picture with its attribution and
"Last updated". Keys, provisional: `wallpaper.source: "online"`, `wallpaper.online.provider: "apod"|"commons"`,
`wallpaper.online.includeCopyrighted` (APOD, default false).

### Size
O1 helper `fetch` with fixtures and a loopback test server (1.5 days), O2 scheduler and cache (1 day), O3 Settings
section and attribution (1-1.5 days), O4 reviewer (network and untrusted input) plus an owner L2 run: ≈ 4-5 days.

## Owner questions (recommended proposal first)
1. **Where pictures and videos are parsed.**
   (a) The one-shot helper `grassfield-wallpaper`; the shell decodes only the helper's output.
   (b) In the shell (pure QML, less code; the parsers run in the process that holds the lock and polkit).
   (c) A separate wallpaper process for everything (a new service, layer-order risk).
2. **Video playback.**
   (a) Transcode once to H.264 at the output size, then play in the shell with QtMultimedia (V1b).
   (b) Play the original when it is already H.264, HEVC or VP9 at or below the output size, and transcode otherwise.
   (c) A separate Quickshell instance for video (V2); this keeps the GPL FFmpeg out of the shell process.
3. **Video on battery and when idle.**
   (a) Pause on battery (with a "Play on battery power" toggle, off), when idle after 60 s (slowing first), when locked,
       under a full-screen window, with Reduce Motion, and in the Reduced profile.
   (b) Always play except locked and full screen (closer to macOS on AC), at half rate on battery.
4. **Lock screen.**
   (a) A still of the current wallpaper (prepared picture or video poster), sharp under the existing scrim.
   (b) The same still, blurred as today.
   (c) The video plays on the lock (QtMultimedia in the security module; its own security review, later).
5. **Menu bar over busy photos.**
   (a) Measured tone, plus the automatic frosted band on an output where neither tone reaches 4.5:1.
   (b) macOS behaviour only: one tone; the user turns on "Show menu bar background"; a documented limit.
   (c) Two tones per bar, measured separately (not the macOS look).
6. **Material tint from the wallpaper.**
   (a) A later optional key `material.wallpaperTint`, off by default, constant luminance, A2 re-checked.
   (b) Not now.
7. **APOD days with a copyright line.**
   (a) Skip them and keep the previous picture.
   (b) Show them with the credit line (needs legal review).
8. **Commons User-Agent contact** (required by Wikimedia).
   (a) A project contact (URL or a dedicated address) chosen by the owner.
   (b) No Commons source until such a contact exists.
9. **Online cache and key.**
   (a) Keep 14 days or 200 MiB per source; `DEMO_KEY` only.
   (b) Keep only the current picture; an optional personal APOD key stored 0600 outside grassfield.json.
10. **Folder picker.**
    (a) Qt Quick Dialogs (the native GTK chooser under the session's gtk3 platform theme), plus drag and drop on the
        preview and "Set as Wallpaper" in Files and Preview.
    (b) Grassfield's own folder browser inside Settings.

## Implementation plan (slices; each ends with `just check`, its tests, the shots it names, and the reviewer where marked)
| Slice | Content | Gate to pass before the next slice |
|---|---|---|
| W0 spike (nested, `.dev/spike/wallpaper`, not committed) | (1) Async decode and upload time, 1080p and 4K JPEG, with a crossfade frame log. (2) QtMultimedia inside Quickshell: VA-API on i915 or not, zero-copy or copy-back, CPU for H.264, HEVC, VP9 and AV1 at 1080p and 4K, paused CPU. (3) The Dock's blur cost over a moving backdrop. (4) `grabToImage` of a `VideoOutput` (poster alternative) | numbers recorded in this ADR; owner answers 1-3 |
| W1 contract | schema, defaults, `Wallpaper.js`, both stores, Settings rules | `check-schema`, `tst_settingsstore` parity, `tst_wallpaper`, `settings_roundtrip`; reviewer (contract) |
| W2 helper | `prepare`, `thumb`, `list`, limits, cache, packaging (`/usr/lib/grassfield`) | GTest including ASan; reviewer (untrusted input) |
| W3 picture path | per-output surfaces, fit modes, artwork and colour, failures, state files, sidecar-driven BarTone, dev guard | shots of 5 fit modes x 2 outputs; P2; P5 not regressed; Q2 through the failure table |
| W4 carousel | listing, order, interval, preload, crossfade, Reduce Motion, bad-file skip, unmounted folder | blank-frame check; P3 nested indication; P1 unchanged; reviewer (performance) |
| W5 Settings pane | layout, grids, thumbnails, pickers, display picker, errors, Esc and Reset, i18n, desktop "Change Wallpaper…" | pane shots in light and dark, en and fr; keyboard scenario; A1, I1 |
| W6 legibility | percentile tone, automatic band (per answer 5), new A2 wallpapers | `contrast.sh` 0 FAIL on the new wallpapers; `test_contrast_tokens.py` |
| W7 video | `probe`, `transcode`, poster, playback, pause policy, crash marker, Settings video rows | pause tests; idle still locks; W-V† and P1† in owner L2 |
| W8 lock still | the proposed diff, by the security-engineer | L1-L5, A2 lock run, opus reviewer PASS |
| W9 (optional) | material tint | token calculation; owner screenshots |
| O1-O4 (step 2) | fetch, scheduler, cache, Settings, attribution | reviewer (network); legal entries; one owner L2 fetch |

## Slice W0 measurements (2026-10-20, nested, Intel UHD 630, 1920x1080, machine load average 5-10 from other agents)
Method: a throw-away QML spike (not committed) loaded into the nested shell through a temporary IPC hook; frame times from
`FrameAnimation.frameTime`; CPU and DRM engine time of the shell and of the nested Hyprland from `/proc/<pid>/stat` and
`/proc/<pid>/fdinfo` (`drm-engine-render`, `drm-engine-video`), every 2 s. Test media generated under `.dev/wallpapers`
(ffmpeg testsrc2 and mandelbrot, ImageMagick plasma). The nested stack renders through the owner's compositor, so absolute
numbers are pessimistic and noisy; gates P3, W-V and P1 stay L2 (owner run).

| Question | Result |
|---|---|
| Async decode of a 3840x2160 JPEG into a 1920x1080 `sourceSize` (Image `asynchronous`, off the GUI thread) | 89-342 ms to `Ready` (median ~200 ms), 18 samples |
| Frames during a 1 s crossfade, texture upload on the first fade frame | 60 frames, 70-80 % under 17.7 ms, 12-18 frames over 33 ms, max 140-450 ms |
| Same, texture upload forced one frame early (opacity 0.004 for 50 ms) | 60 frames, 63-73 % under 17.7 ms, 16-22 frames over 33 ms, max 100-135 ms: no measurable gain |
| Same stack, static wallpaper, no animation (baseline) | 180 frames in 3 s, 98.9 % under 17.7 ms, max 23 ms |
| Cost of a crossfade | shell 50-90 % of one core, nested Hyprland 17-30 % CPU and 28-45 % of the render engine while it runs; zero when idle |
| H.264 1080p30 in the shell (QtMultimedia FFmpeg backend) | hardware decode through VA-API confirmed: video engine 38-40 % busy, QFFmpeg decode thread ~1 % CPU. The shell still used 70-100 % of one core: render thread 38 %, Wayland event thread 26-32 %, main 9 % (presentation through the nested stack, not decode). Not representative of a real session: W-V stays L2 |
| HEVC 1080p, VP9 1080p | hardware decode too (video engine 31-40 % and 24 %), same CPU profile |
| AV1 1080p | software decode: 130-155 % of one core, video engine 0 %, and the decoder kept 90-150 % busy for 10+ s after `pause()` |
| H.264 4K30 | saturates the video engine (86-116 %), the player drops frames, RSS +120 MB (600 MB): a 4K source must be transcoded down to the output size |
| Paused video | shell 1-2 %, Hyprland 0 % within ~4 s (H.264/VP9/HEVC); frame stays on screen |
| Playback rate 0.25 | decode drops to 9 % of the video engine; the shell CPU stayed high while frames were presented |
| Video behind the Dock and menu bar | Hyprland render 27-53 % with the video on the Background layer, 30-43 % with the same video on the Overlay layer: the Dock re-blur is not separable from per-frame compositing cost in this stack |
| Menu-bar frosted band over a playing video | Hyprland render 25-39 % with the band, 28-53 % without: no measurable cost (24 px strip); screenshot `.dev/shots/w0-band.png` shows the band over the video |
| Video on the Background layer above the shell wallpaper | a later-mapped Background layer surface draws above the earlier one; ordering after a restart not verified |
| `grabToImage` of a `VideoOutput` | not measured (poster frames come from the helper's ffmpeg step, option not needed) |

Conclusions: (1) V1b is confirmed: 4K and AV1 sources are unplayable on this GPU, H.264 at output size is hardware decoded.
(2) The early texture upload does not pay off here; the crossfade cost is the compositor and the full-screen blend, so keep
the fade short and make it skippable (Reduce Motion, reduced profile). The preload of the next picture still hides the decode.
(3) Pause is effective for H.264; for software codecs it is not (another reason to transcode).
(4) One shell crash happened during a later HEVC run (shell gone, no log kept: the restart overwrote it); not reproduced,
cause unknown, and the video work (W7) must test the crash marker. No i915 fence timeout was visible to this agent (dmesg
is not readable from the sandbox).

## Implementation notes (slices W1 to W6, 2026-10-21)
Deviations from the text above, each with its reason:
- **Names.** The shared rules module is `ui/Grassfield/Ui/WallpaperConfig.js`, registered as `WallpaperConfig` (the shell has its own `Wallpaper` type, and a JS library registered under another name than its file is not found by a JS `.import`). The artwork moved to `ui/Grassfield/Ui/GrassfieldArtwork.qml` (registered `GrassfieldArtwork`); `shell/desktop/WallpaperArt.qml` stays as a thin wrapper, because the lock screen (security module, read only here) imports both `Grassfield.Ui` and `qs.desktop` and two types called `WallpaperArt` would be ambiguous.
- **One copy of the rules.** `apps/settings/qml/Store.js` takes the wallpaper lists, defaults, path and outputs rules from `WallpaperConfig.js` through an unversioned `.import Grassfield.Ui as Tree`: a versioned `.import Grassfield.Ui 1.0` resolves the installed (older) `/usr/lib/qt6/qml/Grassfield/Ui`, which does not know a module added since, while the unversioned one resolves the tree's own (`QML_IMPORT_PATH`, `-import`). `tests/unit/fixtures/wallpaper-rules.json` holds cases both test files run (`tst_wallpaper` against the module, `tst_settingsstore` through the store); `tst_wallpaper` also checks lists and defaults against the schema and the default file.
- **Review fixes (2026-10-21).** `assist` tests the contrast of the chosen tone, and hysteresis keeps the previous tone only while it reaches 4.5:1 itself. Lists from the JSON adapter (a QVariantList is not an `Array`) are accepted as array-likes, with a bounded read. The helper door of the Settings backend accepts only the exact tool path and the argument vectors of the pane (`systemguard.cpp`, `tests/unit/settings`). The helper refuses a truncated JPEG, tiles with one textured fill, never prunes the pictures on screen (`--keep`). `login` advances only for a new compositor instance. The crossfade is one fixed length (a plain switch with Reduce Motion): an adaptive version was removed because its frame metric counted animation ticks, not frames. A picture is shown only once it is `Image.Ready`; a change that arrives during a decode replaces the pending one. The helper accepts `--out` only as `<...>/grassfield/wallpapers/{prepared,thumbs}` or `<...>/cache/wallpapers/{prepared,thumbs}` (it owns those folders and prunes names of its own form there), creates the folder with `mkdir` mode 0700 in one step and never chmods an existing one. `--out` is trusted as a folder name of the cache layout and nothing more: Settings pins the exact path and the shell computes it, both under the same user, so a caller that can choose `--out` can already write what it likes as that user (documented, accepted). The shell draws every wallpaper kind through one two-slot model (`WallpaperSlot.qml`): the incoming slot on top, ready before it shows, crossfaded, a failure keeps what is on screen; the separate colour and artwork layers are gone. The Settings door resolves real paths (dangling symlinks and a missing first component are refused).
- **Atomic multi-key writes.** `Store.setValues` and `ConfigStore.setMany` write source and path in one file write, so the shell never sees half a change.
- **Helper exit codes** (`WallpaperConfig.EXIT`): 2 usage, 3 not found, 4 not a regular file, 5 file too large, 6 picture too large, 7 unreadable, 8 unsupported, 10 write failed; the shell adds 9 (timeout) and 127 (helper missing, checked once with `test -x`). It prints one JSON object on stdout. `prepare` names the picture by a SHA-256 key of the real path, size, mtime, output size, fit, colour and strip rows, and answers from the cache when both files exist. The cache directory is 0700, files 0600, pruned by modification time (oldest first, never the file just written, never anything younger than a minute). SVG is refused on purpose.
- **Statistics.** The sidecar holds the menu bar strip statistics for the whole width and each half (mean, p5, p95 of the relative luminance, 1024 bins), and the mean colour. `BarTone` uses the whole-width percentiles.
- **Not done in this pass:** video (W7), the lock still (W8, needs the security engineer), material tint (W9), the 30-second preload of the next picture (the change itself is fast through the helper's cache), the display picker and per-display UI, "Play on battery power", the desktop menu's "Change Wallpaper…", `contrast.sh` through the helper (the A2 wallpapers run in `tests/visual/wallpaper-legibility.sh` instead; `contrast.sh` still uses the dev override), the licence entries (`THIRD_PARTY.md`, G9, E32) that the video work needs.
- **Measured (nested, loaded machine):** idle CPU of the shell 0.15 % of one core with a picture and with the artwork (`tests/visual/wallpaper.sh`); a thumbnail or a 4K JPEG prepare takes well under a second; the 5-second carousel and the crossfade ran without a blank frame in the captures reviewed (a pixel-level blank check is not automated).

## Evidence
Design only. This session read the files cited above with `grep`, `sed -n`, `ls` and a Python one-liner over the schema.
No nested session, no measurement, no network. Every cost figure above is an ASSUMPTION until slice W0 or an owner L2
run measures it.

## Consequences
- **Contract** (additive, version 1): the `wallpaper` group and the state files; the `bartone status` JSON gains
  `assist`; a new read-only `WallpaperState.lockStill` used by the lock (security change through R12).
- **New code and files.** The `grassfield-wallpaper` helper and `apps/wallpaper-tool/`. `WallpaperArt` moves to
  `ui/Grassfield/Ui/` (the shell wrapper stays). A Settings page and a symbolic glyph.
- **Packaging.**
  - `depends` gains `ffmpeg` (already present through qt6-multimedia-ffmpeg; now used directly);
  - `optdepends` gains `kimageformats` (name to verify);
  - the helper is installed in `/usr/lib/grassfield`.
- **Legal.**
  - QtMultimedia, and with it GPL-3.0 FFmpeg, is loaded into the shell process for the first time: extend G9 in
    docs/legal/licenses-audit.md and THIRD_PARTY.md (§2, use by the shell). Needs legal review.
  - The `ffmpeg` CLI runs as a separate process (licenses-audit §4.13).
  - E32 in docs/legal/visual-review.md: the default stays the Grassfield artwork; user pictures are the user's.
  - Step 2 adds entries for the APOD and Commons licences, "NASA" and "Wikimedia" as names in the UI, and the
    attribution display. Needs legal review.
- **Specs to update with the slices:** docs/specs/desktop.md (Wallpaper section; ui.md is wrongly cited at desktop.md:9),
  settings.md (the pane; remove the non-goal), menubar.md (tone from statistics, the band, the crossfade), security.md
  (lock still), ui.md (the keys table), docs/testing/visual.md (A2 wallpapers).
- **Given up:** wallpapers per desktop (workspace), "when waking from sleep", a rotation of several videos, live
  time-of-day pictures, screen savers.
- **Revisit:** the video option if W0 shows copy-back decoding or instability, or if legal advice rejects FFmpeg in the
  shell process; then go to V2.

## Owner answers (2026-10-20)
- Step 1 local first, step 2 NASA APOD and Wikimedia Commons (owner batch 10).
- APOD days under copyright: shown with the credit line (needs legal review before any public release).
- Wikimedia User-Agent contact: chapdel.kamga2@gmail.com (owner-provided).
- All other questions: the recommended options, taken as integrator decisions under "macOS model first" (helper
  process, transcode once, pause rules, still on the lock, automatic frosted menu-bar band, tint later, 14-day /
  200 MiB cache, Qt Quick Dialogs picker). The owner can revisit any of them.
