# ADR-0034: Clipboard history in Search, captured and served by a native data-control helper
Status: Proposed (owner decisions of 2026-10-27, clipboard-history cloud session); accepted after the opus review PASS of
step 0 · Date: 2026-10-27 · Decider: owner

## Context
Owner brief (2026-10-27): the clipboard history of macOS 26/27 in Grassfield's Search, with the same access, presentation and
behaviour (choosing an item puts it back on the clipboard and pastes it into the frontmost app) and the same privacy
protections. Non-negotiable: a copy a password manager marks as secret (`x-kde-passwordManagerHint=secret` and equivalents)
or made while the screen is locked is never recorded; an off switch and a "clear all"; nothing leaves the machine; no
content preview in logs; a size limit per item, a count limit, bounded image thumbnails.

macOS (verified 2026-10-27; sources, measurements and what stays unverified: `docs/specs/clipboard.md`): ⌘Space then ⌘4,
or the Clipboard button to the right of the field; off until the user allows it (macOS 26.0: "Clipboard Search … Not Now /
Turn On"; macOS 27: "Allow"); System Settings > Spotlight: "Results from Clipboard", "Clipboard history is available in
Spotlight" for 30 minutes, 8 hours (default) or 7 days, and "Clear Clipboard History" (then "Clear"); in the view, the More
button holds "Clear History" and "Settings…", each row has a copy button, its menu is Paste, Copy, Delete Item; a row shows a
thumbnail with the source app's badge, the title and "Text · Copied 11:23 AM". Press sources say Return or a click pastes
into the frontmost app and the copy button only copies (one source says Spotlight only copies; the owner's brief settles it:
paste).

What Grassfield has: Search (`shell/search/`), `FocusReturn` (the window active when Search opened gets the keyboard back
when it closes), `SessionState.locked` (= `Lock.locked`: locking, locked or authenticating, `shell/security/LockController.qml:30`),
`wl-clipboard` in the package's `depends` (Search's calculator and the desktop copy with `wl-copy`). Quickshell 0.3.1's only
clipboard API is `Quickshell.clipboardText`, empty unless a Quickshell window has the keyboard (`src/core/qmlglobal.hpp:139`
at v0.3.1): it cannot watch.

Platform, read in the sources:
- Hyprland 0.56.2 (`efb5099`) exposes `zwlr_data_control_manager_v1` v2 and `ext_data_control_manager_v1` v1
  (`src/managers/ProtocolManager.cpp:202,218`) and sends the current selection to a new data-control device
  (`src/protocols/ExtDataDevice.cpp:156`). Data control is not in the list allowed to sandboxed (security-context) clients
  (`ProtocolManager.cpp:348`); any other client of the user can read the clipboard today.
- Hyprland's `send_shortcut` / `send_key_state` take a window selector (`src/config/lua/bindings/LuaBindingsDispatchers.cpp:402-440`):
  the keys go to that window's surface, then the keyboard focus goes back to the previous surface
  (`src/config/shared/actions/ConfigActions.cpp:1530`). `CSeatManager::setKeyboardFocus` does not look at the session lock,
  and the Lua API has no lock query.
- wl-clipboard 2.3.0 (Arch extra `1:2.3.0-1`): `wl-paste --watch` sets `CLIPBOARD_STATE=sensitive` when the offer lists
  `x-kde-passwordManagerHint` (presence only, `src/wl-paste.c:103`), but only after it asked the source for the data and piped
  it to the command (`wl-paste.c:316-342`); one MIME type per watcher.
- Omarchy 4 (`basecamp/omarchy@bedf37a`, `shell/plugins/clipboard/`): two `wl-paste --watch` (text, `image/png`) running a
  bash/perl/jq script per copy; history in `~/.local/state/omarchy/clipboard-history.json` (500 entries, no expiry), images in
  `clipboard-images/`; no lock check; paste with `wtype -M shift -k Insert`. Its universal paste is Ctrl+V, Ctrl+Shift+V in
  terminals (`default/hypr/bindings/clipboard.lua`). Grassfield replaces `omarchy-shell` in its session, so that history does
  not run there; Grassfield never reads Omarchy's file.
- The hint: `x-kde-passwordManagerHint` with the value `secret` (Klipper ignores such copies since 2018; KeePassXC and
  Firefox's password manager set it; 1Password for Linux according to its release notes, not verified here; Bitwarden does not,
  an open request).

