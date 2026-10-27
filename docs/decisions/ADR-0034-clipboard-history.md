# ADR-0034: Clipboard history in Search (macOS presentation, Windows power), served by a native data-control helper
Status: Proposed (owner decisions of 2026-10-27, clipboard-history cloud session); accepted after the opus review PASS of
step 0 · Date: 2026-10-27 · Decider: owner

## Context
Owner brief (2026-10-27): the clipboard history of macOS 26/27 in Grassfield's Search, with the same access, presentation and
behaviour (choosing an item puts it back on the clipboard and pastes it into the frontmost app) and the same privacy
protections. Non-negotiable: a copy a password manager marks as secret (`x-kde-passwordManagerHint=secret` and equivalents)
or made while the screen is locked is never recorded; an off switch and a "clear all"; nothing leaves the machine; no
content preview in logs; a size limit per item, a count limit, bounded image thumbnails. Added the same day: items can be
pinned, and the history must be as capable as Windows' clipboard history.

macOS (verified 2026-10-27; sources, measurements and what stays unverified: `docs/specs/clipboard.md`): ⌘Space then ⌘4,
or the Clipboard button to the right of the field; off until the user allows it (macOS 26.0: "Clipboard Search … Not Now /
Turn On"; macOS 27: "Allow"); System Settings > Spotlight: "Results from Clipboard", "Clipboard history is available in
Spotlight" for 30 minutes, 8 hours (default) or 7 days, and "Clear Clipboard History" (then "Clear"); in the view, the More
button holds "Clear History" and "Settings…", each row has a copy button, its menu is Paste, Copy, Delete Item; a row shows a
thumbnail with the source app's badge, the title and "Text · Copied 11:23 AM". Press sources say Return or a click pastes
into the frontmost app and the copy button only copies (one source says Spotlight only copies; the owner's brief settles it:
paste). macOS has no pinning.

Windows 11 (Microsoft Support "Clipboard in Windows", checked 2026-10-27; details in the spec): Windows key + V, "Turn on"
the first time; text, HTML and bitmap, at most 4 MB an item, the 25 latest entries, the oldest unpinned ones removed first;
pinned items are never pushed out, survive a restart (the rest of the history does not) and survive "Clear all" and
Settings > System > Clipboard > "Clear clipboard data"; an item's "See more" (…) menu has Delete and, for text, "Paste as
Text" (press sources); sync across devices through a Microsoft account; "suggested actions" (call a copied phone number,
add a copied date to a calendar) are deprecated by Microsoft.

What Grassfield has: Search (`shell/search/`), `FocusReturn` (the window active when Search opened gets the keyboard back
when it closes), `SessionState.locked` (= `Lock.locked`: locking, locked or authenticating, `shell/security/LockController.qml:30`),
`wl-clipboard` in the package's `depends` (Search's calculator and the desktop copy with `wl-copy`). Quickshell 0.3.1's only
clipboard API is `Quickshell.clipboardText`, empty unless a Quickshell window has the keyboard (`src/core/qmlglobal.hpp:139`
at v0.3.1): it cannot watch. Super+V is free in `config/hypr/grassfield/bindings.lua` (apps paste with Ctrl+V).

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
  terminals (`default/hypr/bindings/clipboard.lua`); its clipboard panel is on Super+Ctrl+V. Grassfield replaces
  `omarchy-shell` in its session, so that history does not run there; Grassfield never reads Omarchy's file.
- The hint: `x-kde-passwordManagerHint` with the value `secret` (Klipper ignores such copies since 2018; KeePassXC and
  Firefox's password manager set it; 1Password for Linux according to its release notes, not verified here; Bitwarden does not,
  an open request).

