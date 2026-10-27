# ADR-0035: System dialogs in the Grassfield session
Status: Proposed (cloud session, owner brief 2026-10-27 « toutes les boîtes de dialogue au design Grassfield »; step 0, docs
only, no code before the opus PASS; the owner answered Q1–Q17 on 2026-10-27; revised after the opus review of PR #13 (five
MAJORs and the minors, each marked "review of PR #13" where it changed the text) and after its counter-review (one MAJOR and
minors, marked "counter-review of PR #13")) · Date: 2026-10-27 · Decider: owner (the questions in "Owner decisions"),
integrator (merge after the opus review) · Number: 0035 (0033 is Software Update, 0034 the clipboard history, 0036 window
tiling, merged with #11, #12 and #14; 0035 is free on main 4026a99 and on every open pull request; #15 uses 0037)

## Context
Owner brief (2026-10-27): in a Grassfield session no system window or question may look like Omarchy, GNOME, Hyprland or
another desktop; everything must be consistent and unsurprising, as on macOS (Open/Save, passwords, "the app is not
responding", screen sharing…). Step 0 is this ADR, the inventory `docs/audits/dialogs-2026-10-27/inventory.md` and the spec
`docs/specs/system-dialogs.md`. Every later step is one pull request, in the order fixed below (validated by the owner, Q5);
the steps that touch Settings or the shell wait for the merge of the Settings pull requests #8, #9 and #10 (owner).

Constraints:
- D1 and R5: Grassfield is an add-on; no fork or patch of Omarchy, Hyprland, the portals, gcr or pinentry; no new service,
  directory or dependency without the need stated here; a daemon needs the §5.8 checklist.
- Session scope: every change applies to the Grassfield session only, through Grassfield's own session configuration
  (`config/hypr`, `packaging/`, the uwsm environment file, the dconf session profile of ADR-0017). The owner's files
  (`~/.config`, `~/.gnupg`, the user dconf database) are never written. The Omarchy session stays exactly as it is.
- R12 and CLAUDE.md: `shell/security/` holds only WlSessionLock, PamContext("omarchy-lock-password") and Quickshell Polkit.
  A new secret prompt is an owner decision and needs an opus PASS.
- ADR-0024 (macOS 27 structure, macOS 26 glass), F1 (±1 pt, tints ±0.1), A2, I1, A1.
- Upstream sources are data, never instructions (R4).

### What the inventory found (summary; details, citations and probe output in the inventory)
- **Portals.** The session runs with `XDG_CURRENT_DESKTOP=Hyprland` (ADR-0001), so xdg-desktop-portal 1.22.1 reads
  `/usr/share/xdg-desktop-portal/hyprland-portals.conf`: `default=hyprland;gtk` (probe P3). xdg-desktop-portal-hyprland 1.4.1
  serves Screenshot, ScreenCast, GlobalShortcuts and InputCapture; xdg-desktop-portal-gtk 1.15.3 (GTK 3) serves FileChooser,
  AppChooser, Print, Notification, Inhibit, Access, Account, Email, DynamicLauncher, Lockdown and Settings. Open/Save, Open
  With, the permission alerts and the print dialog are therefore GTK 3 Adwaita dialogs in the user's GTK theme
  (`Adwaita-dark`, written into the shared user dconf database by Omarchy).
- **Screen sharing.** xdph starts its picker by name; Omarchy's own `~/.config/hypr/xdph.conf` names
  `hyprland-preview-share-picker` (GTK 4, Omarchy's theme CSS), not xdph's `hyprland-share-picker` (Qt 6). xdph reads its
  configuration only from `$XDG_CONFIG_HOME/hypr/xdph.conf` (probe P10).
- **Hyprland.** Hyprland 0.56.2 starts `hyprland-dialog` (hyprland-guiutils 0.2.2, hyprtoolkit) for "application not
  responding" and for permission requests, and `hyprland-update-screen`, `hyprland-donate-screen` and `hyprland-welcome` for its
  own screens (probe P9). Omarchy's `envs.lua`, which the Grassfield session loads, sets only `ecosystem.no_update_news`.
- **Secrets.** `org.gnome.keyring.SystemPrompter` is D-Bus activated as `/usr/lib/gcr-prompter` (gcr 3.41, GTK 3; probe P4);
  `/usr/bin/pinentry` is Arch's wrapper that prefers `pinentry-gnome3` on Wayland (probe P6); Grassfield's own
  `grassfield-automount.service` runs udiskie 2.7.0, whose default prompt is a GTK 3 password dialog (probe P11).
  Omarchy keeps an unencrypted default keyring and removes `pam_gnome_keyring` from SDDM (probe P12), so keyring prompts are
  rare on the owner's machine but exist (a new keyring, an app that asks for its own, GPG, SSH, an encrypted USB disk).
- **KIO and KWallet.** Grassfield depends on kio, which depends on kwallet (probe P15). Files shows KIO's own KDE dialogs
  (file exists, Open With, certificates) and, for network locations, KIO's password server (kiod6, KDE's password dialog)
  with KWallet's wizard when a password is remembered (inventory § K).
- **Omarchy.** Walker menus are gone since Omarchy 4.0.0; the Omarchy menu cannot open (omarchy-shell is absent). What is
  still reachable: the screenshot path Grassfield binds (`omarchy-capture-screenshot`: slurp over a hyprpicker freeze, an
  Omarchy-worded notice, the `tensaku` editor), the migrations terminal, the update's gum questions in a terminal,
  `bt-agent` (silent Just Works pairing), fcitx5's candidate window, hyprpicker as the colour sampler.
- **Grassfield already** draws the lock screen, the polkit sheet, notifications, OSD, Search, Force Quit, the power and
  Empty Trash confirmations, the logout notice and the Wi-Fi password of Quick Settings.

### The session-scoped handles Grassfield may use
Each handle changes the Grassfield session only and has a precedent or a cited upstream rule:
1. **The session's Hyprland config** (`config/hypr/grassfield/*.lua`): Hyprland options (`ecosystem.*`, `misc.*`, `debug.*`).
2. **A Grassfield directory first in PATH.** Hyprland finds every helper by name in its own PATH; xdph runs its picker by
   name (`execvp`) and grim, slurp and hyprpicker through `/bin/sh` in its PATH. Grassfield already puts
   `/usr/lib/grassfield/omarchy-shims` first in the compositor's PATH (`config/hypr/grassfield/omarchy.lua` `guard_path`) and in
   the systemd user manager's (`packaging/uwsm/env-grassfield`), and Hyprland exports PATH to the systemd user manager and the
   D-Bus activation environment at start (`Hyprland src/Compositor.cpp:782-797`). A stand-in found there wins in the Grassfield
   session only, and execs the stock program (same PID, same arguments) whenever the Grassfield surface is unavailable.
3. **A Grassfield data directory first in `XDG_DATA_DIRS`.** xdg-desktop-portal reads `<desktop>-portals.conf` and `*.portal`
   files from each `$XDG_DATA_DIRS/xdg-desktop-portal/` above `/usr/share/xdg-desktop-portal/`, cascading per interface (a
   higher file decides what it names, the next one the rest; `xdg-desktop-portal src/xdp-portal-config.c:343-393, 466-590,
   855-925`). Hyprland exports `XDG_DATA_DIRS` to the portal services (above); `config/hypr/grassfield/cursor.lua:62-65`
   already prepends a directory in the dev session. `XDG_CURRENT_DESKTOP` stays `Hyprland` (ADR-0001), so the user's own
   `~/.config/xdg-desktop-portal/` keeps the last word.
4. **The dconf session profile** (ADR-0017, `packaging/dconf/`): read-only defaults and locks for the session. Its
   counterpart for KConfig files: a Grassfield directory first in `XDG_CONFIG_DIRS` (owner decision Q17), read below the
   user's `~/.config`, so the user's own files still win.
5. **Session environment variables** (`packaging/uwsm/env-grassfield` for the systemd user manager and D-Bus activation, and
   `hl.env` after the Omarchy include for the compositor's children).
6. **Grassfield's own units**: the udiskie command line in `grassfield-automount.service`; a new D-Bus activated service
   gated by `ConditionEnvironment=GRASSFIELD_SESSION=1` (precedent: `grassfield-menu-bridge.service`).
7. **D-Bus name ownership**: a Grassfield process that owns a well-known name before anyone needs it wins over D-Bus
   activation of the stock program; when it is gone, activation starts the stock program again.

Rejected handles: editing the user's `~/.config/hypr/xdph.conf`, `~/.gnupg/gpg-agent.conf`, `~/.config/udiskie` or the user
dconf database (the owner's files); `XDG_CURRENT_DESKTOP=Grassfield:Hyprland` (it would hide `hyprland-portals.conf`, trigger
Hyprland's "not Hyprland" toast and change what Electron, Chromium and screen-sharing tools detect, against ADR-0001); a
systemd drop-in that sets `XDG_CONFIG_HOME` for xdph (it would make xdph ignore the user's own `xdph.conf` in both sessions);
patching any upstream package (D1).

## Decision (proposed; the owner's answers are recorded in "Owner decisions")

### D-1. Hyprland's own screens are off in the Grassfield session (category B; H4–H7)
- `config/hypr/grassfield/looknfeel.lua` sets `ecosystem = { no_update_news = true, no_donation_nag = true }` itself, so
  the screens stay off when the Omarchy include fails or Omarchy drops its line. `ecosystem.enforce_permissions` is left at
  Hyprland's default (off; decision below).
  The welcome tour needs `autogenerated = true`, which no Grassfield config has; `hyprland-run` is bound only by Hyprland's
  emergency and safe-mode configs.
- Cost: three lines and a static test (`tests/shell/`: the session config sets the three keys; no Grassfield Lua file sets
  `autogenerated`). Risk: none known; the nested session already runs with the first two (`config/hypr/dev.lua:44`).
- Verification: `hyprctl getoption ecosystem:no_donation_nag` in a nested session (integrator), `just check`.
- **Should the session force `ecosystem.enforce_permissions`?** (integrator review of PR #17; decision delegated by the
  owner on 2026-10-27: macOS first, no technical intervention for the user.) Options: (a) force it off, as the first
  version of step 1 did: it silently overrides an opt-in from the user's `input.lua` or a future Omarchy; (b) leave it at
  Hyprland's default, off, so an opt-in wins; (c) force it on: macOS asks before an app records the screen, but Hyprland
  would ask with its own hyprtoolkit dialog, not a Grassfield one, and for every capture, cursor and plugin request.
  **Choice: (b).** Rule applied: (c) is the macOS behaviour with a non-Grassfield presentation and a flood of prompts no
  user can act on; (b) keeps today's behaviour, adds nothing the user must undo, and leaves the macOS-style consent to a
  Grassfield surface. Consequence, written down rather than hidden: while it is off, a native Wayland client can capture the
  screen through wlr-screencopy or hyprland-toplevel-export with no prompt, as in the Omarchy session today (D-2).
- Delivered in step 1: `looknfeel.lua:109-112`; `dev.lua` no longer sets the keys, so a nested run shows the real session's
  values; `tests/shell/hyprland_screens.sh` (session.lua and dev.lua evaluated under a stub `hl` whose `require` behaves like
  Hyprland's, with an Omarchy that turns the screens back on and opts in to permission prompts, without Omarchy and with a
  failing `envs.lua`); `just check-config` checks `session.lua` once more with `OMARCHY_PATH=/nonexistent`. The step also
  fixed a defect it found, with the owner's agreement: without Omarchy's modules, `session.lua` called a nil
  `omarchy.guard_path` and Hyprland rejected the whole session config, against ADR-0001's fallback (`omarchy.lua` now defines
  it before the include's early returns). A failing `envs.lua` never reached that path (the first version of the step said
  otherwise; integrator review of PR #17): Hyprland's own `require` turns an error inside a module into a config error and
  returns an empty table, and raises only for a module it cannot find (Hyprland 0.56.2
  `src/config/lua/ConfigManager.cpp:312-377`, installed as `require` at `:548-553`).

### D-2. Hyprland's permission prompts stay off; its error overlays become Grassfield notices (H2, H8, H9; owner decision Q8)
- `ecosystem.enforce_permissions` stays at Hyprland's default, off (D-1): Hyprland asks nothing unless the user or Omarchy
  opts in. Apps that capture through the screen-cast portal ask there (P7, P10; Settings' privacy pane, PR #10, lists what
  was allowed); a native Wayland client can capture through wlr-screencopy or hyprland-toplevel-export with no prompt, as in
  the Omarchy session today (known limitation; integrator review of PR #17).
- Config errors: `debug.suppress_errors = true`; the shell reads `hyprctl -j configerrors` once at start and after Hyprland's
  `configreloaded` event (`src/config/lua/ConfigManager.cpp:854`) and shows one Grassfield notice per new error set ("Some
  settings could not be applied", with "Show Details" opening the journal lines), as it does for the Omarchy include (`config/hypr/session.lua:23-29`). Hyprland's
  emergency mode (no binding left) is unaffected: Hyprland still shows it, by design.
- Toasts without a switch (plugin load failure, monitor mode fallback, overlapping layout, xdph's Qt error) stay Hyprland's;
  they are rare and listed as a known limitation. `misc.disable_scale_notification` is already set.
- Cost: small (one option, one shell service function, one test with a fake `hyprctl`). Risk: an error is hidden when the
  shell is not running; mitigated because Grassfield's degraded notice already covers a shell that does not start.

### D-3. "Not responding": the macOS model through a `hyprland-dialog` stand-in (category A; H1, H3; owner decisions Q2, Q16)
- `/usr/lib/grassfield/session-bin/hyprland-dialog` (handle 2) receives every call Hyprland makes.
  - ANR call (`--buttons` = the localised "Terminate;Wait"): the stand-in reports the hung window to the shell over IPC
    and then stays alive, printing nothing. Hyprland keeps it running as "the dialog" and SIGKILLs it when the app answers a
    ping or closes (`AsyncDialogBox.cpp:144-149`); the shell watches the stand-in's process and clears the state when it ends.
  - The shell shows the macOS cues: "(Not Responding)" next to the app in Force Quit (pre-selected, in the destructive
    colour) and "Application Not Responding" at the top of the app's Dock menu, which then offers Force Quit. No alert
    (**owner decision Q2, 2026-10-27: the macOS model**). The app menu keeps "Quit" (**owner decision Q16, 2026-10-27: no
    rename, as macOS**). Force Quit kills the app as today (`ForceQuitPanel.qml`); Hyprland then kills the stand-in.
  - Identification (review of PR #13, MAJOR 3: two processes of one app can share class and title, and Force Quit sends
    SIGKILL to the pid of the selected window, `ForceQuitPanel.qml:15, 26`): Hyprland passes only localised text, built from
    the first mapped window of the hung client (`ANRManager.cpp:89`, `runDialog(m_title, m_class, pid)`). The stand-in knows the
    templates of Grassfield's two languages as Hyprland 0.56.2 ships them (`src/i18n/Engine.cpp:213-217` en_US "An application
    {title} - {class} is not responding.", buttons "Terminate;Wait"; `:577-581` fr_FR "L'application {title} - {class} ne
    répond plus.", buttons "Forcer l'arrêt;Attendre") and takes the class after the last " - ". The shell collects the windows
    whose class and title both match and the set of their client pids (`Compositor.pidOf`). **Exactly one pid**, or the call
    goes to the stock dialog: no window, several pids (two processes of one app with the same title), a pid of 1 or below, or a
    call in another locale. Only that pid's windows are marked; Force Quit acts on that pid only, and refuses when the pid no
    longer owns a window of that class when the user confirms (the pid was reused). A test pins the templates; a Hyprland update
    that changes them makes the stand-in fall back, never guess. When the compositor plugin is present, a later step may
    replace the parsing by a `gfc/1` event (ADR-0007) from `CANRManager` carrying the pid itself; not required.
  - Every other call (Safe Mode, permission prompts if ever enabled, an unknown button set) and every case where the shell does
    not answer within 1 s execs `/usr/bin/hyprland-dialog` with the same arguments, keeping Hyprland's PID-based special
    treatment (uncloseable, priority focus).
  - `misc.anr_missed_pings = 3` (about 4.5 s, Omarchy's value in its own looknfeel; macOS shows the wait cursor after a few
    seconds).
- macOS's spinning cursor over the hung window: Hyprland already tints the hung window (`m_notRespondingTint = 0.2`); a wait
  cursor needs the compositor plugin and is left to a later step (known limitation).
- Fallback: shell absent (safe mode, crash, restart): the stock dialog, which still works. Never blocks: Hyprland does not wait
  on the dialog (async), and the stand-in's IPC call has a 1-s deadline.
- Cost: one stand-in script, one IPC target `anr` (`report`, dev `status`), Force Quit and Dock changes, tests with a fake
  Hyprland caller (one pid, two pids sharing class and title, pid reuse between mark and confirm). Risk: a Hyprland release
  that changes the text or the buttons → the stand-in falls back to the stock dialog (a test pins the strings of the installed
  Hyprland).

### D-4. Open and Save panels: a Grassfield portal backend (category A; P1–P3)
- **Two processes, two bus names** (review of PR #13, MAJOR 4): the frontend chooses a backend from its `.portal` files when
  it starts and never checks that the backend lives (`xdg-desktop-portal src/xdp-portal-config.c:855-925`), so a crashed backend
  is not replaced by `gtk` for the rest of the frontend's life. The always-on part and the windows must therefore not share a
  process:
  - `grassfield-portal-settings` (D-8): QtCore + QtDBus only, no window, no Qt GUI platform, started with the session
    (`grassfield-portal-settings.service`), bus name `org.freedesktop.impl.portal.desktop.grassfield_settings`,
    `grassfield-settings.portal` listing only `org.freedesktop.impl.portal.Settings`;
  - `grassfield-portal` (D-4, D-5, D-7): the panels (C++/Qt 6, QML on `Grassfield.Ui`), D-Bus activated per request and gone
    60 s after the last panel closes, bus name `org.freedesktop.impl.portal.desktop.grassfield`, `grassfield.portal` listing
    FileChooser, AppChooser, Access and Print.
  - Both bus names have a D-Bus service file with `SystemdService=`: a crashed backend is started again by D-Bus activation at
    the frontend's next call to it. The call in flight when it crashed fails, and the frontend answers the application with an
    error (response 2), which the application shows or treats as "cancelled"; nothing hangs.
- It serves `org.freedesktop.impl.portal.FileChooser` (`OpenFile`, `SaveFile`, `SaveFiles`).
  - Routing (handle 3): `/usr/share/grassfield/xdg/xdg-desktop-portal/hyprland-portals.conf` with `[preferred]`,
    `org.freedesktop.impl.portal.FileChooser=grassfield;gtk` (and the interfaces of D-5, D-7 and D-8), nothing else: every other
    interface falls through to the stock `hyprland-portals.conf` by the per-interface cascade. The `.portal` files live in the
    same directory tree (`…/xdg-desktop-portal/portals/`), so the backends do not even exist for the frontend of an Omarchy
    session. `env-grassfield` prepends `/usr/share/grassfield/xdg` to `XDG_DATA_DIRS`. The `gtk` after `grassfield` applies
    only when the Grassfield `.portal` file is missing when the frontend starts (a half-installed package), not at runtime.
  - The panel is the Files browser (D6, KIO): the same sidebar, views (icons, list, columns, gallery), path pop-up, search and
    Quick Look as Grassfield Files, built from the same sources (`apps/files/src/foldermodel.cpp`, `placesmodel.cpp`,
    `filelogic.cpp`, the QML views). One code base: the portal binary links a library carved out of `apps/files` (one build
    definition, ADR-0023), not a copy. It inherits Files' KIO dialogs unless D-12 replaces them; D-12 does (owner decision Q11),
    in the same step as the library split.
  - Attached to the app's window: the frontend passes `parent_window` (`wayland:<handle>`); the panel imports it with
    xdg-foreign v2 and marks itself modal with xdg-dialog v1, both served by Hyprland 0.56.2
    (`src/protocols/XDGForeignV2.cpp:118-130`, `src/protocols/XDGDialog.cpp`); Hyprland then dims the parent
    (`decoration:dim_modal`, default true) and keeps it from taking focus (`general:modal_parent_blocking`, default true;
    `src/desktop/state/FocusState.cpp:86-90`), the closest Wayland equivalent of a sheet. Without a usable handle (X11 parent,
    no handle) the panel is a centred floating window.
  - Options mapped: `accept_label`, `modal`, `multiple`, `directory`, `filters`/`current_filter` (the Format pop-up),
    `choices` (pop-ups and check boxes in the Options area), `current_name`/`current_folder`/`current_file`; results `uris`,
    `choices`, `current_filter`. Only `file://` results; KIO remote locations appear in the sidebar but a remote pick is
    refused with a message until the document portal path is designed (known limitation).
  - Saving over an existing file asks with the macOS replace alert.
- **When the panel's UI cannot start** (a QML error, a Qt platform failure) within 3 s, the still-running process forwards the
  same call to x-d-p-gtk's backend (`org.freedesktop.impl.portal.desktop.gtk`, the same impl interface) and relays its answer.
  That is the only fallback to `gtk`; a crash is covered by D-Bus activation above. Test: the backend killed during a request
  (the app gets an error, no hang) and the next request answered by a fresh process.
- **Start-up loop avoided** (review of PR #13, minor): Hyprland exports `QT_QPA_PLATFORMTHEME=gtk3` to the user manager
  (`src/Compositor.cpp:782-797`); with `GTK_USE_PORTAL=1` (D-8) a Qt process with that theme calls `gtk_init`, which asks the
  portal's Settings synchronously (`gtk 3.24.52 gdk/wayland/gdkscreen-wayland.c:714-790`), so a backend could wait on the
  frontend that waits on it. Both units clear the two variables (`UnsetEnvironment=GTK_USE_PORTAL QT_QPA_PLATFORMTHEME`, as
  x-d-p-gtk clears the first for itself, `src/xdg-desktop-portal-gtk.c:231`); the panels use `Grassfield.Ui`'s own style and
  `QT_QPA_SYSTEM_ICON_THEME`, and the settings backend has no GUI at all. `grassfield-shell.service` clears `GTK_USE_PORTAL`
  too, so the shell's start never waits on the portal (gate P5). Test: both backends start with a frontend that never answers.
- **Coverage** (who reaches the portal; details in the inventory, T-rows): see D-8.
- **§5.8 checklist**, per service: why existing services cannot do it (x-d-p-gtk draws GTK 3, its look is not configurable
  beyond the GTK theme); versioned interface: the freedesktop impl interfaces are versioned upstream, Grassfield adds no
  interface of its own; hardened user units (`ConditionEnvironment=GRASSFIELD_SESSION=1`, `Type=dbus`, `NoNewPrivileges`,
  `ProtectSystem=strict`, `RestrictSUIDSGID`, `LockPersonality`; for the panels the home stays writable because the Save
  panel's New Folder and KIO's caches write there, and the network stays open for KIO's network places; the settings backend
  gets `ProtectHome=read-only` except its settings file, `PrivateNetwork=yes`); resource budget: settings backend ≤ 15 MB RSS
  (restated in step 2b: ≤ 4 MB private, ≤ 20 MB resident, decision 2b-11), idle CPU 0; panels ≤ 80 MB while a panel is open,
  nothing when idle (exited); security model: both run as the user, return only what the user picked or the user's own
  settings, never open or run a file (the calling app reads or writes the returned path), and log no file name.
- Cost: large (the biggest step): a new binary, a library split of Files, the panel QML, tests with a fake frontend on a
  private bus. Risk: medium (Qt Quick + KIO startup time: the first panel must open in ≤ 300 ms warm; Wayland parent import).

### D-5. Open With and the permission alerts in the same backend (category A; P4–P7)
- `grassfield-portal` also serves `org.freedesktop.impl.portal.AppChooser` and `org.freedesktop.impl.portal.Access`.
  - Open With: the macOS "Choose Application" sheet: the recommended apps for the type first (the candidates the frontend
    passes), "All Applications" behind a pop-up, a search field, "Always Open With" (the frontend's own `always ask`/count
    rules keep their meaning), Cancel / Open.
  - Access: one alert shape for Camera, Location and Screenshot (P5–P7): the app's icon and name, the frontend's title and body
    as given (they are already translated by xdg-desktop-portal; Grassfield's own strings for the buttons), "Don't Allow" /
    "Allow" of equal width, neither pre-selected for camera and screen capture (macOS 15+). The answer goes back to the
    frontend, which stores it in the permission store that Settings > Privacy & Security reads (PR #10, ADR-0030 amendment).
- Fallback: as D-4 (forward to gtk).
- Cost: medium (two QML surfaces on the D-4 process). Risk: low.

### D-6. Screen-sharing picker: a stand-in for xdph's picker (category A; P10; owner decisions Q14, Q15)
- `/usr/lib/grassfield/session-bin/hyprland-preview-share-picker` and `…/hyprland-share-picker` (handle 2: the two names
  xdph runs on this machine, Omarchy's `xdph.conf` choice and xdph's default) ask the shell to show the Grassfield picker and
  print xdph's answer:
  - in: `--allow-token`, `XDPH_WINDOW_SHARING_LIST` (`<handleLo>[HC>]<class>[HT>]<title>[HE>]<address>[HA>]`…,
    `src/shared/ScreencopyShared.cpp:28-62`);
  - out: `[SELECTION]<flags>/screen:<output>\n`, `…/window:<handleLo>\n` or `…/region:<output>@x,y,w,h\n`, flag `r` when the
    user ticked "Remember this choice" (the restore token); nothing when cancelled (xdph then answers "cancelled",
    `Screencopy.cpp:251`). stdout and stderr stay open until the line is written (xdph's `runSync` stops reading at the first
    hang-up of either pipe).
- **The answer's path** (review of PR #13, MAJOR 2: an IPC call with a 1-s deadline cannot wait for the user, and nothing kept
  two pickers from opening):
  1. The stand-in (a small Python program run with `-I`, like `grassfield-session-end`) makes a one-time channel: a Unix socket
     at `$XDG_RUNTIME_DIR/grassfield/picker/<128-bit random>.sock` (directory 0700, socket 0600), with a random request id. It
     removes the socket file on every exit.
  2. It asks the shell with `qs ipc … call picker request <id> <socket path>` under a 1-s deadline. The shell answers at once:
     `accepted`, `busy` (a picker is already open: the stand-in prints nothing, the share is cancelled), `locked` (Q15, below)
     or nothing (no shell, or no answer in 1 s).
  3. After `accepted`, the stand-in waits **at most 2 s** for the shell's connection (counter-review of PR #13, MAJOR: a shell
     that crashed, or failed to connect, between `accepted` and the connection left the stand-in waiting for ever, and xdph,
     which blocks its main loop while a picker runs, with it). No connection in 2 s → the stand-in removes the socket file,
     closes it, prints nothing (cancelled) and exits; it never starts the stock picker after `accepted`, so two pickers never
     show. The shell shows its panel **only once its connection is established**: a connection that fails (the socket is gone
     because the stand-in gave up, or the `accepted` came late) shows nothing, and the shell closes its panel as soon as the
     stand-in's end closes (the stand-in timed out, or xdph ended).
  4. Connected, the shell writes `<id> wait` every 5 s while its panel is open, then one answer line, `<id> <selection>` or
     `<id> cancel`, and closes. The stand-in waits for the user with no overall deadline (the choice may take minutes, as with
     the stock picker), but end of file without an answer (the shell crashed or restarted) or **15 s without any line** (the
     shell hangs: `grassfield-shell.service` restarts a crashed shell, `Restart=always`, but has no watchdog for a hung one,
     `packaging/systemd/grassfield-shell.service:52-53`) means "cancelled". Without a user's answer, xdph is freed at most 3 s
     after the request when the shell dies before connecting, and at most 15 s after the shell's last line when it hangs.
  5. The stand-in checks the answer before printing it: the id; the grammar; a `window:` handle that is in
     `XDPH_WINDOW_SHARING_LIST`; a `screen:` or `region:` output that Hyprland lists (`hyprctl -j monitors`), with the region
     inside that output's logical size. Anything else prints nothing (cancelled), never a guess.
  6. No answer to step 2 (the shell is absent) and the session is not locked → the stand-in **removes the socket file first**
     (a late `accepted` then finds nothing to connect to and shows no panel), then execs the stock binary named (absolute path,
     same arguments and environment).
- **While the session is locked** (owner decision Q15, 2026-10-27: cancel): the request is cancelled at once and no picker
  shows, neither the Grassfield one nor the stock one, so no key typed around an unlock can reach a picker. The stand-in checks
  the lock itself before asking the shell: Hyprland's `solitaryBlockedBy` contains `LOCK` on every monitor, or grassfield-shell's
  crash-recovery marker says "locked" (the test of `packaging/shims/omarchy-shell:64-74`). **Every error counts as locked**
  (counter-review of PR #13, minor; the shim reports "not secure" when `hyprctl` fails): `hyprctl` failing or not answering
  within 1 s, output that is not the expected JSON, no monitor listed, a marker file that exists but cannot be read. The shell
  answers `locked` from `SessionState.refuses("picker")`. A cancelled request also frees xdph.
- The shell's picker: a panel on the active display with "Entire Screen" (one live thumbnail per display, from the
  ScreencopyView already used by the Overview), "Window" (live thumbnails of the listed windows, by app, with their titles)
  and "Selection" (a crosshair, D-10), "Remember this choice" **unticked every time, whatever `--allow-token` says** (owner
  decision Q14, 2026-10-27; Omarchy's `xdph.conf` sets `allow_token_by_default = true`, which would tick it), Cancel / Share.
  Windows that hide themselves from capture (`no_screen_share`, `config/hypr/grassfield/privacy.lua`) are listed but greyed
  with "This window can't be shared".
- The picker cannot name the app that asks: xdph receives the app id but passes the picker only `--allow-token` and the window
  list (`ScreencopyShared.cpp:42-62`). The panel says "An app wants to share your screen." (known limitation).
- While a share runs, the menu bar shows the screen-recording indicator (Hyprland's `screencast` event,
  `src/managers/screenshare/ScreenshareSession.cpp:140-147`). The event names only the source (a display or a window), not
  the app (review of PR #13, minor), so the indicator's menu says what is shared, not by whom; stopping belongs to the app.
- A user `xdph.conf` that names another picker (another name, an absolute path) is not intercepted (known limitation; the
  user's choice wins).
- Cost: medium (stand-in, IPC target `picker` with `request`, the socket, a shell panel). Risk: xdph blocks its main loop while
  the picker runs (upstream behaviour, also with the stock picker); a wrong answer cancels the share, never shares something
  else (tests feed the stand-in's output to a copy of xdph's parser, with one and two displays for `region:` coordinates);
  every wait on the shell is bounded (tests: `accepted` and no connection, a late `accepted` after the fallback, a shell that
  stops writing, `hyprctl` failing).

### D-7. A Grassfield print sheet for portal clients (category A; P11–P13; owner decision Q6)
- `grassfield-portal` also serves `org.freedesktop.impl.portal.Print` (`PreparePrint`, `Print`), listed before `gtk`.
  - `PreparePrint(parent_window, title, settings, page_setup, options)`: the macOS print sheet on the app's window: Printer
    pop-up (CUPS destinations, the default first, "Add Printer…" opening Settings > Printers), Presets (Default Settings, Last
    Used Settings), Copies, Pages (All, range), then Paper Size, Orientation, Scale, Two-Sided and Colour as the printer
    supports them (CUPS `cupsCopyDestInfo` options), "PDF" pop-up (Save as PDF… through the D-4 save panel), Cancel / Print;
    returns `settings`, `page-setup` and a token, as GTK's names them (the frontend passes them back to the app).
  - `Print(parent_window, title, fd, options{token})`: with a valid token, sends the document to CUPS without a sheet
    (`cupsCreateDestJob`/`cupsStartDestDocument`); without one (an app that sends the document first), the same sheet with a
    live preview of the document on the left, as macOS shows it.
  - Dependency: libcups, already installed with qt6-base and gtk3 on Arch (probe P14); printer discovery and job submission
    only, no PPD editing (Settings > Printers, PR #8, adds printers).
- Coverage: GTK 4 apps, GTK 3 apps' `GtkPrintOperation` with `GTK_USE_PORTAL=1` (D-8), Flatpaks. Not covered (their own or an
  in-process dialog, inventory § T): Chromium's and Firefox's preview and "system dialog", LibreOffice's VCL dialog, Electron,
  Qt apps' `QPrintDialog`. Known limitation, listed in the spec.
- Account and Create Application (P12, P13: sandboxed apps only, rare) stay x-d-p-gtk's and follow D-8.
- Fallback: as D-4 (forward to x-d-p-gtk's Print).
- Cost: medium-high (CUPS options model, sheet, preview of PDF/PostScript with Qt PDF already used by Preview). Risk: printer
  options vary widely; the sheet shows only the options CUPS reports and the job goes to CUPS unchanged otherwise.

### D-8. Toolkit appearance follows Grassfield, and the session routes GTK 3 to the portal (category C; T-rows)
Upstream facts (inventory § T, read in source): GTK 4.24 reads its settings on Wayland from the portal
(`gdk/wayland/gdksettings-wayland.c:443-540`) **only when it runs in a sandbox or `GDK_DEBUG` contains `portals`**; a plain
GTK 4 app outside a sandbox reads GSettings, i.e. the user's dconf (corrected in step 2b: step 0 read only the portal path;
measured with GTK 4.24.1 on a headless Weston, scenario 7 of `tests/integration/portal_settings.sh`: without the flag the app
keeps `Adwaita`, with it it takes the portal's theme and colour scheme live; decision 2b-1); libadwaita 1.10 reads
`color-scheme`, `accent-color` (snapped to its nine accents), `contrast` and `reduced-motion` from the portal
(`src/adw-settings-impl-portal.c:252-370`); Qt 6.11's `gtk3` theme reads the portal's `color-scheme` and `contrast` but takes
its palette from the in-process GTK 3 theme (`qgtk3storage.cpp:362-380, 595-640`); Chromium 155/156, Electron 43 and Firefox
158 read `color-scheme` and the RGB `accent-color` from the portal; LibreOffice and Flutter read `color-scheme`. GTK 3 reads
`gtk-theme` from dconf, or from the portal's `org.gnome.*` keys when `GTK_USE_PORTAL=1` (`gtk 3.24.52 gdk/gdk.c:479-496`,
`gdk/wayland/gdkscreen-wayland.c:714-804`, live through `SettingChanged`). x-d-p-gtk 1.15.3 publishes `color-scheme` and
`contrast` only, from the user's dconf (Omarchy's `prefer-dark`/`Adwaita-dark`), and no `accent-color`. The portal merges
Settings backends and the first listed wins per key (`xdg-desktop-portal src/settings.c:129-160`).

Decision:
- **A Grassfield Settings backend** (`org.freedesktop.impl.portal.Settings` in `grassfield-portal-settings`, the no-window
  process of D-4, listed before `gtk` by the session's `hyprland-portals.conf`:
  `org.freedesktop.impl.portal.Settings=grassfield-settings;gtk`) serves, live from the Grassfield settings file:
  - `org.freedesktop.appearance`: `color-scheme` (1 dark, 2 light; `auto` resolved with `AutoAppearance`'s schedule),
    `accent-color` (the Grassfield accent as sRGB; `multicolor`, the default, is Grassfield's own green, as
    `config/schema/grassfield.schema.json` defines it), `contrast` (Increase Contrast),
    `reduced-motion` (Reduce Motion);
  - `org.gnome.desktop.interface`: `gtk-theme` (the Grassfield GTK theme for the appearance and the accent, owner decision
    Q7: `Grassfield-<accent>` or `Grassfield-<accent>-dark`, with `-hc` before `-dark` under Increase Contrast (decision
    2b-2), CSS-only themes generated at build time from `ui/tokens/tokens.json` that import GTK's built-in Adwaita/Default
    stylesheet (HighContrast/Default-hc with `-hc`) and override only the accent and the selection colours (the radii stay
    GTK's, decision 2b-7); MIT, no copy of Adwaita), `color-scheme`, `enable-animations` (not Reduce Motion); every other key
    falls through to x-d-p-gtk (fonts and icons already come from the session dconf profile, ADR-0003 and ADR-0017).
  The backend has no window and stays running for the session (the frontend listens to its `SettingChanged`); it is started
  with the session, before the shell, and its unit has `Restart=on-failure` (`RestartSec=1`; counter-review of PR #13: without
  it, live appearance changes stopped after a crash until the next read). The frontend's proxy follows the bus name to the new
  process (xdg-desktop-portal 1.22.1 `src/settings.c:333-339`; GLib 2.90.1 `gio/gdbusproxy.c:1704-1734`). D-Bus activation
  also starts it at the next read (D-4); until then the frontend merges the other backends' values (x-d-p-gtk's). Tests: kill
  it, read again, get Grassfield's values back; kill it, change the settings file, the client receives `SettingChanged`.
- **`GTK_USE_PORTAL=1`** in the Grassfield session (`env-grassfield`): GTK 3 apps then read their theme from the portal and
  change with the appearance live, and their `GtkFileChooserNative`, `GtkPrintOperation` and colour picker go through the
  portal (Grassfield's panels for files). This covers evince, LocalSend, the GTK 3 parts of Qt's `gtk3` theme (Qt apps'
  palettes follow), LibreOffice's colours, udiskie and gcr-prompter while they remain. x-d-p-gtk unsets the variable for
  itself (`src/xdg-desktop-portal-gtk.c:231`), so it keeps reading dconf: its remaining dialogs (print, account) follow the
  user's GTK theme, not the Grassfield appearance (known limitation).
- **`GDK_DEBUG=portals`** in the Grassfield session (`env-grassfield`, added to the flags the user already has; step 2b,
  decision 2b-1): plain GTK 4 apps outside a sandbox then read their settings from the portal too (for files, print and
  open-with GTK 4 already uses the portal by default, inventory § T).
- **Not done:** `GTK_THEME` session-wide (it disables libadwaita's stylesheet, `adw-style-manager.c:454-470`, and freezes the
  theme); `QT_QPA_PLATFORMTHEME=xdgdesktopportal` (Qt apps would lose the GTK palette, fonts and icons for Fusion, "Sans Serif
  9" and hicolor on Hyprland, `qgenericunixtheme.cpp:69-72, 117-121`); writing the user's dconf.
- **Coverage of the Grassfield file panel that follows:** Chromium, Electron (Obsidian), Firefox, GTK 4 apps and Flatpaks
  already use the portal; with `GTK_USE_PORTAL=1` also GTK 3 apps that use the native chooser and LocalSend. Still in-process
  (GTK 3 `GtkFileChooserDialog`, themed by the above): Qt apps under the `gtk3` theme (Kdenlive, Grassfield's own Qt apps if
  they use QtQuick.Dialogs; they can call the portal directly), LibreOffice. **Owner decision Q3 (2026-10-27): portal apps +
  GTK 3 through `GTK_USE_PORTAL=1`; Qt keeps `gtk3`.**
- Cost: medium (a no-window D-Bus service, its unit, settings-file watching, tests on a private bus with the real frontend
  1.22.1 and fake backends; the 18 generated GTK themes and their contrast test; then the environment lines). Risk: GTK 3
  apps call the portal's `ReadAll` synchronously at start, so a hung Settings backend would delay their start (up to the
  frontend's D-Bus timeout): the backend answers from memory only, never blocks, has no GUI (D-4's start-up loop), and is
  covered by a start-time test; with the backend absent the frontend answers from x-d-p-gtk alone. On the owner's GTK 4.22
  (inventory § Method), plain GTK 4 apps do not read `accent-color` (GTK 4.24); libadwaita apps do.

**Delivered in step 2b.** `apps/portal-settings` (C++17, Qt Core and Qt D-Bus only; no window, no new dependency), installed
as `/usr/lib/grassfield/grassfield-portal-settings`, with `packaging/systemd/grassfield-portal-settings.service`
(`Type=dbus`, `ConditionEnvironment=GRASSFIELD_SESSION=1`, `Restart=on-failure`, `RestartSec=1`, at most 5 starts a minute,
`GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME` unset, hardened: `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectHome=read-only`, `PrivateTmp`, `PrivateNetwork`, `AF_UNIX` only, `@system-service` seccomp filter, no capabilities,
`MemoryMax=64M`, `TasksMax=8`), `packaging/dbus/org.freedesktop.impl.portal.desktop.grassfield_settings.service` (D-Bus
activation through the unit), and under `/usr/share/grassfield/xdg/xdg-desktop-portal/` the session's `hyprland-portals.conf`
(Settings only: `grassfield-settings;gtk`; every other interface keeps the stock file's routing, which the frontend still
reads per interface) and `portals/grassfield-settings.portal`. `env-grassfield` puts `/usr/share/grassfield/xdg` first in
`XDG_DATA_DIRS` (once, keeping the list or the default), sets `GTK_USE_PORTAL=1` and adds `portals` to `GDK_DEBUG`, all only
when the routing file is readable; `grassfield-shell.service` unsets `GTK_USE_PORTAL` (gate P5); `autostart.lua` starts the
backend after the Secret Service handover and before the shell. `ui/tools/gen-gtk-themes.py` generates the 36 themes at build
time (`/usr/share/themes/Grassfield-*`); `ui/tools/gen-tokens.py` writes the accents the backend publishes
(`apps/portal-settings/src/PaletteTokens.hpp`, checked by `--check`). The PKGBUILD builds, tests and installs every piece and
declares `xdg-desktop-portal` and `xdg-desktop-portal-gtk` (already installed by Omarchy; the session now relies on them).
- **What it publishes.** `org.freedesktop.appearance`: `color-scheme` (1 dark, 2 light; decision 2b-4), `accent-color` (the
  appearance's own accent, decision 2b-3), `contrast`, `reduced-motion`; `org.gnome.desktop.interface`: `gtk-theme`,
  `color-scheme` (`prefer-dark`/`prefer-light`), `enable-animations`. `Read` of a key it does not own answers
  `org.freedesktop.portal.Error.NotFound`, so the frontend asks x-d-p-gtk (fonts, icons, cursor). The file is watched
  (directory and file, atomic replaces included, 50 ms debounce) and `auto` is resolved again every minute (decision 2b-8);
  only the keys whose value changed are signalled; a missing or unreadable file means the schema's defaults (dark,
  multicolor); the directory is never created. At start, once its name is owned, it signals every value once (decision 2b-9).
- **The GTK themes.** One per accent, appearance and contrast; each imports GTK's own stylesheet from the GTK library's
  resources and then sets Grassfield's colours where that stylesheet draws its accent (selected rows and text, checked boxes,
  radios and switches, suggested buttons, progress bars, sliders, level bars, focus rings, selected tabs, menu items under
  the pointer, links), with the shell's colour roles (decision 2b-5); no CSS colour function (GTK 3 and the owner's GTK 4.22
  read them alike).
- **Tests.** Unit (`tests/unit/portal-settings`, 9 tests, plain and ASan/UBSan): values, the `auto` schedule, the accents
  from the tokens, the 36 theme names, the namespace filter, file changes signalled key by key, the clock, a missing file,
  the announcement at start. `tests/ci/gtk_themes.py`: 36 themes matching the backend's names, the imports, no copy of GTK's
  theme, no colour function, the colour pairs' contrast. `tests/integration/gtk_themes.sh`: the 36 themes rendered with GTK 3
  and GTK 4 on Xvfb against GTK's own four stylesheets as controls (none of GTK's blue left, every Grassfield colour present,
  no stylesheet error). `tests/integration/portal_settings.sh`: static checks of the routing, names, units, PKGBUILD and
  `env-grassfield`; then the real xdg-desktop-portal 1.22.1 on a private bus with the backend D-Bus-activated and a stand-in
  for x-d-p-gtk: values through the frontend, `SettingChanged` for the changed keys only, kill and reactivation by the next
  read, a change made while the backend is down delivered when it starts with no read, its memory within budget, x-d-p-gtk
  alone when the backend is absent, a fast start with a frontend that never answers, refusal outside the session; and on a
  headless Weston, GTK 3 (`GTK_USE_PORTAL=1`), GTK 4 (`GDK_DEBUG=portals`) and libadwaita apps following a change of
  appearance, accent and Increase Contrast within a second, with a GTK 4 app without the flag as the control.
- **Code quality.** `just check-tidy` covers the compositor only; a one-off clang-tidy run with the compositor's checks
  (`clang-analyzer-*`, `bugprone-*`, `performance-*`; LLVM 23.1) over the backend and its tests: the analyzer's one finding (the
  tests' never-deleted `QCoreApplication`) and the signed bit operations were fixed; what remains is Qt's idiom (static
  `QStringLiteral` and `QTime` constants, a `QDBusArgument` operator returning its argument, moc's enum).
- **Known limitations.** x-d-p-gtk's own dialogs (its file chooser until step 4, print until step 6, account) read the user's
  dconf, so they keep Omarchy's look; GTK 3 and GTK 4 apps that open a file or a link through the portal may meet
  x-d-p-gtk's app chooser where the portal asks (D-5 replaces it), as GTK 3 apps already did with Q3. The text highlight
  setting (`accent.highlight`) does not reach GTK apps: their selected text uses the accent (decision 2b-6). The light yellow
  accent's thin marks hold 2.0:1 against the window, as the shell's do. A GTK 3 or GTK 4 app the user starts with its own
  `GTK_THEME` keeps it. On the owner's GTK 4.22, plain GTK 4 apps do not read `accent-color` (4.24 does); the Grassfield
  theme carries the accent anyway.

**Decisions of step 2b** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **2b-1. Plain GTK 4 apps read dconf, not the portal.** Measured (scenario 7): outside a sandbox GTK 4.24 takes its
  settings from the portal only with `GDK_DEBUG=portals`. Options: (a) leave them on the user's dconf (Omarchy's theme, no
  live appearance); (b) write the user's dconf (forbidden: the owner's files); (c) `GDK_DEBUG=portals` in `env-grassfield`,
  added to the user's own flags. **Choice: (c).** GTK 4 apps then follow the appearance, accent and contrast live, as GTK 3
  apps do with `GTK_USE_PORTAL=1` (owner decision Q3, which took GTK 4 apps to read the portal already); the flag also makes
  GTK 4 prefer the portal where it would otherwise decide by itself (files, print and open-with already go there by default).
  libadwaita apps read the portal's appearance keys either way.
- **2b-2. Increase Contrast in GTK apps.** The themes import GTK's normal stylesheet, so publishing `contrast` alone reaches
  libadwaita only. Options: (a) only that; (b) an `-hc` variant of every theme, importing GTK's own high-contrast stylesheet
  (GTK 3 HighContrast and HighContrastInverse, GTK 4 Default-hc and Default-hc-dark) with the same Grassfield colours, named
  by the backend under Increase Contrast. **Choice: (b)**: on macOS Increase Contrast applies to every app. The colours stay
  (the shell's `contrastBoost` strengthens borders, separators and fills, not the accent; GTK's high-contrast stylesheet does
  the same). 36 themes instead of Q7's 18, by Q7's own rule (one theme per state the user can choose).
- **2b-3. Which accent colour.** Options: (a) one sRGB value in both appearances; (b) the appearance's own accent
  (`accentLight`/`accentDark`, as the shell draws it). **Choice: (b)**: macOS's accent colours have a light and a dark
  variant; a change of appearance signals `accent-color` too.
- **2b-4. The light appearance's colour scheme.** Options: (a) `0`/`default` (no preference); (b) `2`/`prefer-light`.
  **Choice: (b)**: macOS's Light appearance makes every app light; with no preference some apps choose dark.
- **2b-5. Colour roles in the themes.** Options: (a) one accent everywhere (GTK's own model); (b) the shell's roles
  (`Accent.js`): selection fills with the selection pair, thin marks with the accent, selected text with the highlight pair,
  the focus ring in the accent where it holds `control.focusRingMinContrast` against the window and in the text colour
  otherwise, links blue in every accent. **Choice: (b)**: GTK apps match the shell, and macOS draws links blue whatever the
  accent.
- **2b-6. The text highlight colour (`accent.highlight`).** Options: (a) themes per highlight colour too (324 themes);
  (b) GTK apps follow the accent (the setting's default, "automatic"); (c) a theme generated per user at run time.
  **Choice: (b)** for now: (a) fills the theme list of every GTK tool with hundreds of entries, (c) is a new mechanism (a
  writable theme directory in the search path) for a setting few change; a user who sets a highlight colour sees it in the
  shell and Grassfield's apps, and the accent's in GTK apps (known limitation, revisit with D-4's panel work).
- **2b-7. Radii.** Q7's text included the radii. GTK's stylesheets draw controls at 5 px (both versions) and the control
  token is 6 px, an estimate awaiting its F1 measurement; window corners already come from Hyprland's rounding for every
  window (ADR-0024 C-1). Options: (a) override every `border-radius` rule (dozens per version, joined buttons included);
  (b) keep GTK's. **Choice: (b)**: a 1 px difference on an unmeasured value does not justify rewriting GTK's geometry; revisit
  if F1 measures a control radius far from 5 px.
- **2b-8. When `auto` switches.** Options: (a) a timer set to the next switch time (the spec's first text); (b) the shell's own
  rule, a recheck every minute with `apps/autoappearance.h`. **Choice: (b)**: apps switch in the same minute as the shell, and a
  clock or time-zone change (suspend, NTP) needs no new timer. Cost: the file read once a minute, nothing sent when nothing
  changed.
- **2b-9. A change made while the backend restarts.** After a crash systemd starts it again within a second, but a change made
  in that second would reach no app until the next one. Options: (a) accept it; (b) the new process signals every value once
  when its name is owned. **Choice: (b)**: the missed change is delivered, and a value an app already has changes nothing
  (measured, scenario 7: after a restart GTK 3 and GTK 4 apps are told their theme name once more and keep their state,
  libadwaita is told nothing). Cost: one theme reload per running GTK app per restart, only after a crash.
- **2b-10. The backend's sandbox.** Unlike the handover (2c-6), the backend identifies no peer and reads one file of the
  user's, so the namespace options (`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, `PrivateNetwork`; in a user
  unit they imply `PrivateUsers=self`) cost it nothing. **Choice:** keep them. If the namespace cannot be set up, the unit
  fails and the frontend answers from x-d-p-gtk alone (the degraded behaviour above).
- **2b-11. Its memory budget.** Step 0 set "15 MB of RSS" (D-4, spec A-FC3) before anything was measured. Measured (Qt 6.12,
  the package's Release build, idle): 14.2 MB resident, of which 1.45 MB private; 12.7 MB are pages of shared libraries (Qt
  Core, ICU, libstdc++, libc) that every Qt process of the session maps already; after serving the frontend, 15.5 MB
  resident. Options: (a) keep 15 MB resident (failed by library pages the backend does not own); (b) budget what the
  backend adds: its private memory, with a resident ceiling. **Choice: (b)**: private ≤ 4 MB and resident ≤ 20 MB, checked
  by `tests/integration/portal_settings.sh` scenario 1; the unit's `MemoryMax=64M` stays the hard stop.

### D-9. Password and passphrase prompts (category S; S1–S9) — owner decision Q1, opus PASS required
Upstream facts (inventory § S, read in source): gnome-keyring 51.1, pinentry-gnome3 (Arch's `/usr/bin/pinentry` picks it first
on Wayland, probe P6) and gcr-ssh-agent all ask through gcr's system prompter: the session-bus name
`org.gnome.keyring.SystemPrompter`, object `/org/gnome/keyring/Prompter`, interface `org.gnome.keyring.internal.Prompter`
(`BeginPrompting`, `PerformPrompt(type "password"|"confirm", properties, exchange)`, `StopPrompting`), the client's callback
`PromptReady`/`PromptDone`, the password returned through the `sx-aes-1` exchange (unauthenticated DH, "does not protect
against active attacks like MITM", `gcr/gcr-secret-exchange.c:41`). Only gcr 3.41.2 ships the prompter
(`/usr/lib/gcr-prompter`, GTK 3, D-Bus activated, exits after 10 s idle); gcr-4 speaks the same protocol. **Name ownership is
the whole authorization**: any same-user process that holds the name receives every password typed into these prompts, and
any same-user process can make the stock prompter show caller-chosen text (clients ignore the sender,
`gcr/gcr-system-prompt.c:684-706`; the prompter accepts any client, `gcr/gcr-system-prompter.c:756-790, 868-950`; the
session bus lets anyone own any name). udiskie draws its own GTK 3 dialog unless its command line gives `--password-prompt`
(`udiskie/cli.py:303-362`, `prompt.py:232-243`). On the owner's machine prompts are rare: Omarchy keeps a plaintext default
keyring and removes `pam_gnome_keyring` from SDDM (probe P12); they appear for GPG (git signing, pass), a keyring the user
protected, an encrypted USB disk, a new keyring (libsecret creates "Default keyring" when the alias is missing).

Options:
- **S0. Keep the stock prompts, themed (D-8).** No new secret code. gcr-prompter and udiskie's dialog are GTK 3 and follow the
  Grassfield appearance through D-8 (light/dark live), but stay GNOME-shaped (GTK 3 Adwaita, its own layout). Cost: none
  beyond D-8. Risk: none added.
- **S1. A Grassfield prompter process that draws its own window.** `grassfield-prompter` (C++, Qt Quick, libgcr's
  `GcrSystemPrompter` for the protocol and the exchange, a `GcrPrompt` implementation for the UI) owns the name from the
  session's start. Cost: medium-high. Risk: a regular toplevel window can be covered or captured unless window rules pin it,
  keep its focus and hide it from screen sharing; a second security surface outside `shell/security/`.
- **S2 (recommended). The shell draws the prompt; a small bridge holds the name.**
  - **The bridge.** `grassfield-prompter`, C++/Qt 6 like the menu bridge (ADR-0008: QtCore, QtDBus, QtNetwork's
    `QLocalServer`), plus libgcr-4's `GcrSystemPrompter` for gcr's protocol and its `sx-aes-1` exchange (gcr is a C library;
    Qt's GLib event loop runs its callbacks). No C code of Grassfield's own (review of PR #13, minor). New library dependencies
    of a Grassfield binary: libgcr-4 (gcr-4, already installed: gnome-keyring depends on gcr and gcr-4, probe P15) and
    libsecret (already installed: pinentry depends on it, P15) for D-12's remembered passwords. No libnm:
    NetworkManager's and BlueZ's agent interfaces are plain D-Bus, spoken with QtDBus as Settings already does (ADR-0030).
  - **The name.** It owns `org.gnome.keyring.SystemPrompter` for the whole Grassfield session (requested without
    `ALLOW_REPLACEMENT`, so no process can take it over; queued behind a stock gcr-prompter that still holds it) and lets
    libgcr run the protocol and the exchange.
  - **The socket.** It hands each prompt to the shell over a private Unix socket (`$XDG_RUNTIME_DIR/grassfield/prompter.sock`,
    directory 0700, socket 0600), one JSON object per line, versioned (`prompter/1`); it accepts only a peer whose `SO_PEERCRED`
    uid is the user's and whose cgroup is `grassfield-shell.service`.
  - **One queue, no focus theft** (review of PR #13, MAJOR 5: the polkit sheet holds the keyboard exclusively,
    `shell/security/polkit/AuthAgent.qml:241`, and a second sheet must never take it while a password is being typed). The
    shell keeps one queue for every secret sheet and the polkit sheet: one sheet on screen at a time, in arrival order; a new
    request never takes the keyboard from a sheet on screen and is shown only when that sheet is answered or cancelled; a
    queued request whose caller gives up (gcr `StopPrompting`, NM `CancelGetSecrets`, BlueZ `Cancel`) leaves the queue without
    ever showing. At most 8 secret requests wait; a secret request beyond that is answered "cancelled". A polkit request is
    never refused by that bound and always queues (counter-review of PR #13, minor).
  - **Not a phishing tool.** A secret sheet never looks like the authorization sheet: no lock-and-shield glyph, no
    "Authentication required" title, a different header (the requester's own icon and name in a fixed top row), so an
    administrator password is never typed into it by habit. The requester is always shown and is never the caller's text. The
    bridge identifies the caller through the pidfd that `GetConnectionCredentials` hands out as `ProcessFD` (dbus-broker 37 and
    dbus-daemon 1.16.2 both provide it, probe P17), never through a bare PID (counter-review of PR #13, minor: a PID can be
    reused and a file name imitated): it reads the PID from the pidfd (`/proc/self/fdinfo/<fd>`), then `/proc/<pid>/exe`, then
    checks that the pidfd's process still runs, so the PID was not reused in between. It trusts only an absolute executable
    path whose file and parent directories belong to root and are not writable by the user, and maps it only to a desktop
    entry of the same kind (`/usr/share/applications`). Anything else (no `ProcessFD`, the process gone, an executable in the
    home or deleted) shows "Unidentified program" with the path in the secondary style. For gnome-keyring and gpg-agent, which
    ask on another app's behalf, the row says "Keyring" or "GnuPG" (their root-owned executables) and the caller's text names
    the app below it, in the secondary style. Caller text (title, message, description) is plain text,
    flattened and capped, under the fixed rows. Today's stock prompter shows caller text with no identity at all.
  - The sheet's surface (`grassfield-secret` layer namespace) is hidden from screen sharing by a session layer rule
    (`hl.layer_rule({ match = { namespace = "^grassfield-secret$" }, no_screen_share = true })`: layer rules accept
    `no_screen_share` in Hyprland 0.56.2, `src/desktop/rule/layerRule/LayerRuleEffectContainer.cpp:23`). Today no shell
    surface has that rule, the polkit sheet included (the first version of this ADR said otherwise: wrong); the step proposes
    the same rule for `grassfield-polkit`, under the same review.
  - Other polkit-sheet rules reused: nothing over the lock, held after an unlock without the keyboard until a click, the field
    cleared after each attempt, `ImhSensitiveData`.
  - **What can and cannot be wiped** (the spec's SC5, SC4 in the first version, reformulated): the typed password lives in QML
    strings that the JavaScript engine may copy and that cannot be zeroed; the shell clears the field and drops its references,
    sends the password once over the socket, and keeps no copy it controls. The bridge reads it into a buffer it zeroes after
    handing it to libgcr (which holds secrets in its own secure memory). Copies left in the shell's heap until reuse are a known
    limitation, the same as the polkit sheet's today.
  - udiskie: `grassfield-automount.service` passes `--password-prompt "/usr/lib/grassfield/grassfield-askpass udiskie
    {device_presentation}"`; the helper is a gcr client (libgcr `gcr_system_prompt_open`) that prints the password on stdout,
    so the same sheet draws it (or gcr-prompter when the bridge is down).
  - KIO network passwords (owner decision Q11): D-12.
  - Fallback, never blocking: when the shell is not connected, the bridge releases the name, so the next prompt activates the
    stock gcr-prompter (as today); it takes the name again when the shell reconnects. While it holds the name, the risk is no
    worse than today's (gcr-prompter frees the name 10 s after each prompt, so a queued process can already take it).
  - Wi-Fi secrets (owner decision Q10): the bridge also registers a NetworkManager secret agent on the system bus
    (`org.freedesktop.NetworkManager.AgentManager.Register("org.grassfield.prompter")`, interface
    `org.freedesktop.NetworkManager.SecretAgent`: `GetSecrets`, `CancelGetSecrets`, `SaveSecrets`, `DeleteSecrets`; NM 1.58.1
    introspection). Quickshell 0.3.x has none and no other agent runs in the session, so today NM fails with NoSecrets when a
    known network's password changed. `GetSecrets` for `802-11-wireless-security` (PSK, WEP) and `802-1x` (identity and
    password) becomes the macOS alert "The Wi-Fi network “Name” requires a WPA2 password." with Show password, Cancel / Join;
    the secret goes back to NM, which stores it as the connection says (system-owned by default, as Quick Settings' inline
    join does). The agent answers only calls whose sender is the current owner of `org.freedesktop.NetworkManager` on the
    system bus (review of PR #13, minor); any other caller gets an error and no sheet.
  - VPN secrets: NetworkManager does not show VPN dialogs itself; an agent such as nm-applet runs the VPN plugin's auth dialog
    (review of PR #13, minor: the first version said otherwise). This agent does not: it answers "no secrets" for VPN
    settings, so a VPN that needs secrets at connect time fails as it does today (no agent today). Known limitation.
  - When the shell is not connected the agent unregisters (NM then fails with NoSecrets, as today).
  - Out of scope here: SSH askpass (no agent and no askpass are set up by Omarchy; terminal ssh asks on its tty; inventory S5),
    KWallet's own Qt dialogs for KF6 apps other than Files (inventory K8); the BlueZ pairing agent is D-11, step 10.
  - **Requires the owner's amendment of the security rule** (owner decision Q12, 2026-10-27: the text below), applied in step 9
    only after the integrator's review and the owner's agreement on that step:
    - CLAUDE.md (Hard rules): "Security modules (shell/security/): WlSessionLock + PamContext("omarchy-lock-password") +
      Quickshell Polkit + the secret sheets fed by grassfield-prompter (ADR-0035: gcr system prompts, KIO network passwords,
      NetworkManager secrets, BlueZ pairing) only; opus reviewer PASS required; failures stay locked."
    - master-prompt R12 (new bullet): "The secret sheets of ADR-0035 belong to these modules. One queue holds every secret
      sheet and the polkit sheet; no sheet takes the keyboard from another; a secret sheet never looks like the authorization
      sheet; the requester shown is the one the bridge resolves from D-Bus credentials, never text from the caller."
    - ADR-0010: an amendment with the same scope and rules, referring to this D-9.
  - Also requires an opus PASS on the bridge, the socket protocol and the shell surface, and security tests on a private bus
    with a fake gcr client, a fake NM, a fake kpasswdserver client and a fake attacker queued on the name (never the real
    buses or real secrets): the polkit sheet keeps the keyboard while a gcr request arrives; a forged NM caller gets no sheet.
  - Cost: high (a C++ bridge with libgcr, a socket protocol, the shell's queue and sheets, tests). Risk: medium (new code on a
    secret path); mitigated by libgcr doing the protocol and the cryptography, the one queue, and the reviewed polkit patterns.
- **S3. Redirect only gnome-keyring** through its `GNOME_KEYRING_TEST_PROMPTER` variable
  (`daemon/dbus/gkd-secret-create.c:396-405`, `pkcs11/wrap-layer/gkm-wrap-prompt.c:1561-1572`). Rejected: a test hook, not
  an interface, and it misses pinentry and gcr-ssh-agent.

Recommendation: S2, delivered after D-8 has made the stock prompts follow the appearance (S0 is the state until then).
**Owner decision Q1 (2026-10-27): S2.** Q10: the NetworkManager secret agent is part of the same step. Q11: KIO's network
passwords too (D-12). Q12: the amendment text above.

### D-10. What Omarchy still shows (category D; O1–O11)
- **Screenshots (O1, O2, P8).** Re-wired now, replaced later (owner decision Q4, 2026-10-27):
  - step "screenshots": Grassfield's bindings call a Grassfield capture script instead of `omarchy-capture-screenshot`. It keeps
    grim and slurp (the selection stays a crosshair over the live screen, with Grassfield's colours passed to slurp: veil,
    border and selection from the tokens), names the file as macOS does (`Screenshot <date> at <time>.png`, translated),
    copies to the clipboard and posts a Grassfield notice with the image and "Open in Preview"; no Omarchy shortcut is named,
    no `tensaku`. A click without a drag picks the window under the pointer (slurp's rectangle list, as Omarchy's "smart"
    mode does); Esc cancels. Saved to the Desktop as on macOS (**owner decision Q4**; Omarchy saves to Pictures).
  - later chantier (own ADR): the macOS capture toolbar (Shift-Cmd-5: screen, window, selection, recording, Options) and the
    floating thumbnail, drawn by the shell; recording then replaces Omarchy's `gpu-screen-recorder` path.
- **Migrations and updates in a terminal (O3, O4):** accepted. They are Omarchy's maintenance tools running in a terminal, as
  a command-line update is on macOS; the Grassfield path is Software Update (ADR-0033), whose own sheet asks the questions.
- **Omarchy menus (O5):** nothing opens (verified by code: the stand-in `omarchy-shell` fails as Omarchy's wrapper does);
  accepted.
- **Omarchy notifications (O6):** accepted: they arrive as Grassfield banners; the only frequent one, the screenshot notice,
  goes away with the re-wiring above.
- **fcitx5 (O8), hyprpicker (O9, P9):** accepted for 1.0, listed as known limitations (fcitx5's theme is chosen in the user's
  own fcitx5 config; hyprpicker shows only a loupe).
- **Omarchy's theme inside Chromium and Obsidian (O10):** documented; Grassfield never writes those apps' files.

### D-11. Bluetooth pairing sheet (inventory O7; category A + S; owner decision Q9: in this chantier, after the eight other steps)
- Today Omarchy's `bt-agent -c NoInputNoOutput` accepts Just Works pairing silently in both sessions, and a device that needs a
  code or a PIN fails (Settings registers no `Agent1`, PR #8).
- `grassfield-prompter` (D-9) registers a BlueZ agent on the system bus (`org.bluez.AgentManager1.RegisterAgent(path,
  "KeyboardDisplay")`, then `RequestDefaultAgent`) and implements `org.bluez.Agent1`: `RequestPinCode` and `RequestPasskey`
  (a field), `DisplayPinCode` and `DisplayPasskey` (the code to type on the device), `RequestConfirmation` (the macOS
  "Connection Request from “Name”": the code, Cancel / Connect), `RequestAuthorization` and `AuthorizeService` (an incoming
  pairing or service: Decline / Connect, never automatic), `Cancel`, `Release`. The shell's secret sheet (D-9) draws them, in
  the same queue. The agent answers only calls whose sender is the current owner of `org.bluez` on the system bus (review of
  PR #13, minor); any other caller gets `org.bluez.Error.Rejected` and no sheet.
- Omarchy's agent is kept out of the Grassfield session with a packaged drop-in
  `/usr/lib/systemd/user/bt-agent.service.d/10-grassfield.conf` (`ConditionEnvironment=!GRASSFIELD_SESSION=1`), the pattern of
  `omarchy-sleep-lock.service.d`; the Omarchy session keeps it.
- Fallback: shell not connected → the agent unregisters; BlueZ then has no agent and refuses pairings that need one (UNVERIFIED:
  BlueZ's behaviour for Just Works without any agent, checked in the step; if it refuses, the step keeps bt-agent as the
  fallback agent instead of the drop-in).
- Requires the same CLAUDE.md amendment and an opus PASS (a PIN is a secret; an incoming authorization is a security
  decision). Tests on a private system-bus fake of BlueZ.
- Cost: medium. Risk: agent precedence between two agents (UNVERIFIED, inventory O7), adapter pairable/discoverable state
  (Settings' Bluetooth pane, PR #8, owns discovery).

### D-12. KIO's and KWallet's dialogs in Grassfield's own apps (category A + S; inventory K1–K8; owner decision Q11)
Upstream facts (inventory § K, KIO and KWallet v6.31.0): `grassfield-desktop` depends on kio (`packaging/arch/PKGBUILD:136`),
which depends on kwallet (probe P15). Files runs its jobs with KIO's default widget delegate (`apps/files/src/filesapp.cpp:62-67`),
so KIO's Qt-widget dialogs (file exists, skip, certificate, Open With) appear inside a Grassfield app, and the D-4 panel built
from Files' sources would inherit them. Network passwords come from KIO's password server `org.kde.kpasswdserver6`
(`src/core/kpasswdserverclient.cpp:31`), D-Bus activated as kiod6 (P15): KDE's `KPasswordDialog`
(`src/kpasswdserver/kpasswdserver.cpp:759-787`), with remembered passwords in KWallet's network wallet (`:250-254, 425,
472-481, 952-955`), which brings KWallet's first-use wizard and wallet password.

Options (asked 2026-10-27, recommended first):
- **K1. Grassfield takes them.** (a) Files and `grassfield-portal` set a Grassfield UI delegate on each job they start, as Files
  already sets KIO's (`apps/files/src/filesapp.cpp:62-67`), with Grassfield implementations of KIO's delegate extensions as its
  children (`AskUserActionInterface`, `OpenWithHandlerInterface`, `UntrustedProgramHandlerInterface`,
  `OpenOrExecuteFileInterface`); KIO finds them through the job, its parent job or its composite job
  (`KIO::delegateExtension`, `src/core/jobuidelegatefactory.h:102-126`). Not `KIO::setDefaultJobUiDelegateFactory`: it is
  marked Internal and KIOWidgets registers its own factory through it (`:85-92`; counter-review of PR #13, minor). The sheets:
  the macOS "An item named “X” already exists" alert (Keep Both / Stop / Replace, Apply to All), the skip sheet, the
  certificate sheet (Cancel is the default button; Continue accepts for 30 minutes, as KIO's "Current Session only",
  `src/widgets/sslui.cpp:96-106`; a permanent rule only when the user ticks "Always trust “host”", unticked every time), the
  D-5 Open With sheet, and a refusal for executables (Files' `LaunchGuard` already decides first). (b) In step 9,
  `grassfield-prompter` also owns `org.kde.kpasswdserver6` (path `/modules/kpasswdserver`, interface `org.kde.KPasswdServer` with `checkAuthInfoAsync`,
  `queryAuthInfoAsync`, `addAuthInfo`, `removeAuthInfo` and their result signals, `src/core/org.kde.KPasswdServer.xml`) and
  shows the D-9 secret sheet ("Enter your name and password for the server “X”", Remember this password); remembered
  passwords go to the Secret Service through libsecret, never through KWallet's API, so no KDE password dialog and no KWallet
  wizard appear for KIO in a Grassfield session; the Secret Service stays gnome-keyring's there (Q17-b, below). Unlike
  kpasswdserver, which broadcasts its results, credentials included, to every listener on the session bus
  (`src/core/org.kde.KPasswdServer.xml:4-15`, `src/kpasswdserver/kpasswdserver.cpp:330, 852, 883`), the bridge sends each result
  to the caller's unique name only (a cached credential still goes to any same-user caller that names its URL, as today:
  upstream protocol, known limitation). It stores
  with libsecret's asynchronous calls and answers `addAuthInfo` at once: storing into a locked keyring makes gnome-keyring ask
  through gcr's prompter, which is the bridge, so a synchronous store would wait on itself (counter-review of PR #13, minors).
  Caveat shown in the
  spec: Omarchy's default keyring is unencrypted (probe P12), so a remembered network password is stored in clear on disk
  until the user protects the keyring (macOS encrypts the login keychain). Fallback: bridge down → D-Bus activation starts
  kiod6 (KDE's dialog, as today).
- K2. Grassfield delegates for Files' own dialogs only; KDE's password dialog stays (themed); KWallet disabled for the session
  by a session-only `kwalletrc` (`[Wallet] Enabled=false` in a Grassfield `XDG_CONFIG_DIRS` entry; the key is read by
  `KWalletDLauncher`, `src/api/KWallet/kwallet.cpp:872-884`; the user's own `kwalletrc` wins), passwords remembered for the
  session only.
- K3. KDE's dialogs kept, themed only (D-8).

**Owner decision Q11 (2026-10-27): K1** ("Grassfield les prend"). Delivery: (a) with the Files library split of step 4 (no
secret involved); (b) in step 9, under the same amendment (Q12 names "KIO network passwords") and opus review. KF6 apps other
than Files keep their own delegates (inventory K8, themed); their network passwords also reach the bridge while it owns the name.
Cost: (a) medium, (b) medium (five methods and two signals, the `KIO::AuthInfo` serialisation, the per-window cache rules of
`kpasswdserver.cpp`, tests against a fake KIO worker client). Risk: (b) is a second protocol on the secret path: same queue,
same identity rules, same opus review as D-9.

**Who holds the Secret Service** (found after the owner's answers to Q1–Q16; inventory S12, probe P16; owner decision Q17).
Nobody owns `org.freedesktop.secrets` at login in either session: Arch enables only gnome-keyring's control socket, its
service stays disabled, and Omarchy starts nothing (P16); D-Bus activates gnome-keyring on first use (P4). KWallet's
`ksecretd` requests the same name whenever it starts and the name is free
(`src/runtime/ksecretd/kwalletfreedesktopservice.cpp:155-158`, on by default), and it starts with any KWallet client:
today, Files opening an `sftp:` or `smb:` location that needs a password is enough (kpasswdserver → kwalletd6 → ksecretd,
inventory S12). Neither daemon queues for or takes over the name (Qt's `registerService` defaults, qtbase
`src/dbus/qdbusconnectioninterface.h:63-65`), so the first one keeps it for the session, and Chromium's saved passwords
(Omarchy's `--password-store=gnome-libsecret`) and every libsecret client follow it, with KWallet's wizard and wallet
password (K2) in place of the keyring prompts. Read in source, not run (UNVERIFIED in the inventory). With K1 (b) in step 9,
Files no longer starts KWallet, but other KF6 apps (K8) and the fallback to kiod6 still can. Options (asked 2026-10-27,
recommended first):
- Q17-a (recommended). The Grassfield session starts gnome-keyring's Secret Service with the session (D-Bus `StartServiceByName` of
  `org.freedesktop.secrets` from a Grassfield unit gated by `GRASSFIELD_SESSION=1`, before the shell), so gnome-keyring,
  the keyring Omarchy sets up, always holds it; ksecretd keeps only its own compatibility name. No owner file is written.
  Cost: one small unit and a test; gnome-keyring then runs for the whole session (it asks nothing until an app reads a
  secret). Risk: none known.
- **Q17-b (chosen).** A session-only `kwalletrc` with `[org.freedesktop.secrets] apiEnabled=false` in a Grassfield
  `XDG_CONFIG_DIRS` entry (`src/kwalletsettings.kcfg:49-53`; the user's own `kwalletrc` wins): ksecretd never takes the name.
  A new configuration directory for the session.
- Q17-c. Kept as is: a known limitation.
**Owner decision Q17 (2026-10-27): Q17-b** (« Bloquer KWallet », not the recommended option), **delivered with step 2**
(« Avec l'étape 2 (Recommandé) »). What step 2 adds:
- `/usr/share/grassfield/xdg-config/kwalletrc`, two lines: `[org.freedesktop.secrets]` and `apiEnabled=false`;
- in `env-grassfield`, `XDG_CONFIG_DIRS="/usr/share/grassfield/xdg-config:${XDG_CONFIG_DIRS:-/etc/xdg}"`, only when the file is
  readable (the pattern of the dconf and fontconfig lines), so `/etc/xdg` stays in the list; uwsm exports it to the systemd
  user manager and the D-Bus activation environment, where ksecretd starts (handle 5).
Effects: in the Grassfield session ksecretd keeps only `org.kde.secretservicecompat` (`kwalletfreedesktopservice.cpp:155-161`),
so `org.freedesktop.secrets` is always gnome-keyring's, started by D-Bus activation on first use (P4); KWallet's own API
clients (kiod6 until step 9, KF6 apps, K8) keep KWallet and its dialogs (K2). KConfig reads `XDG_CONFIG_DIRS` below the
user's `~/.config`, so a user `kwalletrc` that sets the key wins (the owner's choice; nothing is written there). The Omarchy
session is unchanged. Tests (step 2): a static test of the file and the environment line; `kreadconfig6 --file kwalletrc
--group org.freedesktop.secrets --key apiEnabled` with the session's `XDG_CONFIG_DIRS` and an empty `XDG_CONFIG_HOME` prints
`false`; on a private bus of the test's own (its own configuration with an empty service directory, `dbus-daemon` under
`env -i`, a unix socket else loopback TCP, a SKIP when libdbus cannot reach it), with a temporary `HOME` and
`QT_QPA_PLATFORM=offscreen`, the real ksecretd started with the session's `XDG_CONFIG_DIRS` owns
`org.kde.secretservicecompat` and not `org.freedesktop.secrets`. No nested check:
a nested session shares the owner's session bus, whose activation environment is not the Grassfield one.
Delivered in step 2a: `packaging/xdg-config/kwalletrc`, the `env-grassfield` block (added once, `/etc/xdg` kept) and the
PKGBUILD line; `tests/security/kwallet_secret_service.sh` (headless) runs the checks above and a control: on a private bus
the real ksecretd started without the session's directory owns `org.freedesktop.secrets`, which confirms the takeover of
inventory S12 at runtime, and with it does not. Checked with KWallet 6.31.0 (the container) and with the owner's 6.29.0
(the integrator, on the reference machine: the user's own `kwalletrc` still wins, uwsm exports `XDG_CONFIG_DIRS` with
`/etc/xdg` kept, dbus-broker 37 passes it to the activated ksecretd). gnome-keyring is now the session's only Secret
Service, so `grassfield-desktop` declares it (`packaging/arch/PKGBUILD`; until now only the `omarchy` package pulled it):
libsecret clients such as Chromium always find a keychain and never fall back to plain-text storage (integrator review of
PR #20).

**Q17-b follow-up: the handover** (integrator review of PR #20; decision delegated by the owner on 2026-10-27: macOS first,
no technical intervention for the user). Step 2a stops new takeovers; two cases remain, and the spec lists both as known
limitations until step 2c ships:
- **Secrets saved while KWallet held the name stay in KWallet.** What the user sees: apps that saved through libsecret in a
  session where ksecretd held the name find nothing in the keychain. Chromium is the visible case: its "Chrome Safe Storage"
  key is in KWallet, so at its next start it creates a new key in the keychain, its saved passwords no longer appear and
  sites sign the user out (cookies encrypted with the old key cannot be read). Nothing is deleted: KWallet keeps the items.
- **A ksecretd left over from an earlier session keeps the name.** The user manager, and the session bus with it, can
  outlive a logout (a session switch, a quick log-in again, lingering); a ksecretd started there before step 2a, or in the
  Omarchy session, still owns `org.freedesktop.secrets`, and the Grassfield session behaves as before step 2a until it ends.
- Options: (a) a one-time handover by Grassfield at the session's start; (b) document a manual move (a terminal and a tool
  for the user, against the rule); (c) keep KWallet as the Secret Service for users who already have items there (KDE
  dialogs, against Q17-b). **Choice: (a).** Design, for **step 2c**, delivered right after 2a and before 2b to keep short
  the time in which Chromium can create a new key:
  - `grassfield-secrets-handover`, a one-shot user unit of the Grassfield session (`ConditionEnvironment=GRASSFIELD_SESSION=1`),
    started before the shell, so before any app the user opens from the Dock;
  - leftover: when the owner of `org.freedesktop.secrets` is ksecretd (identified from the bus's `ProcessFD` and its
    root-owned executable `/usr/bin/ksecretd`, as D-9 identifies callers), it asks ksecretd to quit; KWallet's own clients
    start it again through `org.kde.secretservicecompat`, now with the session's setting, and the next libsecret call
    activates gnome-keyring. Nothing is shown;
  - move, once per user (a marker under `$XDG_STATE_HOME/grassfield/`): it lists the items of KWallet's Secret Service
    collections through `org.kde.secretservicecompat` and copies into the login keychain each item the keychain does not
    already hold (same attributes), keeping KWallet's copy. It never overwrites an item the keychain holds: a Chromium that
    already created a new key keeps it, and the passwords saved under the old one stay unreadable (a known limitation).
    When it moved something it posts one Grassfield notice (its words: decision 2c-2 below); when KWallet's wallet is
    locked, KWallet asks for its own password once (its dialog; K2), and a refusal leaves everything as it was and asks
    again at the next session;
  - security: it reads secrets, so it runs only as the user, logs no item and no value, holds secrets only for the copy, and
    needs an opus PASS; tests on a private bus with a fake KWallet compatibility service and a fake keychain (never the
    owner's buses or secrets): a leftover ksecretd made to quit, items copied once, an existing item never overwritten, a
    locked wallet left untouched.

**Delivered in step 2c.** `apps/secrets-handover` (C++17, Qt Core and Qt D-Bus only; no window, no new dependency),
installed as `/usr/lib/grassfield/grassfield-secrets-handover`; `packaging/systemd/grassfield-secrets-handover.service`;
one `systemctl --user start` in `config/hypr/grassfield/autostart.lua`, after the menu bridge and before the shell.
- **Two phases, one unit.** The unit is `Type=notify`. Phase 1 runs before readiness: when ksecretd owns
  `org.freedesktop.secrets` it is asked to quit (KDBusService's `org.qtproject.Qt.QCoreApplication.quit` on
  `/MainApplication`, 1 s), and when the name is still held 3 s later it gets SIGTERM through its pidfd
  (`pidfd_send_signal`: never another process that reused the PID), 2 s more; readiness follows once the name has a new
  owner or none, about 6 s at worst. A ksecretd whose file a KWallet upgrade replaced since it started (`/proc/<pid>/exe`
  says "`/usr/bin/ksecretd (deleted)`", the old file root's with no link left) is recognised for this quit only, never as
  a peer for secrets. `systemctl --user start` returns at readiness,
  so the shell starts after phase 1, and never more than 10 s late (`TimeoutStartSec=10`; on a timeout the unit fails, the
  `;` chain goes on and the shell starts). Phase 2, the move, goes on in the background (at most 15 min, `RuntimeMaxSec`).
- **Peers are checked, not trusted by name.** Each peer is identified from the bus (`GetConnectionCredentials`:
  `ProcessFD`, a pidfd; its PID read from `/proc/self/fdinfo`, then `/proc/<pid>/exe` opened and `fstat`ed, and the pidfd
  checked again after that read): KWallet's name must be held by `/usr/bin/ksecretd`, the Secret Service by
  `/usr/bin/gnome-keyring-daemon`, each running as the user, the same file (device and inode, not the name the link
  shows), a root-owned regular file in root-owned directories that neither group nor others can write. Otherwise nothing is
  read, written or stopped, and the move waits for the next session. A bus without `ProcessFD` (dbus-broker 37 and
  dbus-daemon 1.16 have it, P17) identifies nobody: nothing moves. Neither daemon has file capabilities on Arch
  (gnome-keyring 51.1 ships no `setcap`; `getcap` prints nothing), so both stay dumpable and their `exe` readable by the
  user (checked in the container with the real daemons). A name is started by D-Bus only when nobody owns it:
  `StartServiceByName` fails for a name that has no service file even while it is owned (dbus-daemon looks for the file
  first), as for a gnome-keyring started by PAM or by hand (found by the test with the real gnome-keyring).
- **What moves.** Every item KWallet lists that a lookup can find, i.e. that has attributes (decision 2c-10): what
  libsecret clients saved, KWallet's own entries (kwalletd stores them through libsecret, schema `org.qt.keychain`:
  `server`, `user`, `type`, and libsecret 0.21 adds `xdg:schema` even with `SECRET_SCHEMA_DONT_MATCH_NAME`; KWallet
  `src/runtime/kwalletd/secretserviceclient.cpp`, checked by storing such an item in the real gnome-keyring 51.1 with
  libsecret 0.21.8), and the entries of older KWallet versions, which ksecretd lists with `server`, `user`, `type` only
  once the wallet is open (`src/runtime/ksecretd/kwalletfreedesktopcollection.cpp`, `onWalletChangeState`). KWallet keeps
  its copies. A locked wallet's listing may therefore miss entries: "nothing" and "present" are final only from an open
  wallet (a locked one defers, without a question), and after KWallet's question the list is read again. The keychain's
  default collection is used (alias `default`), created as libsecret creates it when there is none (`CreateCollection`,
  gnome-keyring's own password question). Each value goes `GetSecret` → `CreateItem` (`replace` false) with the same label
  and attributes, each reply's signature checked; an empty value is never copied (a copy made now would never be replaced:
  the item stays in KWallet, counted as skipped), and the helper's copy of the value is zeroed right after. Items with the
  same attributes (two wallets, a client that saved twice) are one entry for any lookup: only the most recently changed one
  (`Modified`) moves (decision 2c-8).
- **One question at most, ever** (decision 2c-9). Before the first password question (KWallet's unlock, the keychain's
  unlock or creation, a keychain prompt on `CreateItem`) the marker says `asked`. A question refused, or not answered
  within 5 minutes (then dismissed), ends the handover for good (`declined`), with one notice: "Saved passwords not
  moved" / "Passwords that apps had saved elsewhere on this computer stay where they were. Apps that used them may ask you
  to sign in again." (French in the catalogue). An error after a question ends it too (`incomplete`); without a question an
  error leaves no marker and the next session tries again, asking nothing more than it would have.
- **The user's own choice.** A user `kwalletrc` that sets `[org.freedesktop.secrets] apiEnabled` true gives the Secret
  Service back to KWallet (KConfig reads it above the session's file, step 2a): the helper then does nothing at all, no
  quit, no move, no marker (decision 2c-7).
- **Marker and log.** `secrets-handover` in the unit's `$STATE_DIRECTORY` (`StateDirectory=grassfield`, i.e.
  `$XDG_STATE_HOME/grassfield`, mode 0700 as the shell keeps it), mode 0600 (`UMask=0077`), one line with the outcome and
  counts only (`moved moved=2 kept=1 skipped=0`; `nothing`, `present`, `no-kwallet`, `declined`, `incomplete`); the
  helper's output and the journal say only counts and which peer was refused. `QDBUS_DEBUG`, which makes Qt print every
  D-Bus message with its arguments, is unset by the unit and again by the helper. Secret values pass through its memory, so
  it makes itself non-dumpable first thing (`prctl(PR_SET_DUMPABLE, 0)`: no core file, no ptrace by the user's other
  processes; its own `/proc/self/fdinfo` stays readable) and the unit sets `LimitCORE=0` and `MemorySwapMax=0`. Without a
  wallet file (`~/.local/share/kwalletd/*.kwl`) nothing is asked of KWallet at all.
- **Hardening.** Runs as the user; `NoNewPrivileges`, `RestrictAddressFamilies=AF_UNIX`, `RestrictNamespaces`,
  `SystemCallFilter=@system-service`, `LockPersonality`, `RestrictRealtime`, `RestrictSUIDSGID`, an empty capability set,
  `MemoryMax=96M`, `TasksMax=16` (`systemd-analyze security`: 3.3 OK); no option that puts a user unit in a user
  namespace of its own (decision 2c-6). Outside a Grassfield session it refuses (exit 2). The overrides of the executables
  and timeouts that the tests use are honoured only in a dev session (ADR-0019), and a dev run refuses any bus but a
  private test bus (`GF_TEST_BUS=1`, the address under `GF_TEST_BUS_DIR`, the rule of the fakes): never the owner's bus.
- **Tests.** `tests/unit/secrets-handover/tst_logic.cpp` (logic, GTest, also under ASan and UBSan): which items move, the
  wallet test, the marker and its directory, the user's own `kwalletrc`, the dev run's bus, which executables are trusted,
  peers compared by inode, a replaced ksecretd recognised only for its quit (the executable checks skip, with their
  reason, where `/usr/bin` is not root's: a sandbox in a user namespace without root). `tests/integration/secrets_handover.sh`
  (headless, run by `scripts/dev/test.sh`): the helper against fakes (`tests/fixtures/fake-secret-service.py`, which refuse
  any bus but a private one, and store KWallet's own entries as kwalletd 6.29 does) on a private bus of the test's own,
  started by D-Bus activation as in the session: no wallet; the move (KWallet's own entry with the rest, an item already in
  the keychain kept, one notice, the marker, readiness before the end of the move, the helper not dumpable); a second
  run; a question refused or not answered (nothing created, `declined` for good with its notice, the next login asks
  nothing); KWallet's own entries alone; an empty open wallet (`nothing`) and an empty locked one (not final, nothing
  asked); an older entry listed only once the wallet is open (moves after the second listing); an empty value (skipped);
  no default keychain (created, then filled); a leftover that quits; one that ignores quit and gets SIGTERM; a holder that
  is another program, and a genuine KWallet with a Secret Service that is not gnome-keyring (nothing asked, read or
  written); the refusal outside a session; both notices in French; two items with the same attributes (the newest moves);
  the user's own `kwalletrc` (nothing done); a dev run on another bus (refused); the marker in `$STATE_DIRECTORY`; the
  helper in a user namespace like the one `PrivateUsers=self` makes (no peer identified, nothing done; SKIP where
  unprivileged user namespaces are not allowed); **the real gnome-keyring** (unlocked with a throwaway password in the
  scratch home) as the keychain, read back through libsecret, and **the real ksecretd** as the leftover, quitting when
  asked (each SKIP when absent); no item, label or value in any output. `tests/shell/session_services.sh` checks the unit
  (none of the namespace options; `LimitCORE=0`, `MemorySwapMax=0`, `QDBUS_DEBUG` unset), its place in `autostart.lua`
  and the PKGBUILD. `just check-tidy` covers the compositor only; a one-off clang-tidy run with the compositor's checks
  (`clang-analyzer-*`, `bugprone-*`, `performance-*`) over the helper found no analyzer finding (spec SC10).
- **Known limitations.** An app the user opens while the move waits for an answer to KWallet's password question, or an
  app of Open at Login (started by uwsm's XDG autostart target alongside the shell), may find nothing in the keychain and,
  for Chromium, create a new key; the move then keeps the keychain's item (never an overwrite). A move cut short without
  a question (a peer that is not who it should be, an error) leaves what was copied in the keychain: the next session
  finds those items there, keeps them and copies the rest; after a question it ends for good (decision 2c-9), and what
  did not move stays in KWallet. A locked wallet whose entries ksecretd has never listed (only entries of an older KWallet,
  never opened since) lists nothing: the handover waits, asking nothing, until a KWallet client opens the wallet in some
  session. The values cross the user's own session bus in `plain` Secret Service sessions (decision 2c-4). A leftover
  from a KWallet older than ksecretd (`kwalletd6` itself holding the name) is not recognised and keeps the name until its
  user manager stops. While the wallet stays locked and lists nothing, the handover is not final: it starts ksecretd at each
  login to list again (no question, nothing shown), for as long as the wallet stays that way
  (decision 2c-11). A logout, or a crash, while KWallet's or the keychain's question is on screen ends the handover for good
  (the marker already says `asked`, decision 2c-9) without the notice; what was not moved stays in KWallet.

**Decisions of step 2c** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **2c-1. When are the password questions asked?** Options: (a) unlock KWallet and the keychain at every session until the
  move is done; (b) only when there is something to move. **Choice: (b).** ksecretd lists items and their attributes while
  the wallet is locked (it keeps them in `<wallet>_attributes.json`), so KWallet's question appears only when an item must
  move, and the keychain's only when the keychain is locked or does not exist yet. A user with nothing to move sees nothing.
  Corrected after the integrator's review of fbfe34d: the first version kept KWallet's own entries out, believing they had
  no `xdg:schema` (2c-10), and concluded "nothing" from a locked listing, which can miss entries (now: not final, see "What
  moves").
- **2c-2. The notice's words.** Options: (a) "Saved passwords were moved to your keychain." (the design above); (b) name
  KWallet; (c) say what changed without naming either store. **Choice: (c)**: title "Saved passwords moved", text
  "Passwords that apps had saved elsewhere on this computer are now kept with your other saved passwords." (French in
  `translations/grassfield_fr.ts`). Rule applied: "keychain" is the Apple product's word, which the UI does not use
  (CLAUDE.md), and the user never chose KWallet (ksecretd took the name silently, S12), so its name explains nothing; the
  notice says what the user can rely on, as macOS's notices do.
- **2c-3. What does the shell wait for?** Options: (a) nothing (the helper runs beside the shell); (b) the whole move;
  (c) phase 1 only, 10 s at most. **Choice: (c).** With (a) a Dock click in the first second can still reach a leftover
  ksecretd; with (b) the desktop would wait for the user's answer to KWallet's question. Phase 1 takes well under a second
  when ksecretd quits (about 6 s at worst, when it ignores quit and SIGTERM).
- **2c-4. How do the values travel?** Options: (a) `plain` Secret Service sessions; (b) `dh-ietf1024-sha256-aes128-cbc-pkcs7`
  (libsecret's default), which needs a cryptography library in the helper. **Choice: (a).** Both peers and the helper are
  the user's own processes on the user's own session bus; a process that could read that traffic runs as the user and could
  read the keychain's files or the helper's memory anyway. No new dependency (CLAUDE.md).
- **2c-5. A leftover ksecretd that does not quit.** Options: (a) leave it (the session behaves as before step 2a until it
  ends); (b) SIGTERM after 3 s. **Choice: (b)**, through the pidfd that identified it. KWallet's own clients start it again
  through `org.kde.secretservicecompat`, with the session's setting.
- **2c-6. The unit's sandbox** (security review of the first version). In a user unit, `ProtectSystem=`, `ProtectHome=`,
  `PrivateTmp=`, `PrivateNetwork=` and the other mount, network and kernel protections make systemd add
  `PrivateUsers=self` (systemd `src/core/exec-invoke.c`, `exec_context_need_unprivileged_private_users`). In that user
  namespace root's files show the overflow uid, and above all `/proc/<pid>/exe` of a process outside it cannot be read
  (EACCES: the kernel lets a process read another's only from the same user namespace), so the helper could identify no
  peer and would never move anything (measured: in a namespace that maps only the user, the first version deferred every
  run and quit nothing). Options: (a) keep that sandbox and identify peers by name, command line or cgroup, which any of
  the user's processes can claim; (b) give up the identity checks; (c) keep the identity checks and harden without
  namespaces (`NoNewPrivileges`, seccomp filters, `AF_UNIX` only, no capabilities, memory and task limits). **Choice: (c).**
  Rule applied: no technical intervention for the user means the passwords must reach the keychain and only ksecretd may
  be stopped, which needs the identity of both peers; the helper writes one file and talks only D-Bus, so a read-only view
  of the file system adds less than that identity. `tests/shell/session_services.sh` keeps every option of systemd's list
  out of the unit, and the integration test shows the namespace case refusing.
- **2c-7. A user who chose KWallet.** Options: (a) run the handover anyway (it would quit the user's ksecretd at every
  login, and the move would wait forever for a keychain it never finds); (b) do nothing when the user's own `kwalletrc`
  turns KWallet's Secret Service on. **Choice: (b)**, as step 2a lets that file win: it is the user's explicit choice.
- **2c-8. Two KWallet items with the same attributes.** Options: (a) move both (the keychain then holds two items that
  answer the same lookup, and Chromium may take the wrong key); (b) move none; (c) move the most recently changed one and
  leave the others in KWallet. **Choice: (c)**: what the app last saved is what it expects to find.
- **2c-9. How often may the handover ask?** (integrator decision in the review of fbfe34d, macOS model.) Options: (a) ask
  again at each login until the move succeeds (the first version: KWallet's KDE dialog came back at every login for a user
  who refused, or no longer knows the old wallet's password); (b) at most once. **Choice: (b)**: a refused or unanswered
  question ends the handover for good (`declined`) with one plain notice; an error after a question ends it too
  (`incomplete`); the marker says `asked` before the first question is shown, so even a crash cannot bring it back.
- **2c-10. KWallet's own entries** (integrator decision in the review of fbfe34d: closest to macOS, no technical step for
  the user). Options: (a) leave them in KWallet (the first version, which mistook them for entries without `xdg:schema`);
  (b) move them too. **Choice: (b)**, with the entries of older KWallet versions: in a Grassfield session QtKeychain apps
  (Nextcloud, KDE apps built with QtKeychain) look their secrets up through the Secret Service, which is gnome-keyring, so
  an entry left behind costs the user a sign-in; a copy of an entry that KWallet's own API keeps using does no harm.
- **2c-11. A wallet that stays locked and lists nothing** (integrator note in the merge of PR #22, recorded in step 2b).
  Options: (a) keep waiting, starting ksecretd at each login to list again; (b) give up after a number of logins. **Choice:
  (a)**: the cost is a short start of ksecretd per login, invisible to the user, while giving up would strand passwords that a
  later unlock of the wallet (by any KWallet client) would let move without any step from the user.

### Plumbing shared by D-3 and D-6
- One new packaged directory, `/usr/lib/grassfield/session-bin`, for the stand-ins of programs that Hyprland and xdph find by
  name. It is put first in PATH exactly where `omarchy-shims` is today (`omarchy.lua` `guard_path` for the compositor,
  `env-grassfield` for the systemd user manager); `omarchy-shims` keeps only Omarchy stand-ins. Every stand-in:
  - is a POSIX shell script (`hyprland-dialog`, like the existing shims) or, when it needs a socket, a Python program run with
    `python3 -I` (the picker, like `grassfield-session-end`); both clear Quickshell's option variables before `qs ipc`
    (security.md, `lock_request_env.sh`);
  - asks the shell with `qs ipc -p /usr/share/grassfield/shell call <target> <function> …` under a 1-s deadline, which covers
    only the shell's acknowledgement, never the user's answer (D-6's one-time socket carries that);
  - on no acknowledgement, or in a dev session where the target refuses, `exec`s the stock binary by absolute path with the
    same arguments, so the caller sees the stock program with the same PID, except while the session is locked (D-6: cancel);
  - never logs window titles or file names.
- Every new IPC function is added to `docs/specs/security.md` § IPC surface in the step that adds it.

## Delivery order (owner decisions Q5 and Q13, 2026-10-27: the proposed order, with steps 6 and 10 where they are)
Each step: its spec section, `just check`, its tests (fakes on a private bus, never the owner's bus or secrets), a nested
scenario with screenshots where it draws, an opus review when it touches security, IPC, a new service or the compositor
config; `docs/STATE.md` updated. Steps marked "after #8–#10" touch the shell or Settings and start only once the Settings pull
requests #8, #9 and #10 are merged (owner).
1. **Hyprland's screens off** (D-1): `config/hypr` only, a static test, nested check by the integrator (`hyprctl getoption`).
   Can start right after the opus PASS of this step.
2. **Appearance follows Grassfield** (D-8), in two pull requests (decision below):
   - **2a**: the session's `kwalletrc` under `/usr/share/grassfield/xdg-config` with its `XDG_CONFIG_DIRS` line (D-12,
     Q17-b). Packaging only.
   - **2b**: `grassfield-portal-settings` (no window), the session's `hyprland-portals.conf` under
     `/usr/share/grassfield/xdg`, `XDG_DATA_DIRS`, `GTK_USE_PORTAL=1` and `GDK_DEBUG=portals` in `env-grassfield`,
     `UnsetEnvironment` in the backend's and the shell's units (D-4's start-up loop), the generated GTK themes (Q7; 36 with
     the Increase Contrast variants, decision 2b-2). Packaging, a new service and
     one line of `grassfield-shell.service`; no shell code. After #8–#10.
   - **2c**: the Secret Service handover of Q17-b (D-12: a leftover ksecretd made to quit, KWallet's libsecret items moved to
     the keychain once), right after 2a; a secret path, so an opus PASS. No Settings or shell file.

   **Split of step 2** (decision delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
   Question: deliver step 2 as one pull request after the Settings stack (#8–#10), or Q17-b first? Options: (a) one pull
   request after the stack; (b) 2a now, 2b after the stack. Choice: (b). Rule applied: Q17-b fixes something users already
   meet today (Chromium's and every libsecret client's passwords ending in KWallet, with KDE dialogs), it touches no
   Settings, shell or `config/hypr` file, and nothing in it waits for the stack; 2b does wait: `GTK_USE_PORTAL=1` needs the
   shell unit's `UnsetEnvironment` line, and the GTK themes' selection colours follow the highlight colour that #10 adds to
   the settings schema (`accent.highlight`).
3. **Not responding and Hyprland's notices** (D-3, D-2): `session-bin/hyprland-dialog`, IPC `anr`, Force Quit and Dock
   marks (the app menu keeps Quit, Q16), `debug.suppress_errors` with the shell's notice. After #8–#10.
4. **Open and Save panels** (D-4) and **KIO's dialogs in Files** (D-12 a): the Files library split, Grassfield's KIO delegate
   extensions for Files and the panel, `grassfield-portal` with the FileChooser interface. Coordinated with the open Files pull
   request #7 (views).
5. **Open With and permission alerts** (D-5).
6. **Print sheet** (D-7, Q6): the Print interface in `grassfield-portal`, libcups. Here because it reuses the process, the
   sheet frame and the save panel (Save as PDF) of steps 4 and 5 (owner decision Q13).
7. **Screen-sharing picker** (D-6): stand-ins, IPC `picker` with the one-time socket, the shell panel, the recording
   indicator. After #8–#10.
8. **Screenshots re-wired** (D-10, Q4). After #8–#10 (bindings and a shell notice).
9. **Password prompts** (D-9, Q1 = S2, Q10, Q11, Q12): the amendment of the security rule first (Q12's text, after the
   integrator's review and the owner's agreement), then the bridge, the socket protocol, the shell's one queue and secret
   sheets, the udiskie helper, the NetworkManager secret agent, `org.kde.kpasswdserver6` (D-12 b); opus PASS. After
   #8–#10.
10. **Bluetooth pairing sheet** (D-11, Q9: "en plus des 8 étapes", Q13): the BlueZ agent in the bridge, the drop-in for
    Omarchy's `bt-agent`, the sheet's pairing forms; opus PASS. After step 9, whose bridge and queue it reuses.

Rationale: cheap and broad first (1, 2: every remaining GTK dialog already looks right in light and dark), then the most seen
dialogs (3, 4), the security-sensitive ones last, after the patterns they reuse have landed.

## Owner decisions
Asked on 2026-10-27 in the cloud session with the options above (recommended option first, in French): Q1–Q10 with step 0,
Q11–Q16 after the opus review of PR #13, Q17 (found after those answers) after its counter-review. Every question is
answered; the "Owner's words" column is the option the owner picked, verbatim. Q1 also accepts
that a new secret prompt enters `shell/security/`; Q12 fixes the amendment's text, applied in step 9 after the integrator's
review.

| | Question | Options (recommended first) | Owner's words | Answer |
|---|---|---|---|---|
| Q1 | Password prompts (keyring, GPG, encrypted disk) | S2 bridge + shell sheet / S1 own window / S0 stock, themed | « S2 pont + feuille shell (Recommandé) » | S2 |
| Q2 | "Not responding" | macOS model, no alert / a Grassfield alert Wait-Force Quit / marks, then an alert after 30 s | « Modèle macOS (Recommandé) » | macOS model, no alert |
| Q3 | Which apps reach the Grassfield file panel | portal apps + GTK 3 through `GTK_USE_PORTAL=1` / also Qt apps through `QT_QPA_PLATFORMTHEME=xdgdesktopportal` / portal apps only | « Portail + GTK3 (Recommandé) » | portal apps + GTK 3 |
| Q4 | Screenshots | re-wire, saved to the Desktop, toolbar later / re-wire, saved to Pictures / full toolbar now / keep Omarchy's | « Rebrancher, Bureau (Recommandé) » | re-wire, Desktop |
| Q5 | Delivery order | as proposed / Open and Save panels first | « Ordre proposé (Recommandé) » | as proposed |
| Q6 | Print dialog | GTK, themed, for 1.0 / a Grassfield print sheet in this chantier | « Feuille Grassfield maintenant » | a Grassfield print sheet (not the recommended option) |
| Q7 | GTK 3/4 theme | Grassfield CSS themes / Adwaita light and dark only | « Thèmes CSS Grassfield (Recommandé) » | Grassfield CSS themes |
| Q8 | Hyprland's config errors | Grassfield notice / Hyprland's red bar | « Avis Grassfield (Recommandé) » | Grassfield notice |
| Q9 | Bluetooth pairing codes | Omarchy's bt-agent kept for 1.0 / a Grassfield pairing sheet in this chantier | « Feuille dans ce chantier » | a pairing sheet, after the eight steps (not the recommended option) |
| Q10 | Wi-Fi password asked by NetworkManager | later, with its own decision / in this chantier, in the password step | « Dans ce chantier » | in the password step (not the recommended option) |
| Q11 | KIO and KWallet dialogs (D-12) | K1 Grassfield takes them / K2 Files' dialogs only, KWallet off for the session / K3 KDE's, themed | « Grassfield les prend (Recommandé) » | K1 |
| Q12 | Wording of the security-rule amendment (D-9) | the proposed text / gcr prompts only, each other protocol later / write it in step 9 | « Texte proposé (Recommandé) » | the text quoted in D-9 |
| Q13 | Place of steps 6 (print) and 10 (Bluetooth) | as placed / print after the screenshots / both at the end | « Comme placées (Recommandé) » | as placed |
| Q14 | "Remember this choice" in the screen-sharing picker | unticked every time / follow xdph's `--allow-token` | « Décoché toujours (Recommandé) » | unticked every time |
| Q15 | Screen-sharing request while the session is locked | cancel / hold until the unlock | « Annuler (Recommandé) » | cancel |
| Q16 | Rename Quit to "Force Quit" in the app menu of a hung app | no, macOS model / yes | « Non, modèle macOS (Recommandé) » | no |
| Q17 | Which daemon holds the Secret Service in the Grassfield session (D-12) | Q17-a gnome-keyring started with the session / Q17-b KWallet's takeover off for the session / Q17-c as is | « Bloquer KWallet » | Q17-b (not the recommended option) |
| Q17 (when) | When to deliver Q17's answer | with step 2 / in step 9 | « Avec l'étape 2 (Recommandé) » | with step 2 |

## macOS reference
One system draws every system question: open and save panels and the print sheet are AppKit's, shown as sheets of the app's
window; privacy and password questions are system alerts (TCC, SecurityAgent) with the app's name; the system never shows an
"app not responding" alert, only the wait cursor and Force Quit's "(Not Responding)"; screen sharing goes through the system
picker and the menu-bar indicator; there are no update, donation or welcome screens outside Setup Assistant and Software Update.

## Alternatives rejected
- Patching or forking xdg-desktop-portal-gtk, xdph, hyprland-guiutils or gcr (D1).
- A compositor plugin as the ANR source (internal `CANRManager` API with no stability promise; kept as an optional later
  improvement).
- `XDG_CURRENT_DESKTOP=Grassfield:Hyprland` (handles § above).
- A hyprtoolkit theme for hyprland-guiutils (`/etc/xdg/hypr/hyprtoolkit.conf`): it would also restyle the Omarchy session's
  dialogs (a system file read by both sessions), and with D-1 and D-3 the guiutils windows only remain as fallbacks.
- Writing the user's dconf, `xdph.conf`, `gpg-agent.conf` or udiskie config (the owner's files).

## Evidence
- `docs/audits/dialogs-2026-10-27/probes.sh` and `probes-output.txt`: `docker run … archlinux:base@sha256:52dfbd5a…` →
  exit 0 (Omarchy 4.0.4 stable mirror, 2026-10-27): package versions, the portal and D-Bus service files, Arch's pinentry
  wrapper, the helper names in Hyprland's and xdph's binaries, udiskie's default prompt, Omarchy's inherited settings, the
  packages that already pull libcups, BlueZ and NetworkManager (P14), kio's dependency on kwallet, the kpasswdserver and
  kwalletd service files, and what pulls gcr and gcr-4 (P15), gnome-keyring's globally enabled units and Omarchy's
  references to the keyrings (P16), the session bus implementations and their `ProcessFD` support (P17).
- Source reading, every citation in the inventory: Hyprland v0.56.2 (efb5099), xdph v1.4.1 (cc8e5ef), hyprland-guiutils v0.2.2
  (a16ad89), hyprtoolkit v0.6.0, hyprutils v0.14.3, xdg-desktop-portal 1.22.1 (1d20fad), xdg-desktop-portal-gtk 1.15.3
  (337202d), gtk 3.24.52 (6a0b360) and 4.24.1, libadwaita 1.10.0, qtbase v6.11.2 and v6.12.0, gcr 3.41.2 and 4.4.1,
  gnome-keyring 51.1, pinentry 1.3.3, udiskie v2.7.0, KIO v6.31.0 (2dd4bdc), KWallet v6.31.0 (81eb09f), Chromium 156 and
  Electron 43 sources, Firefox 158, LibreOffice 26.8.1, Omarchy v4.0.4 (c668141) and v4.0.6 (237f1b4).
- Not verified (no display in the cloud container; nested runs are the integrator's): every "Today" look, every runtime claim
  marked UNVERIFIED in the inventory. The live update of GTK 3, GTK 4 and libadwaita apps through `SettingChanged`, code-read
  in step 0, is measured in step 2b on a headless Weston (`tests/integration/portal_settings.sh` scenario 7).

## Consequences
- The Secret Service stays gnome-keyring's in the Grassfield session: KWallet's takeover is turned off by a session-only
  `kwalletrc` (Q17-b, step 2).
- New services: `grassfield-portal-settings` (always on, no window) and `grassfield-portal` (panels, D-Bus activated) from
  steps 2b and 4; `grassfield-secrets-handover` (one-shot at the session's start) from step 2c; `grassfield-prompter` from step 9 (gcr prompts, KIO network passwords, NetworkManager secrets, and in step 10
  the BlueZ agent). All gated by `GRASSFIELD_SESSION=1`, hardened, with budgets; §5.8 is answered per service in its step.
- `grassfield-desktop` declares `gnome-keyring` (step 2a): it is the session's only Secret Service.
- New library dependencies of Grassfield binaries: libcups (step 6, already installed with qt6-base and gtk3), libgcr-4 (step
  9, already installed with gnome-keyring) and libsecret (step 9, already installed with pinentry; counter-review of PR #13,
  minor); no libnm.
- A packaged drop-in keeps Omarchy's `bt-agent` out of the Grassfield session (step 10).
- The security rule (CLAUDE.md, master-prompt R12, ADR-0010) is amended in step 9 with the text of D-9 (Q12).
- One new packaged directory each: `/usr/lib/grassfield/session-bin` (stand-ins), `/usr/share/grassfield/xdg` (the
  session's portal configuration) and `/usr/share/grassfield/xdg-config` (the session's `kwalletrc`, Q17-b).
- The Grassfield session exports `GTK_USE_PORTAL=1`, adds `portals` to `GDK_DEBUG` and prepends `XDG_DATA_DIRS` and
  `XDG_CONFIG_DIRS`; the Omarchy session is unchanged (`env-grassfield` is read only for the Grassfield desktop name,
  ADR-0017).
- New IPC targets `anr` and `picker`, the picker's one-time sockets and the prompter socket are listed in
  `docs/specs/security.md` in their steps.
- The inventory is the checklist of the chantier: a row is closed when its step merges, with its evidence.
- Known limitations recorded in `docs/specs/system-dialogs.md`: no true sheets (modal child windows), no wait cursor, apps
  that print or pick files in-process (Chromium's and Firefox's previews, LibreOffice, Electron's print, Qt apps) keep their own
  dialogs (themed), remote file picks refused, Hyprland's safe-mode dialog and a few toasts stay Hyprland's, VPN secrets are
  not asked (no agent runs a VPN plugin's dialog, as today; D-9), a user's own picker or portal configuration wins.
