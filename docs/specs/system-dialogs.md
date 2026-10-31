# System dialogs spec · shell-engineer, platform-engineer, apps-engineer, security-engineer · 1.0 (ADR-0035)

Status: step 0 (docs only, owner brief 2026-10-27 « toutes les boîtes de dialogue au design Grassfield »); §6 is built
(steps 2b and 2c), §4 (step 3), §9 (step 4a in Files, step 4b in the panels), §1 (step 4b) and §2's permission alerts (step
5a; Open With is step 5b); §4b's notice is built but not active on Hyprland 0.56.2; the other sections are not built yet. Decisions and delivery order:
`docs/decisions/ADR-0035-system-dialogs.md`. Inventory (every dialog of a Grassfield session, its provider and category):
`docs/audits/dialogs-2026-10-27/inventory.md`. Row ids (P*, H*, S*, K*, O*, T*, G*) refer to that inventory; Q* are the
owner's decisions recorded in the ADR.

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
   `controlFocusOutline`). The blur behind a dialog in the shell's Overlay takes the corner the dialog draws
   (`Dialog.cornerRadius`: an alert's `radiusAlert`, a sheet's `radiusSheet`; ADR-0039 step 4). No hardcoded value; a new measured value is a new token with its source note. F1 target as ADR-0024 (geometry ±1 pt, tints ±0.1); A2 holds at every transparency ≤ 0.6
   and with Reduce Transparency (opaque tint).
2. **Appearance.** Light, dark and auto follow `appearance` live (`ui/Grassfield/Ui/AutoAppearance.js`; the C++ copy in
   `apps/autoappearance.h` for processes outside the shell); the accent follows `accent.color`; Increase Contrast and Reduce
   Motion as the rest of the shell (crossfades ≤ 100 ms).
3. **Keyboard.** Every control reachable with Tab and Shift+Tab, a visible focus ring (`Appearance.focusRingColor`), Return
   activates the default button, Esc (and Cmd-.) cancels, Space activates the focused button. A destructive button is never
   the default, with one written exception: the copy/move conflict sheet of Files (section 9), whose default is Replace, as
   the Finder's (owner decision Q18, ADR-0035, 2026-10-28). Focus enters the surface when it maps and returns to the window that asked when it closes (the platform's
   focus-return path, ADR-0012).
4. **Accessibility.** `Accessible.role: Accessible.Dialog`, `Accessible.name` = the title, `Accessible.description` = the
   message; every control has a role and a name; secure fields expose no text (A1).
5. **i18n.** Every visible string in `qsTr()` (en + fr, `just check` i18n gate I1); strings that come from an application
   (titles, labels, file names, app names, purpose strings) are shown as plain text, never rich text, flattened to one line
   and capped in rendered lines, as the polkit sheet does (`shell/security/polkit/AuthDialog.qml`). The app is named by its
   desktop entry's `Name` in the UI language, its id under it when it is not installed (as the Settings privacy pane does).
6. **Over the lock.** Nothing opens while the session is locked (`SessionState.refuses(<surface>)`, security.md § Nothing
   opens over the lock), and no fallback opens a stock surface instead while locked. Each section says whether a request
   that arrives while locked waits (shown after the unlock without the keyboard until a click, the polkit hold rule) or is
   cancelled (the screen-sharing picker, owner decision Q15).
7. **Never block, never lose.** Each surface says what happens when the Grassfield surface cannot be shown: the stock
   provider where that is possible and safe (the stock dialog, the stock picker when unlocked, x-d-p-gtk's backend from a
   running portal process), otherwise a defined answer ("cancelled" or an error). A crashed portal backend is restarted by D-Bus
   activation at the next call; the frontend never falls back to `gtk` at runtime (ADR-0035 D-4). Every wait on the shell is
   bounded (its acknowledgement, its connection, its heartbeat); the user's own choice is not (an open picker or panel waits for
   the user, as the stock ones do).
8. **Dev guard.** In a dev session (ADR-0019) nothing reaches the owner's real buses or files: tests run on a private session
   bus with fake peers (fake portal frontend, fake prompter caller, fake xdph caller), never the real bus or the real
   secrets. Every new IPC function is listed in `docs/specs/security.md` § IPC surface (`tests/security/ipc_inventory.sh`).
9. **No Apple names or assets.** No Apple trademark in any string (master-prompt §14); own glyphs from `branding/`.

## 1. Open and Save panels (FileChooser; inventory P1–P3; ADR-0035 D-4; built in step 4b)

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
- FC7 never blocks: the UI shows within 3 s or the running process forwards the request to x-d-p-gtk's backend and relays its
  answer (ADR-0035 D-4). A crash during a request ends that request with an error (response 2); the next request starts a
  fresh process through D-Bus activation.
- FC9 Files' KIO dialogs are Grassfield's in the panel too (ADR-0035 D-12, section 9 below).
- FC10 the process starts with `GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME` cleared (its unit), so it never waits on the
  portal that waits on it.
- FC8 over the lock: no panel while locked (common rule 6); a request that arrives then waits for the unlock.

Built in step 4b (`grassfield-portal`, `apps/files/qml/FilePanel.qml`; the decisions are ADR-0035 4b-1 to 4b-18):
- FC1–FC3 as written; an Open panel's default button chooses the selection, opens a selected folder in a file panel, and
  chooses the shown folder in a folder panel; SaveFiles asks about every name that exists in the chosen folder in one alert;
  a Save name that is a folder's is refused with a message (4b-6).
- FC4: the panel carries the application's Wayland app id when the frontend names it, so it counts as that application's
  window (Dock, menu bar, Force Quit), else Files'; modal (xdg-dialog) when the application asked and gave a Wayland parent,
  imported with xdg-foreign v2 through KWindowSystem (4b-3, 4b-4, 4b-13).
