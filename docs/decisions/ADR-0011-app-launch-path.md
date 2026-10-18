# ADR-0011: One app launch path, isolated in dev sessions
Status: Proposed (applied provisionally) · Date: 2026-10-17 · Decider: owner

## Context
The Dock, Apps, Search, the menu bar's app menus, the Dock menu and the desktop each started applications
their own way (`DesktopEntry.execute()`, `Quickshell.execDetached`, `gio open`). In a dev session (nested
Hyprland on the owner's machine, `GRASSFIELD_DEV=1`) an app started by the shell runs with the owner's real
profiles: a reviewer's mis-click started Chromium with the owner's default profile and Nautilus on the real
home folder (STATE.md incident, 2026-10-17). Several modules need the same rule, so it is a cross-module
contract.

## Options
1. **One launch service in `shell/services/Apps.qml`**: `Apps.launch(entry|action)` for desktop entries,
   `Apps.openDetached(argv)` for helpers that open files in an app (`gio open`, `xdg-open`, `gtk-launch`),
   `Apps.openEnvironment()` for `Process` objects. In a dev session they add isolated `XDG_CONFIG_HOME`,
   `XDG_CACHE_HOME`, `XDG_STATE_HOME` (and `XDG_DATA_HOME`) under `.dev/apps-home`; otherwise they call the
   unmodified Quickshell API.
2. Isolate the whole nested session (a separate `HOME` for the nested compositor). Pros: complete.
   Cons: the shell itself must read the repository and `.dev/` paths; Wayland/D-Bus sockets and fonts break in
   subtle ways; diverges further from the real session.
3. Per-module guards. Cons: easy to miss one caller (the review found two).

## Decision (proposed)
Option 1. Every shell module that starts an application or opens a file in one goes through `Apps.launch`,
`Apps.openDetached` or `Apps.openEnvironment`. Direct `Quickshell.execDetached` remains allowed only for
non-app helpers (`cp`, `wl-copy`, `systemctl`, `kill`, `gio trash`) and shell-internal commands.
- Dev detection: `GRASSFIELD_DEV === "1"` only. In a real session the user's environment passes through
  untouched (no variable added or removed).
- Field codes are stripped (`AppLaunch.stripFieldCodes`); `Terminal=true` entries go through `xdg-terminal-exec`,
  as `DesktopEntry.execute()` does.

## Evidence
- Merge bc382c6: a foot started from the nested Dock had `XDG_CONFIG_HOME=.dev/apps-home/config` (and cache,
  state) in `/proc/<pid>/environ`; reviewer confirmed, and confirmed by code reading that real sessions are
  untouched (`shell/services/Apps.qml`).
- Review gaps (Trash tile, network settings, `XDG_DATA_HOME`) are in the fix pass after that review.

## Consequences
- New launch call sites must use the service; reviewers check `Quickshell.execDetached` additions against the
  allowed list above.
- Dev sessions never share app profiles with the owner; app state for dev runs lives in `.dev/apps-home`.
- The real trash is never reachable from a dev session. The Dock Trash tile opens the isolated folder
  `.dev/apps-home/data/Trash/files` as a plain directory (`gio open <path>`), never `trash:///` (served by the
  owner's gvfsd-trash). Grassfield Files (which inherits `GRASSFIELD_DEV=1`) hides its Trash sidebar entry, does not
  open the KIO `trash:/` listing and makes Empty Trash a no-op in dev (simplest safe option; no isolated Trash
  location in Files). Real sessions keep `trash:///` and the Trash place unchanged.

### Addendum: dev open policy and private bus default (counter-review fix)
The first fix still let a dev session escape: `gio open <isolated trash folder>` runs the default folder handler, which
is Nautilus (`DBusActivatable=true`); GIO starts it over D-Bus, dropping the isolated environment, in the owner's
session, with the owner's real trash in its sidebar. Any D-Bus activatable handler does the same.
- A dev session never asks GIO, xdg-open, `gtk-launch` or `gio launch` to start an application. `Apps.openDetached`
  recognises those helpers (`AppLaunch.openRequest`) and runs `scripts/dev/open-policy.sh` instead: a folder opens in
  Grassfield Files and a file Preview can show (images, PDF, text and code, audio, video) in Grassfield Preview, both by
  direct exec through `isolated.sh` (isolated homes and `GRASSFIELD_DEV=1`); anything else is refused with one line
  (`open refused in dev: <type>`, also in `.dev/open-policy.log`). Real sessions keep `gio open` unchanged.
- Code that runs `gio open` itself in a `Process` (`shell/desktop/DesktopFiles.qml`, which another change owns) gets the
  same policy: `shell-run.sh` puts `scripts/dev/open-shims` (`gio`, `xdg-open`, `gtk-launch`) first on the shell's PATH
  (QProcess resolves a program on its parent's PATH, not on the PATH set in the Process environment); the shim applies
  the policy to `open`/`launch` and runs the real `gio` for the other subcommands.
- The private D-Bus session bus is the default for dev sessions (`nested-up.sh`, `shell-run.sh`; `--session-bus` is
  the opt-out for the rare test that needs the owner's bus). Its dbus-daemon starts with the isolated `XDG_*` homes under
  `.dev/apps-home` and `GRASSFIELD_DEV=1`, so a service the bus activates is isolated too.
- `isolated.sh` exports `GRASSFIELD_DEV=1`, so Grassfield Files started through it hides its Trash place, and in a dev
  session also the "Empty Trash" action (no confirmation that does nothing).