## Decision
Owner decisions of 2026-10-27: (Q1) a native helper; (Q2) memory by default, the disk on opt-in; (Q3) a paste sent by
Hyprland to the remembered window only; (Q4) the macOS defaults (off until allowed, 8 hours) with the limits below.

1. **Capture and serving: `grassfield-clipboard-helper`.** One native C++17 process (`apps/clipboard-helper/`, Qt 6 Core and
   Gui, libwayland-client; precedent ADR-0025), installed to `/usr/lib/grassfield/`, started by the shell service
   `shell/services/Clipboard.qml` only while the history is on, killed with the shell (`PR_SET_PDEATHSIG`, end of stdin), at
   nice 10. It binds `ext_data_control_manager_v1` only (a compositor without it gets no history, and the view says so). It
   never reads the primary selection. On each `selection` event:
   a. it reads the offer's MIME list (at most 64 types of at most 255 bytes; more: the copy is not recorded);
   b. it drops the offer **without requesting any data** when the list has `x-kde-passwordManagerHint` (any value: the
      presence is enough, the value is never read) or `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`,
      `org.nspasteboard.AutoGeneratedType`; when the offer is its own (marker type, 4); when it is the first selection after
      a start or a resume (6);
   c. it picks one kind: files (`text/uri-list` holding only `file://` URIs), else an image (the first offered of `image/png`,
      `image/jpeg`, `image/webp`, `image/gif`, `image/bmp`, `image/tiff`), else text (`text/plain;charset=utf-8`,
      `UTF8_STRING`, `text/plain`, `STRING`, `TEXT`); anything else is not recorded. Rich text is not kept: an item is plain
      text, as macOS pastes from its history without formatting;
   d. it asks the shell (`O`, 2) and reads the data only on its answer `Y`;
   e. it reads that one type through a non-blocking pipe with a cap (text 256 KiB, files 64 KiB and 1,000 URIs, image 16 MiB)
      and a 2 s deadline; a copy over the cap or late is not recorded, never truncated. Text must decode (UTF-8; Latin-1 for
      `STRING` and `TEXT` only) and not be blank;
   f. an image is decoded only to make its thumbnail, after reading its size: at most 8,192 px a side and 64 megapixels
      (`QImageReader`, allocation limit 256 MiB); the thumbnail is at most 256 px on its long side, PNG. The original bytes are
      kept as they came, for pasting;
   g. an item with the same kind and data (SHA-256) as one in the history moves to the top with the new time instead of
      being added twice.
   Limits: 100 items and 64 MiB of item data; past either, the oldest items go. Retention (30 minutes, 8 hours, 7 days;
   default 8 hours): an older item is removed, checked every minute, at each copy and when the view opens; the age is the
   larger of the wall-clock and the boot-clock (`CLOCK_BOOTTIME`, suspend included) differences, and an item dated in the
   future is removed (a clock set back never keeps an item longer).

2. **Shell and helper.** One line protocol on stdin and stdout, fields separated by US and escaped (ADR-0025's rule), no
   other channel. Shell to helper: retention, disk store on or off, pause, resume, clear, delete an item, set the clipboard
   to an item, search, make or drop an item's preview (an image at most 1,024 px on its long side, in the runtime directory
   below, only while the preview is open), and the answer to each offer (`Y <n> <app id>` or `N <n>`). Helper to shell: an offer to decide
   (`O <n> <kind>`), item metadata (id, kind, MIME type, size, time, title: the first line cut to 200 characters with control
   characters removed, an excerpt of at most 400 characters for the text thumbnail, the thumbnail path, the source app),
   removals, "the clipboard now holds item n", search results (ids), and its state (`ok`, `unsupported`, `paused`). The full
   text stays in the helper: the search runs there (case- and accent-insensitive substring of the text and file names).
   The shell answers `Y` only while the history is on, the session is not locked (`SessionState.locked`) and the active
   window is not a password manager the session hides from screen sharing (`config/hypr/grassfield/privacy.lua`; for apps
   that set no hint, such as Bitwarden). Neither process logs content: counts, kinds, sizes and reasons only, never text, file
   names, URLs, titles or hashes.

