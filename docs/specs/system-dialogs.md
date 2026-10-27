# System dialogs spec · shell-engineer, platform-engineer, apps-engineer, security-engineer · 1.0 (ADR-0035)

Status: step 0 (docs only, owner brief 2026-10-27 « toutes les boîtes de dialogue au design Grassfield »). Nothing below is
built yet. Decisions and delivery order: `docs/decisions/ADR-0035-system-dialogs.md`. Inventory (every dialog of a
Grassfield session, its provider and category): `docs/audits/dialogs-2026-10-27/inventory.md`. Row ids (P*, H*, S*, O*, T*,
G*) refer to that inventory.

This spec covers the surfaces Grassfield draws in place of another desktop's (category A of the inventory) and the toolkit
appearance alignment (category C). Each section follows Appendix G of the master prompt. Geometry is measured from
`design/reference/` (git-ignored, never committed) in the step that builds the surface; values here are structure, not
measurements.

## Common rules (every surface of this spec)
1. **Look.** Built on `Grassfield.Ui` only: the alert shape of `shell/overlay/Dialog.qml` (icon at the top left, bold title,
   left-aligned message, equal-width capsule buttons) or its sheet shape (title, content, hairline above a 64-pt footer, 24-pt
   push buttons at the bottom right); the frame moves into `Grassfield.Ui` (a public type, `docs/specs/ui-api.md`) in the
   first step whose surface lives outside the shell process. The panel material of ADR-0024 and the existing tokens
   (`Tokens.panelAlertWidth`, `radiusAlert`, `panelSheet*`, `radiusSheet`, `buttonHeight`, `alertButtonHeight`,
   `controlFocusOutline`). No hardcoded value; a new measured value is a new token with its source note. F1 target as ADR-0024 (geometry ±1 pt, tints ±0.1); A2 holds at every transparency ≤ 0.6
   and with Reduce Transparency (opaque tint).
2. **Appearance.** Light, dark and auto follow `appearance` live (`ui/Grassfield/Ui/AutoAppearance.js`; the C++ copy in
   `apps/autoappearance.h` for processes outside the shell); the accent follows `accent.color`; Increase Contrast and Reduce
   Motion as the rest of the shell (crossfades ≤ 100 ms).
3. **Keyboard.** Every control reachable with Tab and Shift+Tab, a visible focus ring (`Appearance.focusRingColor`), Return
   activates the default button, Esc (and Cmd-.) cancels, Space activates the focused button. A destructive button is never
   the default. Focus enters the surface when it maps and returns to the window that asked when it closes (the platform's
   focus-return path, ADR-0012).
4. **Accessibility.** `Accessible.role: Accessible.Dialog`, `Accessible.name` = the title, `Accessible.description` = the
   message; every control has a role and a name; secure fields expose no text (A1).
5. **i18n.** Every visible string in `qsTr()` (en + fr, `just check` i18n gate I1); strings that come from an application
   (titles, labels, file names, app names, purpose strings) are shown as plain text, never rich text, flattened to one line
   and capped in rendered lines, as the polkit sheet does (`shell/security/polkit/AuthDialog.qml`). The app is named by its
   desktop entry's `Name` in the UI language, its id under it when it is not installed (as the Settings privacy pane does).
6. **Over the lock.** Nothing opens while the session is locked (`SessionState.refuses(<surface>)`, security.md § Nothing
   opens over the lock). A request that arrives while locked waits and shows after the unlock without the keyboard until a
   click (the polkit hold rule), or is refused with the backend's "cancelled" answer when the protocol has a timeout.
7. **Never block, never lose.** Each surface has a fallback that ends in the stock provider (the GTK portal backend, the
   stock picker, the stock dialog) when the Grassfield surface cannot be shown within its start deadline. An application never
   waits forever on Grassfield: every wait is bounded and ends with a defined answer (the stock surface, or "cancelled").
