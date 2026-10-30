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
- Config errors: the plan was `debug.suppress_errors = true` with the shell reading `hyprctl -j configerrors` once at start
  and after Hyprland's `configreloaded` event (`src/config/lua/ConfigManager.cpp:854`) and showing one Grassfield notice per
  new error set ("Some settings could not be applied"). **Not done on Hyprland 0.56.2** (decision 3-15, integrator nested
  pass of 2f352b8): under the Lua config `configerrors` is empty while Hyprland's bar shows the errors, measured for a
  failing `require`, a type error, an unknown section, a nil call and a bad monitor mode, at start and after a reload.
  Source: every `hyprctl dispatch` is an `eval` (`src/debug/HyprCtl.cpp:1131-1134`), and `eval` clears the errors first
  (`src/config/lua/ConfigManager.cpp:880-886`); the shell itself dispatches at start and after each reload (its blur and
  motion pushes). So Hyprland's bar stays on, the shell's notice (`ConfigErrors.qml`, built and tested) waits for a source,
  and a report upstream is the owner's call. Also read in the source: the same switch would hide Hyprland's emergency-mode
  banner (no binding left), contrary to the plan (`ConfigManager.cpp:773-801`; decision 3-7).
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

**Delivered in step 3 (D-3 and D-2).**
- `packaging/session-bin/hyprland-dialog` (POSIX sh), installed to `/usr/lib/grassfield/session-bin/` and put right after
  `omarchy-shims` in Hyprland's PATH (`omarchy.lua` `guard_path`, called from `session.lua`; `dev.lua` puts the
  repository's copy first in the nested compositor's PATH). It matches Hyprland 0.56.2's en_US and fr_FR texts exactly
  (`--title T --text X --buttons B`, nothing else), tries every " - " split of "{title} - {class}" against
  `hyprctl -j clients` (read with `python3 -I`), and with exactly one (split, client pid above 1) match asks
  `qs ipc -p /usr/share/grassfield/shell call anr report <its pid> <pid> c:<class> t:<title> i:<instance>` under
  `timeout -k 0.2 1` (decision 3-11). On `ok` it `exec`s `sleep infinity` (same pid, silent, nothing forked) until
  Hyprland kills it (decision 3-12); in every other case it `exec`s `/usr/bin/hyprland-dialog` with the same arguments.
- `shell/services/NotResponding.qml` (singleton, IPC target `anr`: `report` action, `status` dev) and its pure decisions
  `NotResponding.js`: a report is refused for a pid of 1 or below, an empty class, another compositor's instance, and a
  window with that class and (live) title that the shell knows under another pid; the caller gets "refused", the reason
  goes to the journal (decision 3-14). One mark per stand-in, a process marked while any of its stand-ins lives (Hyprland
  runs one dialog per XWayland surface); while there is one, the stand-ins' pids are checked every 250 ms (`kill -0`) and
  the marks of those that ended go.
