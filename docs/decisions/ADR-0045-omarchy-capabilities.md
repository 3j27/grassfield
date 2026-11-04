# ADR-0045: Omarchy's capabilities in the Grassfield session
Status: Proposed (applied provisionally, owner decision of 2026-11-04: « Applique tout le plan et fait le nécessaire pour tout
finaliser ») · Date: 2026-11-04 · Decider: owner (plan), integrator (design, merge after review) · Number: 0045 (0044 is the main
display)

## Context

Grassfield is a separate session on top of an unchanged Omarchy 4 (D1, ADR-0001). It already reuses Omarchy's base: the
Hyprland environment and keyboard defaults (`config/hypr/grassfield/omarchy.lua`), the PAM services of the lock (fingerprint
included when Omarchy set it up), the update chain (`omarchy-update`, snapshot, keyring, migrations, hooks), the Store on
`omarchy-pkg-*` and `omarchy-webapp-*`, power profiles, the 1Password/Bitwarden screen-share rules, SDDM, uwsm and Limine.

What it sets aside on purpose is Omarchy's *surface*: omarchy-shell, the Omarchy menu, the tiling key bindings (D2, macOS
model). Between the two sits a set of Omarchy commands, packages and data that have a macOS counterpart and that Grassfield
did not use. On 2026-11-04 the owner asked whether it is a pity to leave them aside; the integrator compared Omarchy v4.0.6
(`basecamp/omarchy@237f1b4`, the tag of the installed 4.0.6) command by command with Grassfield and proposed a plan in three
priorities; the owner then asked to apply all of it.

Verified on the v4.0.6 tree: every command named below exists; `ddcutil`, `gpu-screen-recorder`, `hyprpicker`, `localsend`,
`qrencode`, `tesseract`, `tesseract-data-eng`, `wtype` and `zbar` are in `install/omarchy-base.packages` (installed with
Omarchy, so no new dependency for the session); `voxtype` (dictation), `fprintd` and `pam-u2f` are optional, installed by
Omarchy's own setup commands. Nothing of this was checked on the owner's machine from the cloud session (UNVERIFIED there).

`docs/compat.md` listed "screen recording bindings" and the "emoji picker" among the Omarchy features "without a macOS
counterpart": wrong (macOS has Shift-Command-5 recording and Emoji & Symbols); it also listed clipboard history, which
Grassfield has since ADR-0034. Corrected with this ADR.

## Decision

