# ADR-0015: Unified toolbar for Grassfield apps: the shared UI framework draws the window controls, the plugin steps aside per window
Status: Accepted 2026-10-22 after the nested spike, with integrator decisions on Q4, step 3 and Q5 (see the end) · Date: 2026-10-20 · Decider: owner

## Context

### Need (F1 gap 9)
`docs/testing/f1-reference-gaps.md` item 9 (:358-364) and the window chrome rows (:100-112):
- macOS toolbar windows use one 52 ± 1 pt row that holds both the traffic lights and the toolbar items (:107). The first
  light's centre is at (25.75, 25.75) ± 0.5 from the window's top-left corner, inside the floating sidebar (:106, :243).
- The items are 36-pt glass capsules: back/forward 72.5 x 36, grouped view and action capsules, and a search circle that
  opens to about 200 (:108).
- The title is about 15 pt bold, left-aligned after back/forward (:109). The corner radius is 26 ± 1.5 (:100). The lights
  are 14 ± 0.5 pt at a 23-pt pitch (:102-103).
- Grassfield today:
  - Files stacks the plugin's 28-px titlebar over its 52-px toolbar (:107, :215) and shows two titles (:109).
  - Settings has no toolbar; its title sits inside the page (:251).
  - Preview has a 44-px toolbar under the titlebar (:235).
- Item 9 calls this cross-module work (plugin + apps + ui), so it needs an ADR (R5, master-prompt.md:154).

### Grassfield today (VERIFIED: read in this session)
- **Which windows get a titlebar.**
  - The plugin adds its titlebar to every mapped window (compositor/src/main.cpp:61-66, :81).
  - It shows the titlebar when the window is floating, not full screen, not X11 override-redirect, and its `decorate`
    rule is true (compositor/src/Titlebar.cpp:233-244). It never looks at xdg-decoration, so CSD apps get a second
    titlebar (docs/specs/compositor.md:976).
- **How the titlebar looks.**
  - A 28-px STICKY strip above the surface (Titlebar.cpp:246-257; core/Theme.hpp:30).
  - Opaque and dark only (Theme.hpp:65-74; compositor.md:974).
  - 12-px lights, 8 px apart, the first 12 px from the edge (Theme.hpp:31-33), and a centred title.
  - No hover glyphs, no grey inactive state, no pressed state (compositor.md:973; Titlebar.cpp:368).
- **Input.**
  - Left button only (Titlebar.cpp:429); no right-click menu.
  - A light acts on release over the same light.
  - The drag is the plugin's own move: no snapping (compositor.md:975), and a maximized window is un-zoomed under the
    pointer (FR8; Titlebar.cpp:136-176).
  - A double-click does what `windows.titlebarDoubleClick` says (Titlebar.cpp:454-468).
- **Actions.**
  - Close is Hyprland's close (Titlebar.cpp:499-502).
  - Zoom toggles `FSMODE_MAXIMIZED` (Titlebar.cpp:122-129).
  - Minimize posts `minimize-request`; the shell answers with the Dock tile (Titlebar.cpp:112-119;
    shell/platform/Compositor.qml:151-170, :300-308). The shell handles no Hyprland `minimized` event
    (Compositor.qml:470-505).
- **gfc/1 capabilities.** `decorations` is always advertised; the other features only when they registered
  (compositor.md:75-81; core/Protocol.hpp:42-62). A degraded shell "keeps client-side decorations" (compositor.md:757).
- **Overview v2 and Stages** assume a 28-px band above every window:
  - Overview: shell/overview/OverviewWindow.qml:105-107 and :131; ui/tokens/tokens.json:337; docs/specs/overview.md:255.
  - Stages: compositor/src/core/Stages.cpp:486-489; core/Stages.hpp:49.
- **Session config.**
  - Every window floats (config/hypr/grassfield/windows.lua:4).
  - Every window has `suppress_event = "maximize"` (windows.lua:7), so a client's `set_maximized` is ignored in the
    Grassfield session.
  - Glance already opts out of the titlebar with `decorate = false` (windows.lua:10; docs/specs/preview.md:51).
  - Hyprland resizes every window from its border (looknfeel.lua:16-17). Rounding is 12 (looknfeel.lua:30).
- **Apps.**
  - The Files, Settings and Preview main windows are plain QtQuick `Window`s (apps/files/qml/BrowserWindow.qml:8-32,
    apps/settings/qml/Main.qml:7, apps/preview/qml/Viewer.qml:7). Their toolbar is an Item inside the window
    (BrowserWindow.qml:361-368, Viewer.qml:172-177) and does not drag the window.
  - Files is a `QApplication` because KIO's conflict, Open With and undo dialogs are widget windows
    (apps/files/src/main.cpp:21-22). These dialogs have the same app id, `org.grassfield.Files` (:29), so a rule keyed
    on the app id also hits them.
  - Files reads `grassfield.json` live (apps/files/src/filesapp.cpp:115, :154-156).
  - Without the plugin, the apps have no lights and no drag (docs/specs/files.md:207, docs/specs/settings.md:99).
- **Legal.** The lights are entry E18, "needs legal review" (docs/legal/visual-review.md:260-265). The owner keeps them
  as they are while legal advice is pending (docs/STATE.md:68).

### Hyprland 0.56.2 (VERIFIED from /usr/include/hyprland)
- **xdg-decoration.**
  - The per-toplevel objects live in a private map (src/protocols/XDGDecoration.hpp:40). The mode is chosen by private
    helpers (:19-21). `mostRecentlyRequested` is public (:13), but nothing public leads from a window to its object.
  - So a plugin cannot read the negotiated mode without private-member access.
  - Hyprland answers SERVER_SIDE and draws nothing (master-prompt.md:95; not re-measured here).
- **xdg-toplevel-tag-v1** is served (src/protocols/XDGTag.hpp).
  - Each window exposes `CWindow::xdgTag()` (src/desktop/view/Window.hpp:417), and window rules can match it
    (src/desktop/rule/Rule.hpp:31, `RULE_PROP_XDG_TAG`).
  - Hyprland also uses the tag as a key for its floating-size memory (src/desktop/state/FloatState.hpp:23-24).
  - The protocol says the tag should come with the initial commit (staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml:61-63).