3. **Source app.** Data control does not say which client set the selection. The shell's `Y` carries the app of the window
   active when the offer was decided (Hyprland's active window), and the row shows its icon as macOS shows the source app;
   no badge when no window was active. Known limit: a copy made by a background program is attributed to the frontmost app.

4. **Copy and paste.** To copy an item (the copy button, ⌘C, the menu's Copy) the helper becomes the clipboard owner with an
   `ext_data_control_source_v1` offering the item's types: text as the five text types above; an image as its own MIME type;
   files as `text/uri-list` and `x-special/gnome-copied-files` ("copy", never a cut: a cut item from the history is pasted as
   a copy); plus the marker type `application/x-grassfield-clipboard-item` (the item id), by which the helper knows its own
   selection (the item moves to the top, step 1g). It serves until another client takes the selection or it exits (the
   clipboard is then empty, as when any Wayland app that owns it quits).
   To paste (Return, Enter, a click, the menu's Paste): the helper copies the item; when it reports owning the selection,
   Search closes and `FocusReturn` gives the keyboard back to the window active when Search opened; once that window is
   active again (at most 1 s), the shell sends Hyprland one Lua function (`Hyprland.dispatch`, the `Zoom.js` pattern) that
   checks that the active window is still that address and only then sends it Ctrl+V, Ctrl+Shift+V when its class is a
   terminal (the class list of `config/hypr/grassfield/forwarding.lua`, one list kept equal by a test), key down then key up
   50 ms later, with `window = "address:<addr>"`. The check and the keys run in one compositor call: the keys can reach no
   other window. Nothing is sent while the session is locked, when no window was active at open (the desktop), when another
   window became active, while another full-attention shell surface is open, or after 1 s: the item then stays on the
   clipboard only. No virtual keyboard.
   Residual risk: Hyprland would still deliver a window-targeted key behind a session lock (no lock check in
   `setKeyboardFocus`); the shell never sends while it knows the session locked, so only a lock taken by another client in the
   same instant could let the chord reach the chosen window, with the chosen item; nothing leaves the window.

5. **Storage.** By default the history lives in the helper's memory; thumbnails are 0600 files in
   `$XDG_RUNTIME_DIR/grassfield/clipboard/` (0700, tmpfs: RAM), removed with their item and when the helper starts or exits.
   It is lost at logout and when the shell restarts. Opt-in `search.clipboard.keepOnDisk` (off by default; a Grassfield
   addition, macOS has no such switch): `$XDG_STATE_HOME/grassfield/clipboard/` (0700) with `index.json`
   (`{version: 1, items: [{id, kind, mime, size, copiedAt, title, app}]}`) and one `<id>.item` per item (the raw data), all
   0600, written atomically (QSaveFile), with the same limits and retention (applied again when the store is loaded). Only the
   helper reads it, with bounds: regular files of the user, opened with `O_NOFOLLOW`, mode 0600, `index.json` at most 1 MiB,
   each item at most its kind's cap; a store that breaks a rule is deleted, not read. Turning the switch off deletes the
   store at once; Clear History, turning the history off and a shorter retention apply to it too. Known limit: a deleted
   file's blocks can stay on the disk until reused (btrfs copy-on-write, SSD); Omarchy's full-disk encryption covers them at
   rest. In a dev session the store is under `Mode.stateDir`.

6. **Lock, off switch, clearing.** While `SessionState.locked` the shell sends `pause`: the helper destroys its data-control
   device, so no selection event reaches it and nothing is read; `resume` after the unlock creates it again, and the
   selection it then receives first is never recorded (it may have been copied during the lock). The view cannot open while
   locked (GF-116); items keep expiring. Turning the history off (`search.clipboard.enabled`, off by default) stops the helper
   and deletes the memory history and the disk store; turning it on starts empty, from the next copy. Clear History (the
   view's More menu) and Clear Clipboard History (Settings > Search, asks first, then writes `search.clipboard.clearedAt`, the
   pattern of `search.historyResetAt` in PR #9) delete every item, memory and disk; the current clipboard is left as it is
   (macOS clears the history, not the clipboard).

7. **Presentation and settings** (`docs/specs/clipboard.md`): the Clipboard view of Search, reached by ⌘4 (Super+4,
   forwarded as Ctrl+4, or Ctrl+4) and a Clipboard button to the right of the empty field; macOS 27's capsule and rows
   (ADR-0024); the first-use prompt; the More menu; the row menu; Delete Item and Clear History; an item preview. Settings >
   Search gets "Results from Clipboard", the retention pop-up, "Clear Clipboard History…" and "Keep clipboard history after
   logging out" (step 3, after the Settings PRs #8, #9 and #10). The keys (`search.clipboard.enabled`, `.retention`,
   `.keepOnDisk`, `.clearedAt`) come from the schema (ADR-0020) in step 1, as the shell reads them.

8. **Dev mode (ADR-0019).** Two dev plumbing variables: `CLIPBOARD_HELPER` (another helper binary) and `CLIPBOARD_DISPLAY`
   (the only Wayland display the helper may watch in a dev session). In a dev session nothing is captured unless
   `GRASSFIELD_CLIPBOARD_DISPLAY` is set: `scripts/dev/shell-run.sh` sets it to the nested socket, tests to their fake
   server's socket path; without it the view says the history is off in development and no helper starts, so no dev run can
   watch the owner's display by accident. In a real session both are inert and the helper uses the session's display.

## macOS reference
Spotlight keeps a rolling clipboard history on the Mac only, off until allowed, for 30 minutes, 8 hours or 7 days; copies an
app marks as concealed or transient (Apple's Passwords) are not kept; choosing an item pastes it into the frontmost app, the
copy button only copies; the history can be cleared from the view or from Spotlight settings.

## Alternatives rejected
- `wl-paste --watch` (Omarchy 4's model): the data of a hinted copy is requested and piped before the script can refuse it; one
  type per watcher (two watchers, and a second `wl-paste --list-types` can see a newer selection); a process chain per copy;
  `wl-copy` restores one type and leaves one forked process per item; no way to know its own copies.
- `wlr-data-control` as well: the same capabilities; the `ext` protocol is the standard one and Hyprland 0.56.2 has both.
- `Quickshell.clipboardText`: empty unless a Quickshell window has the keyboard.
- Capture inside the shell (a C++ QML plugin) or the compositor plugin: data from any app (images) decoded in the shell or
  the compositor, where a crash or a stall takes the session down; the compositor plugin is optional (D3).
- A virtual keyboard (`wtype`, `zwp_virtual_keyboard_v1`) for the paste: a new dependency, types into whatever has the
  keyboard at that moment, may raise Hyprland's keyboard permission prompt, and Shift+Insert pastes the primary selection in
  alacritty and kitty by default.
- Copy only, no paste: contradicts the brief; the press sources describe a paste.
- The disk by default: privacy first, and macOS keeping the history across a logout is not verified.
- A resident service (a systemd user unit) so that a shell restart keeps the history: a new service for a small gain; the
  opt-in store covers it.
- Recording rich text: macOS pastes from its history without formatting, and HTML can carry remote resources.

## Consequences
- New binary in `grassfield-desktop`; no new runtime dependency (Qt 6 and libwayland-client are already required) and no new
  build dependency (`wayland-scanner` comes with `wayland`, already in `makedepends`). `ext-data-control-v1.xml` is vendored
  from wayland-protocols 1.49 (MIT) under `apps/clipboard-helper/protocols/`, listed in `THIRD_PARTY.md`.
- New settings keys (4), a new state directory on opt-in (ADR-0020 table), two dev plumbing variables (ADR-0019 table).
- IPC: dev-class functions only (`clipboard status`, `search view`, the paste and offer test hooks), documented in
  `docs/specs/security.md` with their code; the Settings app clears through `search.clipboard.clearedAt`, so no action-class
  function is added.
- Tests never touch a real clipboard: the helper's logic under gtest (ASan too); the process against
  `tests/fixtures/fake-clipboard-server` (a test-only libwayland-server program offering `wl_seat` and
  `ext_data_control_manager_v1` on a socket in a `mktemp -d` runtime directory) with copies of every kind, a hinted copy
  (no receive request may reach it), a source that hangs, oversized data, the own-copy marker, pause and resume; the shell's
  decisions and the paste request under QML unit tests; a log canary. The real paste, Hyprland's data control and a lock
  during a copy are checked by the integrator in the nested session; never in the owner's session.
- Steps: 0 this ADR and the spec (docs only); 1 the helper, the fake server, the shell service and the keys; 2 the view in
  Search; 3 Settings > Search.
- Not verified: the macOS 27 clipboard view's exact look (no capture found), what macOS does at logout and when the history
  is turned off, its item limit, the Lua `address` format and the `address:` selector in Hyprland 0.56.2's Lua (nested,
  step 1).