- Force Quit (`ForceQuitPanel.qml`): "(Not Responding)" after the app's name, in `colors.danger`; the selection follows a
  window, not a row; before the user moves it, it goes onto the first app that does not respond and never away from the
  app shown (decision 3-13). The Dock menu (`DockMenu.qml`): a disabled "Application Not Responding" first, then Force Quit in place of Quit,
  for the processes that do not respond only (Option + Force Quit: all of the app's). At the confirmation (`Power.qml`) a
  pid that no longer owns a window of the chosen class (the Force Quit panel: the selected window's; the Dock: the app's
  windows') is not killed, and a notice says "The application had already quit."; the others are.
- `looknfeel.lua`: `misc.anr_missed_pings = 3` (Hyprland's default is 5, 7.5 s).
- D-2: Hyprland's error bar stays on: no Grassfield file sets `debug.suppress_errors` (decision 3-15).
  `shell/platform/ConfigErrors.qml` and `ConfigErrors.js` read `hyprctl -j configerrors` at the shell's start and after each
  `configreloaded` event (once more when one came during a read); the shell root posts "Some settings could not be applied"
  with the first three lines as text (Lua's "<eof>" escaped for the notification's markup), then "and N more", for each new
  set, and withdraws it when a reload leaves none. On 0.56.2 under the Lua config that answer is always empty, so the notice
  does not show today; it is kept, tested, for a Hyprland whose `configerrors` answers.
- Tests: `tests/shell/hyprland_dialog.sh` (46 checks: en and fr calls; titles with " - ", a leading "-", a newline or
  none; a class with " - "; an app named to match another split; every fallback with the same pid and arguments, including
  two processes, a refusal, no shell and a shell that hangs past 1 s; spawned by a double fork as Hyprland spawns it, the
  pipe stays open after "ok" and ends at once when the stand-in is killed; the dev hook; the texts pinned against the
  installed Hyprland, with a control), `tests/shell/anr_ipc.sh` (the stand-in through the real `qs ipc` to the real
  `NotResponding` in an offscreen Quickshell against a fake Hyprland: mark, clear, the shell's own ambiguity and instance
  refusals, a rename that lifts the ambiguity, direct calls), `tests/shell/config_errors.sh` (`ConfigErrors.qml` under the real Quickshell with reload events: one notice per
  new set, clear, the read after a read), `tests/unit/tst_notresponding.qml`, `tests/unit/tst_configerrors.qml` (with the
  notification sanitizer), `tests/shell/session_input.sh` (the PATH order; no Grassfield file sets `suppress_errors`), `tests/shell/shell_unit.sh` (the stand-in's shell selector),
  `tests/shell/session_services.sh` (the installed path), `tests/security/ipc_inventory.sh` (target `anr`), and the nested
  scenario `tests/shell/anr_nested.sh` (A-NR2: a SIGSTOP'd foot is marked, SIGCONT and a kill clear the mark).

**Decisions of step 3** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **3-1. Who finds the hung app's pid.** Options: (a) the shell, from its window list (`Compositor.pidOf`); (b) the
  stand-in, from Hyprland's live client list, the shell checking it against what it knows. The shell's list has a pid only
  for the windows Hyprland's list was last read for, and an IPC function answers at once, so (a) would fall back to the stock
  alert for a window opened since. **Choice: (b)**: a hung app gets the macOS cues whenever its window can be told apart
  (not an app without an app id: Hyprland names its class "(unknown)", which matches nothing, and the stock alert shows).
  The shell still refuses a pid that another process's window with the same class and live title contradicts.
- **3-2. Titles that start with "-".** `qs ipc` takes every argument that starts with "-" for an option, even after `--`, so a
  window titled "-rw-r--r-- notes.txt" would have failed the call. Options: (a) let it fall back to the stock alert;
  (b) encode the strings; (c) a fixed prefix the shell strips ("c:", "t:", "i:"). **Choice: (c)**: no alert for any title,
  and the arguments stay readable.
- **3-3. A report from another compositor.** `qs ipc -p` reaches every shell run from that path, so the nested session's
  stand-in could reach the real session's shell. Options: (a) accept; (b) the stand-in passes `HYPRLAND_INSTANCE_SIGNATURE`
  and the shell refuses another one. **Choice: (b)**: an app is never marked in a session where it does not run.
- **3-4. When the mark goes.** Options: (a) the stand-in reports its own end (it is SIGKILLed: it cannot); (b) the shell
  checks the stand-ins' pids every 250 ms while there is a mark. **Choice: (b)**; NR3's 1 s holds. Marks are kept per
  stand-in, not per process: Hyprland runs one dialog per XWayland surface (`ANRManager.cpp:155-158`), and a process stays
  marked while any of its dialogs lives (internal review, MINOR 4). Known limitation: a shell
  restarted while an app hangs loses its mark until the app answers or closes (Hyprland does not run its dialog again); Force
  Quit still lists the app.
- **3-5. Force Quit from the Dock menu of an app with several processes.** Options: (a) all its processes; (b) only those
  that do not respond. **Choice: (b)**: macOS force-quits the app that hangs; another process of the same app that answers
  keeps its work (Option + Force Quit still quits them all). The confirmation checks every pid against the app's window
  classes, so an app whose windows carry two classes is not refused.
- **3-6. "Show Details" for config errors.** The plan opened the journal lines; that needs a terminal. Options: (a) a
  terminal on `journalctl`; (b) the error lines in the notice's body (three, then "and N more"); (c) a details sheet (a new
  surface, not in this step). **Choice: (b)**: the user reads what went wrong in the notice and Notification Center, with no
  terminal. The shell logs the count only, never the lines (they can name the user's files).
- **3-7. `debug.suppress_errors` and Hyprland's emergency mode.** Read in Hyprland 0.56.2 (`ConfigManager.cpp:773-801`): the
  switch hides the emergency banner too, contrary to the plan. Options: (a) always set it (an error that leaves no binding
  leaves the user without keys and without a word); (b) never (Hyprland's red bar for every error); (c) set it only once
  `grassfield.bindings` loaded, read from Hyprland's `require`, which answers `true` for a module that ran and an empty table
  for one that failed (measured on the installed 0.56.2). **Choice: (c)**: a broken binding file keeps Hyprland's bar and
  banner; any other error gets the Grassfield notice. A parse that stops before `core.lua` ends keeps the bar too.
  **Superseded by 3-15**: the switch is not set at all.
- **3-8. Reading Hyprland's client list.** Options: (a) `jq` (not a dependency of grassfield-desktop); (b) `python3 -I`
  (already one). **Choice: (b)**: no new dependency.
- **3-9. Where `session-bin` goes in PATH.** Only Hyprland runs `hyprland-dialog`, so this step adds the directory to the
  compositor's PATH only; `env-grassfield` (the systemd user manager) gets it with the picker stand-ins of step 7 (D-6),
  which xdph runs. The nested session uses the repository's stand-in, which honours `GRASSFIELD_SHELL_DIR` in a dev session
  only (ADR-0019; security.md lists the hook), so the integrator's nested run goes the same way as the real session.
- **3-10. An untitled window.** Hyprland names it "(unknown)" ("(inconnu)") in its text. Options: (a) fall back to the
  alert; (b) match a window with an empty title too. **Choice: (b)**, still with exactly one pid; the stand-in reports the
  empty title, so the shell's own check compares the real one.
- **3-11. A class that holds " - "** (internal review, MAJOR 1). An app sets its own app id and title: with the split at the
  last " - ", a hung app of class "z - victim" titled "Victim" was taken for another app's window of class "victim" titled
  "Victim - z", which was then marked and offered to Force Quit. Options: (a) the last split (that flaw); (b) every split,
  exactly one (split, pid) match, else the stock alert. **Choice: (b)**: the hung app's own window always matches its true
  split, so any other match means two candidates and nothing is guessed.
- **3-12. How the stand-in waits** (internal review, NIT 7: `exec sleep infinity` outlives a compositor that crashed;
  counter-review, MINOR 1). Options: (a) `exec sleep infinity`; (b) poll whether its parent changed (tried, then dropped:
  Hyprland starts its dialogs through a double fork, hyprutils `CProcess::runAsync` `src/os/Process.cpp:183-263`, so the
  parent is init or the user manager from the start; a crash is never seen, and a poll that ended early, or a fork that
  failed, would hand Hyprland an empty answer, "unrecognized result", with no dialog for the rest of that hang); (c) watch
  Hyprland's own pid (the first line of `hyprland.lock`) from a waiter that forks nothing, more moving parts for a rare
  case. **Choice: (a)**: nothing is forked after the report, so it never ends early. In the real session Hyprland runs in
  uwsm's `wayland-wm@.service` (uwsm 0.27.1: no `KillMode`, so systemd's `control-group`), and its stop takes the waiters
  in that cgroup with it. Known limitation: a nested Hyprland that crashes while an app hangs leaves its waiter, which
  holds nothing, until logout.
- **3-13. Which row Force Quit selects** (internal review, MINOR 2; counter-review, MINOR 2). A binding moved the selection
  back to the first row when a mark cleared, under a user who had moved it; and the window list is a new array each time a
  window opens or closes, which resets the view's row: Return would then have targeted another app. Options: (a) select
  once, by row; (b) follow a window, not a row: the user's choice is kept (nothing selected, Force Quit off, when its window
  closes); before the user moves, the selection goes onto the first app that does not respond and never away from the app
  shown (`NotResponding.selectionAfterChange`). **Choice: (b)**: as macOS, a hang that starts while the panel is open is
  shown selected, and nothing ever moves the selection onto an app the user was not shown.
- **3-14. What a refused report says** (internal review, NIT 10). **Choice:** "refused" only; the reason goes to the
  journal, where it helps; the stand-in only needs to know it must run the stock dialog. This hides nothing: a caller with
  valid arguments can still tell "ok" from "refused", and any local process reads `hyprctl -j clients` anyway
  (counter-review, NIT 3).
- **3-15. Hyprland's config-error bar stays on** (integrator nested pass of 2f352b8, BLOCKER). Measured in a nested
  Hyprland 0.56.2: `hyprctl configerrors` is empty under the Lua config while the bar lists the errors (every dispatch is an
  `eval`, which clears them, and the shell dispatches at start and after each reload). With the switch of 3-7, an error in
  any file but `bindings.lua` was shown nowhere. Options: (a) keep the switch (errors hidden from the user); (b) no switch:
  Hyprland's bar shows them, the shell's notice waits for a source; (c) read the errors elsewhere (Hyprland's log: a new
  parser of a format that is not an interface). **Choice: (b)**: the user must see what went wrong without a terminal, and
  Hyprland's bar does that today; the macOS look of that one surface waits for a source that works. Recorded for the owner:
  an upstream report (`eval` clearing the config errors) is theirs to decide.

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

**Delivered in step 4b (the Files library and the Open and Save panels).** `apps/files/files-core.cmake`: Files' sources but
`main.cpp` as a static library, `grassfield-files-core`, linked by `grassfield-files` and by `grassfield-portal` (one CMake source
list; `apps/files/build-direct.sh --core`). `apps/portal/src/`: `chooserlogic.{h,cpp}` (every FileChooser option of
xdg-desktop-portal 1.22.1 checked and mapped for the panels, and the results out), `filechooser.{h,cpp}` (the backend
interface: a Request object per call, the panel's answer as a delayed reply, the 3-s forward to x-d-p-gtk, the idle quit),
`panelstate.{h,cpp}` (`portal-filechooser.json`, ADR-0020), `main.cpp`. `apps/files/qml/FilePanels.qml` and `FilePanel.qml`
(the panels), `PanelLogic.js` (their rules); `BrowserTab.chooser` (a tab that browses for a panel), `FolderModel.chooser` (what
a panel cannot take is dimmed and never selected), `FileLogic::passesFilter`; the toolbar's capsules and the appearance as
components shared with the browser window (`NavCapsule`, `ViewSwitcher`, `SearchCapsule`, `FilesAppearance`). Packaging:
`grassfield.portal`, `grassfield-portal.service`, its D-Bus service file, the session's `hyprland-portals.conf`
(`FileChooser=grassfield;gtk`), the PKGBUILD; `config/hypr/grassfield/windows.lua` (4b-3). Tests:
`tests/unit/portal/tst_chooserlogic.cpp`, `tst_panelstate.cpp`, `tst_filechooser.cpp` (the backend on a private dbus-daemon
with a fake frontend and a fake x-d-p-gtk), `tests/unit/files/tst_folderchooser.cpp` (a real KIO listing),
`tests/unit/tst_filepanel.qml` (the panel over stand-ins), `tests/integration/portal_filechooser.sh` (the real binary and the
real frontend on a private bus: A-FC1, A-FC4, A-FC6, A-FC7).

**Decisions of step 4b** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **4b-1. The Files library.** Options: (a) a shared library installed under `/usr/lib/grassfield`; (b) a static library
  compiled into both programs; (c) the panels as a mode of `grassfield-files`. **Choice: (b)**: one source list and no library
  ABI to install; D-4's two processes stay two (a crash of Files never takes an open panel along, and the reverse).
- **4b-2. One QML code base.** The panels live in Files' QML directory and the portal loads them from there, so a panel is the
  browser itself, not a copy: the views, the sidebar, Glance, Files' KIO sheets (D-12 a). A tab learns it browses for a panel
  (`BrowserTab.chooser`) and then has no file operation (no Trash, Rename, Copy, Paste, tags or quick actions; the
  application does what it wants with what it gets; a sidebar tag takes no drop and has no menu, review of step 4b, MINOR 4),
  a double-click on a file, Return and Esc are the panel's, a drop shows
  the item instead of moving it, "/" and "~" open Go to Folder; the view is the panel's own for its application (macOS keeps
  a panel's view apart from Finder's), the arrangement of a folder stays Files'.
- **4b-3. Whose window a panel is.** Question: which Wayland app id does a panel carry? Options: (a) its own
  (`org.grassfield.Portal`: a Dock tile with no app behind it); (b) Files' (Files shows as running while an application's
  panel is open); (c) the application's when the frontend names it (a desktop id), else Files'. **Choice: (c)**: on macOS a
  panel is a window of its application (Dock, menu bar, Force Quit count it there). Qt reads the app id when it makes the
  window, so the portal sets it just before (`FileChooser::present`). A panel's class is then any application's, so the
  session's rule that removes the compositor plugin's titlebar from a window that draws its own frame matches the panel's xdg
  tag (`file-panel`) whatever its class (`gf-client-chrome-panel`, a `config/hypr` change). This departs from the class list
  of the 2026-10-23 review (review of step 4b, NIT 13): any client that sets that xdg tag on its own window loses the plugin's
  titlebar on that window. It changes nothing else (no other window, no privilege; a client already draws what it wants in
  its own window), and the class list could not name a panel whose class is its application's.
- **4b-4. Modal to what.** The panel is xdg-dialog's modal (Hyprland dims and blocks the parent) when the application asked
  (`modal`, true by default) and gave a Wayland parent, imported with xdg-foreign v2 through KWindowSystem
  (`setMainWindow`, which waits for the toplevel; 4b-13). Qt's window modality without a transient parent blocks no other
  window of the process: two applications' panels open at once stay usable. With no usable parent, the panel is a free
  window: every window floats in the session, and Hyprland centres it.
- **4b-5. Filters.** Items a filter refuses are dimmed (at the disabled opacity) and cannot be selected, not hidden (macOS); a
  glob matches the whole name without regard to case (a "*.PDF" is a PDF), with no regular expression, going back only to
  the last '*', and a filter's patterns are at most 4096 characters together, so an item costs at most its name's length
  times that (review of step 4b, MINOR 8). A hostile filter can still make one Select All in a folder of thousands of items
  take seconds (counter-review, NIT-3), never hang the panels, which share one thread; a MIME rule matches the type, a type it inherits
  from, or "major/*". One filter shows no pop-up (nothing to choose); several show one, "Show:" in an Open panel and
  "Format:" in a Save panel, where the name's extension follows the format chosen (macOS).
- **4b-6. The Save panel.** Compact by default (Save As, Where), expanded to the browser by the disclosure button, as the
  application's last panel was left. A file selected in the browser gives its name. Saving over a file asks with the
  macOS replace alert, Cancel the default; a folder's name is refused with a message (replacing a folder by a file would
  lose its content); SaveFiles asks about every name that exists in the folder in one alert. Left out, written as known
  limitations: the Tags field (the panel would have to tag a file the application has not written yet) and "Hide extension"
  (a Linux file has no hidden-extension attribute, and Files shows every extension).
- **4b-7. New Folder.** In the panels whose answer is a folder or the place of a new file (Save, a folder Open panel,
  SaveFiles), and not in a file Open panel (macOS offers it only where the application allows it). macOS's sheet: "Name of new
  folder:" with "untitled folder", Create; the panel then opens the new folder.
- **4b-8. Nothing over the lock** (common rule 6). Options: (a) the panel reads the shell's lock state (its crash-recovery
  marker or its IPC: a security module's internals); (b) the compositor's session lock already covers every output and takes
  every input (ext-session-lock), so a panel that opens while locked is out of sight and of the keyboard's reach until the
  unlock; a panel that first gets the keyboard later than `files.panelLateFocusMs` (1.5 s) after it opened (it waited behind
  the lock, or under another window) takes keys only after a click in it, the polkit hold rule. **Choice: (b)**.
- **4b-9. The memory budget's measure.** D-4 says 80 MB while a panel is open, without the measure. As decision 2b-11 for the
  Settings backend: 80 MB of private memory (`RssAnon`); the resident size, which counts the shared Qt Quick and KIO
  libraries, is reported. Offscreen in the integration test: 28 MB private, 97 MB resident. The nested measure (A-FC3) is
  the integrator's.
- **4b-10. A network location.** D-4's known limitation: only `file://` results. A panel refuses one with a message naming
  the application ("“App” can only use items on this computer. Choose an item in a folder on this computer."), and stays open.
- **4b-11. Life of the process.** The frontend starts every backend when it starts itself (its proxy auto-starts it), so the
  panels' QML loads at the first request, not at start: an idle start costs no QML and owns its name at once. The process
  quits only when idle (60 s): Qt's quit at the last window closed and KIO's quit locks are off (found by the integration
  test: it quit as its first panel closed). No `Restart=`: D-Bus activation starts it again at the next call, after a crash
  too, and the call in flight ends with response 2. Idle, it gives up its bus name before it quits, so a call the frontend
  sends once it sees the name go starts a new process instead of reaching one that is quitting (review of step 4b, MINOR 6);
  a call that reached it before is served and the name taken back, except under systemd, which stops a `Type=dbus` unit once
  its name goes: that call ends with response 2. So does a call the frontend sends before it sees the name go (its proxy
  sends to the owner it knows; counter-review, NIT-5): a window of microseconds at the end of each idle period. A Close of a
  forwarded request reaches x-d-p-gtk after the forwarded call (one connection, D-Bus keeps its order), but GDBus routes a
  call to an object path as soon as it reads it, which can be before x-d-p-gtk's handler of the forwarded call has exported
  its Request object (both queued while D-Bus activation starts it): a Close that finds no object is sent again every 100 ms,
  for at most 5 s, while the request is forwarded (review of step 4b, NIT 11; counter-review, NIT-4).
- **4b-12. The unit's hardening.** Question: what may the panels write? Options: (a) `ProtectSystem=strict` with a list of
  writable places (the home, the runtime directory, `/tmp`, `/var/tmp`, the removable media) and `UMask=0077`, the first draft;
  (b) `ProtectSystem=full` (`/usr`, `/boot`, `/efi` and `/etc` read-only) and the user's own umask. **Choice: (b)** (review of
  step 4b, MINOR 5): a Save panel saves, and its New Folder works, wherever the user may write, a disk mounted under `/srv`
  or `/data` too, and a folder it makes gets the mode one made in Files gets, as an application's panel writes anywhere the
  user can on macOS; (a) made such a disk read-only and New Folder's folders private. Kept: `NoNewPrivileges`,
  `RestrictSUIDSGID`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`, `MemoryMax`, `TasksMax`. No
  `PrivateTmp` (a panel must show the real `/tmp`); no `MemoryDenyWriteExecute` (the QML engine's JIT) and no
  `SystemCallFilter` (KIO's workers, unverified under systemd in this environment); the network stays open for KIO's
  network places.
- **4b-13. The parent window.** Options: (a) KWindowSystem's `setMainWindow` (KDE Frameworks 6.31, LGPL-2.1-or-later, already
  installed as a dependency of KIO; its Wayland plugin imports the handle with xdg-foreign v2 once the toplevel exists); (b)
  xdg-foreign written by hand on libwayland-client, as `apps/windowchrome.h` writes xdg-toplevel-tag. **Choice: (a)**: no
  protocol code of Grassfield's own; a direct dependency of the package now (`kwindowsystem`, `THIRD_PARTY.md`).
- **4b-14. The application's title.** A sheet shows no title on macOS; NSSavePanel shows the application's message above the
  browser. The portal has no message, and applications put there what macOS apps put in it ("Select a folder to import"):
  the title is the panel's message line (one line of plain text) and its window title.
- **4b-15. What an application may pass.** Its texts are one line of plain text, GTK's mnemonic marker ("_Open") and the bidi
  embedding, override and isolate controls removed, capped at 1024 characters; at most 64 filters, 16 choices and 4096 file
  names (more ends the request with response 2, never a part of them: review of step 4b, NIT 10); at most 16 requests open
  at once (one more ends with response 2). A suggested name is a name (the part after the last "/"), a folder is an absolute
  path. What comes back is the application's own: the filter returned is the one it gave, byte for byte, and a choice or
  option id too long to return whole is dropped, never cut (only the panel's copy of a name is made plain; review of step
  4b, MINOR 7). An option of the wrong D-Bus type is no option: any process on the bus can call the backend directly,
  without the frontend's type checks, and reading it as its type would crash the process (review of step 4b, MINOR 3). A
  panel's answer is read as QML prints a URL, a space as it is (review of step 4b, BLOCKER 1: a strict reading refused any
  path with a space).
- **4b-16. Files' Applications location in a panel** (FP-26, merged from main during step 4b). Question: what does a panel
  do with the Applications location (`grassfield-apps:/`, whose items are launchers, not files)? Options: (a) leave it out of
  the panel's sidebar; (b) keep it, as the sidebar of a macOS panel keeps Applications, with every application dimmed,
  never started, and the default button off there; (c) answer an application's desktop entry file. **Choice: (b)**: a
  panel's sidebar is the Finder's, and an application here is not a file the asking application can open, so a panel
  neither starts one nor answers one; (c) would hand over a launcher file nobody asked for. Cmd-Shift-A (Go to
  Applications) stays out of the panels: nothing there can be chosen. The portal runs Files' icon decoder child and its
  `image://appicon` provider as Files does (an application's icon file is decoded in a child of the portal itself, which
  answers `--decode-icon` before anything else).