- **Window rules.**
  - The built-in `decorate` effect (src/desktop/rule/windowRule/WindowRuleApplicator.hpp:96) is honoured by the plugin.
  - A plugin can read the Hyprland window tags (`m_tagKeeper`, :141; src/helpers/TagKeeper.hpp).
  - A plugin can register its own rule effects (`m_otherProps`, :69; src/desktop/rule/effect/EffectContainer.hpp:28).
  - Upstream Lua uses `tag = "+name"` and `match = { tag = "name" }` (/usr/share/omarchy/default/hypr/windows.lua:6, :25;
    helpers.lua:142-153).
- **xdg_toplevel requests.**
  - `move` and `resize` reach `CWindow::onXDGMoveRequest` / `onXDGResizeRequest` (Window.hpp:459-460, :470-471)
    through the public signals `requestMove` / `requestResize` (src/protocols/XDGShell.hpp:131-132).
  - A client's `set_maximized` enters `FSMODE_MAXIMIZED` (Window.hpp:197-198), unless `SUPPRESS_MAXIMIZE` is set
    (:76-79, :194).
  - `set_minimized` is stored in `m_state.requestsMinimize` and announced on the public `stateChanged` signal
    (XDGShell.hpp:129, :140-144). What Hyprland does next is not in the headers, and the event bus has no minimize event
    (src/event/EventBus.hpp:76-93).
  - The toplevel has no window-menu signal (XDGShell.hpp:127-134), so the headers show no handler for `show_window_menu`.
- **Decorations** can draw over the surface (`DECORATION_LAYER_OVER`,
  src/render/decorations/IHyprWindowDecoration.hpp:20), be positioned absolutely
  (src/render/decorations/DecorationPositioner.hpp:11-14) and take mouse input (IHyprWindowDecoration.hpp:25).
- **No protocol** lets a client declare a toolbar height, or a region where the compositor should draw controls.

### Qt 6.11.2 client side (VERIFIED from /usr/include/qt6 and /usr/lib/qt6)
- **Window actions.**
  - `QWindow::startSystemMove()`, `startSystemResize(edges)`, `showMinimized()`, `showMaximized()` and `showNormal()`
    (QtGui/qwindow.h:267-276) are public slots.
  - On Wayland, `QWaylandWindow::startSystemMove/Resize` (QtWaylandClient/6.11.2/.../qwaylandwindow_p.h:229-230) call
    `QWaylandXdgSurface::move/resize`.
  - The xdg-shell plugin (/usr/lib/qt6/plugins/wayland-shell-integration/libxdg-shell.so, read with `strings`) contains
    the request names `set_minimized`, `unset_maximized` and `show_window_menu`.
- **xdg-decoration.** The same plugin contains `QWaylandXdgDecorationManagerV1` and
  `QWaylandXdgToplevelDecorationV1::requestMode`.
- **xdg-toplevel-tag.** Qt has no client for it: no header in QtWaylandClient/6.11.2/QtWaylandClient/private and no
  string in libxdg-shell.so.
  - A per-window Wayland handle exists only as private API: `QNativeInterface::Private::QWaylandWindow::surfaceRole<T>()`
    and the `surfaceRoleCreated()` signal (QtGui/6.11.2/QtGui/qpa/qplatformwindow_p.h:122-158).
  - The public `QNativeInterface::QWaylandApplication` gives only the display and the seat (QtGui/qguiapplication_platform.h:71-85).
  - `QWaylandClientExtensionTemplate` (public) binds a global.
- **Scaling.** Qt supports fractional scaling on Wayland (qwaylandfractionalscale_p.h:30).

### How macOS does it (from memory, no Apple document consulted: ASSUMPTION)
- **Who draws.** The macOS application framework draws the window frame and the three buttons inside the app's own
  process, as part of the window content. The window server does not draw them: it composites the window and casts the
  shadow.
  - The buttons are ordinary button views that the framework hands to the app (`standardWindowButton(_:)`). An app can
    hide them or offset them.
- **What the app declares.** The toolbar style (`toolbarStyle`: unified 52, unified compact, expanded) and whether the
  content runs under the toolbar. The framework sizes the row and centres the buttons in it, which puts them at 25.75 in
  the 52-pt row.
- **What the framework handles, for every app:**
  - glyphs when the pointer is over the group, grey when the window is not key, hidden in full screen;
  - a dot in close for unsaved changes, disabled while a sheet is shown;
  - empty toolbar space drags the window; a double-click follows the system setting;
  - a right-click on the toolbar opens the toolbar's own menu (no window menu);
  - the buttons are accessibility elements of the window.
- **Third-party toolkits** get the same buttons, because they all create the framework's windows.
- **Mapping to Grassfield.** On macOS the "system" that draws the lights is the shared framework running in the app; the
  app only declares. In Grassfield that role belongs to grassfield-ui for Grassfield apps, and to the plugin for
  third-party apps, which have no shared framework.

## Options

### A. Each app draws its own lights; the plugin skips its titlebar for those windows
- **How the plugin learns to skip.**
  - A1, xdg-decoration client mode: not readable by the plugin in 0.56.2 (XDGDecoration.hpp:40).
  - A2, an app-id list (in the plugin or as a session rule): also strips the titlebar from Files' KIO widget dialogs
    (main.cpp:21-22).
  - A3, a per-window tag: as in D.
- **Without the plugin:** the app still draws its lights. Minimize and zoom take the paths described under D.
- **Consistency:** three app copies plus the plugin make four renderers. Sizes, colours, glyphs and inactive states
  drift, and there is no single place to fix them.
- **Drag, double-click, right-click, keyboard, accessibility:** each app wires its own, so the result is uneven.
- **HiDPI and material:** Qt draws the lights crisply, on the app's material.
- **Overview and Stages:** as in D.
- **Tests:** per app. **Size:** small for the first app, then ×3, with high maintenance.
- **Verdict:** this is D without the shared component. Nothing justifies per-app drawing.

### B. The plugin draws the lights inside the app's toolbar row (compositor-side)
- **Mechanism.**
  - The app keeps the lights' area of its row empty.
  - The plugin draws three circles there, with a decoration on the OVER layer positioned absolutely on the surface
    (IHyprWindowDecoration.hpp:20, DecorationPositioner.hpp:11-14), and takes the presses there (:25).
