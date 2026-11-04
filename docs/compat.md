# Compatibility matrix

Compare these with the installed versions at the start of every session (master-prompt §13).
If Hyprland or Quickshell changed: rebuild the plugin and run the C2 degradation test first.

| Component | Version | Verified | How |
|---|---|---|---|
| Omarchy | 4.0.4 (package; `/usr/share/omarchy/version` says `4.0.0.alpha`) | 2026-10-17 | `pacman -Q omarchy`, `/etc/os-release` |
| Hyprland | 0.56.2 (commit efb50993, tag v0.56.2) | 2026-10-17 | `hyprctl version` |
| Hyprland plugin ABI string | `efb50993780079460b0cbed1363e2166a2de1d9f_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6` | 2026-10-17 | `hyprctl version` |
| Hyprland headers | 0.56.2 | 2026-10-17 | `pkg-config --modversion hyprland` |
| aquamarine / hyprutils | 0.15.0 / 0.14.2 | 2026-10-17 | `pacman -Q` |
| Quickshell | 0.3.1 | 2026-10-17 | `pacman -Q quickshell`, `qs --version` |
| Qt | 6.11.2 | 2026-10-17 | `pacman -Q qt6-base` |
| KIO (KF6) | 6.29.0 | 2026-10-17 | `pacman -Q kio` |
| Compilers | gcc 16.2.1, clang 22.1.8 | 2026-10-17 | `pacman -Q` |
| Mesa | 26.2.2 | 2026-10-17 | `pacman -Q mesa` |
| Kernel | 7.2.5-3-omarchy | 2026-10-17 | `uname -r` |
| grassfield-compositor built for | Hyprland 0.56.2 (ABI efb50993…_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6), via `compositor/build-direct.sh` | 2026-10-17 | plugin log "ABI hash match" in nested |

## Known upstream issues (observed, not caused by Grassfield)
| Component | Issue | Evidence | Impact / mitigation |
|---|---|---|---|
| Hyprland 0.56.2 | SIGSEGV during process exit in `Screenshare::CScreenshareManager` destructor (`CScreenshareSession::~CScreenshareSession` → `screenshareEvents`) when a toplevel capture session is still active | `coredumpctl info 89926` (nested instance, 2026-10-17 02:56, Overview live thumbnails active at compositor exit); no grassfield-compositor frames in the stack | Only at compositor exit (logout). Overview stops captures when it closes; leaves a core dump if the session ends while Overview is open. Report upstream (owner decision). |
| Quickshell 0.3.1 (Arch build, Qt 6.11.2) | SIGSEGV in libc under `Qt::endPropertyUpdateGroup()` ← two unsymbolized quickshell frames ← `QAbstractSocketPrivate::canReadNotification()`, i.e. while a socket read handler applies a batched property update; seen about 1 s after a shell restart in a nested session, right after `quickshell.service.polkit.listener: failed to register listener ... An authentication agent already exists` | Two identical crash stacks (Quickshell crash reporter, 2026-10-21 23:4x, nested dev sessions); 1/10 restarts on main 72176a1, 1/10 and 2/12 on a Dock branch; no Grassfield code in the stack | Nested dev only so far (the polkit agent registers normally in the real session). Owner: watch for "Quickshell crashed" in the real session. Upstream report needs symbols (debuginfod) to name the socket owner, likely the Hyprland IPC event socket. |

## Omarchy dependencies (GF-AUDIT-001, 02 §5.5; remediation of F2, F5, F6, F7)

Grassfield is a separate session over Omarchy (ADR-0001). It reads Omarchy's files and runs a few of its commands; it modifies
none of them and none of the owner's dotfiles. **`scripts/dev/omarchy-compat.sh`** (`just check-omarchy`, also run by
`tests/shell/omarchy_compat.sh`) checks every row below against the installed Omarchy and exits 1 when one is gone or changed
in the way Grassfield relies on. Run it after every Omarchy update (done from the Omarchy session, see below) and before a release.
`/usr/share/omarchy/version` is a stale upstream file (`4.0.0.alpha` at every tag): the include no longer reads it; the gate is the
presence of the modules in the first rows.