8. **Dev guard.** In a dev session (ADR-0019) nothing reaches the owner's real buses or files: tests run on a private session
   bus with fake peers (fake portal frontend, fake prompter caller, fake xdph caller), never the real bus or the real
   secrets. Every new IPC function is listed in `docs/specs/security.md` § IPC surface (`tests/security/ipc_inventory.sh`).
9. **No Apple names or assets.** No Apple trademark in any string (master-prompt §14); own glyphs from `branding/`.

## 1. Open and Save panels (FileChooser; inventory P1–P3; ADR-0035 D-4)

### macOS reference behavior (described in words)
- Attached to the requesting window as a sheet: a card centred over the parent, the parent dimmed and inert; with no parent
  window, a free-standing panel centred on the active display. One panel per parent; the app's other windows stay usable.
- Open panel = a Finder browser: sidebar (Favorites: Recents, Applications, Desktop, Documents, Downloads, Home; Locations;
  Tags), toolbar with Back/Forward, the view switcher (icons, list, columns, gallery), the path pop-up (the folder's name; its
  menu lists the enclosing folders), search field. Items the app cannot open are dimmed, not hidden. Footer: the app's options
  (format pop-up, check boxes) when it has any, Cancel, the default button ("Open" or the app's label).
- Folder mode: only folders can be chosen; the default button reads "Open" or the app's label ("Choose").
- Multiple selection when the app allows it (Shift/Cmd click, Cmd-A).
- Save panel: compact by default (Save As field with the name selected without its extension, Tags, Where pop-up with recent
  places) with a disclosure button that expands it to the full browser (remembered per app). New Folder in the expanded panel.
  A Format pop-up when the app offers formats; changing it changes the extension. "Hide extension". Saving over an existing
  file asks "“name” already exists. Do you want to replace it?" with "A file or folder with the same name already exists in
  the folder “X”. Replacing it will overwrite its current contents.": Cancel (default) / Replace.
- Keyboard: Return = default button; Esc or Cmd-. = Cancel; Cmd-Shift-G, or typing "/" or "~", opens Go to Folder (Tab
  completes); Cmd-Up enclosing folder, Cmd-Down open; Cmd-Shift-D Desktop, Cmd-Shift-H Home, Cmd-Shift-O Documents,
  Cmd-Shift-A Applications, Cmd-Option-L Downloads; Cmd-1…4 views; Cmd-Shift-. hidden files; Space = Quick Look; type to
  select; Tab cycles name field, sidebar, list.
- Remembers the last folder and view per app; dragging a file from Finder onto the panel selects it.

### Purpose and non-goals
Purpose: every portal Open/Save request of the Grassfield session gets this panel; the session routes GTK 3's native chooser
there too (`GTK_USE_PORTAL=1`, owner decision Q3). Non-goals: the in-process GTK 3 dialogs of Qt apps (`gtk3` theme) and
LibreOffice (ADR-0035 D-8); remote (KIO network) results; Tags editing in the Save panel before Files has tags (FP rows of the Finder parity matrix).

### Functional requirements
- FC1 `OpenFile` with `multiple`, `directory`, `filters`, `current_filter`, `choices`, `accept_label`, `current_folder`;
  returns `uris` (file://), `choices`, `current_filter`; response 0 on accept, 1 on cancel, 2 on error.
- FC2 `SaveFile` with `current_name` (name selected without extension), `current_folder`, `current_file`, filters/choices;
  the replace alert when the target exists; returns one `uri`.
- FC3 `SaveFiles` (folder choice for several `files`), returns the folder-based `uris`; the replace alert lists the clashes.
- FC4 parent: the panel is the modal child of the app's toplevel through xdg-foreign v2 + xdg-dialog v1; without a handle,
  a centred floating window above the app.
- FC5 the browser is Files': sidebar, the four views, path pop-up, search in the folder, Quick Look on Space, Go to Folder,
  hidden files, per-app last folder and view (state file listed in ADR-0020).
- FC6 Options area: each `choices` entry is a pop-up (with options) or a check box (without).
- FC7 never blocks: the UI shows within 3 s or the request is forwarded to x-d-p-gtk and its answer relayed (ADR-0035 D-4).
- FC8 over the lock: no panel while locked (common rule 6); a request that arrives then waits for the unlock.

### Acceptance criteria (L0 unit, L1 nested)
- A-FC1 (L0) option mapping table tested on a fake frontend (private bus): every option of FC1–FC3 in, the exact `a{sv}` out.
- A-FC2 (L1) Chromium "Open File…" and "Save Page As…" in a nested session show the Grassfield panel attached to the window
  (screenshot), Return opens, Esc cancels and the app receives the answer.
- A-FC3 (L1) the panel's first show ≤ 300 ms warm (P4-like log line), ≤ 80 MB RSS while open, back to ≤ 25 MB 60 s after
  the last panel closed (the service stays for the Settings interface).
- A-FC4 (L0) fallback: a backend whose QML fails to load forwards to a fake gtk backend and relays its answer.
- A-FC5 F1 side by side with the reference captures (open, save compact, save expanded, replace alert) in both appearances.

### Interfaces / contracts
- `org.freedesktop.impl.portal.FileChooser` (version as the frontend 1.22.1 expects), bus name
  `org.freedesktop.impl.portal.desktop.grassfield`, `grassfield.portal` in
  `/usr/share/grassfield/xdg/xdg-desktop-portal/portals/`.
- Per-app state: `$XDG_STATE_HOME/grassfield/portal-filechooser.json` (last folder, view, expanded), ADR-0020 row.

### Degraded behavior
Backend missing or crashed: the frontend's next name, `gtk`. UI failure: forwarded to gtk. Files' KIO slaves missing: local
folders only, a note in the sidebar.

### Automated tests · Manual verification steps
Unit (fake frontend, fake gtk peer, scratch HOME); nested (`tests/visual/flow-filechooser.sh`, Chromium and a GTK 4 test app);
manual: an Electron app (Obsidian) Open and Save, a Flatpak if installed.

### Performance · Accessibility · i18n
P4-like budget above; common rules 3–5; the panel's strings in the Grassfield catalogue, the app's labels and filter names as
given.

### Known limitations
Not a true sheet (a modal child window dimming its parent, not a card inside it); remote locations refused; apps that draw
their own dialog in-process are not covered (D-8); the Tags field waits for Files' tags.

## 2. Open With and permission alerts (AppChooser, Access; P4–P7; ADR-0035 D-5)

### macOS reference behavior
- Choose Application: an Open panel rooted at Applications with "Enable: Recommended Applications / All Applications" and
  "Always Open With"; Return opens with the selected app.
- Privacy alert (TCC): the alert shape (app icon at the top left, bold title "“App” would like to access the camera.", the app's
  purpose as the message), "Don't Allow" and "Allow" of equal width; for camera, microphone and screen recording neither is
  the default (Return does nothing until a button has focus); asked once per app and category, the answer is changeable in
  System Settings > Privacy & Security; never over the lock screen.

### Functional requirements
- OW1 `ChooseApplication(handle, app_id, parent_window, choices, options{last_choice, modal, content_type, uri, filename,
  activation_token})`: list the `choices` (desktop ids) with icon and name, `last_choice` selected; "All Applications" adds
  every app that can open the type (DesktopEntries); a search field filters; "Always Open With" maps to the frontend's
  `always` handling; `UpdateChoices` refreshes the list live; returns `choice` and `activation_token`.
- AC1 `AccessDialog(handle, app_id, parent_window, title, subtitle, body, options{deny_label, grant_label, icon, choices})`:
  the alert with the app's icon and name (from `app_id`; "An application" when empty), title/subtitle/body as given (plain
  text, capped), the labels given (else "Don't Allow"/"Allow"), `choices` as radio groups or check boxes; returns response
  0 (grant) or 1 (deny) and the choices.
- AC2 no default button on Camera and Screenshot alerts (the frontend's icon or title tells which: `camera-web-symbolic`,
  `applets-screenshooter-symbolic`); other alerts default to the grant label as the frontend's wording intends.
- AC3 over the lock: refused while locked with response 2 (the frontend then answers the app "cancelled"; it asks again next
  time, nothing is stored).

### Acceptance criteria
- A-OW1 (L0) fake frontend: every option in, the answer out; a desktop id that is not installed is not listed.
- A-AC1 (L1) a test client asks for the camera through the real frontend in a nested session with a private permission store:
  the Grassfield alert shows; Allow stores `yes` (read back by Settings > Privacy & Security's model).
- A-AC2 F1 for the alert (both appearances, transparency 0 and 0.6, A2).

### Degraded behavior · Known limitations
As section 1 (forward to gtk). The frontend's wording is xdg-desktop-portal's ("Allow %s to Use the Camera?"), not macOS's
sentence; Grassfield does not rewrite it (it is translated upstream).

## 3. Screen-sharing picker (P10; ADR-0035 D-6)

### macOS reference behavior
See ADR-0035 D-6 and the inventory: the system picker offers the entire screen or a window (hover highlights it, a click picks
it), Esc cancels; while sharing, the menu bar shows the screen-recording indicator naming the app.

### Functional requirements
- SP1 the stand-ins print exactly the grammar of ADR-0035 D-6 and nothing else on stdout; a cancel prints nothing.
- SP2 the panel: tabs "Entire Screen" (one live thumbnail per display, the display's name), "Window" (live thumbnails of the
  windows in `XDPH_WINDOW_SHARING_LIST`, grouped by app, title under each, protected windows greyed with "This window can't be
  shared"), "Selection" (crosshair, region relative to its display); "Remember this choice" (initial state from
  `--allow-token`); Cancel / Share (default once something is selected); double-click shares at once.
- SP3 keyboard: arrows move in the grid, Return shares, Esc cancels, Cmd-1/2/3 switch tabs.
- SP4 the recording indicator in the menu bar while Hyprland reports an active screencast; its menu names the app(s) sharing.
- SP5 fallback to the stock picker within 1 s when the shell is absent, locked, or the IPC call fails.

### Acceptance criteria
- A-SP1 (L0) the stand-in's output for each choice parsed by a copy of xdph 1.4.1's parser (`ScreencopyShared.cpp:70-125`)
  gives the intended selection; malformed answers never reach stdout.
- A-SP2 (L1) Chromium "Share screen" in a nested session: the panel shows, a window share streams that window (screenshot of
  the receiving tab), the indicator appears and goes away when the share stops.
- A-SP3 (L1) shell stopped: the stock picker opens.

### Known limitations
A user `xdph.conf` naming another picker is respected; xdph blocks its main loop while any picker runs (upstream).

## 4. Not responding (H1; ADR-0035 D-3)

### macOS reference behavior
No alert. After a few seconds without event processing the pointer becomes the wait cursor over the app's windows; the app's
Dock menu shows "Application Not Responding" and Force Quit in place of Quit; Force Quit Applications lists the app with
"(Not Responding)" in red; the system never kills an app on its own.

### Functional requirements
- NR1 the `hyprland-dialog` stand-in reports (pid of the stand-in, class, title) for an ANR call in en_US or fr_FR and waits
  silently; every other call is the stock dialog (exec).
- NR2 the shell marks the matching app as not responding while the stand-in lives: Force Quit lists it with "(Not
  Responding)" (destructive colour, pre-selected when the panel opens), its Dock menu starts with a disabled "Application Not
  Responding" item and offers "Force Quit", its app menu's Quit item reads "Force Quit “App”".
- NR3 the mark clears within 1 s of the stand-in's end (the app answered, closed, or was killed).
- NR4 no alert, no sound, no focus change.

### Acceptance criteria
- A-NR1 (L0) stand-in with a fake shell: en and fr texts parsed; ambiguous or other-locale texts exec the fake stock dialog.
- A-NR2 (L1) a test client that stops answering pings (a fixture that blocks its event loop) in a nested session: after ~4.5 s
  Force Quit shows "(Not Responding)"; the mark clears when the fixture resumes.

### Known limitations
No wait cursor (Hyprland only tints the window); the ANR state is known only through Hyprland's dialog call.

## 5. Password prompts (gcr system prompts, udiskie, NetworkManager; S1–S4, S6, S8; ADR-0035 D-9, owner decisions Q1 = S2 and Q10)
Needs the owner's amendment of the CLAUDE.md security rule (text in ADR-0035 D-9) before any code; R12 applies (opus PASS,
fail closed where a secret is involved, nothing logged).