- **What 0.56.2 offers for the app's declaration:** identity and config, not geometry or state.
  - Identity: an xdg toplevel tag plus a session rule (a window tag or a plugin rule effect). The plugin would then take
    a fixed geometry from the tokens: a 52 row with the centre at 25.75.
  - State that the macOS framework knows needs a new Wayland protocol, served by the plugin and bound by each app through
    private Qt API. Examples: a sheet is shown (lights disabled), the document is edited (dot), the toolbar is hidden in
    full screen, the sidebar is collapsed (the lights move over the toolbar). The plugin already serves one global, the
    appmenu one (compositor.md FR18).
- **Without the plugin:** Hyprland draws nothing (master-prompt.md:95), so the app must draw its own lights. B therefore
  contains D as its fallback, plus a switch:
  - The app must notice the plugin's global appear and vanish, also on a runtime unload or reload.
  - During the switch the window can show no lights, or two sets.
- **Consistency:** with the plugin there is one renderer for SSD windows and Grassfield apps. Glyphs, grey and the
  full-screen hide come from the same code, once the plugin has them (compositor.md:973). Without the plugin, the app's
  fallback draws.
- **Drag and double-click:** they stay in the app. The plugin cannot know which parts of the row are empty (the items are
  app content), so one row is split between two processes.
- **Right-click:** the app's toolbar menu, as in D.
- **Keyboard and accessibility:** controls drawn by the compositor are invisible to AT-SPI, like today's titlebars, so
  gate A1 (master-prompt.md:586) cannot be met for them.
- **HiDPI:** two renderers must align on one row. The plugin rounds boxes in device pixels at the monitor scale
  (Titlebar.cpp:347-373); Qt lays out at its fractional buffer scale. The circles and the app's reserved area can be one
  device pixel apart. The plugin was only tested at scale 1 (compositor.md:982).
- **Material:** no strip; the circles are drawn over the app's material.
- **Overview and Stages:**
  - The band above these windows is 0.
  - In live transforms the plugin draws the lights as part of the window.
  - The v1 thumbnails (screencopy of the surface) lose them.
- **Advantage:** the tiling popover on hover of the green light (gap 20, f1-reference-gaps.md:112, :405-408) becomes a
  plain plugin → shell event.
- **Tests:**
  - protocol unit tests;
  - press ownership over the surface: a press on a light never reaches the client (FR13);
  - fallback switching at load and unload;
  - two scales;
  - a heavy R13, C1-C3 load.
- **Size:** L. It needs a new protocol, an overlay decoration with input and hover, the app binding, and all of D for the
  fallback: about twice D.

### C. Keep two rows (status quo)
- **Without the plugin:** Grassfield apps have no lights and no drag (files.md:207).
- **Consistency:** one renderer, the plugin, but it has no glyphs and no grey inactive state.
- **Drag and double-click:** on the titlebar only; the toolbar does not move the window.
- **Right-click:** none. **Accessibility:** the lights are invisible to assistive technologies.
- **HiDPI:** the plugin is tested at scale 1 only.
- **Material:** an opaque dark strip sits above apps in the light appearance (Theme.hpp:65-74).
- **Overview and Stages:** unchanged; the 28-px band stays correct.
- **F1:** gap 9 stays "missing": 80 pt of chrome against 52, and two titles in Files.
- **Size:** 0.

### D. The shared UI framework draws the lights; the app declares (the macOS model)
- **ui (grassfield-ui).**
  - New components `WindowControls` (the three lights) and `UnifiedToolbar` (the row, drag, double-click, and the
    leading space for the lights when no sidebar holds them).
  - The app declares a style, `unified` (52) or `titlebar`, and places its items. It never draws or wires the lights.
  - The values come from new tokens `window.*`: diameter 14, gap 9, row 52, centre 25.75, and the titlebar-only height
    from gap 2.
  - The same tokens generate the plugin's light constants. `ui/tools/gen-tokens.py` already generates `Tokens.qml`, so
    one source of values serves both renderers.
- **Per-window declaration to the compositor.**
  - The chrome sets an xdg toplevel tag that names the window's role (e.g. `browser`, `settings`, `viewer`, `info`),
    which is what the protocol is for (xdg-toplevel-tag-v1.xml:48-63).
  - One helper in `apps/` does this (next to `apps/globalmenu.h`), with `QWaylandClientExtensionTemplate` and
    `QWaylandWindow::surfaceRole<xdg_toplevel>()` on `surfaceRoleCreated()`.
  - KIO's widget dialogs set no tag, so they keep the plugin titlebar.
- **Session rule** (the `xdg_tag` key is UNVERIFIED in Lua; spike step 1):

  ```lua
  hl.window_rule({ name = "gf-client-chrome",
    match = { class = "^org\\.grassfield\\.(Files|Settings|Preview)$", xdg_tag = ".+" },
    tag = "+grassfield-client-chrome" })
  ```

  Rounding per Q5 and the maximize exemption per Q4 are added to this rule.
- **Plugin.**
  - `shouldShow()` returns false for windows tagged `grassfield-client-chrome`. It is evaluated again on
    `window.updateRules` (main.cpp:84).
  - Stages uses that same predicate for the band above each window.
  - New capability `client-chrome`, additive within gfc/1 (ADR-0007).
  - The rule does not use `decorate = false`, which is assumed to drop Hyprland's own border and shadow as well. That is
    the upstream wiki's meaning of the effect, UNVERIFIED on 0.56.2 (spike step 2).
- **Actions.**
  - Close: `QWindow::close()`, which is what Hyprland's close asks the client to do.
  - Zoom: `set_maximized` puts the window in `FSMODE_MAXIMIZED`, the same state as the plugin's zoom
    (Titlebar.cpp:122-129). This needs one of two things: client-chrome windows exempt from `gf-no-maximize-event`
    (windows.lua:7), or the plugin applying the request it sees on `stateChanged` (XDGShell.hpp:129, :141).
  - Minimize: `set_minimized` goes into the shell's minimize path (Dock tile and animation; parking without the plugin).
    It gets there through Hyprland's own report if there is one, or through a plugin bridge to the existing
    `minimize-request` (FR6) (spike step 5, Q4).
  - Drag: `startSystemMove()` starts Hyprland's interactive move (Window.hpp:470).
  - Resize stays on the border (looknfeel.lua:16-17).