| Dependency | Used by | If it disappears |
|---|---|---|
| `$OMARCHY_PATH/default/hypr/{helpers,envs,paths,require_optional,nvidia}.lua`, global `o` | `config/hypr/grassfield/omarchy.lua` (environment, Wayland toolkit variables, GPU variables, PATH) | include skipped, one critical notification at start, journal line `grassfield: Omarchy include`; Grassfield defaults apply |
| `default/hypr/input.lua` (layout from `/etc/vconsole.conf`, `compose:caps`, repeat 40/250, numlock; GF-023) | same | the same defaults are reproduced by the fallback in `omarchy.lua` and one notification says so |
| `~/.config/hypr/{monitors,input}.lua` (owner's files, read only) | same | a failing file is reported, the others still load |
| `bin/omarchy-restart-shell`, `bin/omarchy-launch-shell` and the call chain `omarchy-update-restart` → `omarchy-restart-shell` (GF-032) | shadowed by `/usr/lib/grassfield/omarchy-shims/` (first in PATH: `omarchy.lua` guard_path, `packaging/uwsm/env-grassfield`) | if Omarchy renames them the check fails: the stand-ins no longer cover the update |
| `bin/omarchy-hook`, `omarchy-powerprofiles-init`, `omarchy-powerprofiles-set` | `autostart.lua` (post-boot hooks, power profile at start) | skipped (guarded by `command -v`) |
| `bin/omarchy-migrate` (`--pending`), `omarchy-launch-floating-terminal-with-presentation` | `grassfield-migrate-notify` | no migrations notice |
| user unit `omarchy-sleep-lock` (delay inhibitor, `PrepareForSleep` monitor; `omarchy-system-sleep-lock` calls `omarchy-shell lock lock` and polls `omarchy-shell lock status`) | D-12 fail-safe: drop-in `ExecCondition=/usr/lib/grassfield/sleep-lock-gate` (skipped while grassfield-shell runs), started by `OnFailure=` of grassfield-shell; its `omarchy-shell` calls reach the stand-in in `omarchy-shims`, which starts grassfield-shell again and asks it to lock (docs/specs/security.md "Lock coverage") | renamed unit: no fail-safe after a shell failure; a changed `lock status` JSON contract: Omarchy keeps asking, then reports that the screen did not lock |
| user units `omarchy-crash-watch`, `omarchy-migrate-notify`, `omarchy-update-user-notify` | drop-ins `/usr/lib/systemd/user/<unit>.service.d/10-grassfield.conf` (`ConditionEnvironment=!GRASSFIELD_SESSION=1`) | a renamed unit runs in both sessions and needs the Omarchy shell (check fails; the other `omarchy-*.service` units are listed as info) |
| user unit `bt-agent` (`bt-agent -c NoInputNoOutput`, Omarchy's pairing agent) | drop-in `/usr/lib/systemd/user/bt-agent.service.d/10-grassfield.conf` (`ConditionEnvironment=!GRASSFIELD_SESSION=1`): grassfield-prompter is bluetoothd's only agent in the session (ADR-0035 D-11, decision 10-1) | renamed: a second agent answers pairings in the Grassfield session without asking (check fails); gone: nothing (info) |
| PAM services `omarchy-lock-password` (+ optional `omarchy-lock-fingerprint`), generated by `omarchy-apply-lock` | `shell/security/lock/Lock.qml` | the lock refuses and stays locked (fails closed) |
| `/usr/local/share/wayland-sessions/omarchy.desktop` (fallback `hyprland-uwsm.desktop`) | `grassfield-login set omarchy` starts its `Exec` line | login falls back to Grassfield |
| SDDM theme `omarchy`: `Main.qml` picks the first session whose name contains `uwsm`; no session list (GF-015) | `/etc/sddm.conf.d/grassfield.conf` (SessionDir, autologin session), entry `Grassfield (uwsm)` | the check fails; `grassfield-login-check` explains |
| `/usr/share/uwsm/env.d/10-omarchy` (OMARCHY_PATH, TERMINAL, EDITOR, mise) | both sessions through uwsm | information only |
| `gpu-screen-recorder` (Omarchy base package; arguments after `bin/omarchy-capture-screenrecording`, pinned) | `packaging/bin/grassfield-capture record` (ADR-0045 OC-1); the shell asks `command -v` each time the capture toolbar opens | the toolbar's Record buttons are hidden; the helper exits 3 and runs nothing |
| `uwsm-app` (Omarchy's uwsm) | `shell/services/CaptureState.qml` (the capture helper in its own scope, as app launches) | the helper runs unscoped, inside grassfield-shell's unit |
| `tesseract` (+ `tesseract-data-eng`; French needs `tesseract-data-fra`), `zbarimg` (`zbar`), Omarchy base packages; options after `bin/omarchy-capture-text`, `bin/omarchy-capture-qr` (pinned) | Preview and Glance: text and QR codes in images (ADR-0045 OC-2; `apps/preview/src/previewlogic.cpp`, `previewapp.cpp`) | no text selection or no QR chip, nothing on screen, one journal line (`grassfield-preview: tesseract is not installed…`, `…zbarimg is not installed…`, `…no tesseract language data…`) |
| `$OMARCHY_PATH/shell/plugins/emojis/emojis.json` (1870 `{e, k}` entries in v4.0.6, Unicode order; the group-first glyphs 😀 👋 🐵 🍇 🌍 🎃 👓 🏧 🏁 in that order) | Emoji & Symbols (ADR-0045 OC-3; `shell/services/Emoji.qml`, `EmojiLogic.categories`), read at the first opening | missing, unreadable or empty: the panel says "Emoji list not available"; a group-first glyph moved: one "All" section and a journal line |
| `bin/omarchy-menu-emoji-insert` (`wl-copy --sensitive --foreground`, then `wtype -M shift -k Insert`; `wl-clipboard` and `wtype` are Omarchy base packages) | `shell/services/emoji-insert.sh` (pinned) | `wtype -- <glyph>` when wtype exists, else a journal line; without wtype Omarchy's script copies but sends no Shift+Insert (nothing inserted, not detected) |
| `bin/omarchy-brightness-display-ddc` (`<monitor>` prints 0..100 and exits 0, exit 1 without DDC; `<monitor> N%`, `+N%`, `N%-` print the level set, 1..100; cache under `$XDG_RUNTIME_DIR`), through `ddcutil` (base package) | brightness keys, OSD and Quick Settings (`shell/services/Brightness.qml`, `BrightnessLogic.js`), Settings > Displays (`apps/settings/qml/System.js`; write guarded in `systemguard.cpp`) (ADR-0045 OC-4, pinned) | one journal line; keys drive the backlight or nothing; Quick Settings' Display module hidden on a desktop; no Settings row. No i2c access: the display is marked without DDC |
| `bin/omarchy-theme-set`, `omarchy-theme-current`, `omarchy-theme-list`, the themes `catppuccin-latte` and `tokyo-night` (the defaults' "Catppuccin Latte", "Tokyo Night") | `packaging/bin/grassfield-terminal-theme`, `shell/services/TerminalTheme.qml`, Settings > Appearance > Terminal and Developer Apps (ADR-0045 OC-11) | commands missing: the helper skips (exit 0, journal line), the Settings group is hidden; a default theme missing: the helper exits 1 quoting omarchy-theme-set's error |
| What `omarchy-theme-set` reaches (pinned: `omarchy-theme-set`, `omarchy-restart-hyprctl` → `hyprctl reload`, `omarchy-theme-set-browser-policy` → `pkexec` by PATH, `omarchy-theme-set-gnome` → `gsettings`; Omarchy's shell only through `omarchy-shell`) | the helper's safety: private `pkexec` and `hyprctl` stand-ins first in PATH, no instance signature, no `DCONF_PROFILE` or `SUDO_ASKPASS`, the omarchy-shims next | a new step that reaches the compositor, the shell or an administrator prompt another way: re-read the chain (the pins fail first) |
| `etc/sudoers.d/omarchy-theme-browser` (Omarchy's passwordless rule for Chromium's colour policy) | grassfield-terminal-theme (behaviour only) | Chromium's colour no longer follows (the pkexec stand-in refuses: never a password prompt) |
| `default/hypr/apps/{battlenet,davinci-resolve,geforce,moonlight,retroarch,steam,telegram,pip,webcam-overlay}.lua` (pinned) | `config/hypr/grassfield/apps.lua` (ADR-0045 OC-12: their matches and the effects that hold in a floating-first session; `tests/shell/app_rules.sh`) | a changed rule: the pin fails and the rule is ported or dropped; app ids `WebcamOverlay-*` of `omarchy-capture-screenrecording-with-webcam` for the camera overlay |
| `localsend` (base package) with `bin/omarchy-menu-share`'s invocation (`systemd-run --user --quiet --collect localsend --headless send <files>`, pinned) | Files: Share > Send with LocalSend… (ADR-0045 OC-13; `apps/files/qml/ShareLogic.js`, `FilesApp::sendWithLocalSend`) | no Share button and no Share submenu; a send already asked reports "LocalSend isn't installed." in the window |
| `bin/omarchy-weather-location` (`--set <name> [lat,lon]`, `--clear`), `~/.local/state/omarchy/settings/weather.json`; `shell/plugins/panels/weather/{Model.js,Panel.qml}` (pinned) | the Weather widget (ADR-0045 OC-14; `shell/widgets/Weather.js`, `WeatherSampler.qml`) with `curl` and `https://wttr.in/<q>?format=j1` | no command: Edit Location… hidden; no file: wttr.in's place from the IP (location arrow shown); no answer: "Weather unavailable" |
| `omarchy-launch-floating-terminal-with-presentation` with `omarchy-setup-security-{fingerprint,fido2,sshd}`, `omarchy-remove-security-{fingerprint,fido2}`, `omarchy-drive-password`, `omarchy-hibernation-{setup,remove}`, `omarchy-voxtype-{install,remove}`; `omarchy-voxtype-model` alone (it opens its own terminal) | Settings' setups that no system service offers (ADR-0045 OC-0.4, OC-0.7; exact argv in `systemguard.cpp` `isLaunch`), each behind `TerminalSetupSheet.qml` | the sheet names the missing command and its button stays disabled; nothing starts |
| `omarchy-hw-fingerprint`, `omarchy-hibernation-available`, `omarchy-network-qr --meta` (read-only checks, `isReadOnlyQuery`) and `omarchy-hibernation-setup` | Fingerprint & Security Key (a reader present), Battery > Hibernation, Wi-Fi > Share Network… (OC-6, OC-9, OC-10; `omarchy-network-qr`'s matrix and `meta` line pinned, `NetworkQr.js`) | no Fingerprint section; no Hibernation group (or no "On" state); no Share Network… button |
| Markers Omarchy's setups leave, read only: `/etc/pam.d/{sudo,polkit-1,omarchy-lock-fingerprint}` (`pam_fprintd`), `/etc/fido2/fido2`, `/etc/ssh/sshd_config.d/10-omarchy-hardening.conf`, `/etc/mkinitcpio.conf.d/omarchy_resume.conf`, `/sys/power/image_size` (the setup scripts pinned) | the panes' states (`Setups.js`) | a renamed marker shows the feature as not set up (the pins fail first) |
| `fprintd` (`net.reactivated.Fprint`), `pam-u2f` (`pamu2fcfg`), `openssh` (`sshd.service`), UDisks2 (`org.freedesktop.UDisks2`), `voxtype` (`voxtype-bin`), installed by Omarchy's setups | the native setups of OC-0.7: fingerprint enrolment, Remote Login's switch (after Omarchy's first SSH setup), Disk Encryption's Change Password… (LUKS directly under the root file system), Dictation's Ctrl-Super-X | not installed: the pane shows "not set up" with Omarchy's Set Up…; UDisks2 absent or another layout: Omarchy's `omarchy-drive-password` in its terminal |
| Hyprland Lua API `hl.{bind,on,dispatch,timer,exec_cmd,send_key_state,get_active_window,get_layers,monitor,env,config,gesture}` (stub `/usr/share/hypr/stubs/hl.meta.lua`) | `config/hypr/grassfield/*.lua` | check fails; `just check-config` also parses the config |

What Grassfield provides itself where Omarchy's version needs the Omarchy shell (audit 02 §5.3): crash notifications
(`grassfield-crash-watch.service`: the macOS model, "<App> quit unexpectedly" with Reopen only when a crashed application of the
user is gone: a trusted systemd-coredump entry for an app scope whose cgroup is gone or empty within 10 s; a tool crashing in a
terminal, a helper of a running app, a service and the shell give no notice, the journal keeps every dump; rules in the header
of `packaging/bin/grassfield-crash-watch`, tests in `tests/shell/crash_watch.sh`), low battery at 20/10/5 % (`grassfield-battery-watch.service`), a clickable migrations notice
(`grassfield-migrate-notify.service`; Omarchy's click command travels in a private hint, `omarchy-exec-argv`, that Grassfield's
server does not run, on purpose: any program could otherwise name a command), removable media (`grassfield-automount.service`,
udiskie), Night Shift (`grassfield-nightshift on|off|toggle|status`, hyprsunset; the Control Center switch is shell work),
screenshots (Super+Shift+3/4/5), lid and clamshell (`grassfield-lid`), graceful Log Out / Restart / Shut Down
(`grassfield-session-end`), the keyboard defaults, post-boot hooks and the power profile at start.
Omarchy capabilities Grassfield uses through Omarchy's own commands, packages and data (ADR-0045; rows in the table below):
screen recording in the capture toolbar (gpu-screen-recorder), text and QR codes in images (tesseract, zbar), Emoji & Symbols
(Omarchy's emoji list and insert command), external display brightness (DDC/CI), dictation (voxtype), fingerprint and security
key, Remote Login, disk encryption password and hibernation setups (Omarchy's scripts in Omarchy's terminal), Wi-Fi sharing
by QR code, terminal themes that follow the appearance, per-application window rules, LocalSend, weather. Clipboard history
is Grassfield's own (ADR-0034). Deferred to M6 (ADR-0045 OC-15): factory reset and first-run provisioning.
Not provided (Omarchy features without a macOS counterpart): Omarchy menu, tmux/herdr key menus, 1Password lock on lock.

### Updating Omarchy with Grassfield installed
Run the Omarchy update from the **Omarchy session** (or a TTY): it restarts the Omarchy shell at its end and Omarchy's
pacman hooks reload every Hyprland instance. In a Grassfield session the restart step is shadowed by a no-op
(`tests/shell/omarchy_guard.sh`), so a forgotten update in a Grassfield terminal does no harm, but the Omarchy shell is not
restarted either and `grassfield-shell` is not touched (log out and in to restart it). A reload from Omarchy's hooks still
reaches the Grassfield instance: `grassfield.core` clears its modules and a new Lua state loads the config again (T-OM4 in
the audit: verify in the nested session). After the update: `just check-omarchy`,
`Hyprland --verify-config --config /usr/share/grassfield/hypr/session.lua`, and after a Hyprland upgrade rebuild the plugin
first (ABI hash above).

### Pending for Omarchy 4.0.6 (Qt 6.12, Quickshell 0.3.2): UNVERIFIED here
Omarchy stable is 4.0.6 (installed: 4.0.4); 4.0.5 moves the system to Qt 6.12 and Quickshell 0.3.2. None of this has run on
Grassfield: take a snapshot, update, then run `just test`, `just check-omarchy --require`, the lock and polkit security tests
and the owner L2 list. The lock fixes of 4.0.5/4.0.6 (stale `locked` binding before suspend, stranded-lock takeover) are in
Omarchy's plugin, of which Grassfield's `shell/security/lock/Lock.qml` is an adapted fork (review item for the security
owner; no upstream commit is pinned in the file header).

### Corrections for the documents (integrator)
- ADR-0001, Decision: "If the include fails ... the shell shows one notification" is now true (a critical notification from
  `session.lua`, text fixed); the include is a capability check, no longer the version file; it loads `default.hypr.input` too.
  "XDG_CURRENT_DESKTOP=Hyprland is kept" stays (`packaging/uwsm/env-grassfield` comment fixed): `Hyprland:Grassfield` exists only
  while uwsm prepares the session, so `OnlyShowIn=Grassfield` cannot match; `XDG_SESSION_DESKTOP=Grassfield` identifies it.
- ADR-0002, Keyboard: Ctrl+arrows and Ctrl+1..9 (Spaces) and Ctrl+Up (Overview) are kept as on macOS; Alt+Left/Right,
  Alt+Shift+Left/Right, Alt+Backspace, Alt+Delete are forwarded to the focused window as Ctrl word keys (not in terminals);
  Super+1..9 and Super+Up reach Ctrl+1..9 and Ctrl+Up in the application (Command+number); Super+[ and Super+] send Alt+Left/Right.
- ADR-0009 (per-ABI plugin variants) is still not implemented (one `.so`).
