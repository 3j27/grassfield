# ADR-0016: Wallpapers: local photo, video and carousel (step 1), online daily pictures (step 2)
Status: Accepted (owner decisions 2026-10-20, batch 10/11); step 1 implemented through W7 (video, 2026-10-23, remediation wave 2; W6 merged as bc1d19f), W8 waits for the security engineer (the LockView change is specified below), W9 not started; step 2 implemented for Wikimedia Commons and, since 2026-10-23, NASA APOD behind a strict picture allow-list (the 2026-10-22 verification found the API answering with the NASA logo) · Date: 2026-10-20 · Decider: owner

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
    - output: H.264 yuv420p, at most the output's physical size and never with more pixels than 4K UHD (3840x2160 = 8,294,400) and no side above 4096 (the common hardware decode limit of H.264, VA-API on Intel and AMD): orientation and aspect follow the display, a display within both limits gets its own size (2160x3840 and 1440x2560 are native), any other is scaled down uniformly (5120x2880 and 7680x4320 give 3840x2160, a portrait 8K display 2160x3840, 5120x1440 gives 4096x1152, 7680x1080 gives 4096x576), never enlarged, each side even (the shell scales the video to the display), at most 30 fps, no audio, `+faststart`;
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

### Step 2 verification (integrator, 2026-10-22; requests from the dev machine, results kept in no repo file)
- **NASA APOD is not usable today.** `https://apod.nasa.gov/apod/astropix.html` answers `301` to
  `https://science.nasa.gov/apod/` (a WordPress page that loads the day's entry dynamically; no APOD feed, the only
  RSS is the whole NASA Science site). `api.nasa.gov/planetary/apod` still answers `200`, but for every date tried
  (2026-03-01, 2026-09-15, 2026-10-20, 2026-10-21) it returns `title: "NASA Science"` and the NASA logo
  (`science.nasa.gov/.../nasa-logo@2x.png`) as `url` and `hdurl`, with `media_type: image`. Showing that would put the
  NASA insignia on the desktop, which this ADR forbids. `DEMO_KEY` now reports `X-RateLimit-Limit: 10`.
  **Integrator decision (owner asked for autonomy, 2026-10-21):** step 2 ships Wikimedia Commons only; APOD waits until
  the API returns real entries again. The helper must still refuse an entry whose image host is not on the allow-list,
  so a broken source can never show a logo. **Amended 2026-10-23 (owner: fix every defect):** APOD ships behind that strict allow-list (host `apod.nasa.gov`, path `/apod/image/`), see "Implementation notes (W7 video, APOD, Settings controls)".
- **Wikimedia Commons POTD works as designed, with two changes.**
  - `expandtemplates` gives the file name (`{{Potd/2026-10-20}}`) and the caption (`{{Potd/2026-10-20 (fr)}}`). The
    caption is wikitext with `[[link|text]]` and `''italics''`: reduce it to plain text.
  - `imageinfo` with `iiurlwidth=3840` gives `thumburl` on **`thumb.wikimedia.org`** (not `upload.wikimedia.org`; the
    original `url` stays on `upload.wikimedia.org`). Both URLs carry `utm_source/utm_campaign/utm_content` query
    parameters: drop the query string before fetching. Fetching the bare thumb URL returned `200`, `image/jpeg`,
    `Content-Length` 1866060, a 3840 x 3072 JPEG.
  - `extmetadata` has `LicenseShortName` (`CC BY-SA 4.0`), `LicenseUrl`, `License` (`cc-by-sa-4.0`, the machine key to
    match the allow-list against), `Artist` and `Credit` as HTML, `AttributionRequired`, `UsageTerms`, `ObjectName`.
  - Allow-list of hosts for step 2: `commons.wikimedia.org`, `thumb.wikimedia.org`, `upload.wikimedia.org`.
- **curl 8.22.0 (installed).** `--max-filesize` aborts a transfer that reaches the limit even without a
  `Content-Length` (since 8.4.0, man curl), so it bounds the download by itself; the helper's streamed count stays as
  a second check.

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