- **Without the plugin:**
  - The drawing is the same with and without the plugin: the app draws.
  - Drag and close never need the plugin; zoom does not either if exempted (Q4); minimize depends on spike step 5 and Q4.
  - This is better than today, where the apps have no lights at all.
  - An older plugin without `client-chrome` would draw its strip above the app's lights. Plugin and apps therefore ship
    from the same release (a packaging constraint next to ADR-0009).
- **Consistency.** Two renderers remain: grassfield-ui for Grassfield apps, the plugin for third-party SSD windows.
  - They are kept equal by one token source, a nested parity check (Test plan) and the plugin parity slice (Q2).
  - Full-screen hide: Hyprland syncs full screen to the client by default (WindowRuleApplicator.hpp:110). The app hides
    its lights when Qt reports full screen, as the plugin hides its strip (Titlebar.cpp:241-242).
  - Inactive state: the app follows Qt's `Window.active`, which comes from the xdg `activated` state (ASSUMPTION). The
    plugin parity slice would follow Hyprland's active window; the plugin has no inactive state today.
- **Drag.**
  - One owner holds the whole row, as on macOS.
  - Hyprland's interactive move may differ from the plugin's titlebar drag in two ways: snapping (compositor.md:975) and
    un-zooming a maximized window (FR8). Spike step 3 measures both. If Hyprland refuses to move a maximized window, the
    app un-zooms first (`showNormal()`).
- **Double-click:** the app reads `windows.titlebarDoubleClick`, the way Files already reads `grassfield.json`.
- **Right-click:** later, the toolbar's own menu, as on macOS. There is no window menu: the plugin has none, and Hyprland
  shows no handler for `show_window_menu`.
- **Keyboard and accessibility.**
  - The lights are QML buttons with an Accessible role, a name (Close, Minimize, Zoom) and a press action, so AT-SPI sees
    them.
  - They are not in the Tab chain, as on macOS (from memory). The keyboard equivalents are Ctrl+W and the Window menu (T1).
- **HiDPI:** one renderer, vector shapes, Qt's fractional scale.
- **Material:**
  - The row is drawn on the app's own material, with no opaque strip.
  - The lights follow the dark and light appearance; the plugin strip is dark only.
  - The window itself stays opaque (master-prompt.md:346).
- **Overview and Stages.**
  - Windows tagged `grassfield-client-chrome` get no band.
  - Overview: OverviewWindow.qml:105-107 and :131 read the window's tags from Hyprland's window data, when
    `client-chrome` is advertised. That the window data has this field is UNVERIFIED (spike step 2).
  - Stages: Stages.cpp:486-489 uses the plugin's own predicate.
  - The v1 thumbnails include the lights, because they are part of the surface.
- **Size:** M overall, about half of B. Rough, low confidence:
  - ui components plus tokens and the generator: M;
  - the tag helper plus three app adoptions: M;
  - plugin predicate, Stages band, capability and bridges: S-M, plus R13 and C1-C3;
  - Overview band in the shell: S;
  - the session rule: S.
  - The 36-pt capsule restyle of gap 9 is app work on top of this, not part of D.

### Summary
| Criterion | A | B | C | D |
|---|---|---|---|---|
| Lights without the plugin (C2) | app | app fallback + switch | none | app (same code) |
| One renderer for all lights | no (4) | yes with the plugin | yes | no (2, shared tokens + parity test) |
| Drag / double-click owner | each app | app (row split) | plugin strip | ui framework |
| Lights visible to AT-SPI (A1) | uneven | no | no | yes |
| HiDPI alignment | Qt | two renderers | plugin | Qt |
| New protocol | no | yes | no | no |
| Matches the macOS architecture | partly | no (macOS draws in the app) | no | yes |
| Size | M ×3 | L | 0 | M |

## Decision (proposed)
**Option D.**
- It is the macOS model: the shared framework inside the app draws the lights, and the app only declares a toolbar style.
- No hard constraint on Hyprland 0.56.2 prevents it.
- The constraints that hurt B do not apply to it:
  - C2 needs app-drawn lights anyway, so B contains D.
  - Hyprland offers no channel for client-declared geometry or state, so B needs a new protocol.
  - Compositor-drawn controls fail A1.
  - One row split across two processes risks misalignment, and a gap or double draw at plugin load and unload.
- B's single advantage, one renderer for every light, is recovered by three measures: one token source, a parity check,
  and the plugin parity slice (Q2).
- Implementation starts only after the spike below passes and the owner answers Q1-Q6.

### Owner answers (2026-10-20)
- Q1: (a) option D, grassfield-ui draws the lights inside the app.
- Q2: (a) the plugin parity slice ships before or with the first app.
- Q3: (a) every grassfield-ui window: the main windows of Files, Settings and Preview in the `unified` style, Get Info
  and Customize Folder in the `titlebar` style; KIO and widget dialogs keep the plugin titlebar.