- FC5: the views, sidebar, path pop-up (the toolbar's folder button), search, Glance on Space, Go to Folder, hidden files and,
  per application in `portal-filechooser.json`, the last folder, the view and whether the Save panel was expanded. Items a filter refuses
  are dimmed and cannot be selected (4b-5); a panel changes no file but New Folder (Save, folder Open, SaveFiles; 4b-7).
- FC6: one filter shows no pop-up; several show "Show:" (Open) or "Format:" (Save, where the extension follows); each choice is
  a pop-up or a check box.
- FC7: the UI loads at the first request; no first frame in 3 s, a QML that does not load, or no display: the call goes to
  x-d-p-gtk; the process quits 60 s after its last request (4b-11). The panels never read the disk on the GUI thread: a
  folder that has not answered for 1 s (5 s at most for many names; a share gone, a sleeping disk) is passed over when a
  panel opens, never hiding the application's own folder, is dimmed in the sidebar until it answers, and Save, Go to Folder
  and SaveFiles say "“name” isn't responding." there; another application's panel is never held up (4b-18).
- FC8: the compositor's session lock hides the panel and keeps the keyboard from it; a panel that first gets the keyboard
  1.5 s or more after it opened takes keys only after a click, and its footer says so (4b-8).
- FC9: Files' KIO sheets, in the panel the user last worked in.
- Keys: Return (default button; Cancel in a replace alert), Esc and Cmd-. (Cancel), Cmd-Shift-G, Cmd-L, "/" and "~" (Go to
  Folder), Cmd-[ and Cmd-] (back, forward), Cmd-Up, Cmd-Down and Cmd-O, Cmd-Shift-H, Cmd-Shift-D, Cmd-Shift-O, Cmd-Option-L,
  Cmd-1 to Cmd-4, Cmd-Shift-. and Cmd-H (hidden files), Cmd-F, Cmd-A (several items), Cmd-Shift-N, Cmd-Y and Space (Glance),
  Cmd-Shift-P (preview), typing to select (Ctrl stands for Cmd, as in Files).

### Acceptance criteria (L0 unit, L1 nested)
- A-FC1 (L0) option mapping table tested on a fake frontend (private bus): every option of FC1–FC3 in, the exact `a{sv}` out.
- A-FC2 (L1) Chromium "Open File…" and "Save Page As…" in a nested session show the Grassfield panel attached to the window
  (screenshot), Return opens, Esc cancels and the app receives the answer.
- A-FC3 (L1) the panel's first show ≤ 300 ms warm (P4-like log line: "grassfield-portal: panel shown in N ms"), ≤ 80 MB
  private memory while open (ADR-0035 decision 4b-9; the resident size reported), and the `grassfield-portal` process gone
  60 s after the last panel closed (Settings lives in the other process, `grassfield-portal-settings`: ≤ 4 MB private,
  ≤ 20 MB resident with the shared libraries, AP1, ADR-0035 decision 2b-11).
- A-FC4 (L0) fallback: a backend whose QML fails to load forwards to a fake gtk backend and relays its answer.
- A-FC6 (L0) crash: the backend killed during `OpenFile` gives the fake frontend an error within the D-Bus timeout, and the next
  `OpenFile` is answered by a newly activated process.
- A-FC7 (L0) start-up: the backend starts and answers with a frontend that never answers its `ReadAll` (no wait on itself).
- A-FC5 F1 side by side with the reference captures (open, save compact, save expanded, replace alert) in both appearances.

Step 4b: A-FC1, A-FC4, A-FC6 and A-FC7 by `tests/unit/portal/` (a fake frontend and a fake x-d-p-gtk on a private
dbus-daemon) and `tests/integration/portal_filechooser.sh` (the real binary, offscreen, and the real frontend 1.22.1 on a
private bus); the offscreen part of A-FC3 there (a warm panel shows in about 50 ms, 28 MB private, the process quits once
idle); the panel's behaviour by `tests/unit/tst_filepanel.qml`. A-FC2, the nested part of A-FC3 and A-FC5 wait for the
integrator's nested pass.

### Interfaces / contracts
- `org.freedesktop.impl.portal.FileChooser` (version as the frontend 1.22.1 expects), bus name
  `org.freedesktop.impl.portal.desktop.grassfield`, `grassfield.portal` in
  `/usr/share/grassfield/xdg/xdg-desktop-portal/portals/`.
- Per-app state: `$XDG_STATE_HOME/grassfield/portal-filechooser.json` (last folder, view, expanded), ADR-0020 row.

### Degraded behavior
Backend's `.portal` file missing when the frontend starts: the frontend's next name, `gtk`. Backend crashed: the request in
flight fails (the app gets an error), D-Bus activation starts a new process at the next call. UI failure in a running process:
forwarded to gtk. Files' KIO workers missing: local folders only, a note in the sidebar.

### Automated tests · Manual verification steps
Unit (fake frontend, fake gtk peer, scratch HOME); nested (`tests/visual/flow-filechooser.sh`, Chromium and a GTK 4 test app);
manual: an Electron app (Obsidian) Open and Save, a Flatpak if installed.

### Performance · Accessibility · i18n
P4-like budget above; common rules 3–5; the panel's strings in the Grassfield catalogue, the app's labels and filter names as
given.

### Known limitations
Not a true sheet (a modal child window dimming its parent, not a card inside it); remote locations refused (4b-10); apps that
draw their own dialog in-process are not covered (D-8). Step 4b also leaves out: the Save panel's Tags field (the panel would
tag a file the application has not written yet) and "Hide extension" (4b-6); Tab completion in Go to Folder; Cmd-Shift-A
(Files' Applications location holds launchers, which a panel shows dimmed and never chooses or starts, 4b-16); a drop on a
panel answers Copy to its source though nothing is copied (the item is only shown); the keyboard moves over dimmed items
(they are passed, never selected). Verified offscreen and on a private bus only: the parent attachment, the dimming of the
parent and the look (A-FC2, A-FC3 nested, A-FC5) are the integrator's nested pass.

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
  activation_token})`: list the `choices` (desktop ids) with icon and name, `last_choice` selected; "All Applications" enables
  every application (DesktopEntries); a search field filters; "Always Open With" is not offered (ADR-0035 5b-3: the interface
  has no key for it; the frontend stops asking after the same choice three times); `UpdateChoices` refreshes the list live;
  returns `choice` and `activation_token`.
- AC1 `AccessDialog(handle, app_id, parent_window, title, subtitle, body, options{deny_label, grant_label, icon, choices})`:
  the alert with the app's icon (from `app_id`) and its name as the frontend's title gives it ("Allow Example to Use the
  Camera?"; "Allow Apps to …" when it cannot name it), title/subtitle/body as given (plain text, capped), the labels given (else "Don't Allow"/"Allow"), `choices` as radio groups or check boxes; returns response
  0 (grant) or 1 (deny) and the choices.
- AC2 no default button on Camera and Screenshot alerts (the frontend's icon or title tells which: `camera-web-symbolic`,
  `applets-screenshooter-symbolic`); other alerts default to the grant label as the frontend's wording intends.
- AC3 over the lock (ADR-0035 5a-3, replacing "refused with response 2", which the frontend keeps as "no"): an alert asked while
  the session is locked opens under the lock and waits; the lock hides it and keeps the keyboard from it; after the unlock it
  takes keys only after a click (the hold rule). Nothing is answered for the user.

### Acceptance criteria
- A-OW1 (L0) fake frontend: every option in, the answer out; a desktop id that is not installed is not listed.
- A-AC1 (L1) a test client asks for the camera through the real frontend in a nested session with a private permission store:
  the Grassfield alert shows; Allow stores `yes` (read back by Settings > Privacy & Security's model).
- A-AC2 F1 for the alert (both appearances, transparency 0 and 0.6, A2).

### Degraded behavior · Known limitations
As section 1 (forward to gtk). The frontend's wording is xdg-desktop-portal's ("Allow %s to Use the Camera?"), not macOS's
sentence. xdg-desktop-portal 1.22.1 sends it in English (its French catalog is empty): Grassfield gives its known wording in
Grassfield's language and its button labels as the alert's own (ADR-0035 5a-9); another version's new wording shows as it
comes until it is added.

Built in step 5a (`grassfield-portal`'s Access, `apps/files/qml/AccessAlert.qml`; the decisions are ADR-0035 5a-1 to 5a-9):
- AC1 as written: the alert shape of the shell's alerts, the frontend's title in bold, its question, its note in the secondary
  colour, its choices (pop-ups and check boxes), "Don't Allow" and "Allow" (or the frontend's labels) of one width; the
  application's icon from its desktop entry, the frontend's symbolic icon, in the text colour, for an application it cannot
  name; the buttons one above the other when they do not fit side by side, the default on top ("Don't Allow" on top where
  neither is the default); one alert at a time, the others waiting in order; the frontend's own wording in Grassfield's language
  (5a-4, 5a-9).
- AC2 for the camera and screen capture (the frontend's icon names them; xdg-desktop-portal 1.22.1 asks nothing about the
  microphone); Return grants the other questions, as AC2 says; Esc and the window closed are "Don't Allow" (5a-6); the keyboard
  starts on the alert, never on a button, and no click, key or close answers for 500 ms each time the alert becomes the active
  window (a key meanwhile starts that time again), and an alert back after more than 1.5 s away (the lock, another window) takes
  keys only after a click, as at a late first activation; that click, armed or not, only ends the hold, and the hint stands in
  the buttons' place meanwhile (5a-5).
- AC3 as above; a request that ends without the user's answer ends with a D-Bus error, so the frontend keeps nothing (5a-3).
  FC7's forward: an alert that has not drawn in 3 s, or a process without a display, goes to x-d-p-gtk's Access.
- Evidence: `tests/unit/portal/tst_access.cpp`, `tests/unit/tst_accessalert.qml`, and `tests/integration/portal_filechooser.sh`
  scenario 7: the camera asked through the real frontend on a private bus, the alert's answer back to the application and
  kept by the frontend's permission store ("yes" or "no"); A-AC1 in a nested session and A-AC2 are the integrator's.

Built in step 5b (`grassfield-portal`'s AppChooser, Choose Application in `apps/files/qml/FilePanel.qml`; the decisions are
ADR-0035 5b-1 to 5b-7):
- OW1 as the macOS panel: the Open panel in the Applications location, titled "Choose Application", the document named over the
  browser ("Choose an application to open the document “notes.txt”."); the Enable pop-up's "Recommended Applications" (the
  frontend's candidates and its last choice) and "All Applications" (every one), the others dimmed; the last choice selected
  once listed; the candidates and the last choice are listed under both even when the Apps grid hides them (NoDisplay=true,
  OnlyShowIn elsewhere: Omarchy's image viewer imv is NoDisplay and the type's default, which the Open With submenu offers;
  FolderModel.chooser `listed`, 2026-10-30); Open, Return or a double-click answers the application's desktop id, Cancel or Esc answers 1; UpdateChoices
  changes the candidates of the open panel; the search field and the views are the Open panel's. No "Always Open With" box
  (5b-3).
- A-OW1: `tests/unit/portal/tst_appchooser.cpp` (every option in, the answer and its token out, a desktop id that is not one
  never listed or answered), and `tests/integration/portal_filechooser.sh` scenario 8 through the real frontend's OpenFile: the
  panel answers the type's default application, the frontend starts it with the document and counts the choice; Cancel starts
  nothing.

Built in step 5c (Files' own Open With; ADR-0035 5c-1 to 5c-7):
- OW2 Files' Open With, in the item menu and the File menu, lists the applications for the selected files' type, then Other…
  (Other… alone when none); Other… opens the same Choose Application panel, modal over the Files window the user worked in,
  for the selection ("Choose an application to open the document “X”.", or "… the N selected documents."); the application
  chosen opens the documents; Cancel and Esc open nothing. No "Always Open With" box (5c-4).
- OW3 A document whose type has no application (KIO's question in Files): Finder's alert, "There is no application set to open
  the document “X”.", with Choose Application… (the default, Return) and Cancel (Esc); Choose Application… opens the panel,
  and the application chosen opens the document. A job that ends takes its alert or panel away. No store button until
  Grassfield Store can search by document type (5c-3).
- The panel's line cuts a long name in its middle (its extension and the closing quote stay) and shows an address decoded,
  without its password.
- Every selected document goes to the application chosen, each as one argument (KIO starts it; no shell reads a name).
- A-OW2: `tests/unit/files/tst_applicationchooser.cpp` (Other… with two documents, one named with a shell's characters, started
  for real), `tests/unit/files/tst_kiodialogs.cpp` (a real OpenUrlJob for a type
  with no application: the alert, the panel, the chosen application started with the document; Cancel on either; a job killed
  under its panel), `tests/unit/tst_filesbrowser.qml` (Other…, the panel over the browser window), `tst_filesglobalmenu.qml`,
  `tst_fileskiosheets.qml`, `tst_filepanel.qml` (a click and a right-click on a dimmed item in each view); the look in a nested
  session is the integrator's.

## 3. Screen-sharing picker (P10; ADR-0035 D-6)

### macOS reference behavior
See ADR-0035 D-6 and the inventory: the system picker offers the entire screen or a window (hover highlights it, a click picks
it), Esc cancels; while sharing, the menu bar shows the screen-recording indicator naming the app.

### Functional requirements
- SP1 the stand-ins print exactly the grammar of ADR-0035 D-6 and nothing else on stdout; a cancel prints nothing.
- SP2 one-time channel: the stand-in creates a Unix socket with a random 128-bit name under
  `$XDG_RUNTIME_DIR/grassfield/picker/` (directory 0700, socket 0600) and a random request id, calls `picker request <id>
  <path>`, and removes the socket file on every exit. The shell answers `accepted`, `busy` or `locked` within 1 s.
- SP2b every wait on the shell is bounded (counter-review of PR #13): after `accepted` the stand-in waits at most 2 s for the
  connection, then removes the socket file and prints nothing (cancelled); after `accepted` the stock picker never starts.
  The shell shows its panel only once connected; a failed connection shows nothing; the panel closes when the stand-in's end
  closes. Connected, the shell writes `<id> wait` every 5 s while the panel is open, then `<id> <selection>` or `<id> cancel`
  once and closes; end of file without an answer, or 15 s without a line, is "cancelled". The user's own choice has no
  deadline.
- SP3 the stand-in validates before printing: the id; the grammar; a `window:` handle present in `XDPH_WINDOW_SHARING_LIST`; a
  `screen:`/`region:` output listed by `hyprctl -j monitors`, a region inside that output's logical size. Anything else prints
  nothing.
- SP4 one picker at a time: a request while a picker is open gets `busy` (cancelled).
- SP5 locked (owner decision Q15): the stand-in checks the lock itself (Hyprland's `solitaryBlockedBy` LOCK on every monitor, or
  the shell's crash-recovery marker, the test of `packaging/shims/omarchy-shell:64-74`) and the shell answers `locked`; either
  way the request is cancelled and no picker shows, Grassfield's or stock. Every error counts as locked: `hyprctl` failing or
  silent for 1 s, output that is not the expected JSON, no monitor, a marker file that exists but cannot be read.
- SP6 the panel: tabs "Entire Screen" (one live thumbnail per display, the display's name), "Window" (live thumbnails of the
  windows in `XDPH_WINDOW_SHARING_LIST`, grouped by app, title under each, protected windows greyed with "This window can't be
  shared"), "Selection" (crosshair, region relative to its display); the heading "An app wants to share your screen." (the
  picker cannot know which app); "Remember this choice" unticked at every opening, whatever `--allow-token` says (owner
  decision Q14); Cancel / Share (default once something is selected); double-click shares at once.
- SP7 keyboard: arrows move in the grid, Return shares, Esc cancels, Cmd-1/2/3 switch tabs.
- SP8 the recording indicator in the menu bar while Hyprland reports an active screencast; its menu says what is shared (a
  display or a window), not which app shares it (Hyprland's events carry only the source).
- SP9 no acknowledgement within 1 s and the session not locked: the stand-in removes the socket file, then execs the stock
  picker (a late `accepted` finds no socket and shows nothing).

### Acceptance criteria
- A-SP1 (L0) the stand-in's output for each choice parsed by a copy of xdph 1.4.1's parser (`ScreencopyShared.cpp:70-125`)
  gives the intended selection; malformed, foreign-handle, unknown-output and out-of-bounds answers print nothing.
- A-SP2 (L0) channel: a second request while one is open gets `busy`; a shell that closes the socket without an answer gives
  "cancelled"; after `accepted`, killing the shell never starts the stock picker; a wrong id is ignored.
- A-SP2b (L0) bounds: `accepted` and no connection → nothing printed within 2.5 s, socket file gone, no stock picker; a late
  `accepted` after the stand-in fell back → the fake shell's connection fails and no panel is shown; a connected fake shell
  that stops writing → nothing printed within 15.5 s; the fake shell's panel closes when the stand-in exits.
- A-SP3 (L0) locked: with a fake `hyprctl` reporting LOCK, failing, hanging, printing garbage or listing no monitor, and with an
  unreadable marker, the stand-in prints nothing and starts nothing.
- A-SP4 (L1) Chromium "Share screen" in a nested session: the panel shows, a window share streams that window (screenshot of
  the receiving tab), the indicator appears and goes away when the share stops.
- A-SP5 (L1) two displays: a `region:` selection on the second display streams the selected area (coordinates relative to
  that display).
- A-SP6 (L1) shell stopped, session unlocked: the stock picker opens.

### Known limitations
A user `xdph.conf` naming another picker is respected; xdph blocks its main loop while any picker runs (upstream), for up to
3 s when the shell dies before connecting and 15 s when it hangs after; the picker and the indicator cannot name the
requesting app.

## 4. Not responding (H1; ADR-0035 D-3; built in step 3)

### macOS reference behavior
No alert. After a few seconds without event processing the pointer becomes the wait cursor over the app's windows; the app's
Dock menu shows "Application Not Responding" and Force Quit in place of Quit; Force Quit Applications lists the app with
"(Not Responding)" in red; the system never kills an app on its own.

### Functional requirements
- NR1 the `hyprland-dialog` stand-in (`packaging/session-bin/hyprland-dialog`) takes only Hyprland's exact ANR call in en_US
  or fr_FR (`--title T --text X --buttons B`), tries every " - " split of "{title} - {class}" against Hyprland's client
  list, and with exactly one (split, client pid above 1) match reports (its own pid, that pid, "c:" class, "t:" title, "i:"
  Hyprland instance) to `anr report` and then `exec`s `sleep infinity` (same pid, silent, nothing forked) until Hyprland
  kills it; every other call, and every case below, `exec`s the stock dialog with the same arguments.
- NR1b the shell accepts a report only for a pid above 1, a class, its own Hyprland instance, and a window that no other pid
  it knows shares class and live title with (ADR-0035 decision 3-1); otherwise it answers `refused` (the reason goes to the
  journal) and the stand-in runs the stock dialog. An untitled window ("(unknown)" / "(inconnu)" in Hyprland's text) is
  matched by its empty title and reported with it.
- NR2 the shell marks that pid as not responding while one of its stand-ins lives: Force Quit lists the app with "(Not
  Responding)" (destructive colour); the selection follows a window, not a row: the user's choice is kept, and before the
  user moves it the panel selects the first such app and never moves away from the app shown; the app's Dock menu starts with a disabled "Application Not Responding" item and offers "Force
  Quit" in place of "Quit", for the marked processes only (Option + Force Quit: all of the app's); the app menu keeps "Quit"
  (owner decision Q16). At the confirmation a pid that no longer owns a window of the chosen class (pid reuse) is not
  killed, and a notice says "The application had already quit."; the others are.
- NR3 the mark clears within 1 s of the stand-in's end (the app answered, closed, or was killed): the shell checks the
  stand-ins every 250 ms while there is a mark.
- NR4 no alert, no sound, no focus change. `misc.anr_missed_pings = 3` (about 4.5 s).

### Acceptance criteria
- A-NR1 (L0, `tests/shell/hyprland_dialog.sh`) the stand-in with fake `qs`, `hyprctl` and stock dialog: en and fr texts
  parsed, titles with " - ", a leading "-" or a newline, a class with " - "; ambiguous (two processes, an app named to
  match another split), other-locale, malformed, refused, unanswered (1-s deadline) calls exec the stock dialog with the
  same pid and arguments; spawned by a double fork as Hyprland spawns it, the pipe stays open after "ok" and ends when the
  stand-in is killed; the texts match the installed Hyprland. (L0, `tests/shell/anr_ipc.sh`) the stand-in through the real `qs ipc` to
  the real service in an offscreen Quickshell: marked, cleared within 1 s, the shell's own refusals, a rename that lifts an
  ambiguity.
- A-NR3 (L0, `tests/unit/tst_notresponding.qml`) two processes of one app with the same class and title: refused; a pid
  reused between mark and confirmation: Force Quit refuses.
- A-NR2 (L1, `tests/shell/anr_nested.sh`) a foot window stopped with SIGSTOP in a nested session is marked within 12 s and no
  stock dialog opens; SIGCONT clears the mark, and so does killing the stopped app.

### Known limitations
No wait cursor (Hyprland only tints the window); the ANR state is known only through Hyprland's dialog call. A shell restarted
while an app hangs loses the mark until the app answers or closes (Hyprland runs its dialog once per hang); Force Quit still
lists the app. A Hyprland release that changes the texts makes the stand-in fall back to the stock dialog, and so does an app
without an app id (class "(unknown)") or a window that cannot be told apart. A nested Hyprland that crashes while an app hangs
leaves the stand-in waiting (it holds nothing) until logout; the real session's unit takes it down with Hyprland.

## 4b. Hyprland's config errors (H8, H9; ADR-0035 D-2; the notice built in step 3, not active on Hyprland 0.56.2)

### macOS reference behavior
macOS has no user-edited compositor configuration; a setting that cannot be applied is reported in words in a notification,
never as a red bar over the screen.

### Functional requirements
- CE1 Hyprland's error bar stays on: no Grassfield file sets `debug.suppress_errors` (ADR-0035 decision 3-15). Under the Lua
  config of Hyprland 0.56.2 `hyprctl configerrors` is empty (measured: every dispatch is an `eval`, which clears the
  errors, and the shell dispatches at start and after each reload), so the shell has no source to show them instead.
- CE2 the shell reads `hyprctl -j configerrors` when it starts and after every `configreloaded` event; each new non-empty
  set of errors posts one notice "Some settings could not be applied" whose body lists the first three lines as text, then
  "and N more"; the same set after a reload posts nothing; a reload that leaves no error withdraws the notice. No terminal,
  no journal (decision 3-6); the shell logs the count, never the lines. On 0.56.2 the answer is always empty and no notice
  shows.

### Acceptance criteria
- A-CE1 (L0, `tests/unit/tst_configerrors.qml`, `tests/shell/config_errors.sh`) Hyprland's reply parsed (none: `[""]`),
  anything else ignored; one notice per new set, withdrawn when empty, three lines shown as text ("<eof>" kept); a reload
  during a read is read once more.
- A-CE2 (L0, `tests/shell/session_input.sh`) no Grassfield config file sets `suppress_errors`. (L1, integrator) a broken
  config line in the nested session shows Hyprland's bar.

### Known limitations
Hyprland's bar, not a Grassfield notice, shows config errors on 0.56.2 (CE1); its runtime Lua errors (a binding's callback
that fails) and its other toasts stay Hyprland's too (ADR-0035 D-2).

## 5. Password prompts (gcr, udiskie, NetworkManager, KIO; S1–S4, S6, S8, K1; ADR-0035 D-9, D-12; owner decisions Q1, Q10–Q12)
Needs the amendment of the security rule (text in ADR-0035 D-9, owner decision Q12), applied in step 9 after the integrator's
review and the owner's agreement, before any code; R12 applies (opus PASS, fail closed where a secret is involved, nothing
logged).

### macOS reference behavior
System-modal alert centred on the active display, above every window, never on the lock screen: the requesting app's icon,
bold title, a message naming the requesting app ("“App” wants to use your confidential information stored in “item” in your
keychain."), a secure password field, a check box where relevant ("Remember this password in my keychain"), buttons "Deny"
and "Allow" (default) or "Cancel"/"OK". A wrong password shakes the alert and clears the field. Not visible to screenshots or
screen sharing. It does not look like the administrator authorization dialog. Encrypted disk: "Enter a password to unlock the
disk “Name”." with "Remember this password in my keychain", Cancel / Unlock. Server: "Enter your name and password for the
server “X”." with "Remember this password in my keychain", Cancel / Connect.

### Functional requirements
- SC1 `grassfield-prompter` (C++/Qt 6 and libgcr-4) owns `org.gnome.keyring.SystemPrompter` while the shell is connected
  (requested without `ALLOW_REPLACEMENT`, so nobody can take it away; queued behind a stock gcr-prompter that still holds it,
  which frees it 10 s after its last prompt); libgcr runs `BeginPrompting`/`PerformPrompt`/`StopPrompting` and the `sx-aes-1`
  exchange.
- SC2 one queue in the shell for every secret sheet and the polkit sheet: one sheet on screen at a time, in arrival order; a new
  request never takes the keyboard from the sheet on screen (the polkit sheet's `WlrKeyboardFocus.Exclusive` stays where it is,
  `shell/security/polkit/AuthAgent.qml:241`) and is shown only after that sheet is answered or cancelled; a request withdrawn by
  its caller (`StopPrompting`, `CancelGetSecrets`, BlueZ `Cancel`, the KIO client gone) leaves the queue unseen; at most 8
  secret requests wait, the 9th secret request is answered "cancelled"; a polkit request always queues, whatever the count.
- SC3 look and identity: a secret sheet is not the authorization sheet: no lock-and-shield glyph, never the title
  "Authentication required"; a fixed top row with the requester's icon and name that only the bridge fills, from the pidfd of
  `GetConnectionCredentials` (`ProcessFD` → PID → `/proc/<pid>/exe`, the pidfd checked alive after the read; trusted only when
  the executable and its parent directories are root-owned and not writable by the user, mapped only to a root-owned desktop
  entry; "Keyring" for gnome-keyring, "GnuPG" for gpg-agent, "Network" for KIO's workers; anything else, or no `ProcessFD`,
  "Unidentified program" and the path); then the caller's `title`, `message`, `description`
  as plain text, flattened and capped, in the secondary style; `warning` in red under the field; a secure field (`password-new`:
  New and Verify fields and a strength bar); `choice-label` as a check box; `continue-label` / `cancel-label` (else "OK" /
  "Cancel"); a `confirm` prompt has no field.
- SC4 security rules of the polkit sheet: nothing over the lock (a request that arrives while locked waits and is shown after
  the unlock without the keyboard until a click 500 ms after it appears); the field is cleared after each answer and on close;
  `ImhSensitiveData`, no input method; Esc and Cancel answer "no"; the shell never logs any field. The surface's layer namespace
  `grassfield-secret` is hidden from screen sharing by a session layer rule (`no_screen_share`, accepted for layers by Hyprland
  0.56.2, `src/desktop/rule/layerRule/LayerRuleEffectContainer.cpp:23`).
- SC5 socket protocol (bridge ↔ shell): one JSON object per line, versioned (`prompter/1`); the bridge accepts only the shell
  (uid and cgroup checked). What can be wiped: the shell clears the field and drops its references and sends the password once;
  the QML strings the JavaScript engine made cannot be zeroed and may stay in the shell's heap until reused (known limitation,
  as for the polkit sheet today); the bridge reads the password into a buffer it zeroes after handing it to libgcr or to the
  D-Bus reply.
- SC6 fallback: shell not connected → the bridge releases the name (the stock gcr-prompter is activated for the next prompt) and
  unregisters its NetworkManager agent; it takes them again when the shell reconnects; a request in flight when the shell
  disconnects is answered "no".
- SC7 udiskie: `grassfield-askpass udiskie <device>` opens a gcr prompt ("Enter a password to unlock the disk “%1”.",
  "Remember this password" when udiskie offers its cache), prints the password and a newline on stdout, exit 0; cancel: no
  output, exit 1 (udiskie then leaves the disk locked).
- SC8 NetworkManager: the bridge's secret agent answers `GetSecrets` for `802-11-wireless-security` and `802-1x` with the
  sheet's Wi-Fi form ("The Wi-Fi network “%1” requires a WPA2 password.", Show password, Cancel / Join; identity and password
  for 802.1X), `CancelGetSecrets` closes it, `SaveSecrets`/`DeleteSecrets` store nothing in Grassfield (NM keeps the secret as
  the connection says). It accepts calls only from the current owner of `org.freedesktop.NetworkManager` on the system bus;
  other callers get an error and no sheet. VPN settings get "no secrets": NetworkManager shows no VPN dialog itself (an agent
  like nm-applet runs the VPN plugin's auth dialog, which this one does not), so a VPN that needs secrets at connect time fails,
  as it does today.
- SC9 KIO network passwords (ADR-0035 D-12 b): the bridge owns `org.kde.kpasswdserver6` at `/modules/kpasswdserver`
  (interface `org.kde.KPasswdServer`: `checkAuthInfoAsync`, `queryAuthInfoAsync`, `addAuthInfo`, `removeAuthInfo`, the result
  signals), shows the server form ("Enter your name and password for the server “%1”.", name, password, Remember this
  password, Cancel / Connect), keeps answers for the session as kpasswdserver does, and stores remembered ones with libsecret
  in the Secret Service (never through KWallet's API; in the Grassfield session the Secret Service stays gnome-keyring's,
  ADR-0035 Q17-b); the sheet says when the keyring that receives them is not protected by a password (Omarchy's default keyring
  is not); bridge down → D-Bus activation starts kiod6 (KDE's dialog, as today).
- SC9b results go to the caller only (counter-review of PR #13, minor): kpasswdserver broadcasts `checkAuthInfoAsyncResult` and
  `queryAuthInfoAsyncResult`, credentials included, to every listener on the session bus (KIO
  `src/core/org.kde.KPasswdServer.xml:4-15`, `src/kpasswdserver/kpasswdserver.cpp:330, 852, 883`); the bridge sends each
  result as a signal addressed to the caller's unique name (`QDBusMessage::createTargetedSignal`), which KIO's client receives
  unchanged (`src/core/kpasswdserverclient.cpp:52, 90`). A cached credential goes only to the connection that asks; any
  same-user process can still ask for one by its URL, as with kpasswdserver today (upstream protocol, known limitation).
- SC9c never blocks on itself (counter-review of PR #13, minor): storing into a locked keyring makes gnome-keyring ask through
  gcr's prompter, which is the bridge. The bridge therefore stores with libsecret's asynchronous calls (`secret_password_store`
  with a callback on its GLib main context), answers `addAuthInfo` at once, and makes no synchronous call that can cause a
  prompt; the unlock prompt then takes its turn in the queue.
- SC10 the Secret Service handover (ADR-0035 D-12, owner decision Q17-b, step 2c; `grassfield-secrets-handover`, a user unit
  the session starts before the shell). Nothing for the user to do. At the session's start a ksecretd left over from an
  earlier session that still holds `org.freedesktop.secrets` is made to quit, so apps opened from the Dock find the keychain;
  the shell waits for that at most 10 s. Once per user, everything KWallet holds is copied into the keychain: the passwords
  that libsecret clients (Chromium, git helpers) saved while it held that name, and KWallet's own entries, which QtKeychain
  apps now look up in the keychain (ADR-0035 decision 2c-10); never over an item the keychain already holds (of two items
  with the same attributes, the most recently changed; never an empty value). KWallet keeps its copies. A user whose own
  `kwalletrc` gives the Secret Service back to KWallet is left alone. KWallet asks for its password only when something must
  move and the wallet is locked (its own dialog, K2), the keychain only when it is locked or does not exist yet, and the
  handover asks at most once, ever (decision 2c-9). When something moved, one notice: "Saved passwords moved" / "Passwords
  that apps had saved elsewhere on this computer are now kept with your other saved passwords." A refused or unanswered
  question ends it for good, with one notice: "Saved passwords not moved" / "Passwords that apps had saved elsewhere on
  this computer stay where they were. Apps that used them may ask you to sign in again." A peer that is not the expected
  program, or an error before any question, leaves everything as it was, and the handover runs again at the next session.
  No item, label or value is logged; the helper is not dumpable and its unit allows no core file and no swap. Code quality:
  `just check-tidy` covers the compositor only; the helper is built with `-Wall -Wextra` (no warning), its tests run under
  ASan and UBSan, and a one-off clang-tidy run with the compositor's checks (`clang-analyzer-*`, `bugprone-*`,
  `performance-*`; 2026-10-27, LLVM 23.1) found no analyzer finding; the two findings worth a change were fixed (sizes
  narrowed to int, a const local that blocked a move), and what remains is Qt's own idiom (static `QStringLiteral`
  constants, `S_IW*` bit masks, a `QDBusArgument` operator returning its argument, an enum's base type).

### Acceptance criteria
- A-SC1 (L0) a fake gcr client on a private bus gets the password through the exchange; a fake process queued on the name never
  receives a prompt while the bridge holds it; with the shell disconnected, the fake stock prompter is activated.
- A-SC2 (L0) queue: with the polkit sheet open and its field focused, a gcr request arrives: the polkit sheet keeps the keyboard,
  the gcr sheet shows only after the polkit answer; a withdrawn request never shows.
- A-SC3 (L0) identity: a caller whose text says "Authentication required" still gets the secret sheet's header with its resolved
  executable; the sheet never shows the polkit glyph.
- A-SC3b (L0) identity sources: a fake caller that exits and whose PID is reused before the read, a caller run from the home
  directory, and a bus that gives no `ProcessFD` all show "Unidentified program"; a polkit request arriving with 8 secret
  requests waiting is queued, not refused.
- A-SC4 (L0) a fake NetworkManager on a private system-style bus asks for a PSK and receives the typed secret; a VPN request
  gets "no secrets"; a call from another sender gets an error and no sheet.
- A-SC5 (L0) a fake KIO client asks `queryAuthInfoAsync` and receives the typed credentials; "Remember" writes to a fake Secret
  Service, never to a KWallet name.
- A-SC5b (L0) a second fake client listening to the bridge's signals never receives another client's result; with the fake
  Secret Service's collection locked, "Remember" raises an unlock prompt in the queue after the server sheet and nothing
  hangs (the bridge answers other calls meanwhile).
- A-SC6 (L0) mutants: removing the uid/cgroup check, the lock refusal, the queue's focus rule, the caller checks or the buffer
  zeroing fails a test.
- A-SC7 (L1) nested: pinentry-gnome3 with a throwaway GNUPGHOME and key asks through the Grassfield sheet (screenshot, "visual
  NOT verified" otherwise); udiskie with a loop-mounted LUKS image and an sftp location are the owner's L2 checks.
- A-SC8 opus PASS.
- A-SC9 (L0) the handover against fakes on a private bus (`tests/integration/secrets_handover.sh`): the items move once and
  an item the keychain holds is kept; KWallet's own entries (stored as kwalletd 6.29 stores them) move too, and so does an
  older entry KWallet lists only once open; nothing is final from a locked listing that lists nothing; an empty value is
  not copied; a refused or unanswered question creates nothing, ends the handover for good with its notice, and the next
  login asks nothing; a missing default keychain is created; a leftover ksecretd quits, or gets SIGTERM, before readiness;
  a holder that is another program, or a Secret Service that is not gnome-keyring, is left alone and nothing is read or
  written; both notices in English and French; of two items with the same attributes only the newest moves; the user's own
  `kwalletrc` keeps KWallet and nothing is done; a dev run on any bus but a private test bus is refused; in a user namespace
  like `PrivateUsers=self` no peer is identified and nothing is done (why the unit has no namespace option, checked
  statically); the helper is not dumpable; with the real gnome-keyring as the keychain, what moved is read back through
  libsecret; the real ksecretd quits when asked; no item, label or value in any output. Opus PASS (secret path).

### Known limitations
Name ownership is the only authorization (upstream design): a same-user process can still show a fake stock prompt through
gcr-prompter while the bridge is down; the requester shown is the D-Bus caller (gnome-keyring or gpg-agent for most prompts,
with the original app named only when the caller's text names it); copies of the password may stay in the shell's heap (SC5);
remembered network passwords are as safe as the keyring that holds them (Omarchy's default keyring is unencrypted); a
same-user process can ask the bridge for a cached network password by its URL, as it can ask kpasswdserver today (SC9b); VPN
secrets are not asked (SC8); until step 2a ships the session's `kwalletrc` (ADR-0035 Q17-b), KWallet's `ksecretd` can hold
the Secret Service for a session when a KWallet client starts before gnome-keyring, and libsecret clients then meet KWallet's
dialogs (inventory S12); a user `kwalletrc` that turns the key back on wins. The handover (SC10, step 2c) moves what
KWallet holds into the keychain, and makes a leftover ksecretd quit; what remains: a Chromium that made a new key before the
handover keeps it, and what it saved under the old key stays unreadable (the handover never overwrites); an app opened
while the handover waits for the answer to KWallet's password question, or an app of Open at Login (started alongside the
shell), can still find nothing in the keychain, and Chromium then makes a new key; a user who refuses the question keeps
their passwords in KWallet only (asked once, ever); a locked wallet that ksecretd has never listed waits, unasked, until a
KWallet client opens it; KWallet's question is KDE's dialog (K2); the values cross the user's own session bus in plain
Secret Service sessions (ADR-0035 decision 2c-4).

## 6. Toolkit appearance (category C; ADR-0035 D-8)

### macOS reference behavior
Every app follows the system appearance (Light, Dark, Auto) and the accent colour live; Increase Contrast and Reduce Motion
apply to every app.

### Functional requirements
- AP1 `grassfield-portal-settings` (no window, QtCore + QtDBus, started with the session) serves
  `org.freedesktop.impl.portal.Settings` (`Read`, `ReadAll` with the namespace filter, the `SettingChanged` signal, property
  `version` 1; the frontend's `ReadOne` is its `Read`) for `org.freedesktop.appearance` (`color-scheme` u: 1 dark, 2 light;
  `accent-color` (ddd) sRGB, the accent of the current appearance; `contrast` u: 1 when Increase Contrast; `reduced-motion`
  u: 1 when Reduce Motion) and `org.gnome.desktop.interface` (`gtk-theme`, `color-scheme` `prefer-dark`/`prefer-light`,
  `enable-animations`), from the Grassfield settings file, watched (its nearest existing parent while its directory does not
  exist yet) and read as ADR-0020 §2 requires: never without a bound (a FIFO, a device or a directory is never read, at most
  1 MiB, read whole), on a worker thread, one read at a time: a read that hangs is not waited for (ADR-0020's 5 s cut, logged
  once), the calls are answered at once with the last settings all along, and the start waits 3 s at most for the first read;
  a malformed or unreadable file keeps the last good settings (defaults only at start); a missing file means the schema's
  defaults. `auto` follows `AutoAppearance`'s schedule: the clock is checked again every minute as the shell does, the file
  never (ADR-0035 decision 2b-8). A key it does not own answers `org.freedesktop.portal.Error.NotFound` (the frontend then
  asks x-d-p-gtk). Only the keys whose value changed are signalled; once its bus name is owned it signals every value once
  (decision 2b-9); it answers x-d-p-gtk's `SettingChanged` (by its bus name) for a key it owns and a value other than its own
  with its own value (decision 2b-13). A dev run refuses any bus but a private test bus. Budget: ≤ 4 MB private and ≤ 20 MB
  resident memory, no CPU while nothing changes but a clock check a minute under `auto` (decision 2b-11).
- AP1b its unit has `Restart=on-failure` (`RestartSec=1`; counter-review of PR #13): a crashed backend is back within about a
  second, so live changes resume without waiting for a read. The frontend's proxy is bound to the bus name, not to the process,
  and follows its new owner (xdg-desktop-portal 1.22.1 `src/settings.c:333-339`, `G_DBUS_PROXY_FLAGS_NONE`; GLib 2.90.1
  `gio/gdbusproxy.c:1704-1734`: signals subscribed by name, `NameOwnerChanged` tracked).
- AP2 the session's `hyprland-portals.conf` (under `/usr/share/grassfield/xdg/xdg-desktop-portal/`) lists only
  `org.freedesktop.impl.portal.Settings=grassfield-settings;gtk` (`grassfield-settings.portal`, bus name
  `org.freedesktop.impl.portal.desktop.grassfield_settings`); every other interface keeps the stock file's routing.
- AP2b the backend's unit clears `GTK_USE_PORTAL` and `QT_QPA_PLATFORMTHEME`, and `grassfield-shell.service` clears
  `GTK_USE_PORTAL`, so neither waits on the portal at start (ADR-0035 D-4); the shell gives `GTK_USE_PORTAL=1` back to every
  app it starts when `env-grassfield` recorded `GRASSFIELD_APPS_GTK_USE_PORTAL=1` (`Mode.appsGtkPortal`, decision 2b-12).
  `autostart.lua` starts the backend without waiting for it, and its unit gives a start 5 s; the frontend's unit wants the
  backend and starts after it (packaged drop-in, decision 2b-14), since the frontend makes its backend proxies once, when it
  starts.
- AP3 `env-grassfield`, when the routing file is readable: `/usr/share/grassfield/xdg` first in `XDG_DATA_DIRS` (once, the
  list or its default kept), `GTK_USE_PORTAL=1`, and `portals` added once to `GDK_DEBUG` (plain GTK 4 apps outside a sandbox
  read the portal only with it; decision 2b-1); never `GTK_THEME`.
- AP4 (owner decision Q7, decision 2b-2) `/usr/share/themes/Grassfield-<accent>[-hc][-dark]/` with `gtk-3.0/gtk.css` and
  `gtk-4.0/gtk.css` (36 themes: nine accents, two appearances, Increase Contrast), generated at build time from
  `ui/tokens/tokens.json`, each `@import`ing GTK's built-in stylesheet (GTK 3: Adwaita, or HighContrast with `-hc`; GTK 4:
  Default, or Default-hc) and setting only Grassfield's colours where that stylesheet draws its accent, with the shell's
  colour roles (decision 2b-5): the GTK 4 focus ring opaque (`control.focusOutlineOpacity`, decision 2b-15), hover, pressed
  and border shades as the shell's overlays, the selected tab's indicator at GTK's own width (`gtk.tabIndicatorWidth`); no
  CSS colour function; the radii stay GTK's (decision 2b-7). MIT, no copy of Adwaita. `gtk-theme` names the matching one.
- AP5 a change of appearance, accent, contrast or motion in Settings or Quick Settings reaches running GTK 3 (with the
  variable), GTK 4 (with `GDK_DEBUG=portals`), libadwaita, Qt (`gtk3` theme), Chromium, Electron and Firefox within 1 s.

### Acceptance criteria
- A-AP1 (L0) the real xdg-desktop-portal 1.22.1 on a private bus, the session's routing directory first in its
  `XDG_DATA_DIRS` (a copy of the package's), the Grassfield backend D-Bus-activated and a stand-in for x-d-p-gtk: `ReadAll`
  returns Grassfield's values first and the stand-in's for the rest (`font-name`); the namespace filter holds; every other
  interface keeps the stock routing; a settings-file change reaches a client as `SettingChanged`, for the changed keys only;
  after the stand-in signals a dconf change of `gtk-theme` and `color-scheme`, the client ends with Grassfield's values
  (`tests/integration/portal_settings.sh` 1, 2). (L0, unit) a FIFO, a device symlink, a directory, a file over 1 MiB and an
  unreadable file are never read, and they and a malformed file keep the last good settings.
- A-AP2 (L0) on a headless Weston with the session's variables: a GTK 3 app, a GTK 4 app and a libadwaita app take the
  Grassfield theme, colour scheme, contrast and accent from the portal and follow a change within 1 s; a GTK 4 app without
  `GDK_DEBUG=portals` does not (control) (scenario 7). (L1, the integrator) a nested Grassfield session: the same apps and a
  Qt `gtk3` one switch with Settings (screenshots).
- A-AP3 (L0) the themes' colour pairs (WCAG 2.x) for the nine accents in both appearances: selected and highlighted text
  4.5:1, links 4.5:1 and the focus ring 3:1 against the Grassfield window and GTK's own window and view backgrounds, thin
  marks 3:1 except the light yellow accent's (1.86:1 on GTK's window, 1.99:1 under high contrast; the shell's own yellow,
  pinned) (`tests/ci/gtk_themes.py`); the 36 themes rendered with GTK 3 and GTK 4 leave none of GTK's blue and
  show their own colours, against GTK's four stylesheets as controls (`tests/integration/gtk_themes.sh`).
- A-AP4 (L0) crash: the backend killed, the next read through the real frontend activates it again and returns Grassfield's
  values, and the new process signals the next change; with a frontend that never answers, the backend still starts (no GUI,
  no wait) (scenarios 3, 5); a backend whose activation fails when the frontend starts is left out by that frontend for good
  (scenario 4b), so the frontend's unit starts after the backend (static check of the drop-in).
- A-AP5 (L0) crash without a read: the backend killed, the settings file changed while it is down, then the backend started
  with no read (as systemd's `Restart=on-failure` starts it): the change reaches the client (scenario 3); after a restart
  the apps keep their state (scenario 7). systemd's restart itself is not run in the container (no user manager): the unit's
  lines are checked statically; (L2) on the reference machine, `systemctl --user kill -s KILL grassfield-portal-settings`
  then a change in Settings.

### Degraded behavior
Backend absent or crashed: x-d-p-gtk's values (the user's dconf, Omarchy's theme) until systemd restarts it (about 1 s) or
D-Bus activation starts it at the next read; a change made meanwhile is delivered when it starts. A backend that keeps
failing stops after 5 starts in a minute, and the frontend answers from x-d-p-gtk until a later read or the next login. GTK
theme missing: GTK falls back to its default theme. Routing file unreadable: `env-grassfield` sets nothing, and the session
behaves as before step 2b. A `hyprland-portals.conf` of the user's (`~/.config/xdg-desktop-portal`) or of the
administrator's (`/etc/xdg-desktop-portal`) wins over the session's: the apps then take x-d-p-gtk's values.

### Known limitations
x-d-p-gtk's own remaining dialogs (its file chooser until step 4, print until step 6, account) and apps that read dconf
directly follow the user's GTK theme, not the Grassfield appearance; GTK 3 and GTK 4 apps that open a file or link through
the portal may meet x-d-p-gtk's app chooser where the portal asks (step 5 replaces it); libadwaita snaps the accent to its
nine accents; Qt reads no accent (its highlight comes from the GTK 3 theme); the text highlight setting (`accent.highlight`)
does not reach GTK apps, whose selected text uses the accent (decision 2b-6); the light yellow accent's thin marks hold
1.86:1 on GTK's window, as the shell's yellow does on its own; after x-d-p-gtk signals a dconf change, apps see its value for
an instant before Grassfield's (decision 2b-13); GTK and libadwaita apps keep GTK's own radii; an app started with its own
`GTK_THEME` keeps it; on the owner's GTK 4.22 plain GTK 4 apps do not read `accent-color` (the Grassfield theme carries the
accent). Code quality: `just check-tidy` covers the compositor only; a one-off clang-tidy run with its checks over the
backend left only Qt's idiom.

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
- BT4 the agent accepts calls only from the current owner of `org.bluez` on the system bus; other callers get
  `org.bluez.Error.Rejected` and no sheet. Its sheets go through the same queue as the other secret sheets (section 5, SC2).

### Acceptance criteria
- A-BT1 (L0) a fake BlueZ on a private system-style bus drives every method; mutants removing the "no automatic yes" rule or
  the caller check fail.
- A-BT2 (L2, owner) pairing a keyboard that needs a passkey and a phone that compares a code; opus PASS before merge.

### Known limitations
Agent precedence with another agent that also asks to be the default is BlueZ's (the last one to ask wins); legacy devices
with fixed PINs need the user to know the PIN.

## 9. KIO's dialogs in Files and the panel (inventory K3–K7, K9; ADR-0035 D-12 a, owner decision Q11; built in step 4a for Files)

### macOS reference behavior
Finder's own alerts: "An item named “X” already exists in this location. Do you want to replace it with the one you're
moving?" ("An older item named…" or "A newer item named…" when the dates tell) with Keep Both / Stop / Replace, Skip and
"Apply to All" for several items; "The operation can't be completed because you don't have permission…" with Skip / Stop;
the certificate sheet ("… can't verify the identity of the server “X”", Show Certificate, Cancel / Continue); Open With >
Other… opens the Choose Application panel. No progress window opens for Undo.

### Functional requirements
- KD1 Files (and, from step 4b, `grassfield-portal`) sets Grassfield's UI delegate, KIO's own `KIO::JobUiDelegate` class with
  Grassfield's KIO delegate extensions as its children, on every job it starts, and makes it KIO's default delegate factory
  while it runs (ADR-0035 4a-2: KIO gives its own sub-jobs and Undo's jobs a default delegate of their own, which
  `KIO::delegateExtension` reads before the parent's, `src/core/jobuidelegatefactory.h:102-126`; KIO's factory comes back when
  Files' prompts go):
  - `AskUserActionInterface`: rename/overwrite (Keep Both / Skip at the leading edge, Stop / Replace at the trailing edge,
    "Merge" for a folder onto a folder, Apply to All for several items; Keep Both names the new item as KIO does,
    `KFileUtils::suggestName`; Resume / Start Over / Stop for a copy that stopped part way), skip (Try Again, or Rename for characters the destination refuses, Stop, and for several
    items Skip and Apply to All; one item that can't be retried: OK), the permanent deletions KIO asks about (a plain move to the Trash is not asked), `requestUserMessageBox` as a sheet
    with the worker's buttons (Show Details for its details), `askIgnoreSslErrors` as the certificate sheet (Show Certificate
    lists the chain as text: subject, issuer, validity, SHA-256, the problems found): Cancel is the default button (Return
    and Esc cancel); Continue accepts for 30 minutes, KIO's "Current Session only"; a permanent rule ("Forever") only when
    the user ticks "Always trust “host”", shown with the certificate and unticked at every opening (ADR-0035 4a-6);
  - `OpenWithHandlerInterface`: Finder's alert for a type with no application, then the Choose Application panel (section 2,
    OW3; 4a-5, 5c-3);
  - `UntrustedProgramHandlerInterface`: refuses with a notice (Files' `LaunchGuard` decides first and never hands an
    executable to KIO, `docs/specs/security.md` § Files never runs what it opens; this is the second guard).
    `OpenOrExecuteFileInterface` has no installed header in KIO 6.31: Files never enables the job option that asks it (4a-4).
- KD2 every answer is the KIO answer the widget dialog gives for the same choice (`RenameDialog_Result`, `SkipDialog_Result`,
  `KIO::WorkerBase::ButtonCode`), so jobs behave exactly as before.
- KD3 the sheets show in the Files window the user last worked in when the question came, one at a time, and stay there
  until answered (in another window if that one closes); a question waits while another sheet or a menu of that window is
  open (Go to Folder, a confirmation, a context or toolbar menu) and keeps its choices; while shown it keeps the keyboard;
  a question whose job ends goes away unanswered; keyboard as common rule 3 (4a-9).
- KD4 errors and warnings KIO shows by itself (where KIO turns its automatic handling on) are notice sheets; Undo reports its
  errors on the window's error line, keeps a copy changed since it was made and says so (4a-11); no job of Files opens
  KIO's progress window (4a-12).
- KD5 Paste is offered for items only: text or an image on the clipboard is not pasted (4a-14).
- KD6 Return never takes a warning's action or a deletion (Cancel, or the secondary action where there is no Cancel,
  4a-17); in the copy/move conflict sheet Return replaces (Merge onto a folder, Resume for a copy that stopped part way),
  as the Finder (owner decision Q18, the exception to common rule 3); a question takes no input for the double-click interval after it shows, a key's auto-repeat answers nothing,
  and a question opens with the keyboard on the sheet,
  not on a button clicked before (4a-18); a long text scrolls inside the sheet, the buttons stay on screen (4a-19); names
  inside KIO's texts show their direction controls (4a-20).

### Acceptance criteria
- A-KD1 (L0) every choice of the conflict, skip and message sheets gives the KIO answer the widget dialog gives
  (`tests/unit/files/tst_kioprompts.cpp`, table test); real KIO copy and move jobs through KIO's file worker in a scratch home,
  answered as the sheets answer, do what that answer says (Replace, Keep Both, Stop, Skip with Apply to All asked once, a
  folder copied and a folder moved onto a folder merged, a file onto a folder never "Merge", a sheet's reply, a withdrawn
  question; `tests/unit/files/tst_kiodialogs.cpp`); the sheets' texts, buttons and replies (`tests/unit/tst_fileskiosheets.qml`);
  the window that shows a question, a question that waits for Go to Folder and for a menu, a sheet that takes the
  keyboard back, and the safe answer with no window (`tests/unit/tst_filesbrowser.qml`).
- A-KD5 (L0) Return on a warning and on a deletion cancels (or gives the secondary action); a double click and a repeated
  Return answer one question only; Return is the default button's after a Tab in the last question; a 200-line message
  keeps the buttons inside the window; direction controls in KIO's texts show as <U+XXXX> (`tst_fileskiosheets.qml`,
  `tst_kioprompts.cpp`).
- A-KD2 (L0) no widget is created by those jobs, KIO's own jobs resolve Grassfield's extensions, an error KIO reports itself
  is a notice, Undo of a changed copy keeps it, a job KIO tracks makes no progress window, only items are pastable, and
  Files' sources hold no KIO or Qt widget dialog, set no other delegate, never use KIO's paste test and never enable "open
  or execute" (`tst_kiodialogs.cpp`).
- A-KD4 (L0) certificate: Return and Esc cancel; Continue answers KIO's follow-up with "Current Session only" (30 minutes),
  and with "Forever" only when "Always trust" was ticked, also when the follow-up comes late; never after Cancel or after
  another question (`tst_kioprompts.cpp`, `tst_kiodialogs.cpp`, `tst_fileskiosheets.qml`).
- A-KD3 F1 against Finder's conflict alert and certificate sheet captures.

### Known limitations
- KF6 apps other than Files keep KIO's own dialogs (inventory K8, themed by D-8); network passwords are section 5's (SC9).
- While a sheet is open, the window's menu commands and keys stay live (as with Files' other sheets, Go to Folder and the
  deletion confirmations); macOS disables them under a sheet.
- The certificate path is tested on KIO's answers (table, extension and sheet), not against a live https server with a bad
  certificate.
- A worker's message box whose job's delegate is deleted before the user answers goes unanswered, and KIO's notification
  queue then waits for it, holding the later message boxes of Files' workers (`usernotificationhandler.cpp:43-54`); KIO's
  own widget handler behaves the same way.