## Decision
Owner decisions of 2026-10-27, each asked with its options: (Q1) a native helper; (Q2) the history in memory by default, on
disk on opt-in; (Q3) a paste sent by Hyprland to the remembered window only; (Q4) the macOS defaults (off until allowed,
8 hours) and the limits below; then, for Windows' power: (Q5) pinned items always kept on disk; (Q6) formatting kept, with
"Paste as Plain Text"; (Q7) Super+V opens the history directly; (Q8) Windows' clearing model (clearing spares pinned items,
Settings can delete them too).

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
      `image/jpeg`, `image/webp`, `image/gif`, `image/bmp`, `image/tiff`), else text. A text item has a plain part
      (`text/plain;charset=utf-8`, `UTF8_STRING`, `text/plain`, `STRING`, `TEXT`, the first offered) and keeps the formatted
      parts offered with it (`text/html`; `text/rtf` or `application/rtf`), as Windows keeps HTML. With HTML and no plain
      type, the plain part is made from the HTML by a tag stripper in the helper (no HTML engine, nothing loaded). Anything
      else is not recorded;
   d. it asks the shell (`O`, 2) and reads the data only on its answer `Y`;
   e. it reads each chosen type through a non-blocking pipe with a cap (plain text 256 KiB, HTML 1 MiB, RTF 1 MiB, files
      64 KiB and 1,000 URIs, image 16 MiB) and a 2 s deadline per type; plain text, files or an image over the cap or late:
      the copy is not recorded, never truncated; a formatted part over its cap or late is dropped and the plain text kept.
      Text must decode (UTF-8; Latin-1 for `STRING` and `TEXT` only) and not be blank;
   f. an image is decoded only to make its thumbnail, after reading its size: at most 8,192 px a side and 64 megapixels
      (`QImageReader`, allocation limit 256 MiB); the thumbnail is at most 256 px on its long side, PNG. The original bytes are
      kept as they came, for pasting;
   g. an item with the same kind and data (SHA-256 of the plain part, the file list or the image) as an unpinned one moves to
      the top with the new time instead of being added twice; one equal to a pinned item leaves the pinned item where it is
      and adds nothing.
   Limits: the history (unpinned items) holds 100 items and 64 MiB; past either, its oldest items go. Pinned items: 50 and
   32 MiB, never pushed out and never expired; a pin past either limit is refused with a notice. Retention of unpinned items
   (30 minutes, 8 hours, 7 days; default 8 hours): an older item is removed, checked every minute, at each copy and when the
   view opens; the age is the larger of the wall-clock and the boot-clock (`CLOCK_BOOTTIME`, suspend included) differences,
   and an item dated in the future is removed (a clock set back never keeps an item longer).

2. **Shell and helper.** One line protocol on stdin and stdout, fields separated by US and escaped (ADR-0025's rule), no
   other channel. Shell to helper: retention, history store on or off, pause, resume, clear the unpinned items, clear the
   pinned items, delete an item, pin, unpin, set the clipboard to an item (with or without its formatted parts), search, make
   or drop an item's preview (an image at most 1,024 px on its long side, in the runtime directory below, only while the
   preview is open), and the answer to each offer (`Y <n> <app id>` or `N <n>`). Helper to shell: an offer to decide
   (`O <n> <kind>`), item metadata (id, kind, MIME types, size, time, pinned, formatted, title: the first line cut to 200
   characters with control characters removed, an excerpt of at most 400 characters for the text thumbnail, the thumbnail
   path, the source app), removals, "the clipboard now holds item n", search results (ids), notices (pin limit), and its state
   (`ok`, `unsupported`, `paused`). The full text stays in the helper: the search runs there (case- and accent-insensitive
   substring of the plain text and file names).
   The shell answers `Y` only while the history is on, the session is not locked (`SessionState.locked`) and the active
   window is not a password manager the session hides from screen sharing (`config/hypr/grassfield/privacy.lua`; for apps
   that set no hint, such as Bitwarden). Neither process logs content: counts, kinds, sizes and reasons only, never text, file
   names, URLs, titles or hashes.