- Q6: (a) Qt private API accepted, isolated in one helper header in `apps/`; the apps are rebuilt with each Qt minor.
- Q4: open until spike steps 4-6 report (native paths first).
- Q5: (a) radius 26 for unified-toolbar windows, 12 for titlebar-style windows, following the macOS model (integrator
  choice under the owner's "macOS model first" rule; judged at the F1 review).

## Test plan (option D)
- **L0.**
  - `tests/unit/tst_windowcontrols.qml`:
    - geometry per style: centre 25.75 ± 0.01 in `unified`, pitch 23, hit radius;
    - states: active, inactive, hover, pressed, disabled, full screen;
    - the double-click setting.
  - `tst_tokens.qml` reference metrics: 52, 14, 9, 25.75.
  - compositor GTest:
    - the tag predicate;
    - the Stages band per window;
    - the capability list;
    - the generated light constants equal what the titlebar draws.
  - `Hyprland --verify-config` on the rule.
- **L1, nested.** A new `tests/compositor/client_chrome.sh` with a fixture, run with the plugin and with `--no-plugin`:
  1. Tagged window: no plugin strip. Untagged dialog of the same app id: strip kept (`scripts/nestctl clients -j` and a
     screenshot).
  2. Real clicks through `scripts/dev/pointer.sh`:
     - close closes the window;
     - minimize goes to the Dock tile (gfc `minimized`, `special:minimized`);
     - zoom gives `FSMODE_MAXIMIZED`, and a second zoom returns to the same box (as `zoom_restore.sh`).
  3. Drag: a drag on empty row space moves the window by Δ; a drag on an item does not. Double-click for each
     `titlebarDoubleClick` value (as `double_click_setting.sh`).
  4. Visual states: grey when inactive, glyphs on hover, lights hidden in full screen (screenshots and pixel samples).
  5. Overview v2 and Stages: no empty band above tagged windows (screenshots and layout logs).
  6. Plugin unload and reload while the window is mapped: never two sets of lights, never a strip.
  7. The fixture in the `soak.sh` window churn (C1).
- **Screens.**
  - `scripts/dev/shot.sh` on GF-REF: `client-chrome-{files,settings,preview}-{active,inactive,hover}.png`.
  - A side-by-side with a foot window (plugin titlebar) for the parity check, at scale 1 and 1.5.
  - The A2 contrast check of the glyphs on the lights, and the F1 sign-off by the owner.
- **Review.** R13 for the plugin. The ui public QML API change (a semver minor, master-prompt.md:304). The apps.

## Owner questions (recommended proposal first)
1. **Who draws the lights in Grassfield apps?**
   (a) grassfield-ui inside the app (option D).
   (b) The plugin, over the app's row (option B: a new protocol; the app still draws them without the plugin).
   (c) Keep two rows (option C) until after M5.
2. **When do third-party windows get the same lights?** The plugin parity is hover glyphs, grey when inactive, and
   14-pt lights 9 apart (gap 2).
   (a) One compositor slice, before or with the first app.
   (b) Apps first, plugin later, with a visible mismatch meanwhile, listed under STATE placeholders.
   (c) App lights limited to the plugin's current look until parity.
3. **Which windows draw their own chrome?**
   (a) Every window built from grassfield-ui:
       - the main windows of Files, Settings and Preview in the 52-pt `unified` style;
       - Get Info and Customize Folder in the `titlebar` style of the same component;
       - KIO and widget dialogs keep the plugin titlebar.
   (b) The three main windows only.
   (c) (a), plus Glance moving from `decorate = false` to the same mechanism. Glance would then get close and full-screen
       circles (f1-reference-gaps.md:232).
4. **Minimize and zoom without the plugin.** This only matters if spike steps 4-5 find no native path.
   (a) Hyprland's native paths only:
       - exempt client-chrome windows from `gf-no-maximize-event`;
       - the shell handles Hyprland's minimize report;
       - the lights then behave the same with and without the plugin.
   (b) A plugin bridge. Without the plugin, the app greys minimize and zoom. It learns that the plugin is absent from a
       runtime file the shell writes from the capabilities (a new small contract).
   (c) A plugin bridge, with inert lights without the plugin as a documented limit. Not recommended: R11.
5. **Corner radius of unified-toolbar windows.**
   (a) 26, set by the same session rule (gap 1); titlebar-style windows keep 12.
   (b) Keep 12 everywhere for now.
6. **Qt private API in the apps (needed to tag a window).**
   (a) Accept it, isolated in one helper header in `apps/`. The apps are then rebuilt with each Qt minor, as Quickshell
       already is.
   (b) No private API: keep option C until Qt ships its own xdg-toplevel-tag support (date unknown).

## Spike plan (smallest nested proof of D, before any implementation)
- **Owner.** compositor-engineer, about one day. The code stays under `.dev/spike/client-chrome/` and is not committed.
  Nested only, with headless GF-REF.
- **Fixture, about 150 lines.** A Qt 6.11 `QApplication` with app id `org.grassfield.SpikeChrome`:
  - One QML window with a 52-pt row and three 14-pt lights.
  - A `DragHandler` on empty row space calls `startSystemMove()`.
  - A double-tap calls `showMaximized()` / `showNormal()`.
  - The minimize light calls `showMinimized()`.
  - C++ binds `xdg_toplevel_tag_manager_v1`, with code generated from
    /usr/share/wayland-protocols/staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml, and tags the window on
    `surfaceRoleCreated()`.
  - A second, untagged `QDialog` uses the same app id.
- **Plugin prototype, about 40 lines.**
  - `shouldShow()` returns false for the tag.
  - A per-toplevel `stateChanged` listener logs `requestsMinimize` and `requestsMaximize`.
  - A `requestMove` listener logs the requests.
- **Dev config.** The rule above.

| # | Step | Pass |
|---|---|---|
| 1 | `Hyprland --verify-config` on the rule | the `xdg_tag` match key and `tag` effect are accepted |
| 2 | Map both windows; `scripts/nestctl clients -j`; `scripts/dev/shot.sh` | the main window has the xdg tag and `grassfield-client-chrome` and no strip; the dialog has a strip; Hyprland's border and shadow stay on the main window. Repeat with `decorate = false` and record whether the shadow goes. Record whether the client JSON lists tags |
| 3 | `scripts/dev/pointer.sh`: drag 200,100 on empty row space, on a light, and on a zoomed window | moves by (200, 100) ± 1; no move from a light; record what Hyprland does with a maximized window (refuse, move maximized, un-zoom) and whether it snaps |
| 4 | Double-tap with `gf-no-maximize-event` on, then with the window exempted | on: the plugin log shows the request and Hyprland ignores it; exempted: `FSMODE_MAXIMIZED`, then back to the same box |
| 5 | Minimize light, with a socket2 listener as in the existing tests | record whether Hyprland posts its own `minimized` report; the plugin log shows `requestsMinimize` |
| 6 | `scripts/dev/nested-up.sh --no-plugin`, steps 2-5 again | lights drawn, close and drag work; zoom and minimize outcomes recorded (Q4) |
| 7 | Shot next to a foot window with the plugin titlebar, then at scale 1.5 | light centres at 25.75 ± 0.5 px at scale 1; crisp at 1.5 |
| 8 | Unload and reload the plugin while mapped; `tests/compositor/soak.sh 300` | no Hyprland crash, no stale strip |

**If a step fails:**
- **Step 2** (the tag is not applied at map): check whether Hyprland applies rules again when the tag changes. If not,
  return to the owner with a rule on the class plus "no parent window".
- **Step 3** (the move is refused or wrong): the plugin handles `requestMove` with its own titlebar drag. If Hyprland's
  handler cannot be kept out of it, the question goes back to the owner.
- **Step 5** (no native report): minimize goes through the plugin bridge, and Q4 decides the degraded behaviour.

## Consequences
- **Two renderers for the lights.** grassfield-ui draws them for Grassfield apps and the plugin for SSD windows.
  - Generated constants and the parity check keep them equal.
  - E18 in docs/legal/visual-review.md gets a second source file.
  - Lights inside the toolbar at the macOS position bring the trade dress closer: "needs legal review".
- **New additive contracts:**
  - the gfc/1 feature `client-chrome`;
  - the Hyprland tag `grassfield-client-chrome`;
  - the role tags of Grassfield windows;
  - ui components `WindowControls` and `UnifiedToolbar` (semver minor).
- **Packaging.** Plugin and apps ship from the same release (double lights otherwise). With Q6(a), the apps depend on
  Qt private API and are rebuilt with each Qt minor.
- **Overview v2 and Stages:** the band becomes per window. The token `overview.windowTitlebarHeight` stays for
  plugin-decorated windows.
- **Not in this ADR:**
  - The tiling popover on hover of the green light (gap 20). Under D it needs an app → shell path for client-drawn
    lights, which would be its own ADR. The plugin can raise it for SSD windows.
  - The 36-pt capsules and the search circle (gap 9, second half) are app slices that build on `UnifiedToolbar`.
- **Re-verify on every Hyprland update:**
  - the plugin reads `CWindowRuleApplicator::m_tagKeeper`;
  - the plugin may listen to `CXDGToplevelResource::m_events.{stateChanged, requestMove}`;
  - the Lua keys `xdg_tag` and `tag`.

## Implementation notes: spike results (2026-10-22)
**Setup.** Hyprland 0.56.2 (commit efb50993, `scripts/nestctl version`), Qt 6.11.2, nested on headless GF-REF
1920x1080. The spike code stays in `.dev/spike/client-chrome/` (git-ignored, not committed):
- fixture: `QApplication`, app id `org.grassfield.SpikeChrome`, a QML window with a 52-pt row and three 14-pt lights
  (centre 25.75, pitch 23), tagged `browser` on `surfaceRoleCreated()`, plus an untagged `QDialog`. The tag client code
  is generated by `qt6_generate_wayland_protocol_client_sources` from the staging XML;
- plugin prototype: a scratch copy of `compositor/` (0.8.2), built to `.dev`. `shouldShow()` returns false for the
  `grassfield-client-chrome` tag; per-toplevel `stateChanged`/`requestMove` listeners log the requests, the window's
  `m_suppressedEvents` and its fullscreen modes. Loaded with `scripts/nestctl plugin load <.dev path>`;
- dev rule: `.dev/spike/client-chrome/rule.lua` (the rule above, class list plus `SpikeChrome`), added at runtime with
  `scripts/nestctl dispatch 'function() dofile("…/rule.lua") end'`.

Captures are in `.dev/shots/` and logs in `.dev/spike/client-chrome/logs/` (both git-ignored). The 1-min load during the
nested runs was 6.1–11.3:
- plugin session: 7.67, 7.33, 6.73 (soak start), 11.34 (after the soak), 10.17;
- no-plugin session: 6.06–6.33.

2–4 other nested sessions were running.

| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `Hyprland --verify-config` on the rule: exit 0, `config ok` |
| 2 | PASS | tag present at map; no strip on the tagged window, strip on the dialog; border and shadow kept |
| 3 | FAIL | (190, 95) instead of (200, 100); a zoomed window is un-zoomed and centred on the pointer, row off-screen |
| 4 | PASS, with a defect found | suppressed: logged and ignored; exempted: `FSMODE_MAXIMIZED`, then the same box |
| 5 | PASS (recorded) | `requestsMinimize true` logged; Hyprland posts no `minimized` event and does nothing |
| 6 | PASS | no plugin: lights drawn, close and drag work; zoom works when exempted; minimize has no effect |
| 7 | PASS | centre (25.75, 25.76) at scale 1; (25.75, 25.75) pt at 1.5, crisp |
| 8 | PASS | two unload/reload cycles while mapped; `tests/compositor/soak.sh 300`: PASS |

**Step 1.** `GRASSFIELD_CONFIG_DIR=<tree>/config/hypr Hyprland --verify-config --config .dev/spike/client-chrome/verify.lua`
(the core config plus one variant file):
- the rule: exit 0, `config ok`. Variants: `decorate = false` exit 0; the Q4(a) exemption
  `match = { class = ".*", xdg_tag = "negative:.+" }` on `gf-no-maximize-event` exit 0.
- Negative control, a misspelled key: exit 1, `hl.window_rule: unknown match property 'xdg_tagg'`.
- **Q5 finding:** `rounding = 26` in the rule: exit 1, `hl.window_rule: field 'rounding': value 26 is more than the
  maximum of 20` (also in LuaBindingsInternal.hpp: `CLuaConfigInt(0, 0, 20)`). Q5(a) "radius 26 set by the same session
  rule" cannot be done with a 0.56.2 window rule.

**Step 2.**
- The fixture sends `set_toplevel_tag(xdg_toplevel, "browser")` before the toplevel's initial `wl_surface.commit`
  (`WAYLAND_DEBUG=client`, logs/fixture-A2.log).
- The plugin's first `updateRules` line for the window, before `open`, already shows `xdgTag browser tags
  [grassfield-client-chrome*]`, so the tag is applied at map. No re-check path was needed.
- `scripts/nestctl clients -j`: the main window has `"tags": ["grassfield-client-chrome*"], "xdgTag": "browser"`; the
  dialog has `"tags": [], "xdgTag": ""`.
  - The client JSON lists both fields, so Overview can read them. The dynamic tag carries a `*` suffix, which a match
    on the JSON must accept.
  - Not checked: whether Quickshell's Hyprland window data exposes these fields.
- Capture `spike-A-s2-plugin.png`: the main window has no strip and draws its own lights; the dialog has the plugin
  strip; the shadow is under the main window.
- `decorate = false` variant (`spike-A-s2-decorate-false.png`, same window box), sampled with ImageMagick:
  - the shadow goes: pixel (600, 775) is (37,86,50) by default and (46,107,63), the bare background, with the variant;
  - the border goes: column x=559 is (44,78,92) by default and equals the outside pixel with the variant.
  - `scripts/nestctl decorations address:…` still lists Drop Shadow, Border, Inner Glow and grassfield-titlebar: the
    effect stops the drawing, not the objects.
  - This confirms the ADR's choice not to use `decorate = false`.

**Step 3** (`scripts/dev/pointer.sh`; the fixture starts `startSystemMove()` from a `DragHandler`).
- Drag (200, 100) on empty row space: the window moved (190, 95), from (2000, 261) to (2190, 356). FAIL against ± 1.
  - Cause: the `DragHandler` activates after Qt's drag threshold. Fixture log: `startSystemMove at 510 31` for a
    press at (500, 26), i.e. after the first 20-step increment.
  - A slow start (20 px to the right, then to a net (-200, -100)) moved the window (-209, -100). So Hyprland's move
    follows the pointer exactly from the moment the request arrives, and the window lags the pointer by the threshold.
  - Variant `--move-on-press` (`startSystemMove()` on the press): exactly (200, 100), (2000, 261) → (2200, 361). The
    app still sees both presses, so it can detect a double-click from two presses within the double-click interval
    (logs/fixture-A6.log, fixture-A9.log).
- Drag from the zoom light and from a toolbar item: no move, no click. PASS.
- Snap: Hyprland's move snaps (`general:snap:enabled` true, `monitor_gap = 8`). A drag aimed at a left edge 4 px from
  the output edge ended at local x = 1, with the 1-px border on the edge. The plugin's own titlebar drag does not snap
  (compositor.md:975).
- Zoomed window (maximize exemption active): a drag of (200, 100) from the row un-zooms the window (fullscreen 0, back to
  800x500) and centres it on the pointer, at local (700, -124). The row and the lights are above the output, under the
  menu bar (`spike-A-s3-zoomed-drag.png`). Same with `--move-on-press`.
- **Branch applied:** "Step 3 (the move is refused or wrong)": the plugin would handle `requestMove` with its own drag
  (FR8 un-zoom under the pointer).
  - Keeping Hyprland's handler out is not possible through a documented hook. `CWindow::m_listeners.xdgMoveRequest` is
    public (Window.hpp:459), so a plugin could drop it, but it cannot restore it at unload: `onXDGMoveRequest` is private.
    Not tried.
  - As the ADR says, the question goes back to the owner.
  - The plain-drag lag has an app-only fix: start the move on the press.

**Step 4.**
- With `gf-no-maximize-event`:
  - the plugin logs `requestsMaximize false … suppressedEvents 0x2 fs internal 0 client 0`;
  - Hyprland ignores the request: `clients -j` shows `"fullscreen": 0` and the window keeps 800x500.
- With the window exempted (the rule's match extended with `xdg_tag = "negative:.+"`):
  - the window maps with `suppressedEvents 0x0`;
  - the first double-tap gives `"fullscreen": 1, "fullscreenClient": 1`, 1918x972 at (1441, 25);
  - the second returns it to (2000, 261) 800x500. Reproduced with the plugin (fixtures A3 and A8) and without it
    (B2, step 6).
- **Defect found: Qt's maximized state is inverted in the Grassfield session.**
  - Hyprland sends the xdg `maximized` state to these floating windows. Qt reports `Window.Maximized` (visibility 4) for
    the 800x500 floating window after every configure (logs/fixture-A2.log, fixture-A3.log). Window.hpp:196-197:
    "Hyprland sends XDG_TOPLEVEL_STATE_MAXIMIZED to tiled windows to suppress CSD".
  - So Qt never sends `set_maximized` for a normal window: `showMaximized()` sends nothing. Every zoom request is an
    `unset_maximized`.
  - Hyprland toggles `FSMODE_MAXIMIZED` on any maximize request, whatever its value. The plugin logs
    `requestsMaximize false … fs internal 1 client 1` after Hyprland's own handler ran.
  - The exempted zoom therefore works only by this double inversion. The app must not take its zoom state or its glyph
    from Qt's `visibility`, and the behaviour must be re-verified on every Hyprland update.
- **Test caveat.** Each plugin unload or load makes Hyprland re-apply its config. That drops rules added at runtime:
  - after the step-8 reload, fixture A7 ran suppressed (`suppressedEvents 0x2`, logged);
  - fixture A6 behaved the same (not logged).
  - A rule in the session config is not affected.
- Re-registering a named rule merges the given fields into the existing rule: `decorate = false` stayed after
  re-registering the rule without it.

**Step 5.** A click on the minimize light:
- the fixture sends `xdg_toplevel.set_minimized()` (WAYLAND_DEBUG);
- the plugin logs `requestsMinimize true`;
- Hyprland does nothing: the window stays mapped and visible on workspace 2. Qt's visibility goes 3 → 2 at once.
- No `minimized>>` event among the 894 socket2 events of the whole plugin session (logs/socket2-A.log). The only
  `special:minimized` moves are the soak's plugin minimizes.
- **Branch applied:** "Step 5 (no native report)": minimize goes through the plugin bridge (`stateChanged` with
  `requestsMinimize` → the existing `minimize-request`, FR6), and Q4 decides the degraded behaviour.

**Step 6** (`scripts/dev/nested-up.sh --no-plugin`; `scripts/nestctl plugin list`: `no plugins loaded`).
- Step 2 again: the rule still applies (`"tags": ["grassfield-client-chrome*"], "xdgTag": "browser"`).
  `spike-B-s2-noplugin.png`: the fixture draws its lights; the dialog has no titlebar.
- Step 3 again: a row drag moves the window (190, 95), as with the plugin. A drag from a light does not move it.
- Step 4 again:
  - suppressed: `unset_maximized` sent, ignored;
  - exempted: `fullscreen>>1`, 1918x972, then `fullscreen>>0` and back to (2000, 261) 800x500, both through
    `unset_maximized` (logs/fixture-B2.log, socket2-B.log).
- Step 5 again: `set_minimized` sent; the window stays mapped on workspace 2; no socket2 event follows the click.
- Close light: `xdg_toplevel.destroy`, then `closewindow>>`. Close works without the plugin.

**Step 7** (`spike-A-s7-scale1.png`, `spike-A-s7-scale15.png`; tool `.dev/spike/client-chrome/measure.py`, a
coverage-weighted centroid within each light's 23-pt cell, checked to ± 0.01 px on synthetic circles).
- Scale 1, next to a foot window with the plugin titlebar:
  - close (25.75, 25.76), minimize (48.76, 25.76), zoom (71.76, 25.76) px from the window's top-left;
  - diameter about 13.9 px. PASS (± 0.5).
- Scale 1.5 (`scripts/nestctl dispatch 'function() hl.monitor({…, scale = 1.5}) end'`):
  - Hyprland draws the surface from device (150, 392). The logical y of 261 × 1.5 = 391.5 is rounded up, under a 2-px
    border.
  - From that origin: close (38.62, 38.62) device px = (25.75, 25.75) pt, pitch 23.00 pt.
  - From the unrounded logical origin, y is 26.08 pt.
- Crisp:
  - a vertical profile through the close light has one partial pixel at each edge (rendered at 1.5, not scaled up);
  - 8x crops `logs/s7-scale15-lights-x8.png` and `s7-scale15-foot-x8.png`: the plugin's lights are crisp at 1.5 too.

**Step 8.**
- Unload, then reload, with the fixture and a foot window mapped (11:00), and again at 11:14 for a rebuilt prototype.
  - `scripts/nestctl version` answers after each unload.
  - `spike-A-s8-unloaded.png`: foot's strip is gone, the fixture keeps its lights, the shell shows its degraded notice.
  - `spike-A-s8-reloaded.png`: foot's strip is back and the fixture has no strip. Never two sets of lights, no stale
    strip.
- `tests/compositor/soak.sh 300` (load 6.73), with the fixture mapped:
  - `soak: PASS`, 307 s, 45 rounds, Hyprland alive;
  - RSS 156648 → 162172 kB, `No coredumps found.`, grassfield exceptions 0;
  - log `.dev/soak-20261022-110115.log`.
  - The soak reported `minimize pairs 0 (skipped, no move seen: 5)` and 2 minimizes animated. That is the soak's own
    Dock check, not the spike.

**Q4 recommendation** (minimize and zoom without the plugin): split it.
- **Zoom: (a), native.** Change `gf-no-maximize-event` to `match = { class = ".*", xdg_tag = "negative:.+" }`. Zoom
  then behaves the same with and without the plugin.
  - Cost: every window that sets any xdg tag, not only Grassfield's, may maximize itself.
  - Cost: the app must send one maximize request per zoom and never read Qt's maximized state (step 4 defect).
- **Minimize: (b), plugin bridge.** Hyprland has no native path: no report, no state change. Without the plugin the app
  greys the minimize light; it learns that the plugin is absent from the shell's capabilities file.
  - (a) is impossible for minimize. (c) leaves an inert light (R11).
- **Still open for the owner:**
  - dragging a zoomed window (step 3 branch);
  - Q5's radius 26 (step 1 finding).

**Not verified:**
- Window data and bands:
  - whether Quickshell's Hyprland window data carries `tags` and `xdgTag`;
  - the Overview v2 and Stages bands (L1 item 5).
- The fixture's lights:
  - AT-SPI exposure (A1);
  - hover glyphs, the inactive grey and the full-screen hide: the fixture has none.
- Hyprland internals:
  - the contents of the xdg state arrays: WAYLAND_DEBUG prints only their length, and the `maximized` state is inferred
    from Qt and Window.hpp:196-197;
  - why Hyprland toggles on any maximize request: observed only, no source read;
  - detaching `m_listeners.xdgMoveRequest` from a plugin.
- Not exercised:
  - real KIO widget dialogs: a plain `QDialog` stood in;
  - scale 1.5 without the plugin, and several monitors;
  - clang-tidy on the prototype, which is not committed.
- One spike-only incident: a Hyprland "not responding" dialog (`hyprland-dialog`, ANR manager) appeared once at load
  10.2 during a double-click on fixture A9. That attempt was discarded and repeated; its cause was not identified.

## Integrator decisions after the spike (2026-10-22)
The owner asked for decisions without questions (2026-10-21, docs/STATE.md); the macOS model decides the open points.
- **Q4: the spike's split is accepted.** Zoom is native: `gf-no-maximize-event` matches `xdg_tag = "negative:.+"`, and
  the app sends one maximize request per zoom and never reads Qt's maximized state (step 4 defect). Minimize goes
  through the plugin bridge (`requestsMinimize` → `minimize-request`, FR6); without the plugin the app greys its
  minimize light, from the shell's capabilities.
- **Dragging a zoomed window (step 3).** macOS 26: dragging a window that fills the screen from its toolbar takes it
  out of that state at its previous size, and the window stays under the pointer at the same place in its toolbar row.
  So the plugin handles `requestMove` for tagged windows. If the window is zoomed, it restores the remembered box,
  places it so the grab point keeps its horizontal ratio and the toolbar row stays under the pointer, then starts the
  move. The 10 px lag of the move (190 for 200) is Qt's drag threshold and stays, as macOS also has a threshold.
- **Q5, radius 26 (step 1).** Hyprland 0.56.2 rejects `rounding` above 20 in a rule. Tagged windows get 20 with the
  session's `rounding_power`, the closest native shape, as F2a does for `org.grassfield.*`. A plugin-drawn corner mask
  is considered only if the owner's F1 review finds the difference visible.
  - **Correction (F2a, 2026-10-22):** 26 is native through the global `decoration.rounding`; only per-window rules are
    capped at 20 (`--verify-config`: `decoration = { rounding = 26 }` config ok; the rule: "value 26 is more than the
    maximum of 20"). F2a sets the global 26 and gives every class that is not `org.grassfield.*` the radius 12 with a
    negated whole-class rule (`negative:^org\.grassfield\..*$`; 12 is under the cap), measured getprop 26 / 12.
    Tagged unified-toolbar windows get 26 the same way: the 12 rule must exclude them too (by tag or class), no
    rule may raise a window above 20.
- **Status:** accepted with these decisions. Next slices, in order:
  1. plugin parity: the tag rule, `requestMove` un-zoom, the minimize bridge for tagged windows, C2 behaviour;
  2. the grassfield-ui `WindowControls` / `UnifiedToolbar` components;
  3. F2b: sidebars and toolbars of Files, Settings and Preview.