### macOS reference behavior
System-modal alert centred on the active display, above every window, never on the lock screen: lock icon (or the app's),
bold title, a message naming the requesting app ("“App” wants to use your confidential information stored in “item” in your
keychain."), a secure password field, a check box where relevant ("Remember this password in my keychain"), buttons "Deny"
and "Allow" (default) or "Cancel"/"OK". A wrong password shakes the alert and clears the field. Not visible to screenshots or
screen sharing. Encrypted disk: "Enter a password to unlock the disk “Name”." with "Remember this password in my keychain",
Cancel / Unlock.

### Functional requirements
- SC1 `grassfield-prompter` owns `org.gnome.keyring.SystemPrompter` while the shell is connected (requested without
  `ALLOW_REPLACEMENT`, so nobody can take it away; queued behind a stock gcr-prompter that still holds it, which frees it 10 s
  after its last prompt); libgcr runs `BeginPrompting`/`PerformPrompt`/`StopPrompting` and the `sx-aes-1` exchange; one prompt
  at a time, a second caller gets gcr's "in progress" answer as with the stock prompter.
- SC2 the shell sheet shows, as plain text with bounded lines: `title` (or "Authentication required"), `message`,
  `description`, `warning` (red, under the field), the requester (resolved by the bridge from `GetConnectionCredentials`: the
  desktop entry's name, else the executable's name, and the PID), a secure field (`password-new`: New and Verify fields and a
  strength bar), `choice-label` as a check box, `continue-label` / `cancel-label` (else "OK"/"Cancel"); a `confirm` prompt has
  no field.
- SC3 security rules copied from the polkit sheet: nothing over the lock (a prompt that arrives while locked waits and is
  shown after the unlock without the keyboard until a click 500 ms after it appears); the field is cleared after each answer
  and on close; `ImhSensitiveData`, no input method; the surface is excluded from screen capture; Esc and Cancel answer
  "no"; the shell never logs any field.
- SC4 socket protocol (bridge ↔ shell): one JSON object per line, versioned (`prompter/1`); the bridge accepts only the shell
  (uid and cgroup checked); the password travels once, in one message, and both sides overwrite their buffers after use.
- SC5 fallback: shell not connected → the bridge releases the name (the stock gcr-prompter is activated for the next prompt);
  it takes the name again when the shell reconnects; a prompt in flight when the shell disconnects is answered "no".
- SC6 udiskie: `grassfield-askpass udiskie <device>` opens a gcr prompt ("Enter a password to unlock the disk “%1”.",
  "Remember this password" when udiskie offers its cache), prints the password and a newline on stdout, exit 0; cancel: no
  output, exit 1 (udiskie then leaves the disk locked).
- SC7 NetworkManager: the bridge's secret agent answers `GetSecrets` for `802-11-wireless-security` and `802-1x` with the
  sheet's Wi-Fi form ("The Wi-Fi network “%1” requires a WPA2 password.", Show password, Cancel / Join; identity and password
  for 802.1X), `CancelGetSecrets` closes it, `SaveSecrets`/`DeleteSecrets` store nothing in Grassfield (NM keeps the secret as
  the connection says); other setting names (VPN) answer "no secrets" so NM asks the VPN plugin's own dialog; while the shell is
  disconnected the agent unregisters.

### Acceptance criteria
- A-SC1 (L0) a fake gcr client on a private bus gets the password through the exchange; a fake process queued on the name never
  receives a prompt while the bridge holds it; with the shell disconnected, the fake stock prompter is activated.
- A-SC2 (L0) mutants: removing the uid/cgroup check, the lock refusal or the buffer wipe fails a test.
- A-SC3 (L1) nested: pinentry-gnome3 with a throwaway GNUPGHOME and key asks through the Grassfield sheet (screenshot,
  "visual NOT verified" otherwise); udiskie with a loop-mounted LUKS image is the owner's L2 check (root needed).
- A-SC4 (L0) a fake NetworkManager on a private system-style bus asks for a PSK and receives the typed secret; a VPN request
  gets "no secrets".
- A-SC5 opus PASS.

### Known limitations
Name ownership is the only authorization (upstream design): a same-user process can still show a fake stock prompt through
gcr-prompter while the bridge is down; the requester shown is the D-Bus caller (gnome-keyring or gpg-agent for most prompts,
with the original app named only when the caller's text names it).

## 6. Toolkit appearance (category C; ADR-0035 D-8)

### macOS reference behavior
Every app follows the system appearance (Light, Dark, Auto) and the accent colour live; Increase Contrast and Reduce Motion
apply to every app.

### Functional requirements
- AP1 `grassfield-portal` serves `org.freedesktop.impl.portal.Settings` (`Read`, `ReadAll`, `ReadOne`, `SettingChanged`) for
  `org.freedesktop.appearance` (`color-scheme` u: 1 dark, 2 light; `accent-color` (ddd) sRGB; `contrast` u: 1 when Increase
  Contrast; `reduced-motion` u: 1 when Reduce Motion) and `org.gnome.desktop.interface` (`gtk-theme`, `color-scheme`,
  `enable-animations`), from the Grassfield settings file (watched, ADR-0020 contract); `auto` follows `AutoAppearance`'s
  schedule with a timer at the next switch time.
- AP2 the session's `hyprland-portals.conf` lists `org.freedesktop.impl.portal.Settings=grassfield;gtk`.
- AP3 `GTK_USE_PORTAL=1` and the `XDG_DATA_DIRS` entry in `env-grassfield`; never `GTK_THEME`.
- AP4 (owner decision Q7) `/usr/share/themes/Grassfield-<accent>{,-dark}/gtk-3.0/gtk.css` and `gtk-4.0/gtk.css`,
  generated at build time from `ui/tokens/tokens.json` (accent colours, control and window radii, selection colours), each
  `@import`ing GTK's built-in Adwaita/Default resource and overriding only named colours and radii (MIT, no copy of Adwaita);
  `gtk-theme` names the matching one.
- AP5 a change of appearance, accent, contrast or motion in Settings or Quick Settings reaches running GTK 3 (with the
  variable), GTK 4, libadwaita, Qt (`gtk3` theme), Chromium, Electron and Firefox within 1 s.

### Acceptance criteria
- A-AP1 (L0) the real xdg-desktop-portal 1.22.1 on a private bus with `XDG_DESKTOP_PORTAL_DIR` pointing at a test copy of the
  session configuration and the Grassfield backend: `ReadAll` returns Grassfield's values first and x-d-p-gtk's (a fake) for
  the rest; a settings-file change emits `SettingChanged`.
- A-AP2 (L1) nested: a GTK 3 test window, a GTK 4/libadwaita one and a Qt `gtk3` one switch to light and back within 1 s of a
  Settings change (screenshots).
- A-AP3 A2 contrast of the GTK themes (selection text on the accent) for the nine accents, both appearances.

### Degraded behavior
Backend absent: x-d-p-gtk's values (the user's dconf, Omarchy's theme), as today. GTK theme missing: GTK falls back to its
default theme.

### Known limitations
x-d-p-gtk's own remaining dialogs (print, account) and apps that read dconf directly follow the user's GTK theme, not the
Grassfield appearance; libadwaita snaps the accent to its nine accents; Qt reads no accent (its highlight comes from the GTK 3
theme); libadwaita apps keep libadwaita's radii (only GTK 3 and plain GTK 4 apps get the Grassfield themes' radii).

## 7. Print sheet (Print portal; P11; ADR-0035 D-7, owner decision Q6)

### macOS reference behavior
The print sheet attaches to the document's window: a preview of the pages on the left (page arrows under it), on the right
Printer, Presets, Copies, Pages (All, From–to, Selection), then Paper Size, Orientation, Scale, Two-Sided and the printer's
options in collapsible sections; at the bottom "PDF" (a menu: Save as PDF…, Open in Preview) and Cancel / Print (default).
The last-used printer and settings are remembered per app.

### Functional requirements
- PR1 `PreparePrint`: the sheet without preview (the document is not sent yet), every option the destination reports through
  CUPS (`cupsCopyDestInfo`), defaults from the destination; returns GTK's `settings` and `page-setup` keys and a token valid
  for the matching `Print` call.
- PR2 `Print` with a valid token: submits the document fd to the chosen CUPS destination with the chosen options, no UI; without
  a token: the full sheet with the preview of the document (Qt PDF for PDF, the first page of PostScript as an image when it can
  be rendered, else "No preview").
- PR3 "Save as PDF…" opens the D-4 save panel and writes the document there (PDF input) instead of printing.
- PR4 no printer: the sheet says "No printers available" with "Add Printer…" (opens Settings > Printers).
- PR5 never blocks: CUPS calls run off the UI thread with deadlines (a dead network printer never freezes the sheet); the UI
  falls back to forwarding the call to x-d-p-gtk as D-4.

### Acceptance criteria
- A-PR1 (L0) a fake CUPS (a scratch `cupsd` with a file-backed queue, or a mocked libcups seam) gets the job with the chosen
  options; option mapping tested in both directions with GTK's key names.
- A-PR2 (L1) evince with `GTK_USE_PORTAL=1` in a nested session prints a test page to a file-backed queue through the
  Grassfield sheet (screenshot).
- A-PR3 F1 against the reference print sheet captures (both appearances).

### Known limitations
Only portal clients get it (Chromium's and Firefox's own previews, LibreOffice, Electron and Qt apps keep their dialogs); no
preview when the app asks for settings before it renders (the portal sends the document later); printer setup stays in
Settings.

## 8. Bluetooth pairing (BlueZ Agent1; inventory O7; ADR-0035 D-11, owner decision Q9)

### macOS reference behavior
Pairing a keyboard shows "Connection Request from “Name”" with the code to type on the device or to compare, Cancel / Connect;
a device that asks for a PIN gets a PIN field; an incoming request from an unknown device asks before anything connects;
nothing is accepted silently.

### Functional requirements
- BT1 the bridge registers a `KeyboardDisplay` agent and becomes the default agent while the shell is connected; Omarchy's
  `bt-agent` does not run in the Grassfield session (packaged drop-in), unless the step's BlueZ check shows that pairing without
  any agent is refused, in which case `bt-agent` stays as the fallback and the bridge only requests to be the default.
- BT2 each `Agent1` method maps to one form of the secret sheet: PIN or passkey field (`RequestPinCode`, `RequestPasskey`),
  code to type (`DisplayPinCode`, `DisplayPasskey`, updated on each `entered` count), code to confirm (`RequestConfirmation`),
  yes/no (`RequestAuthorization`, `AuthorizeService`, naming the device and, for a service, its profile); `Cancel` closes the
  sheet; a timeout of BlueZ answers "rejected".
- BT3 the device is named by its alias from `org.bluez.Device1` (plain text, capped), with its icon class.

### Acceptance criteria
- A-BT1 (L0) a fake BlueZ on a private system-style bus drives every method; mutants removing the "no automatic yes" rule fail.
- A-BT2 (L2, owner) pairing a keyboard that needs a passkey and a phone that compares a code; opus PASS before merge.

### Known limitations
Agent precedence with another agent that also asks to be the default is BlueZ's (the last one to ask wins); legacy devices
with fixed PINs need the user to know the PIN.