3. **Source app.** Data control does not say which client set the selection. The shell's `Y` carries the app of the window
   active when the offer was decided (Hyprland's active window), and the row shows its icon as macOS shows the source app;
   no badge when no window was active. Known limit: a copy made by a background program is attributed to the frontmost app.

4. **Copy and paste.** To copy an item (the copy button, ⌘C, the menu's Copy) the helper becomes the clipboard owner with an
   `ext_data_control_source_v1` offering the item's types: text as the five plain types above plus its formatted parts; an
   image as its own MIME type; files as `text/uri-list` and `x-special/gnome-copied-files` ("copy", never a cut: a cut item
   from the history is pasted as a copy); plus the marker type `application/x-grassfield-clipboard-item` (the item id), by
   which the helper knows its own selection (the item moves to the top, step 1g). "Paste as Plain Text" (the menu, Shift+Return)
   offers the plain types and the marker only. The helper serves until another client takes the selection or it exits (the
   clipboard is then empty, as when any Wayland app that owns it quits).
   To paste (Return, Enter, a click, the menu's Paste; Shift+Return or the menu's Paste as Plain Text): the helper copies the
   item; when it reports owning the selection, Search closes and `FocusReturn` gives the keyboard back to the window active
   when Search opened; once that window is active again (at most 1 s), the shell sends Hyprland one Lua function
   (`Hyprland.dispatch`, the `Zoom.js` pattern) that checks that the active window is still that address and only then sends
   it Ctrl+V, Ctrl+Shift+V when its class is a terminal (the class list of `config/hypr/grassfield/forwarding.lua`, one list
   kept equal by a test), key down then key up 50 ms later, with `window = "address:<addr>"`. The check and the keys run in
   one compositor call: the keys can reach no other window. Nothing is sent while the session is locked, when no window was
   active at open (the desktop), when another window became active, while another full-attention shell surface is open, or
   after 1 s: the item then stays on the clipboard only. No virtual keyboard.
   Residual risk: Hyprland would still deliver a window-targeted key behind a session lock (no lock check in
   `setKeyboardFocus`); the shell never sends while it knows the session locked, so only a lock taken by another client in the
   same instant could let the chord reach the chosen window, with the chosen item; nothing leaves the window.

5. **Storage.** `$XDG_STATE_HOME/grassfield/clipboard/` (0700) holds up to two stores, each an `index.json`
   (`{version: 1, items: [{id, kind, mimes, size, copiedAt, pinnedAt, title, app}]}`) and one `<id>.item` per item (its parts,
   length-prefixed), all 0600, written atomically (QSaveFile):
   - `pinned/`, always (Q5, Windows' model): an item is written when it is pinned and removed when it is unpinned, deleted,
     or when the pinned items are cleared; it never expires;
   - `history/`, only with the opt-in `search.clipboard.keepOnDisk` (off by default; a Grassfield addition, macOS has no such
     switch): the unpinned items, same limits and retention (applied again when the store is loaded); turning the switch off
     deletes it at once.
   Without `history/`, unpinned items live in the helper's memory only and are lost at logout and when the shell restarts (as
   Windows loses them at a restart). Thumbnails and previews are 0600 files in `$XDG_RUNTIME_DIR/grassfield/clipboard/`
   (0700, tmpfs: RAM), removed with their item and when the helper starts or exits. Only the helper reads the stores, with
   bounds: regular files of the user, opened with `O_NOFOLLOW`, mode 0600, `index.json` at most 1 MiB, each item at most
   its kind's caps; a store that breaks a rule is deleted, not read. Known limit: a deleted file's blocks can stay on the disk
   until reused (btrfs copy-on-write, SSD); Omarchy's full-disk encryption covers them at rest. In a dev session the stores
   are under `Mode.stateDir`.

6. **Lock, off switch, clearing.** While `SessionState.locked` the shell sends `pause`: the helper destroys its data-control
   device, so no selection event reaches it and nothing is read; `resume` after the unlock creates it again, and the
   selection it then receives first is never recorded (it may have been copied during the lock). The view cannot open while
   locked (GF-116); items keep expiring.
   Clearing follows Windows (Q8): Clear History (the view's More menu) and Clear Clipboard History (Settings > Search, asks
   first, then writes `search.clipboard.clearedAt`, the pattern of `search.historyResetAt` in PR #9) delete every unpinned
   item, memory and `history/`; Settings' confirmation also offers "Also delete pinned items" (writes
   `search.clipboard.pinnedClearedAt` as well), which empties `pinned/`: that is the "clear all". Turning the history off
   (`search.clipboard.enabled`, off by default) stops the helper and deletes the unpinned items; pinned items stay in
   `pinned/`, unread and not shown, until the history is turned on again (or deleted from Settings: with the history off,
   the shell runs the helper once with `--clear-pinned`). The current clipboard is left as it is (both systems clear the
   history, not the clipboard).

7. **Presentation and settings** (`docs/specs/clipboard.md`): the Clipboard view of Search, reached by ⌘4 (Super+4,
   forwarded as Ctrl+4, or Ctrl+4), a Clipboard button to the right of the empty field, and Super+V from anywhere (Q7,
   Windows' Win+V: `bindings.lua` calls the action-class IPC function `search clipboard`, which opens Search in that view or
   closes it); macOS 27's capsule and rows (ADR-0024); pinned items first, with a pin mark, then the history newest first; a
   pin button and a copy button on each row; the first-use prompt; the More menu; the row menu (Paste, Paste as Plain Text,
   Copy, Pin or Unpin, Delete Item); an item preview. Settings > Search gets "Results from Clipboard", the retention pop-up,
   "Clear Clipboard History…" (with "Also delete pinned items") and "Keep clipboard history after logging out" (step 3, after
   the Settings PRs #8, #9 and #10). The keys (`search.clipboard.enabled`, `.retention`, `.keepOnDisk`, `.clearedAt`,
   `.pinnedClearedAt`) come from the schema (ADR-0020) in step 1, as the shell reads them.

8. **Dev mode (ADR-0019).** Two dev plumbing variables: `CLIPBOARD_HELPER` (another helper binary) and `CLIPBOARD_DISPLAY`
   (the only Wayland display the helper may watch in a dev session). In a dev session nothing is captured unless
   `GRASSFIELD_CLIPBOARD_DISPLAY` is set: `scripts/dev/shell-run.sh` sets it to the nested socket, tests to their fake
   server's socket path; without it the view says the history is off in development and no helper starts, so no dev run can
   watch the owner's display by accident. In a real session both are inert and the helper uses the session's display.

## macOS reference
Spotlight keeps a rolling clipboard history on the Mac only, off until allowed, for 30 minutes, 8 hours or 7 days; copies an
app marks as concealed or transient (Apple's Passwords) are not kept; choosing an item pastes it into the frontmost app, the
copy button only copies; the history can be cleared from the view or from Spotlight settings.

## Windows reference
Win+V opens the history anywhere; text, HTML and bitmaps up to 4 MB, 25 entries; pinned items stay through restarts and
"Clear all"; an item can be deleted or pasted as text; sync goes through a Microsoft account. Grassfield takes the access key,
the pins, the formats and Paste as Plain Text, with larger limits; it keeps everything on the machine.

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
- The whole history on disk by default: privacy first, and macOS keeping the history across a logout is not verified.
- Pinned items in memory only, or on disk only with the opt-in switch: a pin that vanishes at logout is not Windows' pin
  (owner, Q5).
- Plain text only (macOS): less than Windows, which keeps HTML (owner, Q6). The preview never renders HTML.
- Sync across devices (Windows): nothing leaves the machine (brief, non-negotiable).
- Suggested actions on a copied phone number or date (Windows): deprecated by Microsoft; Search already offers commands.
- Super+Ctrl+V (Omarchy's clipboard panel key) or no direct key: Super+V is Windows' key and free here (owner, Q7).
- A resident service (a systemd user unit) so that a shell restart keeps the history: a new service for a small gain; the
  opt-in store covers it.

## Consequences
- New binary in `grassfield-desktop`; no new runtime dependency (Qt 6 and libwayland-client are already required) and no new
  build dependency (`wayland-scanner` comes with `wayland`, already in `makedepends`). `ext-data-control-v1.xml` is vendored
  from wayland-protocols 1.49 (MIT) under `apps/clipboard-helper/protocols/`, listed in `THIRD_PARTY.md`.
- New settings keys (5), a state directory with an always-on pinned store and an opt-in history store (ADR-0020 table), two
  dev plumbing variables (ADR-0019 table), one binding (Super+V, with its Settings > Keyboard description in
  `apps/settings/qml/Bindings.js` and the French catalog).
- IPC, documented in `docs/specs/security.md` with its code: one action-class function, `search clipboard` (Super+V; opens or
  closes the view, returns nothing), and dev-class functions (`clipboard status`, `search view`, the paste and offer test
  hooks). The Settings app clears through `search.clipboard.clearedAt` and `.pinnedClearedAt`.
- Tests never touch a real clipboard: the helper's logic under gtest (ASan too); the process against
  `tests/fixtures/fake-clipboard-server` (a test-only libwayland-server program offering `wl_seat` and
  `ext_data_control_manager_v1` on a socket in a `mktemp -d` runtime directory) with copies of every kind, HTML with and
  without plain text, a hinted copy (no receive request may reach it), a source that hangs, oversized data, the own-copy
  marker, pins across a restart of the helper, pause and resume; the shell's decisions and the paste request under QML unit
  tests; a log canary. The real paste, Hyprland's data control and a lock during a copy are checked by the integrator in the
  nested session; never in the owner's session.
- Steps: 0 this ADR and the spec (docs only); 1 the helper, the fake server, the shell service and the keys; 2 the view in
  Search and Super+V; 3 Settings > Search.
- Not verified: the macOS 27 clipboard view's exact look (no capture found), what macOS does at logout and when the history
  is turned off, its item limit; Windows' keyboard keys inside Win+V; the Lua `address` format and the `address:` selector in
  Hyprland 0.56.2's Lua (nested, step 1).