- **4b-17. Write access to what was picked** (integrator review of bd78424, MINOR 4). Question: does a sandboxed application
  get write access to a file opened through a panel? xdg-desktop-portal 1.22.1 (`src/file-chooser.c`,
  `send_response_in_thread_func`) starts from `XDG_DOCUMENT_FLAG_WRITABLE` and drops it only for an explicit `writable`
  false; it has no read-only option to pass on. A missing key is therefore already writable. **Choice:** the panels
  answer `writable` true explicitly for Open, Save and SaveFiles: macOS gives an application read and write access to what
  its panel returns, and the access no longer depends on that default.
- **4b-18. The disk off the GUI thread** (integrator review of bd78424, MAJOR 1: a hung mount froze every application's
  panel, and the 3-s forward with them). Question: how do the panels ask the disk (the folder a panel starts in, whether a
  name exists, Go to Folder) when a mount may not answer? Options: (a) the D-Bus side on a thread of its own, the panels
  still reading the disk on the GUI thread (the forward survives; every panel still freezes); (b) every question asked on
  a thread of its own with a deadline (`FileChooser::probe`, 1 s), the GUI thread never waiting. **Choice: (b).** A folder
  that has not answered in time is passed over when a panel opens (the next of the application's folder, the remembered
  one, Documents, Home), and Save, SaveFiles and Go to Folder say "“name” isn't responding." with "Choose another folder,
  or try again later.", as the Finder says of a server that went away; the panel stays open. The questions go through
  `DiskProbe` (Files' library, shared by the portal and Files' sidebar): a call's paths are read in the order given on one
  thread of its own, each answer posted as it comes; the call ends once every path has answered, once none has for 1 s (a
  share that is slow but answering is waited for), or after 5 s in all. Each path's answer is its own and goes to every call
  waiting for it: a path queued behind a hung one in the same call is not responding for that call only and is read again by
  the next, and a call asking a path another call's thread is reading waits for that read instead of starting one (one read
  per path: 30 calls on one hung path are one thread, re-review of 24bdf58, MINOR 3). A read still running when a call
  waiting for it ends is stuck: until it returns, a later call gets "not responding" for that path at once; when it returns,
  its answer is given late (`answeredLate`). At most 32 threads live at once per DiskProbe (a burst, the sidebar's seven calls
  and a panel's six, is far below it; with 32, a new call's paths are not responding at once); the portal has two, the panels'
  and their sidebar model's, so 64 at most, still under the unit's `TasksMax` of 128 (step 4b's integrator status, MINOR). A panel's start folders are a call each, all at once (the application's folder, the remembered one, Home, Documents,
  Desktop, Downloads), and where calls answer about the same folder a real answer wins over "not responding", whichever
  comes first: no hung folder hides another (re-reviews of 65311e0 and 24bdf58, MAJOR 1: a hung remembered folder, then a
  hung Documents in the places' one call, hid the application's ~/Downloads; the places were read in a hash's order, which
  changes from one process to the next). Earlier versions: a thread per path and a bound of 16 paths (SaveFiles with 17
  names was never answered, re-review of 6b26afc); one job per call that kept a path queued behind a hung one as "being
  read" until the process quit (re-review of 65311e0). Files' sidebar (`PlacesModel`, the same in Files and in a panel)
  lists the standard folders at once and asks the disk about each in a call of its own: one that is not there leaves the
  list, one that does not answer stays, dimmed, as the Finder shows a server that went away, and is shown again when its
  read returns (re-review of 65311e0, MAJOR 2: it read them on the GUI thread, when a panel's UI was made and at every
  device change; re-review of 24bdf58, MINOR 2: a dimmed folder stayed dimmed). New
  Folder asks KIO (its job runs off the GUI thread) and learns a taken name from KIO's error instead of a look first. Left on
  the GUI thread: the files under the home folder's configuration directory (`user-dirs.dirs`, `grassfield.json`, the panels'
  state file; a hung home folder stops the whole session anyway), Files' own per-item reads once a listing has arrived (tags,
  folder looks), and the application's desktop entry (KService's cache).

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