## Implementation notes (step 2, slices O1 to O3, Commons only, 2026-10-22)
NASA APOD is not built (see "Step 2 verification"); the code is shaped so that a second provider is a new name in `WallpaperConfig.ONLINE_PROVIDERS`, a new `fetch <provider>` subcommand and a new fetch module next to `commonsfetch.cpp`, with no abstraction layer in between. Deviations from the outline above, each with its reason:
- **Helper** (`apps/wallpaper-tool/src/commonsfetch.{h,cpp}`, called from `main.cpp`):
  - `grassfield-wallpaper fetch commons --date YYYY-MM-DD --out <.../online/commons> [--width 640..3840] [--lang en|fr] [--base-url http://127.0.0.1:<port>]` and `latest commons --out <...>` (the newest cached picture and its sidecar, no network). New exit codes: 11 network (no answer, an HTTP error, a refused host or redirect), 12 skipped (the entry cannot be used: licence outside the allow-list, not a picture, no entry for the date), 13 bad response (malformed or oversized JSON). They map to the ids `network`, `skipped` and `bad-response` in `WallpaperConfig.REASONS`.
  - Three requests per fetch: `expandtemplates` for `{{Potd/DATE}}` (the file name, accepted only as a plain name: no `{}[]<>|#/\` and no control character), `expandtemplates` for `{{Potd/DATE (lang)}}` (the caption; a failure here is not an error), `imageinfo` with `iiprop=url|size|mime|sha1|extmetadata` and `iiurlwidth` (default 3840). The picture is `thumburl` with its query string dropped. Both answers are read as `formatversion=2` (pages as an array); the older object form is accepted too. `sha1` is requested as in the outline but not checked: it names the original, not the scaled thumbnail.
  - **curl** is run as an argument vector by `QProcess` (`/usr/bin/curl`): `-q` first (no `~/.curlrc`), `--proto =https --proto-redir =https --max-redirs 3 --connect-timeout 10 --max-time 60 --max-filesize <n> --tlsv1.2 --globoff --no-clobber --user-agent <fixed> --output <file> --write-out '%{http_code}\n%{content_type}\n%{redirect_url}\n' --url <url>`; no `--location`, no cookie jar, no Referer, no netrc, no `--compressed` (nothing is inflated, so the size limits count what is stored). `SSLKEYLOGFILE` is removed from curl's environment; the user's proxy variables are kept. **Redirects are followed by the helper, one hop at a time** (at most 3), with the host allow-list applied to every hop before any request goes there: curl cannot restrict a redirect to a host list, and `--proto-redir` alone would let a redirect reach any https host. A redirect to another host fails with exit 11 and "host not allowed". `--max-filesize` is 256 KiB for JSON and 40 MiB for the picture (curl 8.22 aborts at the limit without a `Content-Length`); the helper counts the stored file again (`checkFile`), an older curl would stop only at `--max-time`.
  - **User-Agent**: `Grassfield/0 (chapdel.kamga2@gmail.com)`: product, major version, the owner-provided contact. The repository has no project URL yet (`packaging/arch/PKGBUILD` uses the placeholder `https://grassfield.invalid`), so the URL part is omitted, as agreed.
  - **Hosts**: `commons.wikimedia.org`, `thumb.wikimedia.org`, `upload.wikimedia.org`, https, default port, no user info (a trailing dot, a longer name, `@` tricks and other ports fail: `tst_commonsfetch.cpp`). The one exception is `--base-url http://127.0.0.1:<port>` (exactly that form), accepted only with `GRASSFIELD_DEV=1` and then the only origin allowed; the library refuses it too (not only `main`).
  - **Untrusted content**: `Content-Type` in {jpeg, png, webp} AND the first bytes are that format's signature; a download is a regular file within the limit; then the step 1 loader (`loadPicture`: header limits 16384 px per side and 64 MP, the allocation limit, a truncated JPEG is refused) and a re-encode to JPEG quality 92 in sRGB, metadata dropped, at most 3840 px on a side (alpha flattened on white). The download is deleted (every temporary `.dl-<pid>-*.part` is removed on every way out, and leftovers older than an hour at the next prune). The imageinfo `mime` must be `image/*` (a video entry is skipped). The licence is matched on the machine key `extmetadata.License` (lower-cased): `pd`, `pd-*`, `cc0`, `cc0-<ver>`, `cc-zero`, `cc-by-<ver>`, `cc-by-sa-<ver>` (version 1.0 to 4.9, with the real Commons variants: an optional two-letter country that is never `nc` or `nd`, then an optional `-migrated`: `cc-by-sa-3.0-de`, `cc-by-sa-3.0-migrated`); NC, ND, GFDL and a missing or non-string field are skipped. Text (`Artist`, `Credit`, `ObjectName`, `LicenseShortName`, caption): input cut to 32 KiB, `<script>` and `<style>` blocks, comments and tags removed, wikitext templates, `[[a|b]]`, `[url text]` and quote marks reduced to the text, entities decoded in one pass (an invalid number is dropped, an unknown name stays as written), then control characters, bidi characters, zero-width and tag characters, the Hangul fillers (U+115F, U+1160, U+3164, U+FFA0), U+034F, U+180B..180F, the Khmer inherent vowels, variation selectors supplement, noncharacters removed (a Braille blank counts as white space), white space collapsed, cut by code points (title 200, author and credit 300, caption 500, licence name 64). The licence URL must be https; the source page URL is built from the validated file name, never taken from the answer. `latest` hands on a whitelist of these fields, cleaned again.
  - Unit tests (`tests/unit/wallpaper-tool/tst_commonsfetch.cpp`, linked into `wallpaper-unit-tests`, including the ASan build of `scripts/dev/test.sh`): the pure rules above, and the whole fetch against `fixtures/commons/server.py`, a loopback stand-in (`python3 -I`, synthetic JSON modelled on the real answers recorded in "Step 2 verification", the JPEG generated by the test, nothing downloaded or committed). The tests cover the requests made (the bare thumbnail, one fixed User-Agent, no Referer, no cookie), a day already cached (no request), a server error, a redirect to another host, a thumbnail host outside the list (no fourth request), a refused licence, wrong type, wrong bytes, a truncated and a too wide picture, an oversized answer, no entry for the day, a missing curl and the base URL outside a dev session. They never use the network.
- **Cache**: `$XDG_CACHE_HOME/grassfield/wallpapers/online/commons/YYYY-MM-DD.{jpg,json}` (dev: `.dev/cache/wallpapers/online/commons`), the folder and `online/` 0700, files 0600, `--out` accepted only in that form. A date with both files is not fetched again. After a fetch the folder keeps the newest 14 dates and 200 MiB (the newest is never removed). The per-output prepared copies stay in the step 1 cache; the feed prepares the cached file like any picture.
- **Scheduler**: `shell/services/WallpaperOnline.qml` runs what the pure rules in `WallpaperConfig.js` decide (`onlineSchedule`, `onlineAfter`, `onlineWanted`, `fetchArgs`, `latestArgs`; tests in `tests/unit/tst_wallpaper.qml`). One fetch per UTC date, the date flipping at 00:10 UTC, at a random time within 6 h after that (stored per date), at once when nothing is cached; failures back off 1 h, 3 h, then the next date; a skipped entry ends the date. State in `$XDG_STATE_HOME/grassfield/wallpaper-online.json`. One timer (at most 6 h), re-evaluated by events (settings, connectivity, a finished fetch); nothing polls. A fetch that runs longer than `wallpaper.fetchTimeoutMs` (5 min) is killed.
  - **Connectivity**: `Connectivity.fullyConnected` (NetworkManager through Quickshell.Networking): `Full`, or `Unknown` (NetworkManager's connectivity check is off) with a link up, or no NetworkManager backend (nothing to ask: the fetch just tries and curl fails when offline, the backoff does the rest). Portal, Limited and None wait for a change of connectivity. **Metered: the documented gap.** Quickshell 0.3.1 exposes the connectivity but no metered flag, so the service asks `nmcli -t -g GENERAL.METERED device show` once, just before a fetch (not polled): any line starting with `yes` (also "yes (guessed)") postpones the fetch by an hour, anything else, or a failing `nmcli`, does not. **NOT VERIFIED**: the sandbox cannot start `nmcli` (it cannot create the NetworkManager socket), the output format is from the manual, and a real metered connection was never present.
  - **Dev sessions** never fetch, except from the loopback server named by `GRASSFIELD_ONLINE_BASE_URL`. The dev IPC `wallpaper onlineClock <hours>` moves the scheduler's clock (date, the day's slot at 00:10, backoff, fetch) so the visual test drives the real accounting; `wallpaper onlineStatus` prints the state. Both refuse without the loopback server.
- **Feed and Settings**: `WallpaperFeed` handles `online` like a file (state `waiting` with the artwork when nothing is cached; the cache not read yet keeps what is on screen, no flash of the artwork). `wallpaper-state.json` gains an `online` block (`phase`, `failure`, the sanitized `entry`) next to `outputs`. Settings: the "Online" group with one tile, the opt-in disclosure (Cancel and Esc change nothing; "Use Picture of the Day" writes `wallpaper.source` and `wallpaper.online.provider` in one write), the caption and the "About This Wallpaper" rows. The desktop menu's "About This Wallpaper" opens the same attribution in a small card (`AttributionCard.qml`). Everything shown is plain text. Config keys: `wallpaper.source` gains `online` (top level and per display), `wallpaper.online.provider` is `commons`; contract version 1, additive; schema, defaults, both stores and the tests are updated (the "online is invalid" cases of `tst_settingsstore` and the rules fixture were flipped).
- **Not done / limits**: NASA APOD (waits for the API); the sandbox optional hardening (`systemd-run --user`); the legal entries (`THIRD_PARTY.md`, licenses-audit: the Wikimedia names, the CC licences, the attribution display) and the legal review; one owner L2 fetch against the real servers (no test or dev session touched the network: `NOT VERIFIED` against the real Commons, whose JSON shapes come from the integrator's verification above); the metered check (above); `iiurlwidth` is the helper default 3840 rather than the largest output width (the helper does not know the outputs; a smaller `--width` is accepted for a later caller); the French caption comes from the shell's language (`Qt.locale()`), `en` for any other language.

## Implementation notes (W7 video, APOD, Settings controls; remediation wave 2, 2026-10-23)
Decided by the integrator under the owner's rule "every open UX choice follows macOS": each item below says what and why.
- **Video (W7), `probe` and `transcode`** (`apps/wallpaper-tool/src/videotool.{h,cpp}`, `main.cpp`). Both run `/usr/bin/ffprobe` and `/usr/bin/ffmpeg` by argument vector, never through a shell: the path is the value of `-i` (an absolute path, so never an option or a protocol), `-protocol_whitelist file`, `-nostdin`, low priority (`nice 10`), `PR_SET_PDEATHSIG` (the child dies with the helper), a deadline per run, and a SIGTERM or SIGINT to the helper kills the running ffmpeg and ends with exit 17 (cancelled). `probe <video>` prints `{duration, width, height, fps, codec, audio, real}` (rotation applied; a cover picture of an audio file is not a video). `transcode --size WxH --fit F --color C --out <cache>/video [--strip-rows N] [--cache-max-bytes N] [--max-seconds N] [--max-bytes N] [--keep FILE] -- <video>` writes H.264 (libx264, `-preset fast -crf 22`) yuv420p fitted inside the output's physical size and never enlarged, `fps=30` when the source is faster or unknown, no audio, subtitles, data or metadata, `-movflags +faststart`, `-t 600`, `-fs 512 MiB`; it re-probes the result and refuses anything that is not H.264, no larger than asked, at most 30 fps and without audio (exit 15). A source longer than 600 s is refused before any encoding (exit 14); a source over 8 GiB, a FIFO or a device by `checkFile`; a missing ffmpeg or ffprobe is exit 16. Progress: ffmpeg's `-progress pipe:1`, printed by the helper as `{"progress":0.42}` lines (at most one per percent, flushed), then the result object. Files: `<key>.mp4` (key = SHA-256 of the real path, size, mtime and output size, so a change of fit or colour reuses the encode), `<keyfull>.jpg` (the poster: the frame at a tenth of the video, at most 5 s, composed on the output with the fit and colour, JPEG 95) and `<keyfull>.json` (the sidecar: the poster, the video, sizes, duration, fps, codec, `posterMs`, `mean`, and the **menu bar strip statistics, worst case of the poster and 8 frames** read from the transcoded file: the mean of the means, the lowest 5th and the highest 95th percentile). Temporary output is `.vt-<pid>.mp4`, removed on every way out (stale ones after an hour). `outDirAllowed` accepts only `<...>/grassfield/wallpapers/video` or `<...>/cache/wallpapers/video`; the cache is pruned as the others (oldest first, never the files on screen, `--keep`, never younger than a minute). `thumb` also takes a video (one frame, for the Videos grid). New exit codes: 14 video too long, 15 transcode failed, 16 ffmpeg missing, 17 cancelled (`WallpaperConfig.EXIT` and `REASONS` name them).
- **Playback and the pause policy** (`shell/desktop/WallpaperFeed.qml`, `Wallpaper.qml`, `WallpaperSlot.qml`, `WallpaperVideo.qml`). The feed runs `probe`, then `transcode` as a streaming `WallpaperJob` (one job per display, a newer request supersedes), publishes `progress` in `wallpaper-state.json`, and the display it hands to `Wallpaper.qml` carries `video`. The poster is the slot's picture (crossfaded like any picture, tone from the sidecar); once the slot is on screen a `Loader` creates `WallpaperVideo` (no QtMultimedia object exists before): `MediaPlayer` with `loops: Infinite`, no `AudioOutput`, `VideoOutput` with `endOfStreamPolicy: KeepLastFrame` and `PreserveAspectCrop` or `PreserveAspectFit`, starting at the poster's position so that the first frame is the poster. The policy inputs per output: `Lock.lockState` (passed from `shell.qml` as `locked`), `Compositor.fullscreenOn` (shell/platform), an `IdleMonitor` per output (`videoIdleSeconds` 60, `respectInhibitors: false`, enabled only while a video is wanted: it asks whether the user is away, not whether the session may sleep), `UPower.onBattery`, `Settings.reduceMotion` and `Settings.materialProfile`, fed to `WallpaperConfig.playbackState` (unchanged, already tested). `settle` eases `playbackRate` to `videoSettleRate` (0.25) over `videoSettleMs` (2 s) and pauses; `pause` pauses at once; a paused `MediaPlayer` decodes nothing. Tokens: `wallpaper.videoIdleSeconds`, `videoSettleMs`, `videoSettleRate`, `videoStableMs`, `videoMaxSeconds`, `videoMaxBytes`, `videoToolTimeoutMs`.
- **No idle inhibitor (REQ-ADR0016-18).** No wallpaper file creates an `IdleInhibitor`; the monitor ignores inhibitors. `tests/shell/wallpaper_video.sh` fails if a `shell/desktop/Wallpaper*.qml` code line names an inhibitor, if the monitor does not set `respectInhibitors: false`, if the video layer has an audio output, does not loop or does not keep its last frame, or if a policy input is missing. The runtime half, "the idle lock still fires while a video plays" (`qs ipc call idle status` after the idle time with a video playing), needs a nested session and is a bare command for the integrator: see the nested list in the wave-2 report.
- **Crash marker (REQ-ADR0016-19)** (`WallpaperState.qml`): `videoStarting {path, at}` in `wallpaper.json`, written at once (not debounced) before the first `play()`, cleared after `videoStableMs` of playback, or when the video is deliberately paused or released (the shell is then plainly alive). A marker found at start becomes `videoBlocked` (and the marker leaves the file): the feed shows the poster, does not start the player, and reports the reason `video-crashed`, which Settings shows as "The video wallpaper was stopped; a still is shown." It stays blocked until no output has that video as its wallpaper any more (`releaseVideo` from the feed), so choosing another wallpaper and the video again plays it. `tests/shell/wallpaper_video.sh` runs the real `WallpaperState` headless on a state folder seeded with a marker.
- **Lock still, shell side (REQ-ADR0016-20, `WallpaperState.lockStill(output)`)**: read only; the prepared picture or the video's poster of that output, only when the output is `ready` and the file is under `<cache>/prepared` or `<cache>/video`; otherwise `""`. `tests/shell/wallpaper_video.sh` checks it (a path outside the cache, a not-ready output and a traversal give `""`). A new token `wallpaper.lockStillMaxBytes` (64 MiB) exists for the lock's size check.
- **Lock still: the LockView change (for the security engineer; this wave did not touch `shell/security/`).** In `shell/security/lock/LockView.qml` the `WallpaperArt { id: wallpaper }` block (lines 74-91) keeps the artwork underneath, and its child dev `Image` becomes the still:
  1. add `readonly property string still: VisualFixtures.wallpaperFile !== "" ? VisualFixtures.wallpaperFile : WallpaperState.lockStill(root.screenName)` where `screenName` is the lock surface's `ShellScreen.name` (import `qs.services`, already imported for `VisualFixtures`); the dev override keeps priority, so the A2 run is unchanged;
  2. the `Image` takes `source: root.still !== "" ? "file://" + root.still : ""`, with `sourceSize: Qt.size(root.width, root.height)` (capped at the screen), `asynchronous: true`, `cache: false`, and `retainWhileLoading: false`, so that a slow or failing load leaves the artwork that is drawn underneath;
  3. before the `source` is set, `LockView` checks the file through a small `Process` or `FileView`-free route of the security module's choosing: a regular file of at most `Tokens.wallpaperLockStillMaxBytes` whose real path is under the wallpaper cache (`WallpaperState.preparedDir` or `videoDir`); anything else leaves `still` empty (this keeps the module's rule "the lock decodes only Grassfield's own file"; `lockStill` already enforces the folder, the size cannot be read in QML without a process);
  4. option C1 (owner answers: the recommended proposals): the still is drawn **sharp**, so the `MultiEffect` `blur` becomes `0` when `still !== ""` (the artwork alone, as today, stays blurred), the scrim (`lock.dimOpacity`), the text and the field are unchanged, hence gate A2 holds by the same argument as today (security.md, Decisions);
  5. no `VideoOutput`, `MediaPlayer` or `QtMultimedia` import enters the module (option C3 remains a separate decision).
  Gates for that change: L1-L5 (`tests/security`), the A2 lock run on the new wallpapers (`tests/visual/contrast.sh --surfaces lock`), the opus reviewer PASS.
- **NASA APOD (REQ-ADR0016-S2-2, A20261022-1)**: the second provider, `fetch apod --date YYYY-MM-DD --out <cache>/online/apod [--base-url http://127.0.0.1:<port>]` and `latest apod --out ...`, in `commonsfetch.{h,cpp}` (the fetch machinery is shared; the file keeps its name). One request to `https://api.nasa.gov/planetary/apod?api_key=DEMO_KEY&date=D&thumbs=false` and one for the picture; the same curl vector, UA, redirect-per-hop host check and untrusted-content rules as Commons. **The allow-list is the host `apod.nasa.gov` and the path prefix `/apod/image/`** (an `http` address of that host is upgraded to https; no query, no `..`): the NASA Science logo of the broken answers (host `science.nasa.gov`) is refused as skipped before any picture request, and so is any other host or path; `media_type` must be `image` (a video or `other` is skipped, nothing downloaded); the answer's `date` must be the one asked (else a bad response); `hdurl` is tried before `url`. A copyrighted day is accepted (owner decision 2026-10-20, shown with the credit): `author` and `credit` are the sanitized `copyright` text and `licenseShort` is `(c) <holder>`; a day without it reads `Public domain (NASA)`, `licenseUrl` is empty, `sourceUrl` is `https://apod.nasa.gov/apod/apYYMMDD.html` built from the date. The APOD date follows US Eastern time: the day flips at 05:10 UTC in `WallpaperConfig.onlineDate(ms, provider)` (Commons stays 00:10 UTC), the random slot lies within 6 h after it, and each provider has its own accounting (`wallpaper-online.json` carries the provider; a state without one is Commons's) and cache folder. `wallpaper.online.provider` accepts `apod` (schema, defaults, both stores, tests). `DEMO_KEY` is shared and limited per IP (HTTP 429 is a network failure: the normal 1 h, 3 h, next-day backoff). GIF entries are skipped (the signature check admits jpeg, png and webp). Tests: `tests/unit/wallpaper-tool/tst_commonsfetch.cpp` (`ApodRules`, `ApodFetch`) against `fixtures/commons/server.py`, which now also serves `/planetary/apod` and `/apod/image/*` on loopback, with synthetic fixtures for a public day, a copyrighted day, a video day and the logo answer; nothing touches the network. NOT VERIFIED against the real API (no network in the sandbox); the 2026-10-22 verification says it was returning the logo, so the first real fetch is an owner L2 item.
- **Aspect rule (S2-10)**: `WallpaperConfig.onlineFit(picW, picH, outW, outH, mean)`: within +-35 % of the output's aspect the picture is filled, otherwise fitted on its mean colour (the sidecar's new `mean`, the re-encoded picture's mean, `#rrggbb`). `WallpaperFeed.applyOnline` passes it to `prepare` as the fit and colour for that output (the user's Fit and Colour rows still apply to a picture or a folder).
- **Settings controls (REQ-SET-MP-d1, DESK-WALL-d13, d16, ADR-0016 section 8)**: Display picker (more than one output; rows read and write the display's `wallpaper.outputs` entry through `WallpaperConfig.resolve` and `withOutput`; `QScreen::serialNumber` is now in `Backend::screens()` so that the identity is the shell's), "Play on battery power" (`wallpaper.videoOnBattery`), the transcode progress row with Cancel (Cancel restores what the display showed before, which makes the shell stop the job; a display with no wallpaper of its own goes back to following All Displays), a Videos group with "Add Video…" and a play badge, a drop on the preview (a folder is recognised by the helper's `list`, so the pane runs no new helper command), the NASA tile with its own disclosure, and the reason sentences of the new failure ids. French strings are in the catalog.
- **Packaging (REQ-ADR0016-28)**: `grassfield-desktop` depends on `ffmpeg` and `curl` (the helper runs both) and optdepends on `kimageformats` (HEIF, AVIF, JPEG XL; the name is as in the Arch repositories, to VERIFY on the next package build). Legal (REQ-ADR0016-29): `THIRD_PARTY.md` (ffmpeg and curl as run programs, FFmpeg in the shell, section 5b for Commons and APOD), `docs/legal/licenses-audit.md` (G9 extended) and `docs/legal/visual-review.md` (E32 extended) say what is shown and what is used; **needs legal review**.
- **Review fixes (opus review of 00d32a0, 2026-10-23).**
  - **Signals.** The SIGTERM/SIGINT handler (which ends ffmpeg and exits 17) is installed only by `probe`, `transcode` and the video branch of `thumb`; every other subcommand keeps the default action, so `WallpaperFeed.supersede()` kills a superseded `prepare`, `list`, still `thumb` or `fetch` at once (measured: a 62 MP `prepare` told to stop at 150 ms exits 143 after 153 ms; `tests/shell/wallpaper_tool_signals.sh`, which also checks that `transcode` ends as 17 and leaves no ffmpeg and no `.vt-*` file).
  - **Containers.** `probe`, `transcode` and the frame grabs pass `-format_whitelist mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,ogg` (the demuxers behind the supported suffixes), so a playlist (HLS, ffconcat) is refused under any name (`APlaylistIsRefusedWhateverItIsCalled`); the `probe` and `transcode` commands also refuse a name whose suffix is not in the video list (exit 8). The comment about `--` was wrong (ffmpeg has none; the path is the value of `-i` and starts with `/`).
  - **Memory (revised twice).** The first cap, `RLIMIT_AS` 2/4/8 GiB, broke legitimate transcodes on many-core machines (thread pools and glibc arenas reserve address space per core), and the second, 6 GiB of `RLIMIT_DATA` with x264 at 8 threads, failed every output above 4K (8K output: 8.9-9.7 GiB needed; rc 187). Now: **the transcoded video has at most the pixels of 4K UHD whatever the display (never with more pixels than 4K UHD (3840x2160 = 8,294,400) and no side above 4096 (the common hardware decode limit of H.264, VA-API on Intel and AMD): orientation and aspect follow the display, a display within both limits gets its own size (2160x3840 and 1440x2560 are native), any other is scaled down uniformly (5120x2880 and 7680x4320 give 3840x2160, a portrait 8K display 2160x3840, 5120x1440 gives 4096x1152, 7680x1080 gives 4096x576), never enlarged, each side even)** (macOS Aerials are 4K on 5K and 6K displays too); the shell scales it to the display, the poster and the strip statistics are composed on the display itself, the file is shared by every display above 4K. Every ffmpeg call has explicit thread counts (at most 8: `-threads` for the decoder and the encoder, `-filter_threads`; frame grabs 2 on both sides, because the PNG encoder grew to 74 threads at 64 cores), `MALLOC_ARENA_MAX=2`, `-max_alloc` 1 GiB, `-max_pixels` 64 MP and `RLIMIT_DATA`: probe 1 GiB, frame grabs 3 GiB, transcode 6 GiB. RLIMIT_DATA counts brk and private writable mappings, thread stacks included (not the reserved but unused address space that RLIMIT_AS counts). Measured on 8 CPUs through the helper, peak RSS of the largest process, 8K display (4K video), 2 s at 30 fps: H.264 source 2615 MiB, HEVC 10-bit 3382 MiB, AV1 2887 MiB; 4K60 to 4K 2000 MiB; thumbnail of an 8K AV1 source 822 MiB in 1.0 s (HEVC 890 MiB). The reviewer measured VmData up to 4580 MiB for AV1 to 4K, so the 6 GiB cap keeps a margin. That the cap bites is shown by `TheHeapCapStopsARunawayDecode` (160 MiB: code 15, nothing left behind); the 8K H.264, HEVC 10-bit and AV1 sources run under the real cap with 256 forced threads in `VideoToolHeavy` (`tests/shell/wallpaper_video_heavy.sh`, a bare command, 91-103 s; generating the 8K HEVC source alone takes 50 s and peaks at 8.1 GiB RSS, so run it on a machine with the memory). `TheVideoNeverExceeds4kWhateverTheDisplay` covers the size rule (portrait 4K, rotated QHD, 5120x1440, 7680x1080, DCI 4K, portrait 5K and 8K). The mp4 is keyed by the size it really has (not by the limit), so a 1080p source on a 1440p and on a 4K display is one file.
  - **APOD hops.** Every hop of a fetch, not only the first URL, must have the provider's path: exactly `/planetary/apod` for the API and the prefix `/apod/image/` for the picture (no `..`); a redirect to another page of an allowed host is refused before any request (`ARedirectToAnotherPageOfAnAllowedHostIsRefusedAtEveryHop`).
  - **Crash marker.** One marker per output (`markVideoStarting(owner, path)`), written for the FIRST play of a video only (an unlock or an idle return starts nothing new, so a restart soon after cannot block it by mistake), cleared by the same output's pause or after `videoStableMs`; one output's pause never clears another's. `wallpaper.json` holds `videoStarting` and `videoBlocked` as lists (older single values still read).
  - **Settings Cancel** on the transcode row restores what the display showed before the video was chosen (remembered per scope, `WallpaperConfig.rememberPrevious`, `forgetPrevious` and `cancelPlan`: a display that follows All Displays ignores and drops any entry of its own, since it went back to following All, and "Use the All Displays Wallpaper" forgets it; Cancel acts on the scope the choice was made in, so a video chosen under All Displays is undone for all even when the picker was moved to a display that follows All, and no override is ever created for such a display; the picker moving never touches another display) (macOS: Cancel leaves things as they were); the Grassfield wallpaper only when nothing was recorded.
  - **P2 for video** (QtMultimedia and its frames <= 120 MB) is still an estimate from W0, to be measured in the nested session.
- **Not verified here**: playback itself, the pause tests on a live compositor, W-V and P1 (owner L2), the Settings pane's look (no screenshots: no nested session), the real APOD and Commons servers, hardware decode on the reference machine.

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