### OC-0 Rules common to every capability
1. **Reuse, do not fork.** Grassfield runs Omarchy's own command, package or data file as it is. A Grassfield copy of Omarchy
   code is made only when the command cannot serve as is (it draws Omarchy's UI, talks to omarchy-shell), MIT attribution
   kept, and the upstream file pinned in `docs/upstream/omarchy.lock` (`just check-upstream`).
2. **Every Omarchy path, command or unit used** gets a row in `docs/compat.md` and an entry in `scripts/dev/omarchy-compat.sh`
   (`just check-omarchy`), with what happens when it is missing.
3. **Graceful degradation.** A missing command or package hides the control or shows one line that says what is missing; it
   never raises an error dialog or a broken surface. Detection with `command -v` / `QStandardPaths::findExecutable` at use
   time, not at build time.
4. **Root goes through Omarchy's terminal, as Omarchy's own menu does.** A setup that needs root (fingerprint, security key,
   SSH, disk password, hibernation, dictation install) is started as
   `omarchy-launch-floating-terminal-with-presentation <omarchy-command>`, the exact argv of `default/omarchy/omarchy-menu.jsonc`
   (the same path Software Update's "Update Now" already uses, ADR-0033). Grassfield runs no code as root, writes no PAM or
   system file, adds no polkit policy. Each argv is an exact entry of the Settings launch allowlist (`systemguard.cpp`
   `isLaunch`); no argument comes from the UI. A dev session launches nothing (ADR-0019 dev guard). The page reads the state
   again when the terminal's window closes or Settings becomes active again.
5. **Names.** No Apple name (`tests/ci/ui_names.py`). Names used: "Screen Recording" « Enregistrement de l'écran », "Select
   Text in Images" « Sélectionner le texte des images », "Emoji & Symbols" « Emojis et symboles », "Dictation" « Dictée »,
   "Fingerprint & Security Key" « Empreinte et clé de sécurité », "Sharing" « Partage », "Remote Login" « Session à distance »,
   "Disk Encryption" « Chiffrement du disque », "Hibernation" « Hibernation », "Share Network" « Partager le réseau »,
   "Terminal and Developer Apps" « Terminal et apps de développement », "Send with LocalSend" « Envoyer avec LocalSend »,
   "Weather" « Météo ».
7. **macOS 27 design for every tool (owner, 2026-11-04: « Et tous ces outils doivent avoir un design mac os 27 »).** Every
   surface this ADR adds is a Grassfield surface drawn with Grassfield.Ui components and tokens to macOS 27 (layout,
   proportions, radii, states, motion; ADR-0024 glass; ADR-0039 rules), never an Omarchy UI, a gum prompt or a bare terminal
   when the system offers a way around it. So the setups of OC-0.4 are native wherever a system service has its own polkit
   action (the ADR-0030 path: the service asks polkit, Grassfield's polkit sheet asks the password, as macOS does):
   - Remote Login switch: systemd's `EnableUnitFiles`/`DisableUnitFiles` and `StartUnit`/`StopUnit` on `sshd.service` only,
     when OpenSSH is installed;
   - Disk Encryption "Change Password…": a macOS 27 sheet (current password, new password, verify) calling UDisks2's
     `org.freedesktop.UDisks2.Encrypted.ChangePassphrase` on the root file system's LUKS device, when UDisks2 answers;
   - Fingerprint: enrolling and deleting fingers in a macOS 27 sheet through fprintd's D-Bus API (`net.reactivated.Fprint`:
     Claim, EnrollStart, the EnrollStatus signal, EnrollStop, Release, ListEnrolledFingers, DeleteEnrolledFingers2), when
     fprintd is installed.
   What no system service exposes (installing a package, editing PAM files, the FIDO2 key setup, the hibernation swap file,
   initramfs and boot entry, the first OpenSSH, fprintd or voxtype install) stays Omarchy's script in Omarchy's terminal, opened
   from a macOS 27 sheet that says what will happen and why a terminal opens. That gap is documented under "Known
   limitations" (master-prompt §1 honesty rule), not hidden.
8. **Owner decisions superseded (2026-11-04).** The 2026-10-26 entries of `docs/specs/settings.md` — "no Sharing pane" and
   "Touch ID & Password is out of scope: fingerprint enrolment belongs to Omarchy's own setup, and changing a password is not a
   Settings action here" — are superseded for exactly what this ADR adds: a Sharing pane holding Remote Login only, a
   Fingerprint & Security Key pane and Disk Encryption's "Change Password…". The spirit stays: the enrolment, the PAM edits and
   the password change are Omarchy's own scripts in Omarchy's terminal; Settings shows the state and starts them.

### OC-1 Capture toolbar and screen recording (priority 1)
- **Shift-Super-5** opens the capture toolbar (macOS 27 layout): a shell layer surface centred at the bottom of the focused
  output: Close · Capture Entire Screen · Capture Selected Window · Capture Selected Portion · Record Entire Screen · Record
  Selected Portion · Options ▾ · the Capture / Record button. Esc closes it. Options: Save to (Desktop, the default, Documents,
  Clipboard, Preview), Timer (None, 5 Seconds, 10 Seconds), Microphone (None, the default input), Show Mouse Pointer. They
  persist in `capture.*` (schema). Shift-Super-3, Shift-Super-4 and Print keep their direct captures.
- **Recording** is `grassfield-capture record screen|selection` with gpu-screen-recorder (Omarchy base package), with the
  backend arguments of `omarchy-capture-screenrecording` (reference, pinned). File: "Screen Recording 2026-11-04 at
  14.05.12.mp4" (translated as the screenshots are) in the chosen place. Microphone only (macOS records no system audio).
- **Stop**: a stop item in the menu bar while recording (it shows the elapsed time), or **Ctrl-Super-Esc** (macOS
  Control-Command-Esc), both `grassfield-capture stop` (SIGINT to the recorder it started, by pid, never by name). The
  recorder's state is a private file in `$XDG_RUNTIME_DIR/grassfield/` that the shell watches. A notice "Screen recording
  saved" with "Open" (Preview plays it) follows.
- **Lock**: no capture starts while the session is locked; a recording stops when the session locks.

### OC-2 Text and QR codes in images (priority 1)
- **Preview** (and Glance, which shares its image view) recognises text in a still image with tesseract when it is installed:
  TSV word boxes, languages = the installed traineddata among the session language and English (`tesseract --list-langs`), run
  in the background on the file (never on the screen), nothing stored. Over text the pointer is an I-beam; a drag selects words
  in reading order; Ctrl/Super-C and the context menu's "Copy Text" copy them; "Select All Text" in the context menu.
- **QR codes**: `zbarimg` with QR only (Omarchy's options: other symbologies false-positive on screen content); each code gives a
  chip under the image: a http(s) link → "Open Link" (`xdg-open` of that URL only), anything else → "Copy".
- Setting `preview.textInImages` (default on), Settings > Language & Region "Select Text in Images" (macOS: Live Text).
- Screenshots reach it the macOS way: the capture notice's "Open in Preview".

### OC-3 Emoji & Symbols (priority 1)
- **Ctrl-Super-Space** (macOS Control-Command-Space) toggles a Grassfield panel at the pointer, clamped to its output: a search
  field, category tabs (Recently Used, Smileys & People, Animals & Nature, Food & Drink, Activity, Travel & Places, Objects,
  Symbols, Flags), a grid; arrows, Return and a click choose; Esc closes. The T0 Edit menu gets "Emoji & Symbols" where T0 has
  an Edit menu.
- **Data**: Omarchy's `$OMARCHY_PATH/shell/plugins/emojis/emojis.json` (1870 entries `{e, k}`, MIT), read at run time, never
  copied. Categories come from the Unicode group boundaries (the first emoji of each group); when a boundary is missing the
  panel shows one "All" group. Search matches Omarchy's English keywords and the translated category names (known limitation:
  no French keywords). Missing file: "Emoji list not available".
- **Insert**: Omarchy's `omarchy-menu-emoji-insert <emoji>` after the panel gave the keyboard back to the window that was active
  (it copies with `wl-copy --sensitive`, so clipboard history does not record it, then sends Shift+Insert). Known limitation:
  the clipboard does not keep its previous content.
- Recently used: `~/.local/state/grassfield/emoji-recents.json`, 30 at most, written privately.

### OC-4 External display brightness (priority 1)
- Outputs without a backlight are driven over DDC/CI with Omarchy's `omarchy-brightness-display-ddc <monitor> [N%|+N%|N%-]`
  (it caches the i2c bus per output). The brightness keys act on the output under the pointer: the backlight for the internal
  panel, DDC for an external display; the OSD shows that output's level. Settings > Displays shows a Brightness slider for an
  external display that answers DDC.
- At most one DDC process per output in flight; a slider drag sends the last value only (DDC writes take 50–200 ms).
- No i2c access (module or group missing): no slider, no key effect for that output, one journal line; documented.

### OC-5 Dictation (priority 1)
- Settings > Keyboard > Dictation (macOS 27): the switch `keyboard.dictation`, the shortcut shown (**Ctrl-Super-X**, Omarchy's
  toggle), "Set Up…" when voxtype is missing (`omarchy-voxtype-install`), "Language Model…" (`omarchy-voxtype-model`),
  "Remove…" (`omarchy-voxtype-remove`), each in Omarchy's terminal (OC-0.4). Recognition is local (Whisper), as on-device
  dictation on macOS.
- The key runs `voxtype record toggle` only when the setting is on and `voxtype` exists; Omarchy's push-to-talk on plain F9 is
  not bound (plain function keys stay the apps').

### OC-6 Fingerprint & Security Key (priority 2)
- A Settings pane "Fingerprint & Security Key" after Lock Screen. Fingerprint: shown when `omarchy-hw-fingerprint` finds a
  reader; state from fprintd's presence and the PAM files Omarchy's script edits (read only); "Set Up…" /
  "Remove…" = `omarchy-setup-security-fingerprint` / `omarchy-remove-security-fingerprint`. Security key (FIDO2): state from
  pam-u2f's presence and the user's key file; "Set Up…" / "Remove…" = `omarchy-setup-security-fido2` /
  `omarchy-remove-security-fido2`. The pane says where each one is used (lock screen, administrator prompts, sudo), as the
  scripts configure them.
- Omarchy's fingerprint setup adds `pam_fprintd` to `/etc/pam.d/polkit-1` and `sudo`: Grassfield's polkit sheet then receives
  fprintd's conversation. How the sheet presents it is a security-module question (R12): checked by the security review; any
  change in `shell/security/` needs the opus reviewer's PASS.

### OC-7 Remote Login (priority 2)
- Settings > General > Sharing, a pane with one row: "Remote Login" (switch). On = `omarchy-setup-security-sshd`, off =
  `omarchy-remove-security-sshd`, both in Omarchy's terminal; state = sshd.service's unit file state (the read-only systemd
  query already allowed in dev). When on: "To log in to this computer remotely, type ssh <user>@<host>".

### OC-8 Disk Encryption (priority 2)
- Settings > Privacy & Security, a "Disk Encryption" group (macOS: FileVault): on/off read from `lsblk` (a crypto_LUKS device
  under the root file system), "Change Password…" = `omarchy-drive-password` in Omarchy's terminal. Encryption cannot be turned
  on in place: the text says so, with no button.

### OC-9 Hibernation (priority 2)
- Settings > Battery (or the energy pane of a desktop), "Hibernation": available when `/sys/power/image_size` exists and
  Omarchy's `omarchy-hibernation-available` agrees; "Set Up…" / "Remove…" = `omarchy-hibernation-setup` /
  `omarchy-hibernation-remove` in Omarchy's terminal. No Hibernate item in the Grassfield menu (macOS has none).

### OC-10 Share a Wi-Fi network (priority 2)
- Wi-Fi > the current network's Details: "Share Network…" shows a QR code of the network (the payload and matrix of
  `omarchy-network-qr`, drawn by Settings) and the network name, not the password in clear. Enterprise networks: the button
  is absent (Omarchy refuses them). Reading the secret uses NetworkManager's own permission model (as `nmcli --show-secrets`).

### OC-11 Terminal and developer apps follow the appearance (priority 3)
- Settings > Appearance, group "Terminal and Developer Apps": "Match Appearance" (default off), "Light Theme" and "Dark Theme"
  (Omarchy's themes, `omarchy-theme-list`). When on, each change of the effective appearance (Light, Dark, Auto at sunrise and
  sunset) runs `grassfield-terminal-theme light|dark`, which runs `omarchy-theme-set "<theme>"` in an environment that keeps
  it out of the Grassfield session: no `HYPRLAND_INSTANCE_SIGNATURE` (no reload of Grassfield's Hyprland), dconf writes to
  Omarchy's own database (not Grassfield's isolated one, ADR-0017), the omarchy-shims first in PATH. Omarchy's theme is shared:
  the Omarchy session gets the same theme and background (said in the pane).

### OC-12 Per-application window rules (priority 3)
- `config/hypr/grassfield/apps.lua`: Omarchy's `default/hypr/apps/*.lua` rules that still hold in a floating-first session
  (Steam, JetBrains, QEMU, Telegram, LocalSend, DaVinci Resolve, Moonlight, GeForce Now, RetroArch, Battle.net, webcam overlay,
  picture-in-picture where Grassfield has none), each citing its source file, the upstream files pinned. Tiling-only rules are
  not ported.

### OC-13 LocalSend (priority 3)
- Files: "Send with LocalSend…" in the Share menu and the context menu of the selection, when `localsend` exists: Omarchy's
  invocation (`omarchy-menu-share`: `systemd-run --user --quiet --collect localsend --headless send <files>`), the selected
  paths as separate arguments after `--`-safe checks (local files only).

### OC-14 Weather widget (priority 3)
- A "Weather" desktop/Notifications widget (small and medium): place, temperature, condition, wind, from wttr.in's JSON for
  Omarchy's saved location (`omarchy-weather-location`, shared with the Omarchy session), refreshed every 30 minutes while the
  widget is placed, never otherwise. The gallery says that the weather comes from wttr.in. "Edit Location…" in its menu writes
  through `omarchy-weather-location --set`.

### OC-15 Deferred to M6 (Grassfield OS, owner go/no-go)
- "Erase All Content and Settings…" (Omarchy's `omarchy-system-factory-reset`, which needs the `@factory` snapshot that only the
  Omarchy Quattro installer takes) and a first-run assistant (`omarchy-provision-first-run`) belong to the ISO. Not built now.

## Consequences
- New Settings rows and panes; a new shell surface (capture toolbar), panel (Emoji & Symbols), widget (Weather) and menu bar
  item (recording); new `capture.*`, `keyboard.dictation`, `preview.textInImages` and `appearance.terminal*` settings; a new
  `grassfield-terminal-theme` helper. No daemon, no root code, no new package dependency of `grassfield-desktop` beyond what
  Omarchy installs (optional: voxtype, fprintd, pam-u2f through Omarchy's own commands).
- More Omarchy coupling: each command is a compat row and, where code derives from it, a pin; `just check-omarchy` fails when
  Omarchy renames one.
- Verification limits of the cloud session that built this: no Hyprland, no Quickshell runtime, no nested session: QML is linted
  with qmllint 6.12 against Quickshell 0.3.2's types, logic is unit-tested offline, and every visual or nested check is
  reported NOT VERIFIED until it runs on the owner's machine.