**Delivered in step 5a (the permission alerts).** `apps/portal/src/requesthost.{h,cpp}`: the request lifecycle FileChooser had
(a Request object per call, the delayed reply, the bound on open requests, the UI made at the first request, the 3-s forward to
x-d-p-gtk with its answer relayed and Close sent on, the idle quit), now shared (5a-2). `access.{h,cpp}`: the backend interface
(`AccessDialog`: the frontend's strings as plain lines, its labels without mnemonics, a symbolic icon name or none, the choices
through chooserlogic's functions, no default button for the camera and screen capture), on the same exported
object as FileChooser; `main.cpp` makes both roots of the UI at the first request of either and quits once both are idle.
`apps/files/qml/AccessAlerts.qml` and `AccessAlert.qml` (the alert). Packaging: `grassfield.portal` lists Access, the
session's `hyprland-portals.conf` routes `Access=grassfield;gtk`, `config/hypr/grassfield/windows.lua` gives the alert's tag
(`access-alert`) the client-chrome tag. Tests: `tests/unit/portal/tst_access.cpp` (the backend on
the run's private dbus-daemon with a fake frontend and a fake x-d-p-gtk), `tests/unit/tst_accessalert.qml` (the alert over a
stand-in), `tests/integration/portal_filechooser.sh` scenario 7 (the camera asked through the real frontend: the alert's
answer reaches the application and the frontend's permission store keeps "yes" or "no").

**Decisions of step 5a** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **5a-1. Step 5 in two pull requests.** Question: deliver Open With and the permission alerts together, or apart? Options:
  (a) one pull request; (b) **5a** the permission alerts, **5b** Open With. **Choice: (b).** Rule applied: the smallest slice
  that a user meets first; the alerts are one window and one rule set, Open With is a panel of its own (the Applications
  location, "All Applications", "Always Open With") and gains nothing from waiting for the alerts' review.
- **5a-2. One request lifecycle for the portal's interfaces.** Options: (a) Access with its own copy of FileChooser's request
  handling; (b) that handling moved to a base class, `RequestHost`, that FileChooser, Access and later AppChooser build on.
  **Choice: (b)**: one place for the forward, Close and the idle quit, reviewed once (four review rounds went into them in
  step 4b); FileChooser keeps its API and its tests unchanged.
- **5a-3. An alert asked while the session is locked waits for the user** (replaces AC3's "refused with response 2").
  Question: what does a permission question asked behind the lock get? What xdg-desktop-portal 1.22.1 does with the answer:
  for a permission not decided yet, any response but 0 is kept as "no" (`src/camera.c:150-157`, `screenshot.c`,
  `wallpaper.c`); only a failed call keeps nothing; and it waits on the Access backend without a timeout
  (`src/xdp-context.c:379-383`). Options: (a) response 2 at once (AC3 as first written): a "no" the user never gave, which only
  Settings > Privacy & Security undoes; (b) a D-Bus error: nothing kept, the application told it failed, and it must ask
  again; (c) the alert opens under the lock as a panel does (FC8) and waits there; the lock hides it and takes the keyboard;
  after the unlock it takes keys only after a click (the hold rule). **Choice: (c).** Rule applied: macOS first (the alert is
  there when the user is back, as a macOS alert waits on the screen), no technical intervention (no decision made in the
  user's absence that only Settings can undo). For the same reason a request that ends without the user's answer (Close,
  over the bound, a forward that failed, the process going) ends with a D-Bus error, never a response the frontend would keep
  as "no" (review of step 5a, MINOR 1).
- **5a-4. The alert's shape and window.** Options: (a) the shell's alert (`shell/overlay/Dialog.qml`) moved into Grassfield.Ui
  and shared; (b) the same shape built in the portal from the same tokens; (c) a sheet like the panels'. **Choice: (b)**: macOS
  asks for a permission with the same alert as every other alert, so the shape is the shell's (the application's icon in a 64-pt
  frame at the top left, the title in bold, the message under it, capsule buttons of one width); moving the shell's Dialog into
  the library would change the shell's alerts in a portal step (a later step that needs the alert in a third process does that,
  with its review). A window of its own, opaque like the panels and every application window (ADR-0002), with every window's
  radius (20, ADR-0024 C-1: a window rule cannot go past `decoration.rounding`, so the shell's 24 is not available to a window;
  `Hyprland --verify-config` refuses it); the application's icon from its desktop entry, the frontend's symbolic icon for an
  application it cannot name, drawn in the text colour (its theme's grey was 1.2:1 on the dark window; A2 asserts 3:1). Two
  buttons that do not fit side by side (French: "Ne pas autoriser" and "Autoriser") stack at the row's width, the default button
  on top as macOS (11 and later) stacks an alert's buttons, "Don't Allow" on top where neither is the default (the camera, AC2;
  re-review of a4740a2, MINOR 1). An alert that stops being the active window is disarmed until it is active again (re-review of
  a4740a2, NIT 2). One alert at a time, as macOS shows them: the others wait in the order they came, with no 3-s deadline while
  they wait (`RequestHost::queue`), and the next shows when the one on screen goes (integrator nested pass of 1745c0c: MAJOR 1,
  MINOR 3, MINOR 5).
- **5a-5. No answer by accident.** Question: what keeps a click or a key meant for something else from answering an alert that
  appears under it? Options: (a) nothing more than macOS shows; (b) each time the alert becomes the active window, no click, key
  or close answers it for `panelAlertArmMs` (500 ms), a key pressed meanwhile starts that time again (typing on for the window
  before never arms it), the keyboard starts on the alert and never on a button, again each time it becomes active (Space acts
  only on a button reached with Tab; Return is the default button's), and the panels' hold rule for an alert that gets the
  keyboard late, the first time or after more than `filesPanelLateFocusMs` (1.5 s) away (the lock, the screen saver or another
  window came in front of it; integrator review of e24ea5c, MINOR 1: a Return after the unlock granted a location alert), whose
  ending click is not an answer: the first press in the alert ends the hold even before it is armed, the press that made it
  active included (it may come just before the activation), the alert is armed again from that press (a double click never
  answers), and the hint takes the buttons' place meanwhile, so the alert keeps one size and nothing moves under the pointer
  (integrator nested pass of 1745c0c, MINOR 2: it took three clicks after the unlock; MINOR 4: the hint resized the window,
  which Hyprland centred again). **Choice: (b)** (review of step 5a, M1 and M2: an alert armed under the lock took the first
  click after the unlock, and a Space typed for another window pressed the focused Allow). Rule applied: no technical
  intervention: the frontend keeps the answer, and an "Allow" given by a stray click or key would need Settings to undo; the
  alert looks and answers as macOS's otherwise. With AC2, neither button is the default for the camera and screen capture, as on
  macOS 15 and later (macOS's microphone question has no xdg-desktop-portal 1.22.1 counterpart, and no icon names it here). For
  location, the wallpaper and running in the background "Allow" stays the default, so Return grants once the alert is armed and
  not held: that is AC2's choice, as macOS's location alert has "Allow" as its default, not the safer button made the default;
  the arm and the hold are what keep a Return meant for something else from granting (integrator review of e24ea5c, NIT 4).
- **5a-6. Esc and the window closed are "Don't Allow".** The alert has no Cancel: the frontend reads any answer but 0 as "no",
  so Esc and a close by the compositor say it plainly, as macOS's Esc does (a close before the alert is armed is refused,
  5a-5). The application's name is in the frontend's title ("Allow Example to Use the Camera?"), not on a line of its own.
- **5a-7. The forward.** xdg-desktop-portal uses one Access backend (no fallback at runtime), so an alert that cannot show is
  forwarded to x-d-p-gtk's Access by the backend itself, as the panels are (FC7); its answer and its choices are relayed. A
  forwarded request the application or the frontend closes ends with a D-Bus error, not x-d-p-gtk's answer to its closed dialog,
  which the frontend would keep as "no" (counter-review of step 5a).
- **5a-8. Who may call.** Any process on the session bus can call the backend directly (as for the panels). Options: (a) only
  the owner of `org.freedesktop.portal.Desktop`; (b) any caller. **Choice: (b)** for now: such a process can draw any window
  of its own already, its answer goes only to itself, and the integrator's nested passes call the backend directly
  (`tests/fixtures/portal-client.py`); a check of the caller is a follow-up for both interfaces together (review of step 5a,
  MINOR 6).
- **5a-9. The frontend's wording in Grassfield's language.** xdg-desktop-portal 1.22.1 sends its title, question and note in
  English whatever the language: its installed French catalog is empty (integrator nested pass of 1745c0c, MINOR 6; D-5 had
  assumed the text arrives translated). Options: (a) show it as it comes; (b) give the frontend's known wording (`src/camera.c`,
  `location.c`, `screenshot.c`, `wallpaper.c`, `background.c` of 1.22.1, matched whole, the application's name kept) in
  Grassfield's language from Grassfield's catalog, any other wording as it comes; (c) write Grassfield's own sentences per
  question. **Choice: (b)**, and the frontend's own button labels ("Deny Access"/"Grant Access", "Deny"/"Allow", "Don't
  allow"/"Allow") become the alert's "Don't Allow" and "Allow", the words macOS gives every privacy alert. Rule applied: macOS
  first (an alert in the user's language, the same two buttons on every privacy question), no technical intervention (nothing to
  install or set). (c) would rewrite the questions the frontend asks and break with its wording ("Allow Apps to …" for an
  application it cannot name) on its next version; with (b) a new wording shows in English until it is added.

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
(`Type=dbus`, `ConditionEnvironment=GRASSFIELD_SESSION=1`, `TimeoutStartSec=5`, `Restart=on-failure`, `RestartSec=1`, at most
5 starts a minute, `GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME` unset, hardened: `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectHome=read-only`, `PrivateTmp`, `PrivateNetwork`, `AF_UNIX` only, `@system-service` seccomp filter,
`MemoryDenyWriteExecute`, no capabilities, `MemoryMax=64M`, `TasksMax=8`),
`packaging/dbus/org.freedesktop.impl.portal.desktop.grassfield_settings.service` (D-Bus activation through the unit),
`packaging/systemd/xdg-desktop-portal.service.d/10-grassfield.conf` (the frontend wants the backend and starts after it,
decision 2b-14), and under `/usr/share/grassfield/xdg/xdg-desktop-portal/` the session's `hyprland-portals.conf` (Settings
only: `grassfield-settings;gtk`; every other interface keeps the stock file's routing, which the frontend still reads per
interface) and `portals/grassfield-settings.portal`. `env-grassfield` puts `/usr/share/grassfield/xdg` first in
`XDG_DATA_DIRS` (once, keeping the list or the default), sets `GTK_USE_PORTAL=1` and adds `portals` to `GDK_DEBUG`, all only
when the routing file is readable, and records `GRASSFIELD_APPS_GTK_USE_PORTAL=1`; `grassfield-shell.service` unsets
`GTK_USE_PORTAL` for the shell itself (gate P5), and the shell's launch environment (`shell/services/Apps.qml`) gives it back
to every app it starts (decision 2b-12); `autostart.lua` starts the backend after the Secret Service handover without waiting
for it (`--no-block`), then the shell. `ui/tools/gen-gtk-themes.py` generates the 36 themes at build time
(`/usr/share/themes/Grassfield-*`); `ui/tools/gen-tokens.py` writes the accents the backend publishes
(`apps/portal-settings/src/PaletteTokens.hpp`, checked by `--check`). The PKGBUILD builds and installs every piece (its
`check()` runs the compositor's and the menu bridge's tests only, as before) and declares `xdg-desktop-portal` and
`xdg-desktop-portal-gtk` (already installed by Omarchy; the session now relies on them).
- **What it publishes.** `org.freedesktop.appearance`: `color-scheme` (1 dark, 2 light; decision 2b-4), `accent-color` (the
  appearance's own accent, decision 2b-3), `contrast`, `reduced-motion`; `org.gnome.desktop.interface`: `gtk-theme`,
  `color-scheme` (`prefer-dark`/`prefer-light`), `enable-animations`. `Read` of a key it does not own answers
  `org.freedesktop.portal.Error.NotFound`, so the frontend asks x-d-p-gtk (fonts, icons, cursor). The file is watched
  (directory and file, atomic replaces included, 50 ms debounce; while the directory does not exist yet, its nearest existing
  parent) and, while the appearance is `auto`, the clock is read again every minute, never the file (decision 2b-8); only the
  keys whose value changed are signalled. The file is read as ADR-0020 §2 requires (review of step 2b): never without a bound
  (only a regular file is opened, without blocking, and checked again on the descriptor: a FIFO, a device or a directory is
  never read; at most 1 MiB, read whole); a malformed or unreadable file keeps the last good settings (defaults only at
  start, as the shell's own start); a missing file is a fresh start (the schema's defaults: dark, multicolor); the directory
  is never created. Every read runs on a worker thread, one at a time: a read that hangs (a home on a network mount that
  stops answering) is not waited for (ADR-0020's 5 s cut: logged once at 5 s), the calls are still answered at once with the
  last settings, a change made meanwhile is read once more after it, and the start waits 3 s at most for the first read (the
  unit allows 5 s). At start, once its name is owned, it signals every value once (decision 2b-9); when x-d-p-gtk signals a
  value other than Grassfield's for a key Grassfield owns, it answers with its own (decision 2b-13). A dev run refuses any
  bus but a private test bus (`apps/testbus.h`, shared with the handover).
- **The GTK themes.** One per accent, appearance and contrast; each imports GTK's own stylesheet from the GTK library's
  resources and then sets Grassfield's colours where that stylesheet draws its accent (selected rows and text, checked boxes,
  radios and switches, suggested buttons, progress bars, sliders, level bars, focus rings, selected tabs, menu items under
  the pointer, links), with the shell's colour roles (decision 2b-5): the GTK 4 focus ring opaque at
  `control.focusOutlineOpacity` (decision 2b-15), hover, pressed and border shades as the shell's overlays
  (`material.hoverOpacity`, `control.pressedOpacity`, `material.borderOpacity`), the selected tab's indicator at GTK's own
  width (`gtk.tabIndicatorWidth`, 4 px in both versions), visited links blue; no CSS colour function (GTK 3 and the owner's
  GTK 4.22 read them alike).
- **Tests.** Unit (`tests/unit/portal-settings`, 12 tests, plain and ASan/UBSan): values, the `auto` schedule, the accents
  from the tokens, the 36 theme names, the namespace filter, file changes signalled key by key, a malformed file keeping the
  last good settings, a FIFO (at start and later), a device symlink, a directory, a file over 1 MiB and an unreadable file
  never read, a read that hangs not waited for, the minute timer reading no file, the clock, a missing directory watched
  until it appears, the announcement at start; `tests/unit/tst_applaunch.qml`: the launch environment's `GTK_USE_PORTAL`.
  `tests/ci/gtk_themes.py`: 36 themes matching the backend's names, the imports, no copy of GTK's theme, no colour function,
  the colour pairs' contrast. `tests/integration/gtk_themes.sh`: the 36 themes rendered with GTK 3 and GTK 4 on Xvfb against
  GTK's own four stylesheets as controls (none of GTK's blue left, every Grassfield colour present, no stylesheet error).
  `tests/integration/portal_settings.sh`: static checks of the routing, names, units, PKGBUILD and `env-grassfield`; then the
  real xdg-desktop-portal 1.22.1 on a private bus with the backend D-Bus-activated and a stand-in for x-d-p-gtk: values
  through the frontend, the stock routing kept for every other interface, `SettingChanged` for the changed keys only, the
  client ending with Grassfield's values after x-d-p-gtk signals a dconf change, kill and reactivation by the next read, a
  change made while the backend is down delivered when it starts with no read, its memory within budget, x-d-p-gtk alone when
  the backend is absent, a fast start with a frontend that never answers, refusal outside the session and of a dev run on a
  bus that is not a private test bus; and on a headless Weston, GTK 3 (`GTK_USE_PORTAL=1`), GTK 4 (`GDK_DEBUG=portals`) and
  libadwaita apps following a change of appearance, accent and Increase Contrast within a second, with a GTK 4 app without
  the flag as the control.
- **Code quality.** `just check-tidy` covers the compositor only; a one-off clang-tidy run with the compositor's checks
  (`clang-analyzer-*`, `bugprone-*`, `performance-*`; LLVM 23.1) over the backend and its tests: the analyzer's one finding
  (the tests' never-deleted `QCoreApplication`), the signed bit operations and, after the review fixes, two widening
  multiplications were fixed; what remains is Qt's idiom (static `QStringLiteral` and `QTime` constants, a `QDBusArgument`
  operator returning its argument, moc's enum).
- **Known limitations.** x-d-p-gtk's own dialogs (its file chooser until step 4, print until step 6, account) read the user's
  dconf, so they keep Omarchy's look; GTK 3 and GTK 4 apps that open a file or a link through the portal may meet x-d-p-gtk's
  app chooser where the portal asks (D-5 replaces it), as GTK 3 apps already did with Q3. The text highlight setting
  (`accent.highlight`) does not reach GTK apps: their selected text uses the accent (decision 2b-6). The light yellow
  accent's thin marks hold 1.86:1 on GTK's window (1.99:1 under high contrast; 2.0:1 on the shell's window, as the shell's
  own). A GTK 3 or GTK 4 app the user starts with its own `GTK_THEME` keeps it. A `hyprland-portals.conf` of the user's
  (`~/.config/xdg-desktop-portal`) or of the administrator's (`/etc/xdg-desktop-portal`) is read before the session's and
  wins: with it, the apps take x-d-p-gtk's values (Omarchy's look) until it is removed. When x-d-p-gtk signals a dconf change
  of a key Grassfield owns, apps see its value for an instant before Grassfield's (decision 2b-13). On the owner's GTK 4.22,
  plain GTK 4 apps do not read `accent-color` (4.24 does); the Grassfield theme carries the accent anyway.

**Decisions of step 2b** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **2b-1. Plain GTK 4 apps read dconf, not the portal.** Measured (scenario 7): outside a sandbox GTK 4.24 takes its settings
  from the portal only with `GDK_DEBUG=portals`. Options: (a) leave them on the user's dconf (Omarchy's theme, no live
  appearance); (b) write the user's dconf (forbidden: the owner's files); (c) `GDK_DEBUG=portals` in `env-grassfield`, added
  to the user's own flags. **Choice: (c).** GTK 4 apps then follow the appearance, accent and contrast live, as GTK 3 apps do
  with `GTK_USE_PORTAL=1` (owner decision Q3, which took GTK 4 apps to read the portal already); the flag also makes GTK 4
  prefer the portal where it would otherwise decide by itself (files, print and open-with already go there by default).
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
- **2b-6. The text highlight colour (`accent.highlight`).** Options: (a) themes per highlight colour too (324 themes); (b)
  GTK apps follow the accent (the setting's default, "automatic"); (c) a theme generated per user at run time. **Choice:
  (b)** for now: (a) fills the theme list of every GTK tool with hundreds of entries, (c) is a new mechanism (a writable
  theme directory in the search path) for a setting few change; a user who sets a highlight colour sees it in the shell and
  Grassfield's apps, and the accent's in GTK apps (known limitation, revisit with D-4's panel work).
- **2b-7. Radii.** Q7's text included the radii. GTK's stylesheets draw controls at 5 px (both versions) and the control
  token is 6 px, an estimate awaiting its F1 measurement; window corners already come from Hyprland's rounding for every
  window (ADR-0024 C-1). Options: (a) override every `border-radius` rule (dozens per version, joined buttons included); (b)
  keep GTK's. **Choice: (b)**: a 1 px difference on an unmeasured value does not justify rewriting GTK's geometry; revisit if
  F1 measures a control radius far from 5 px.
- **2b-8. When `auto` switches.** Options: (a) a timer set to the next switch time (the spec's first text); (b) the shell's
  own rule, a recheck every minute with `apps/autoappearance.h`. **Choice: (b)**: apps switch in the same minute as the
  shell, and a clock or time-zone change (suspend, NTP) needs no new timer. Cost: a timer each minute while the appearance is
  `auto` (the clock only, no file read: integrator review of ea7ad8a), nothing sent when nothing changed.
- **2b-9. A change made while the backend restarts.** After a crash systemd starts it again within a second, but a change
  made in that second would reach no app until the next one. Options: (a) accept it; (b) the new process signals every value
  once when its name is owned. **Choice: (b)**: the missed change is delivered, and a value an app already has changes
  nothing (measured, scenario 7: after a restart GTK 3 and GTK 4 apps are told their theme name once more and keep their
  state, libadwaita is told nothing). Cost: one theme reload per running GTK app per restart, only after a crash.
- **2b-10. The backend's sandbox.** Unlike the handover (2c-6), the backend identifies no peer and reads one file of the
  user's, so the namespace options (`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, `PrivateNetwork`; in a
  user unit they imply `PrivateUsers=self`) cost it nothing. **Choice:** keep them. If the namespace cannot be set up, the
  unit fails and the frontend answers from x-d-p-gtk alone (the degraded behaviour above).
- **2b-11. Its memory budget.** Step 0 set "15 MB of RSS" (D-4, spec A-FC3) before anything was measured. Measured (Qt 6.12,
  the package's Release build, idle): 14.2 MB resident, of which 1.45 MB private; 12.7 MB are pages of shared libraries (Qt
  Core, ICU, libstdc++, libc) that every Qt process of the session maps already; after serving the frontend, 15.5 MB
  resident. Options: (a) keep 15 MB resident (failed by library pages the backend does not own); (b) budget what the backend
  adds: its private memory, with a resident ceiling. **Choice: (b)**: private ≤ 4 MB and resident ≤ 20 MB, checked by
  `tests/integration/portal_settings.sh` scenario 1; the unit's `MemoryMax=64M` stays the hard stop.
- **2b-12. `GTK_USE_PORTAL` for the apps the shell starts** (review of step 2b). The shell's unit clears the variable: the
  shell's gtk3 platform theme would otherwise ask the portal synchronously at start, and the lock screen and the polkit agent
  would wait on it (gate P5). Every app the shell starts (Dock, Apps, Search, Open With) inherited that, so a GTK 3 app
  opened there kept the dconf theme and its in-process file chooser, while the same app from a keyboard shortcut followed.
  Options: (a) leave it; (b) let the shell keep the variable; (c) the shell's unit keeps clearing it, and the shell gives
  `GTK_USE_PORTAL=1` back to the apps it starts, from `GRASSFIELD_APPS_GTK_USE_PORTAL` that `env-grassfield` records.
  **Choice: (c)**: an app behaves the same however it is opened, as on macOS, and the shell never waits on the portal.
- **2b-13. Another backend's signal for a key Grassfield owns** (review of step 2b). xdg-desktop-portal 1.22.1 passes every
  backend's `SettingChanged` on to the apps (measured), so a dconf change that x-d-p-gtk signals (Omarchy's theme tool
  writing `gtk-theme` or `color-scheme`) switched running apps to Adwaita until they restarted, while reads still answered
  Grassfield's values. Options: (a) document it; (b) the backend answers each such signal with its own value. **Choice:
  (b)**: the apps end with Grassfield's appearance and no step is asked of the user; cost: one signal more per such key, and
  an instant with x-d-p-gtk's value (one theme reload). Only x-d-p-gtk is answered, by its bus name, and only for a value
  other than Grassfield's (counter-review: answering any sender let a client make the backend signal, or ping-pong with it);
  `tests/integration/portal_settings.sh` scenario 2 checks both.
- **2b-14. The frontend starts after the backend** (integrator review of ea7ad8a). xdg-desktop-portal 1.22.1 creates its
  proxy for each Settings backend once, when it starts; a backend whose D-Bus activation fails then is left out until the
  frontend restarts, i.e. for the session, and no later read starts it again (measured: scenario 4b). The frontend is started
  by D-Bus activation whenever the first portal client calls, which nothing orders after `autostart.lua`. Options: (a)
  document it; (b) start the backend earlier in `autostart.lua` (a portal client can still come first); (c) a packaged
  drop-in for `xdg-desktop-portal.service`: `Wants=` and `After=` the backend. **Choice: (c)**, and the backend loses the
  `Requisite=graphical-session.target` of the first review, which would fail it when the frontend starts before that target.
  In the Omarchy session the backend's `ConditionEnvironment` skips it, which neither fails nor delays the frontend.
- **2b-15. The GTK 4 focus ring** (integrator review of ea7ad8a). It was drawn at 50 % alpha, so its checked contrast was not
  the one drawn (blended, 92 of 108 cases under 3:1). Options: (a) keep the alpha and check the blended colour; (b) draw it
  opaque. **Choice: (b)**: the shell's keyboard focus ring is opaque (`control.focusOutlineOpacity` 1.0, A11Y-08), and the
  theme takes that token; the accent where it holds `control.focusRingMinContrast`, the text colour otherwise.

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
which depends on kwallet (probe P15). Files ran its jobs with KIO's default widget delegate (`apps/files/src/filesapp.cpp:62-67`, until step 4a),
so KIO's Qt-widget dialogs (file exists, skip, certificate, Open With) appear inside a Grassfield app, and the D-4 panel built
from Files' sources would inherit them. Network passwords come from KIO's password server `org.kde.kpasswdserver6`
(`src/core/kpasswdserverclient.cpp:31`), D-Bus activated as kiod6 (P15): KDE's `KPasswordDialog`
(`src/kpasswdserver/kpasswdserver.cpp:759-787`), with remembered passwords in KWallet's network wallet (`:250-254, 425,
472-481, 952-955`), which brings KWallet's first-use wizard and wallet password.

Options (asked 2026-10-27, recommended first):
- **K1. Grassfield takes them.** (a) Files and `grassfield-portal` set a Grassfield UI delegate on each job they start, as Files
  already sets KIO's (`apps/files/src/filesapp.cpp:62-67`), with Grassfield implementations of KIO's delegate extensions as its
  children (`AskUserActionInterface`, `OpenWithHandlerInterface`, `UntrustedProgramHandlerInterface`,
  `OpenOrExecuteFileInterface`, which has no installed header: decision 4a-4); KIO finds them through the job, its parent job or its composite job
  (`KIO::delegateExtension`, `src/core/jobuidelegatefactory.h:102-126`). Not `KIO::setDefaultJobUiDelegateFactory`: it is
  marked Internal and KIOWidgets registers its own factory through it (`:85-92`; counter-review of PR #13, minor).
  **Superseded by 4a-2**: KIO's own sub-jobs keep a default delegate of their own, so Files sets both. The sheets:
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

**Delivered in step 4a (D-12 a in Files).** `apps/files/src/kioprompts.{h,cpp}`: `GrassfieldJobUiDelegate` (KIO's own
`KIO::JobUiDelegate` class, so clipboard updates and the rest stay KIO's, with Grassfield's extensions as its children:
`GrassfieldAskUserAction`, `GrassfieldOpenWithHandler`, `GrassfieldUntrustedProgramHandler`), set on every job Files starts
(`attachDelegate`) and made KIO's default factory while Files runs (4a-2), installed before Files' first job (the Trash
listing); `GrassfieldUndoUi` for KIO's `FileUndoManager`; a job tracker that tracks nothing (4a-12);
`KioPrompts`, the queue of questions the window shows one at a time (`current`, `reply`), each withdrawn when its job ends
(KIO closes its own dialog then). `apps/files/src/kiopromptlogic.{h,cpp}`: which buttons a sheet offers for the options KIO
passes and the KIO answer each choice gives, the one KIO's widget dialog gives for the same choice (KD2: `renamedialog.cpp`,
`skipdialog.cpp`, `widgetsaskuseractionhandler.cpp:460-485`). `apps/files/qml/KioSheets.qml` and `KioSheetsLogic.js`: the
sheets (conflict, skip, deletion, a worker's message, certificate, notice) on Grassfield.Ui's `Sheet`, which gains buttons at
its leading edge (`extraButtons`, `extra(id)`, on a row of their own when the row is too narrow) and `returnCancels`; Main.qml
places a question in a window (4a-9). Tests: `tests/unit/files/tst_kioprompts.cpp` (the table of KD2: every choice, with and
without Apply to All, every message type, the certificate's follow-up, deletions, plain text), `tests/unit/files/tst_kiodialogs.cpp`
(its own process with a scratch home: real KIO copy and move jobs through KIO's file worker answered as the sheets answer:
Replace, Keep Both, Stop, Skip with Apply to All asked once, a folder merged, a sheet's reply reaching the job, a question
withdrawn when its job ends, KIO's own jobs resolving Grassfield's extensions, an error KIO reports itself, Undo of a copy
changed since; after each, no widget exists; Files' sources hold no KIO or Qt widget dialog and set no other delegate),
`tests/unit/tst_fileskiosheets.qml` (texts, buttons and replies, Return, Esc, Apply to All, Show Certificate and Always trust,
a withdrawn question, an unknown kind), `tests/unit/tst_filesbrowser.qml` (the window that shows a question).

**Decisions of step 4a** (each delegated by the owner on 2026-10-27: macOS first, no technical intervention for the user).
- **4a-1. Splitting step 4.** Options: (a) one pull request: the Files library split, the delegates and `grassfield-portal`
  with its FileChooser; (b) 4a: the delegates in Files (D-12 a), then 4b: the library split with its first user, the
  portal's Open and Save panels (D-4), whose KIO jobs get the same delegates. **Choice: (b)**: Files' users get the macOS
  sheets now, with no new process; the library split lands with the code that needs it (no abstraction before its user),
  and the delegate classes move into it unchanged.
- **4a-2. KIO's default delegate factory.** Found in KIO 6.31: KIO gives the jobs it makes itself a default delegate of their
  own (`FileCopyJob`, `TransferJob`, `StatJob`, `DirectCopyJob`… `src/core/filecopyjob.cpp:94`, `job.cpp:282`), and
  `KIO::delegateExtension` looks at a job's own delegate before its parent's: a worker's message box or certificate question
  raised on such a sub-job, and every job of Undo, would reach KIOWidgets' widget handler whatever delegate Files set on the
  job it started. Options: (a) per-job delegates only (the plan, K1(a)); (b) also make Grassfield's delegate KIO's default
  factory while Files runs (`KIO::setDefaultJobUiDelegateFactory`, marked Internal). **Choice: (b)**, the per-job delegate
  kept: no KDE dialog reaches the user from any job of Files. Files restores KIO's factory when its prompts go, and
  `tst_kiodialogs.cpp` fails if a KIO update changes how the factory is reached (a build of either path fails if it goes).
- **4a-3. Errors and warnings KIO shows by itself.** Files' jobs report their errors through the window's error line
  (automatic handling off). Where KIO turns automatic handling on for a job of its own (`KDirModel`'s renames,
  `src/widgets/kdirmodel.cpp:1038`), the error or warning is a Grassfield notice sheet, not KIO's message box.
- **4a-4. "Open or Execute?" (`OpenOrExecuteFileInterface`).** KIO 6.31 installs no header for it, so no implementation is
  possible without KIO's private headers. KIO asks it only of a job that enables `setShowOpenOrExecuteDialog`, which Files
  never does (it never runs what it opens, `LaunchGuard`). **Choice:** no implementation; `tst_kiodialogs.cpp` fails if
  Files' sources ever enable it.
- **4a-5. No application set for a document's type** (`OpenWithHandlerInterface`). Options: (a) KDE's `KOpenWithDialog` until
  step 5; (b) a Grassfield notice that names the document and points to Open With; (c) the Choose Application sheet now.
  **Choice: (b)**: no KDE dialog, and the sheet of section 2 stays step 5's (D-5); step 5 replaces the notice with it.
- **4a-6. "Always trust".** After Continue on a certificate, KIO's http worker asks a second question on the same job: accept
  the certificate "Forever" or for the "Current Session only" (30 minutes; `kioworkers/http/http.cpp:310-336`). Options:
  (a) show it as a second sheet; (b) answer it from the first sheet's "Always trust “host”" box (unticked at every opening).
  **Choice: (b)**: one sheet, as macOS. The answer goes to the next question of that kind (`WarningTwoActionsCancel`) on the
  same job's delegate, with no time limit (internal review, MINOR 1: the first version allowed 10 s, but KIO asks worker
  message boxes one at a time, so the follow-up can wait behind another job's question, and would then have been shown as
  a sheet whose default button trusts "Forever"); any other question on that delegate clears it first. The http worker is
  KIO 6.31's only caller of `sslError`, and it asks the follow-up right after a Continue. The box shows with the
  certificate (Show Certificate), where macOS shows its trust setting. Every answer reaches KIO after the call that gave it
  returns (KIO connects to the certificate's answer only once it has asked, `usernotificationhandler.cpp:136-140`; internal
  review, MINOR 2).
- **4a-7. A folder onto a folder.** KIO's Overwrite writes into the folder (its items with the same name are asked about one
  by one); "Replace" would say the folder's content goes. **Choice:** the button says "Merge" (Finder's word for it)
  whenever KIO offers Overwrite onto a folder, as KIO's own dialog says "Write Into" (`renamedialog.cpp:304-312`): a move
  within one file system asks without `SourceIsDirectory` (`copyjob.cpp:2521-2533`; internal review, MAJOR 1). KIO offers
  no Overwrite for a local file onto a folder (`:2521-2524`); for a remote source it guesses from the error
  (`copyjob.cpp:2457`), and shows "Write Into" then too, as the sheet shows "Merge".
- **4a-8. The name Keep Both gives.** Options: (a) KIO's (`KFileUtils::suggestName`: "Report (1).pdf"); (b) Finder's
  ("Report 2.pdf"). **Choice: (a)**: with Apply to All, KIO names the following items itself with the same function, so one
  operation never mixes two rules.
- **4a-9. Which window shows a question.** Files' jobs belong to the app, not to a window. Options: (a) every window; (b) the
  window the user last worked in when it was asked, kept there until it is answered, moved to another window if that one
  closes. **Choice: (b)** (a sheet belongs to one window); with no browser window open (`--info`), the question gets its safe
  answer (Stop, Cancel, Don't Delete). One sheet at a time in a window, as AppKit queues a window's sheets and holds them
  during menu tracking: a question waits, out of sight and of the keyboard's reach, while Go to Folder, a confirmation or
  a menu is open in that window, and shows once it closes, with the choices already made on it (internal review, MAJOR 2,
  and counter-review, MAJOR: the first versions opened it behind the other sheet, then under an open menu, with the
  keyboard, where Return would have answered Replace unseen). While shown, the sheet keeps the keyboard: a view that takes
  it a moment later (a navigation's queued focus, an inline rename that ends) gives it back (counter-review, MINOR 1).
- **4a-10. Delete confirmations KIO asks for** (`askUserDelete`). Files asks before its own permanent deletions. **Choice:**
  every permanent deletion KIO asks about is a sheet; a plain move to the Trash is not asked (macOS) unless KIO forces the
  question. KIO's "do not ask again" answers (`kiorc` for deletions, `kioslaverc` for a worker's message boxes,
  `widgetsaskuseractionhandler.cpp:401-405`) are neither read nor written: no setting lives in a file for the user, and
  every question Files shows can be answered on the spot.
- **4a-11. Undo of a copy changed since it was made.** KIO asks synchronously whether to delete it anyway. Options: (a) a
  synchronous sheet (a nested event loop in the app); (b) keep the copy and say so on the window's error line. **Choice:
  (b)**: nothing the user changed is deleted, and the message says how to remove it (Move to Trash).
- **4a-12. KIO's progress window.** Found by `tst_kiodialogs.cpp`: an undo's job goes to KIO's job tracker, which, with no
  KDE job server on the bus (a Grassfield session), opens KIO's progress window (`KWidgetJobTracker`,
  `src/widgets/kdynamicjobtracker.cpp:103-195`; inventory K9); so does any job KIO starts without `HideProgressInfo`, such
  as the removal of a link by Undo (`fileundomanager.cpp:699`; internal review, MINOR 4). **Choice:** while Files runs, KIO's
  job tracker is one that tracks nothing (`KIO::setJobTracker`, marked internal, restored when Files' prompts go), and Undo
  asks for no progress either: no KIO progress window from any job of Files, as Files' own jobs
  (`KIO::HideProgressInfo`). Files shows its own activity in the status bar.
- **4a-13. The words.** Finder's: "An item named “X” already exists in this location.", "An older item…" or "A newer item…"
  when the dates tell, "Do you want to replace it with the one you’re moving?" (copying), Keep Both / Skip at the leading
  edge, Stop and Replace at the trailing edge, Apply to All. A question of a kind this version does not know is answered
  Stop rather than left waiting. The certificate's host, subject and issuer are shown as file names are (no bidi override,
  no line break: `FileLogic::displayName`), since whoever made the certificate chose them.
- **4a-14. Pasting text or an image** (internal review, MAJOR 3). `KIO::paste` of data without items asks a file name and a
  format in KIO's own widget dialogs (`KIO::PasteDialog`, `src/widgets/paste.cpp:37-126`), outside any delegate. Options:
  (a) keep it (KDE dialogs); (b) paste items only, as the Finder does (Paste is unavailable for text); (c) a Grassfield
  "name the new file" sheet. **Choice: (b)**: Paste is offered only when the clipboard holds items (`text/uri-list`, the
  form `KIO::paste` copies or moves, `pastejob.cpp:68-70`); `tst_kiodialogs.cpp` fails if Files' sources call KIO's own
  test (`canPasteMimeData`, which accepts text). Paste's count, its checks and the job use the same list, KIO's (local URLs
  first, valid ones), and the job gets its own copy of it, not the clipboard's data, which it reads a moment later.
- **4a-15. Skip for one item** (internal review, MINOR 3). KIO's skip dialog offers Skip and Skip All only when there are
  several items still to do (`skipdialog.cpp:58-72`; `copyjob.cpp:1540, 1854, 2045`, so not for the last one either); for
  one, Try Again (or Rename) and Cancel, or OK alone when it can't be retried. **Choice:** the same buttons (KD2), so a
  one-file copy that fails ends with its error, never as a silent skip.
- **4a-16. A copy that stopped part way** (counter-review, MINOR 2). KIO asks before resuming it (`filecopyjob.cpp:355-376`,
  Overwrite, Resume, no new name), after an interrupted copy left `name.part`. Options: (a) the conflict sheet without
  Resume (Replace or Stop only: the part already copied is lost); (b) a sheet of its own: "Part of “X” is already in this
  location." with Resume (the default), Start Over and Stop. **Choice: (b)**, KIO's answers (`Result_Resume`,
  `Result_ResumeAll` with Apply to All, `Result_Overwrite`).
- **4a-17. What Return does on a warning or a deletion** (integrator review of c0dd590, MAJOR 1). A worker's warning (an
  sftp host key that changed: "Connect Anyway", kio-extras' `kio_sftp.cpp:855-886`; the certificate's "Forever" when it
  shows as a sheet) took its action on Return, where KDE's own box defaults to Cancel (`kmessagedialog.cpp:357-386`), and
  common rule 3 says a destructive button is never the default. **Choice:** on a warning, Return gives Cancel, or the
  secondary action where there is no Cancel; on a permanent deletion KIO asks about, Return cancels. Questions that are
  not warnings keep their primary action as the default. The conflict sheet's default is the owner's decision Q18 (below):
  Replace, as the Finder, a written exception to common rule 3 for that sheet only.
- **4a-18. One answer, one question** (integrator review of c0dd590, MAJOR 2). The next question shows in the same sheet the
  moment one is answered, so the second click of a double click on Replace, or a Return held down, answered a second job's
  question unseen. **Choice:** a question takes no click and no key for the double-click interval after it shows
  (`Sheet.holdInput`, `Application.styleHints.mouseDoubleClickInterval`), and a sheet answers nothing on a key's
  auto-repeat, so Return held past the hold does not answer the next question either (integrator re-review: Grassfield's
  key repeat starts after 250 ms, `config/hypr/grassfield/omarchy.lua:113-114`). Found while testing it: a button the user clicked kept
  the keyboard, so in the next question Return pressed that button (Delete, Keep Both) instead of the default. A sheet
  without a field now opens with the keyboard on itself, and its buttons take the keyboard only by Tab.
- **4a-19. A long message** (integrator review, MINOR 4). A 200-line worker message made the sheet taller than its window,
  buttons out of sight. **Choice:** the message, the field and the body scroll inside the sheet when they would not fit
  (`Sheet.qml`, laid out as before when they fit); the title and the buttons stay. Every Grassfield sheet gets it.
- **4a-20. Names inside KIO's texts** (integrator review, MINOR 5). A skip text or a worker's message names files and hosts
  others chose: their direction overrides and isolates show as <U+XXXX>, as in file names (`FileLogic::displayName`), and
  other control characters go; line breaks stay (`KioPromptLogic::plainText`).

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
     `UnsetEnvironment` in the backend's and the shell's units (D-4's start-up loop) with the shell giving `GTK_USE_PORTAL`
     back to the apps it starts (decision 2b-12), the generated GTK themes (Q7; 36 with the Increase Contrast variants,
     decision 2b-2). Packaging, a new service, one line of `grassfield-shell.service` and one function of the shell's (the
     launch environment). After #8–#10.
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
   marks (the app menu keeps Quit, Q16), `debug.suppress_errors` with the shell's notice (not on 0.56.2: decision 3-15).
   After #8–#10.
4. **Open and Save panels** (D-4) and **KIO's dialogs in Files** (D-12 a): the Files library split, Grassfield's KIO delegate
   extensions for Files and the panel, `grassfield-portal` with the FileChooser interface. Coordinated with the open Files pull
   request #7 (views). In two pull requests (decision 4a-1): **4a**, the delegates and sheets in Files; **4b**, the library
   split and the portal.
5. **Open With and permission alerts** (D-5), in two pull requests (decision 5a-1): **5a**, the permission alerts (Access);
   **5b**, Open With (AppChooser).
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
| Q18 | Return (the default button) in the copy/move conflict sheet, "An item named “X” already exists" (step 4a; integrator review of c0dd590, point 3) | Replace, as the Finder / Stop, as KIO's dialog / Keep Both | relayed by the integrator on grassfieldhq/grassfield#33, 2026-10-28: "Replace … like Finder" | Replace: a written exception to common rule 3 (a destructive button is never the default) for the copy/move conflict sheet only (with Merge for a folder and Resume for a copy that stopped part way); a worker's warnings and the deletions keep Return = Cancel (4a-17) |

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
